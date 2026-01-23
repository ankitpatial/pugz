//! Pugz Build Step - Compile .pug templates to Zig code at build time.
//!
//! This module transforms .pug template files into native Zig functions during the build process.
//! The generated code runs ~3x faster than interpreted templates by eliminating runtime parsing.
//!
//! ## Architecture
//!
//! The compilation pipeline:
//! 1. `compileTemplates()` - Entry point, creates a build step that produces a Zig module
//! 2. `CompileTemplatesStep` - Build step that orchestrates template discovery and compilation
//! 3. `findTemplates()` - Recursively walks source_dir to find all .pug files
//! 4. `generateSingleFile()` - Creates generated.zig with helper functions and all templates
//! 5. `Compiler` - Core compiler that transforms AST nodes into Zig code
//!
//! ## Generated Output
//!
//! The generated.zig file contains:
//! - Shared helpers: `esc()` (HTML escaping), `truthy()` (boolean coercion), `strVal()` (type conversion)
//! - One public function per template, named after the file path (e.g., pages/home.pug -> pages_home())
//! - Static string merging for consecutive literals (reduces allocations)
//! - Zero-allocation rendering for fully static templates
//!
//! ## Usage in build.zig:
//! ```zig
//! const build_templates = @import("pugz").build_templates;
//! const templates = build_templates.compileTemplates(b, .{
//!     .source_dir = "views",
//! });
//! exe.root_module.addImport("templates", templates);
//! ```
//!
//! ## Usage in code:
//! ```zig
//! const tpls = @import("templates");
//! const html = try tpls.home(allocator, .{ .title = "Welcome" });
//! ```

const std = @import("std");
const lexer_mod = @import("lexer.zig");
const Lexer = lexer_mod.Lexer;
const Diagnostic = lexer_mod.Diagnostic;
const Parser = @import("parser.zig").Parser;
const ast = @import("ast.zig");

pub const Options = struct {
    /// Root directory containing .pug template files (searched recursively)
    source_dir: []const u8 = "views",
    /// File extension for template files
    extension: []const u8 = ".pug",
};

/// Creates a build module containing compiled templates.
/// Call this from build.zig to integrate template compilation into your build.
/// Returns a module that can be imported as "templates" (or any name you choose).
pub fn compileTemplates(b: *std.Build, options: Options) *std.Build.Module {
    const step = CompileTemplatesStep.create(b, options);
    return b.createModule(.{
        .root_source_file = step.getOutput(),
    });
}

/// Build step that discovers and compiles all .pug templates in source_dir.
/// Outputs a single generated.zig file containing all template functions.
const CompileTemplatesStep = struct {
    step: std.Build.Step,
    options: Options,
    generated_file: std.Build.GeneratedFile,

    fn create(b: *std.Build, options: Options) *CompileTemplatesStep {
        const self = b.allocator.create(CompileTemplatesStep) catch @panic("pugz failed on CompileTemplatesStep");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "pugz-compile-templates",
                .owner = b,
                .makeFn = make,
            }),
            .options = options,
            .generated_file = .{ .step = &self.step },
        };
        return self;
    }

    fn getOutput(self: *CompileTemplatesStep) std.Build.LazyPath {
        return .{ .generated = .{ .file = &self.generated_file } };
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
        const self: *CompileTemplatesStep = @fieldParentPtr("step", step);
        const b = step.owner;
        const allocator = b.allocator;

        var templates = std.ArrayList(TemplateInfo){};
        defer templates.deinit(allocator);

        try findTemplates(allocator, self.options.source_dir, "", self.options.extension, &templates);

        const out_path = try std.fs.path.join(allocator, &.{ self.options.source_dir, "generated.zig" });
        try generateSingleFile(
            allocator,
            self.options.source_dir,
            self.options.extension,
            out_path,
            templates.items,
        );

        self.generated_file.path = out_path;
    }
};

/// Metadata for a discovered template file
const TemplateInfo = struct {
    /// Path relative to source_dir (e.g., "pages/home.pug")
    rel_path: []const u8,
    /// Valid Zig identifier derived from path (e.g., "pages_home")
    zig_name: []const u8,
};

/// Recursively walks source_dir to discover all .pug template files.
/// Populates the templates list with path and generated function name for each file.
fn findTemplates(
    allocator: std.mem.Allocator,
    source_dir: []const u8,
    out_path: []const u8,
    extension: []const u8,
    templates: *std.ArrayList(TemplateInfo),
) !void {
    const full_path = if (out_path.len > 0)
        try std.fs.path.join(allocator, &.{ source_dir, out_path })
    else
        try allocator.dupe(u8, source_dir);
    defer allocator.free(full_path);

    var dir = std.fs.cwd().openDir(full_path, .{ .iterate = true }) catch |err| {
        std.log.warn("Cannot open directory {s}: {}", .{ full_path, err });
        return;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const name = try allocator.dupe(u8, entry.name);
        if (entry.kind == .directory) {
            const new_sub = if (out_path.len > 0)
                try std.fs.path.join(allocator, &.{ out_path, name })
            else
                name;
            try findTemplates(allocator, source_dir, new_sub, extension, templates);
        } else if (entry.kind == .file and std.mem.endsWith(u8, name, extension)) {
            const rel_path = if (out_path.len > 0)
                try std.fs.path.join(allocator, &.{ out_path, name })
            else
                name;

            const without_ext = rel_path[0 .. rel_path.len - extension.len];
            const zig_name = try pathToIdent(allocator, without_ext);

            try templates.append(allocator, .{
                .rel_path = rel_path,
                .zig_name = zig_name,
            });
        }
    }
}

/// Converts a file path to a valid Zig identifier.
/// Replaces path separators and special chars with underscores.
/// Prefixes with '_' if the path starts with a digit.
fn pathToIdent(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return try allocator.alloc(u8, 0);

    const first_char = path[0];
    const needs_prefix = !std.ascii.isAlphabetic(first_char) and first_char != '_';

    const result_len = if (needs_prefix) path.len + 1 else path.len;
    var result = try allocator.alloc(u8, result_len);

    const offset: usize = if (needs_prefix) blk: {
        result[0] = '_';
        break :blk 1;
    } else 0;

    for (path, 0..) |c, i| {
        result[i + offset] = switch (c) {
            '/', '\\', '-', '.' => '_',
            else => c,
        };
    }

    return result;
}

/// Block content from child template, used during inheritance resolution.
/// Stores the mode (replace/append/prepend) and child nodes.
const BlockDef = struct {
    mode: ast.Block.Mode,
    children: []const ast.Node,
};

/// Generates the complete generated.zig file containing all compiled templates.
/// Writes helper functions at the top, followed by each template as a public function.
fn generateSingleFile(
    allocator: std.mem.Allocator,
    source_dir: []const u8,
    extension: []const u8,
    out_path: []const u8,
    templates: []const TemplateInfo,
) !void {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    const w = out.writer(allocator);

    // Header
    try w.writeAll(
        \\//! Auto-generated by pugz.compileTemplates()
        \\//! Do not edit manually - regenerate by running: zig build
        \\
        \\const std = @import("std");
        \\const Allocator = std.mem.Allocator;
        \\const ArrayList = std.ArrayList(u8);
        \\
        \\// ─────────────────────────────────────────────────────────────────────────────
        \\// Helpers
        \\// ─────────────────────────────────────────────────────────────────────────────
        \\
        \\const esc_lut: [256]?[]const u8 = blk: {
        \\    var t: [256]?[]const u8 = .{null} ** 256;
        \\    t['&'] = "&amp;";
        \\    t['<'] = "&lt;";
        \\    t['>'] = "&gt;";
        \\    t['"'] = "&quot;";
        \\    t['\''] = "&#x27;";
        \\    break :blk t;
        \\};
        \\
        \\fn esc(o: *ArrayList, a: Allocator, s: []const u8) Allocator.Error!void {
        \\    var i: usize = 0;
        \\    for (s, 0..) |c, j| {
        \\        if (esc_lut[c]) |e| {
        \\            if (j > i) try o.appendSlice(a, s[i..j]);
        \\            try o.appendSlice(a, e);
        \\            i = j + 1;
        \\        }
        \\    }
        \\    if (i < s.len) try o.appendSlice(a, s[i..]);
        \\}
        \\
        \\fn truthy(v: anytype) bool {
        \\    return switch (@typeInfo(@TypeOf(v))) {
        \\        .bool => v,
        \\        .optional => v != null,
        \\        .pointer => |p| if (p.size == .slice) v.len > 0 else true,
        \\        .int, .comptime_int => v != 0,
        \\        else => true,
        \\    };
        \\}
        \\
        \\var int_buf: [32]u8 = undefined;
        \\
        \\fn strVal(v: anytype) []const u8 {
        \\    const T = @TypeOf(v);
        \\    switch (@typeInfo(T)) {
        \\        .pointer => |p| switch (p.size) {
        \\            .slice => return v,
        \\            .one => {
        \\                // For pointer-to-array, slice it
        \\                const child_info = @typeInfo(p.child);
        \\                if (child_info == .array) {
        \\                    const arr_info = child_info.array;
        \\                    const ptr: [*]const arr_info.child = @ptrCast(v);
        \\                    return ptr[0..arr_info.len];
        \\                }
        \\                return strVal(v.*);
        \\            },
        \\            else => @compileError("unsupported pointer type"),
        \\        },
        \\        .array => @compileError("arrays must be passed by pointer"),
        \\        .int, .comptime_int => return std.fmt.bufPrint(&int_buf, "{d}", .{v}) catch "0",
        \\        .optional => return if (v) |val| strVal(val) else "",
        \\        else => @compileError("strVal: unsupported type " ++ @typeName(T)),
        \\    }
        \\}
        \\
        \\// ─────────────────────────────────────────────────────────────────────────────
        \\// Templates
        \\// ─────────────────────────────────────────────────────────────────────────────
        \\
        \\
    );

    // Generate each template
    for (templates) |tpl| {
        const src_path = try std.fs.path.join(allocator, &.{ source_dir, tpl.rel_path });
        defer allocator.free(src_path);

        const source = std.fs.cwd().readFileAlloc(allocator, src_path, 5 * 1024 * 1024) catch |err| {
            std.log.err("Failed to read {s}: {}", .{ src_path, err });
            return err;
        };
        defer allocator.free(source);

        compileTemplate(allocator, w, source_dir, extension, tpl.zig_name, source) catch |err| {
            std.log.err("Failed to compile template {s}: {}", .{ tpl.rel_path, err });
            return err;
        };
    }

    // Template names list
    try w.writeAll("pub const template_names = [_][]const u8{\n");
    for (templates) |tpl| {
        try w.print("    \"{s}\",\n", .{tpl.zig_name});
    }
    try w.writeAll("};\n");

    const file = try std.fs.cwd().createFile(out_path, .{});
    defer file.close();
    try file.writeAll(out.items);
}

/// Logs a diagnostic error with file location in compiler-style format.
fn logDiagnostic(file_path: []const u8, diag: Diagnostic) void {
    std.log.err("{s}:{d}:{d}: {s}", .{ file_path, diag.line, diag.column, diag.message });
    if (diag.source_line) |src_line| {
        std.log.err("  | {s}", .{src_line});
    }
    if (diag.suggestion) |hint| {
        std.log.err("  = hint: {s}", .{hint});
    }
}

/// Compiles a single .pug template into a Zig function.
/// Handles three cases:
/// - Empty templates: return ""
/// - Static-only templates: return literal string (zero allocation)
/// - Dynamic templates: use ArrayList and return o.items
fn compileTemplate(
    allocator: std.mem.Allocator,
    w: std.ArrayList(u8).Writer,
    source_dir: []const u8,
    extension: []const u8,
    name: []const u8,
    source: []const u8,
) !void {
    var lexer = Lexer.init(allocator, source);
    defer lexer.deinit();
    const tokens = lexer.tokenize() catch |err| {
        if (lexer.getDiagnostic()) |diag| {
            logDiagnostic(name, diag);
        } else {
            std.log.err("Tokenize error in '{s}': {}", .{ name, err });
        }
        return err;
    };

    var parser = Parser.initWithSource(allocator, tokens, source);
    const doc = parser.parse() catch |err| {
        if (parser.getDiagnostic()) |diag| {
            logDiagnostic(name, diag);
        } else {
            std.log.err("Parse error in '{s}': {}", .{ name, err });
        }
        return err;
    };

    var compiler = Compiler.init(allocator, w, source_dir, extension);

    // Resolve extends/block inheritance chain before emission
    const resolved_nodes = try compiler.resolveInheritance(doc);

    // Determine template characteristics for optimal code generation
    var has_content = false;
    for (resolved_nodes) |node| {
        if (nodeHasOutput(node)) {
            has_content = true;
            break;
        }
    }

    var has_dynamic = false;
    for (resolved_nodes) |node| {
        if (nodeHasDynamic(node)) {
            has_dynamic = true;
            break;
        }
    }

    // Generate function signature: pub fn name(a: Allocator, d: anytype) ![]u8
    try w.print("pub fn {s}(a: Allocator, d: anytype) Allocator.Error![]u8 {{\n", .{name});

    if (!has_content) {
        // Empty template (e.g., mixin-only files)
        try w.writeAll("    _ = .{ a, d };\n");
        try w.writeAll("    return \"\";\n");
    } else if (!has_dynamic) {
        // Static-only: return string literal directly, no heap allocation needed
        try w.writeAll("    _ = .{ a, d };\n");
        try w.writeAll("    return ");
        for (resolved_nodes) |node| {
            try compiler.emitNode(node);
        }
        try compiler.flushAsReturn();
    } else {
        // Dynamic: build output incrementally with ArrayList
        try w.writeAll("    var o: ArrayList = .empty;\n");

        for (resolved_nodes) |node| {
            try compiler.emitNode(node);
        }
        try compiler.flush();

        // Suppress unused parameter warning if data wasn't accessed
        if (!compiler.uses_data) {
            try w.writeAll("    _ = d;\n");
        }

        try w.writeAll("    return o.items;\n");
    }

    try w.writeAll("}\n\n");
}

/// Checks if a node produces any HTML output (used to detect empty templates)
fn nodeHasOutput(node: ast.Node) bool {
    return switch (node) {
        .doctype, .element, .text, .raw_text, .comment => true,
        .conditional => |c| blk: {
            for (c.branches) |br| {
                for (br.children) |child| {
                    if (nodeHasOutput(child)) break :blk true;
                }
            }
            break :blk false;
        },
        .each => |e| blk: {
            for (e.children) |child| {
                if (nodeHasOutput(child)) break :blk true;
            }
            break :blk false;
        },
        .case => |c| blk: {
            for (c.whens) |when| {
                for (when.children) |child| {
                    if (nodeHasOutput(child)) break :blk true;
                }
            }
            for (c.default_children) |child| {
                if (nodeHasOutput(child)) break :blk true;
            }
            break :blk false;
        },
        .mixin_call => true, // Mixin calls may produce output
        .block => |b| blk: {
            for (b.children) |child| {
                if (nodeHasOutput(child)) break :blk true;
            }
            break :blk false;
        },
        .include => true, // Includes may produce output
        .document => |d| blk: {
            for (d.nodes) |child| {
                if (nodeHasOutput(child)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// Checks if a node contains dynamic content requiring runtime evaluation
/// (interpolation, conditionals, loops, mixin calls)
fn nodeHasDynamic(node: ast.Node) bool {
    return switch (node) {
        .element => |e| blk: {
            if (e.buffered_code != null) break :blk true;
            if (e.inline_text) |segs| {
                for (segs) |seg| {
                    if (seg != .literal) break :blk true;
                }
            }
            for (e.children) |child| {
                if (nodeHasDynamic(child)) break :blk true;
            }
            break :blk false;
        },
        .text => |t| blk: {
            for (t.segments) |seg| {
                if (seg != .literal) break :blk true;
            }
            break :blk false;
        },
        .conditional, .each, .case => true,
        .mixin_call => true, // Mixin calls are dynamic
        .block => |b| blk: {
            for (b.children) |child| {
                if (nodeHasDynamic(child)) break :blk true;
            }
            break :blk false;
        },
        .include => true, // Includes may have dynamic content
        .document => |d| blk: {
            for (d.nodes) |child| {
                if (nodeHasDynamic(child)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// Checks if a mixin body references `attributes` (for &attributes pass-through).
/// Used to avoid emitting unused mixin_attrs struct in generated code.
fn mixinUsesAttributes(nodes: []const ast.Node) bool {
    for (nodes) |node| {
        switch (node) {
            .element => |e| {
                // Check spread_attributes field
                if (e.spread_attributes != null) return true;

                // Check attribute values for 'attributes' reference
                for (e.attributes) |attr| {
                    if (attr.value) |val| {
                        if (exprReferencesAttributes(val)) return true;
                    }
                }

                // Check inline text for interpolated attributes reference
                if (e.inline_text) |segs| {
                    if (textSegmentsReferenceAttributes(segs)) return true;
                }

                // Check buffered code
                if (e.buffered_code) |bc| {
                    if (exprReferencesAttributes(bc.expression)) return true;
                }

                // Recurse into children
                if (mixinUsesAttributes(e.children)) return true;
            },
            .text => |t| {
                if (textSegmentsReferenceAttributes(t.segments)) return true;
            },
            .conditional => |c| {
                for (c.branches) |br| {
                    if (mixinUsesAttributes(br.children)) return true;
                }
            },
            .each => |e| {
                if (mixinUsesAttributes(e.children)) return true;
                if (mixinUsesAttributes(e.else_children)) return true;
            },
            .case => |c| {
                for (c.whens) |when| {
                    if (mixinUsesAttributes(when.children)) return true;
                }
                if (mixinUsesAttributes(c.default_children)) return true;
            },
            .block => |b| {
                if (mixinUsesAttributes(b.children)) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Checks if an expression string references 'attributes' (e.g., "attributes.class").
fn exprReferencesAttributes(expr: []const u8) bool {
    // Check for 'attributes' as standalone or prefix (attributes.class, attributes.id, etc.)
    if (std.mem.startsWith(u8, expr, "attributes")) {
        // Must be exactly "attributes" or "attributes." followed by more
        if (expr.len == 10) return true; // exactly "attributes"
        if (expr.len > 10 and expr[10] == '.') return true; // "attributes.something"
    }
    return false;
}

/// Checks if text segments contain interpolations referencing 'attributes'.
fn textSegmentsReferenceAttributes(segs: []const ast.TextSegment) bool {
    for (segs) |seg| {
        switch (seg) {
            .interp_escaped, .interp_unescaped => |expr| {
                if (exprReferencesAttributes(expr)) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Zig reserved keywords - field names matching these must be escaped with @"..."
/// when used in generated code (e.g., @"type" instead of type)
const zig_keywords = std.StaticStringMap(void).initComptime(.{
    .{ "addrspace", {} },
    .{ "align", {} },
    .{ "allowzero", {} },
    .{ "and", {} },
    .{ "anyframe", {} },
    .{ "anytype", {} },
    .{ "asm", {} },
    .{ "async", {} },
    .{ "await", {} },
    .{ "break", {} },
    .{ "callconv", {} },
    .{ "catch", {} },
    .{ "comptime", {} },
    .{ "const", {} },
    .{ "continue", {} },
    .{ "defer", {} },
    .{ "else", {} },
    .{ "enum", {} },
    .{ "errdefer", {} },
    .{ "error", {} },
    .{ "export", {} },
    .{ "extern", {} },
    .{ "false", {} },
    .{ "fn", {} },
    .{ "for", {} },
    .{ "if", {} },
    .{ "inline", {} },
    .{ "linksection", {} },
    .{ "noalias", {} },
    .{ "noinline", {} },
    .{ "nosuspend", {} },
    .{ "null", {} },
    .{ "opaque", {} },
    .{ "or", {} },
    .{ "orelse", {} },
    .{ "packed", {} },
    .{ "pub", {} },
    .{ "resume", {} },
    .{ "return", {} },
    .{ "struct", {} },
    .{ "suspend", {} },
    .{ "switch", {} },
    .{ "test", {} },
    .{ "threadlocal", {} },
    .{ "true", {} },
    .{ "try", {} },
    .{ "type", {} },
    .{ "undefined", {} },
    .{ "union", {} },
    .{ "unreachable", {} },
    .{ "usingnamespace", {} },
    .{ "var", {} },
    .{ "volatile", {} },
    .{ "while", {} },
});

/// Escapes identifier if it's a Zig keyword by wrapping in @"..."
fn escapeIdent(ident: []const u8, buf: []u8) []const u8 {
    if (zig_keywords.has(ident)) {
        return std.fmt.bufPrint(buf, "@\"{s}\"", .{ident}) catch ident;
    }
    return ident;
}

/// Core compiler that transforms AST nodes into Zig source code.
/// Maintains state for:
/// - Static string buffering (merges consecutive literals into single appendSlice)
/// - Loop variable tracking (to distinguish loop vars from data fields)
/// - Mixin parameter tracking (for proper scoping)
/// - Template inheritance (blocks from child templates)
/// - Mixin definitions (collected during parsing for later calls)
const Compiler = struct {
    allocator: std.mem.Allocator,
    writer: std.ArrayList(u8).Writer,
    source_dir: []const u8,
    extension: []const u8,
    buf: std.ArrayList(u8), // Accumulates static strings for batch output
    depth: usize, // Current indentation level in generated code
    loop_vars: std.ArrayList([]const u8), // Active loop variable names (for each loops)
    mixin_params: std.ArrayList([]const u8), // Current mixin's parameter names
    mixins: std.StringHashMap(ast.MixinDef), // All discovered mixin definitions
    blocks: std.StringHashMap(BlockDef), // Child template block overrides
    uses_data: bool, // True if template accesses the data parameter 'd'
    mixin_depth: usize, // Nesting level for generating unique mixin variable names
    current_attrs_var: ?[]const u8, // Variable name for current mixin's &attributes

    fn init(
        allocator: std.mem.Allocator,
        writer: std.ArrayList(u8).Writer,
        source_dir: []const u8,
        extension: []const u8,
    ) Compiler {
        return .{
            .allocator = allocator,
            .writer = writer,
            .source_dir = source_dir,
            .extension = extension,
            .buf = .{},
            .depth = 1,
            .loop_vars = .{},
            .mixin_params = .{},
            .mixins = std.StringHashMap(ast.MixinDef).init(allocator),
            .blocks = std.StringHashMap(BlockDef).init(allocator),
            .uses_data = false,
            .mixin_depth = 0,
            .current_attrs_var = null,
        };
    }

    /// Resolves template inheritance chain (extends keyword).
    /// Walks up the inheritance chain collecting blocks, then returns the root template's nodes.
    /// Block overrides are stored in self.blocks and applied during emitBlock().
    fn resolveInheritance(self: *Compiler, doc: ast.Document) ![]const ast.Node {
        try self.collectMixins(doc.nodes);

        if (doc.extends_path) |extends_path| {
            // Child template: collect its block overrides
            try self.collectBlocks(doc.nodes);

            // Load parent and recursively resolve (parent may also extend)
            const parent_doc = try self.loadTemplate(extends_path);
            try self.collectMixins(parent_doc.nodes);
            return try self.resolveInheritance(parent_doc);
        }

        // Root template: return its nodes (blocks resolved during emission)
        return doc.nodes;
    }

    /// Recursively collects all mixin definitions from the AST.
    /// Mixins can be defined anywhere in a template (top-level or nested).
    fn collectMixins(self: *Compiler, nodes: []const ast.Node) !void {
        for (nodes) |node| {
            switch (node) {
                .mixin_def => |def| try self.mixins.put(def.name, def),
                .element => |e| try self.collectMixins(e.children),
                .conditional => |c| {
                    for (c.branches) |br| try self.collectMixins(br.children);
                },
                .each => |e| {
                    try self.collectMixins(e.children);
                    try self.collectMixins(e.else_children);
                },
                .block => |b| try self.collectMixins(b.children),
                else => {},
            }
        }
    }

    /// Collects block definitions from a child template for inheritance.
    /// These override or extend the parent template's blocks.
    fn collectBlocks(self: *Compiler, nodes: []const ast.Node) !void {
        for (nodes) |node| {
            switch (node) {
                .block => |blk| {
                    try self.blocks.put(blk.name, .{
                        .mode = blk.mode,
                        .children = blk.children,
                    });
                },
                .element => |e| {
                    try self.collectBlocks(e.children);
                },
                .conditional => |c| {
                    for (c.branches) |br| {
                        try self.collectBlocks(br.children);
                    }
                },
                .each => |e| {
                    try self.collectBlocks(e.children);
                },
                else => {},
            }
        }
    }

    /// Loads and parses a template file by path (for extends/include).
    /// Path can be with or without extension.
    fn loadTemplate(self: *Compiler, path: []const u8) !ast.Document {
        const full_path = blk: {
            if (std.mem.endsWith(u8, path, self.extension)) {
                break :blk try std.fs.path.join(self.allocator, &.{ self.source_dir, path });
            } else {
                const with_ext = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ path, self.extension });
                defer self.allocator.free(with_ext);
                break :blk try std.fs.path.join(self.allocator, &.{ self.source_dir, with_ext });
            }
        };
        defer self.allocator.free(full_path);

        const source = std.fs.cwd().readFileAlloc(self.allocator, full_path, 5 * 1024 * 1024) catch |err| {
            std.log.err("Failed to load template '{s}': {}", .{ full_path, err });
            return err;
        };

        var lexer = Lexer.init(self.allocator, source);
        const tokens = lexer.tokenize() catch |err| {
            if (lexer.getDiagnostic()) |diag| {
                logDiagnostic(path, diag);
            } else {
                std.log.err("Tokenize error in included template '{s}': {}", .{ path, err });
            }
            return err;
        };

        var parser = Parser.initWithSource(self.allocator, tokens, source);
        return parser.parse() catch |err| {
            if (parser.getDiagnostic()) |diag| {
                logDiagnostic(path, diag);
            } else {
                std.log.err("Parse error in included template '{s}': {}", .{ path, err });
            }
            return err;
        };
    }

    /// Writes buffered static content as a single appendSlice call and clears the buffer.
    fn flush(self: *Compiler) !void {
        if (self.buf.items.len > 0) {
            try self.writeIndent();
            try self.writer.writeAll("try o.appendSlice(a, \"");
            try self.writer.writeAll(self.buf.items);
            try self.writer.writeAll("\");\n");
            self.buf.items.len = 0;
        }
    }

    /// Writes buffered static content as a return statement (for static-only templates).
    fn flushAsReturn(self: *Compiler) !void {
        try self.writer.writeAll("\"");
        try self.writer.writeAll(self.buf.items);
        try self.writer.writeAll("\";\n");
        self.buf.items.len = 0;
    }

    /// Appends static string content to the buffer, escaping for Zig string literals.
    fn appendStatic(self: *Compiler, s: []const u8) !void {
        for (s) |c| {
            const escaped: []const u8 = switch (c) {
                '\\' => "\\\\",
                '"' => "\\\"",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                else => &[_]u8{c},
            };
            try self.buf.appendSlice(self.allocator, escaped);
        }
    }

    /// Appends string with whitespace normalization (for backtick template literals).
    /// Collapses newlines/spaces into single spaces, escapes quotes as &quot; for HTML.
    fn appendNormalizedWhitespace(self: *Compiler, s: []const u8) !void {
        var in_whitespace = true; // Start true to skip leading whitespace
        for (s) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                if (!in_whitespace) {
                    try self.buf.appendSlice(self.allocator, " ");
                    in_whitespace = true;
                }
            } else {
                const escaped: []const u8 = switch (c) {
                    '\\' => "\\\\",
                    // Escape double quotes as HTML entity for valid attribute values
                    '"' => "&quot;",
                    else => &[_]u8{c},
                };
                try self.buf.appendSlice(self.allocator, escaped);
                in_whitespace = false;
            }
        }
        // Remove trailing space if present
        if (self.buf.items.len > 0 and self.buf.items[self.buf.items.len - 1] == ' ') {
            self.buf.items.len -= 1;
        }
    }

    fn writeIndent(self: *Compiler) !void {
        for (0..self.depth) |_| try self.writer.writeAll("    ");
    }

    /// Main dispatch function - emits Zig code for any AST node type.
    fn emitNode(self: *Compiler, node: ast.Node) anyerror!void {
        switch (node) {
            .doctype => |dt| {
                if (std.mem.eql(u8, dt.value, "html")) {
                    try self.appendStatic("<!DOCTYPE html>");
                } else {
                    try self.appendStatic("<!DOCTYPE ");
                    try self.appendStatic(dt.value);
                    try self.appendStatic(">");
                }
            },
            .element => |e| try self.emitElement(e),
            .text => |t| try self.emitText(t.segments),
            .raw_text => |r| try self.appendStatic(r.content),
            .conditional => |c| try self.emitConditional(c),
            .each => |e| try self.emitEach(e),
            .case => |c| try self.emitCase(c),
            .comment => |c| if (c.rendered) {
                try self.appendStatic("<!-- ");
                try self.appendStatic(c.content);
                try self.appendStatic(" -->");
            },
            .block => |b| try self.emitBlock(b),
            .include => |inc| try self.emitInclude(inc),
            .mixin_call => |call| try self.emitMixinCall(call),
            .mixin_def => {}, // Mixin definitions are collected, not emitted directly
            .mixin_block => {}, // Handled within mixin call context
            .extends => {}, // Handled at document level
            .document => |dc| for (dc.nodes) |child| try self.emitNode(child),
            else => {},
        }
    }

    /// Emits an HTML element: opening tag, attributes, children, closing tag.
    /// Handles void elements (self-closing), class merging, and buffered code.
    fn emitElement(self: *Compiler, e: ast.Element) anyerror!void {
        const is_void = isVoidElement(e.tag) or e.self_closing;

        try self.appendStatic("<");
        try self.appendStatic(e.tag);

        if (e.id) |id| {
            try self.appendStatic(" id=\"");
            try self.appendStatic(id);
            try self.appendStatic("\"");
        }

        // Check if there's a class attribute that needs to be merged with shorthand classes
        var class_attr_value: ?[]const u8 = null;
        var class_attr_escaped: bool = true;
        for (e.attributes) |attr| {
            if (std.mem.eql(u8, attr.name, "class")) {
                class_attr_value = attr.value;
                class_attr_escaped = attr.escaped;
                break;
            }
        }

        // Emit merged class attribute (shorthand classes + class attribute value)
        if (e.classes.len > 0 or class_attr_value != null) {
            try self.emitMergedClassAttribute(e.classes, class_attr_value, class_attr_escaped);
        }

        // Emit other attributes (skip class since we handled it above)
        for (e.attributes) |attr| {
            if (std.mem.eql(u8, attr.name, "class")) continue; // Already handled
            if (attr.value) |v| {
                try self.emitAttribute(attr.name, v, attr.escaped);
            } else {
                // Boolean attribute
                try self.appendStatic(" ");
                try self.appendStatic(attr.name);
                try self.appendStatic("=\"");
                try self.appendStatic(attr.name);
                try self.appendStatic("\"");
            }
        }

        if (is_void) {
            try self.appendStatic(" />");
            return;
        }

        try self.appendStatic(">");

        if (e.inline_text) |segs| {
            try self.emitText(segs);
        }

        if (e.buffered_code) |bc| {
            try self.emitExpr(bc.expression, bc.escaped);
        }

        for (e.children) |child| {
            try self.emitNode(child);
        }

        try self.appendStatic("</");
        try self.appendStatic(e.tag);
        try self.appendStatic(">");
    }

    /// Emits a merged class attribute combining shorthand classes (.foo.bar) with
    /// dynamic class attribute values. Handles static strings, arrays, and concatenation.
    fn emitMergedClassAttribute(self: *Compiler, shorthand_classes: []const []const u8, attr_value: ?[]const u8, escaped: bool) !void {
        _ = escaped;

        if (attr_value) |value| {
            // Check for string concatenation first: "literal" + variable
            if (findConcatOperator(value)) |concat_pos| {
                // Has concatenation - need runtime handling
                try self.flush();
                try self.writeIndent();
                try self.writer.writeAll("try o.appendSlice(a, \" class=\\\"\");\n");

                // Add shorthand classes first
                if (shorthand_classes.len > 0) {
                    try self.writeIndent();
                    try self.writer.writeAll("try o.appendSlice(a, \"");
                    for (shorthand_classes, 0..) |cls, i| {
                        if (i > 0) try self.writer.writeAll(" ");
                        try self.writer.writeAll(cls);
                    }
                    try self.writer.writeAll(" \");\n"); // trailing space before concat value
                }

                // Emit the concatenation expression
                try self.emitConcatExpr(value, concat_pos);

                try self.writeIndent();
                try self.writer.writeAll("try o.appendSlice(a, \"\\\"\");\n");
                return;
            }

            // Check if attribute value is static (string literal) or dynamic
            const is_static = value.len >= 2 and (value[0] == '"' or value[0] == '\'' or value[0] == '`');
            const is_array = value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']';

            if (is_static or is_array) {
                // Static value - can merge at compile time
                try self.appendStatic(" class=\"");
                // First add shorthand classes
                for (shorthand_classes, 0..) |cls, i| {
                    if (i > 0) try self.appendStatic(" ");
                    try self.appendStatic(cls);
                }
                // Then add attribute value
                if (shorthand_classes.len > 0) try self.appendStatic(" ");
                if (is_array) {
                    try self.appendStatic(parseArrayToSpaceSeparated(value));
                } else if (value[0] == '`') {
                    try self.appendNormalizedWhitespace(value[1 .. value.len - 1]);
                } else {
                    try self.appendStatic(value[1 .. value.len - 1]);
                }
                try self.appendStatic("\"");
            } else {
                // Dynamic value - need runtime concatenation
                try self.flush();
                try self.writeIndent();
                try self.writer.writeAll("try o.appendSlice(a, \" class=\\\"\");\n");

                // Add shorthand classes first
                if (shorthand_classes.len > 0) {
                    try self.writeIndent();
                    try self.writer.writeAll("try o.appendSlice(a, \"");
                    for (shorthand_classes, 0..) |cls, i| {
                        if (i > 0) try self.writer.writeAll(" ");
                        try self.writer.writeAll(cls);
                    }
                    try self.writer.writeAll(" \");\n"); // trailing space before dynamic value
                }

                // Add dynamic value
                var accessor_buf: [512]u8 = undefined;
                const accessor = self.buildAccessor(value, &accessor_buf);
                try self.writeIndent();
                try self.writer.print("try o.appendSlice(a, strVal({s}));\n", .{accessor});

                try self.writeIndent();
                try self.writer.writeAll("try o.appendSlice(a, \"\\\"\");\n");
            }
        } else {
            // No attribute value, just shorthand classes
            try self.appendStatic(" class=\"");
            for (shorthand_classes, 0..) |cls, i| {
                if (i > 0) try self.appendStatic(" ");
                try self.appendStatic(cls);
            }
            try self.appendStatic("\"");
        }
    }

    fn emitText(self: *Compiler, segs: []const ast.TextSegment) anyerror!void {
        for (segs) |seg| {
            switch (seg) {
                .literal => |lit| try self.appendStatic(lit),
                .interp_escaped => |expr| try self.emitExpr(expr, true),
                .interp_unescaped => |expr| try self.emitExpr(expr, false),
                .interp_tag => |t| try self.emitInlineTag(t),
            }
        }
    }

    fn emitInlineTag(self: *Compiler, t: ast.InlineTag) anyerror!void {
        try self.appendStatic("<");
        try self.appendStatic(t.tag);
        if (t.id) |id| {
            try self.appendStatic(" id=\"");
            try self.appendStatic(id);
            try self.appendStatic("\"");
        }
        if (t.classes.len > 0) {
            try self.appendStatic(" class=\"");
            for (t.classes, 0..) |cls, i| {
                if (i > 0) try self.appendStatic(" ");
                try self.appendStatic(cls);
            }
            try self.appendStatic("\"");
        }
        for (t.attributes) |attr| {
            if (attr.value) |v| {
                if (v.len >= 2 and (v[0] == '"' or v[0] == '\'')) {
                    try self.appendStatic(" ");
                    try self.appendStatic(attr.name);
                    try self.appendStatic("=\"");
                    try self.appendStatic(v[1 .. v.len - 1]);
                    try self.appendStatic("\"");
                }
            }
        }
        try self.appendStatic(">");
        try self.emitText(t.text_segments);
        try self.appendStatic("</");
        try self.appendStatic(t.tag);
        try self.appendStatic(">");
    }

    /// Emits code for an interpolated expression (#{expr} or !{expr}).
    /// Flushes static buffer first since this generates runtime code.
    fn emitExpr(self: *Compiler, expr: []const u8, escaped: bool) !void {
        try self.flush();
        try self.writeIndent();

        var accessor_buf: [512]u8 = undefined;
        const accessor = self.buildAccessor(expr, &accessor_buf);

        if (escaped) {
            try self.writer.print("try esc(&o, a, strVal({s}));\n", .{accessor});
        } else {
            try self.writer.print("try o.appendSlice(a, strVal({s}));\n", .{accessor});
        }
    }

    /// Emits an HTML attribute. Handles various value types:
    /// - String literals (single, double, backtick quoted)
    /// - Object literals ({color: 'red'} -> style="color:red;")
    /// - Array literals (['a', 'b'] -> class="a b")
    /// - String concatenation ("btn-" + type)
    /// - Dynamic variable references
    fn emitAttribute(self: *Compiler, name: []const u8, value: []const u8, escaped: bool) !void {
        _ = escaped;

        // Check for string concatenation: "literal" + variable or variable + "literal"
        if (findConcatOperator(value)) |concat_pos| {
            // Parse concatenation expression
            try self.flush();
            try self.writeIndent();
            try self.writer.print("try o.appendSlice(a, \" {s}=\\\"\");\n", .{name});

            try self.emitConcatExpr(value, concat_pos);

            try self.writeIndent();
            try self.writer.writeAll("try o.appendSlice(a, \"\\\"\");\n");
        } else if (value.len >= 2 and (value[0] == '"' or value[0] == '\'' or value[0] == '`')) {
            // Simple string literal (single, double, or backtick quoted)
            try self.appendStatic(" ");
            try self.appendStatic(name);
            try self.appendStatic("=\"");
            // For backtick strings, normalize whitespace (collapse newlines and multiple spaces)
            if (value[0] == '`') {
                try self.appendNormalizedWhitespace(value[1 .. value.len - 1]);
            } else {
                try self.appendStatic(value[1 .. value.len - 1]);
            }
            try self.appendStatic("\"");
        } else if (value.len >= 2 and value[0] == '{' and value[value.len - 1] == '}') {
            // Object literal - convert to appropriate format
            try self.appendStatic(" ");
            try self.appendStatic(name);
            try self.appendStatic("=\"");
            if (std.mem.eql(u8, name, "style")) {
                // For style attribute, convert object to CSS: {color: 'red'} -> color:red;
                try self.appendStatic(parseObjectToCSS(value));
            } else {
                // For other attributes (like class), join values with spaces
                try self.appendStatic(parseObjectToSpaceSeparated(value));
            }
            try self.appendStatic("\"");
        } else if (value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']') {
            // Array literal - join with spaces for class attribute, otherwise as-is
            try self.appendStatic(" ");
            try self.appendStatic(name);
            try self.appendStatic("=\"");
            try self.appendStatic(parseArrayToSpaceSeparated(value));
            try self.appendStatic("\"");
        } else {
            // Dynamic value (variable reference)
            try self.flush();
            try self.writeIndent();
            try self.writer.print("try o.appendSlice(a, \" {s}=\\\"\");\n", .{name});

            var accessor_buf: [512]u8 = undefined;
            const accessor = self.buildAccessor(value, &accessor_buf);
            try self.writeIndent();
            try self.writer.print("try o.appendSlice(a, strVal({s}));\n", .{accessor});

            try self.writeIndent();
            try self.writer.writeAll("try o.appendSlice(a, \"\\\"\");\n");
        }
    }

    /// Finds the + operator for string concatenation, skipping + chars inside quotes.
    /// Returns the position of the operator, or null if not found.
    fn findConcatOperator(value: []const u8) ?usize {
        var in_string = false;
        var string_char: u8 = 0;
        var i: usize = 0;

        while (i < value.len) : (i += 1) {
            const c = value[i];

            if (in_string) {
                if (c == string_char) {
                    in_string = false;
                }
            } else {
                if (c == '"' or c == '\'' or c == '`') {
                    in_string = true;
                    string_char = c;
                } else if (c == '+') {
                    // Check it's surrounded by spaces (typical concat)
                    if (i > 0 and i + 1 < value.len) {
                        return i;
                    }
                }
            }
        }
        return null;
    }

    /// Emits code for a string concatenation expression (e.g., "btn btn-" + type).
    /// Recursively handles chained concatenations.
    fn emitConcatExpr(self: *Compiler, value: []const u8, concat_pos: usize) !void {
        const left = std.mem.trim(u8, value[0..concat_pos], " ");
        const right = std.mem.trim(u8, value[concat_pos + 1 ..], " ");

        // Emit left part
        if (left.len >= 2 and (left[0] == '"' or left[0] == '\'' or left[0] == '`')) {
            // String literal (single, double, or backtick quoted)
            try self.writeIndent();
            try self.writer.print("try o.appendSlice(a, {s});\n", .{left});
        } else {
            // Variable
            var accessor_buf: [512]u8 = undefined;
            const accessor = self.buildAccessor(left, &accessor_buf);
            try self.writeIndent();
            try self.writer.print("try o.appendSlice(a, strVal({s}));\n", .{accessor});
        }

        // Check if right part also has concatenation
        if (findConcatOperator(right)) |next_concat| {
            try self.emitConcatExpr(right, next_concat);
        } else {
            // Emit right part
            if (right.len >= 2 and (right[0] == '"' or right[0] == '\'' or right[0] == '`')) {
                // String literal (single, double, or backtick quoted)
                try self.writeIndent();
                try self.writer.print("try o.appendSlice(a, {s});\n", .{right});
            } else {
                // Variable
                var accessor_buf: [512]u8 = undefined;
                const accessor = self.buildAccessor(right, &accessor_buf);
                try self.writeIndent();
                try self.writer.print("try o.appendSlice(a, strVal({s}));\n", .{accessor});
            }
        }
    }

    /// Emits an expression inline (used for dynamic attribute values).
    fn emitExprInline(self: *Compiler, expr: []const u8, escaped: bool) !void {
        try self.flush();
        try self.writeIndent();

        var accessor_buf: [512]u8 = undefined;
        const accessor = self.buildAccessor(expr, &accessor_buf);

        if (escaped) {
            try self.writer.print("try esc(&o, a, strVal({s}));\n", .{accessor});
        } else {
            try self.writer.print("try o.appendSlice(a, strVal({s}));\n", .{accessor});
        }
    }

    fn isLoopVar(self: *Compiler, name: []const u8) bool {
        for (self.loop_vars.items) |v| {
            if (std.mem.eql(u8, v, name)) return true;
        }
        return false;
    }

    fn isMixinParam(self: *Compiler, name: []const u8) bool {
        for (self.mixin_params.items) |p| {
            if (std.mem.eql(u8, p, name)) return true;
        }
        return false;
    }

    /// Builds a Zig accessor expression for a template variable.
    /// Handles: loop vars (item), mixin params (text), data fields (@field(d, "name")),
    /// nested access (user.name), and mixin attributes (attributes.class).
    fn buildAccessor(self: *Compiler, expr: []const u8, buf: []u8) []const u8 {
        if (std.mem.indexOfScalar(u8, expr, '.')) |dot| {
            const base = expr[0..dot];
            const rest = expr[dot + 1 ..];

            // Special case: attributes.X should use current mixin's attributes variable
            if (std.mem.eql(u8, base, "attributes")) {
                if (self.current_attrs_var) |attrs_var| {
                    return std.fmt.bufPrint(buf, "{s}.{s}", .{ attrs_var, rest }) catch expr;
                }
            }

            // For loop variables or mixin params like friend.name, access directly
            if (self.isLoopVar(base) or self.isMixinParam(base)) {
                // Escape base if it's a keyword - use the output buffer
                if (zig_keywords.has(base)) {
                    return std.fmt.bufPrint(buf, "@\"{s}\".{s}", .{ base, rest }) catch expr;
                }
                return std.fmt.bufPrint(buf, "{s}.{s}", .{ base, rest }) catch expr;
            }
            // For top-level data field access - mark that we use 'd'
            self.uses_data = true;
            return std.fmt.bufPrint(buf, "@field(d, \"{s}\").{s}", .{ base, rest }) catch expr;
        } else {
            // Special case: 'attributes' alone should use current mixin's attributes variable
            if (std.mem.eql(u8, expr, "attributes")) {
                if (self.current_attrs_var) |attrs_var| {
                    return attrs_var;
                }
            }

            // Check if it's a loop variable or mixin param
            if (self.isLoopVar(expr) or self.isMixinParam(expr)) {
                // Escape if it's a keyword - use the output buffer
                if (zig_keywords.has(expr)) {
                    return std.fmt.bufPrint(buf, "@\"{s}\"", .{expr}) catch expr;
                }
                return expr;
            }
            // For top-level like "name", access from d - mark that we use 'd'
            self.uses_data = true;
            return std.fmt.bufPrint(buf, "@field(d, \"{s}\")", .{expr}) catch expr;
        }
    }

    fn emitConditional(self: *Compiler, c: ast.Conditional) anyerror!void {
        try self.flush();
        for (c.branches, 0..) |br, i| {
            try self.writeIndent();
            if (i == 0) {
                if (br.is_unless) {
                    try self.writer.writeAll("if (!");
                } else {
                    try self.writer.writeAll("if (");
                }
                try self.emitCondition(br.condition orelse "true");
                try self.writer.writeAll(") {\n");
            } else if (br.condition) |cond| {
                try self.writer.writeAll("} else if (");
                try self.emitCondition(cond);
                try self.writer.writeAll(") {\n");
            } else {
                try self.writer.writeAll("} else {\n");
            }
            self.depth += 1;
            for (br.children) |child| try self.emitNode(child);
            try self.flush();
            self.depth -= 1;
        }
        try self.writeIndent();
        try self.writer.writeAll("}\n");
    }

    /// Emits a condition expression for if/else if.
    /// Handles string comparisons (== "value") and optional field access (@hasField).
    fn emitCondition(self: *Compiler, cond: []const u8) !void {
        // String equality: status == "closed" -> std.mem.eql(u8, strVal(status), "closed")
        if (std.mem.indexOf(u8, cond, " == \"")) |eq_pos| {
            const lhs = std.mem.trim(u8, cond[0..eq_pos], " ");
            const rhs_start = eq_pos + 5; // skip ' == "'
            if (std.mem.indexOfScalar(u8, cond[rhs_start..], '"')) |rhs_end| {
                const rhs = cond[rhs_start .. rhs_start + rhs_end];
                var accessor_buf: [512]u8 = undefined;
                const accessor = self.buildAccessor(lhs, &accessor_buf);
                try self.writer.print("std.mem.eql(u8, strVal({s}), \"{s}\")", .{ accessor, rhs });
                return;
            }
        }
        // Handle string inequality: status != "closed"
        if (std.mem.indexOf(u8, cond, " != \"")) |eq_pos| {
            const lhs = std.mem.trim(u8, cond[0..eq_pos], " ");
            const rhs_start = eq_pos + 5;
            if (std.mem.indexOfScalar(u8, cond[rhs_start..], '"')) |rhs_end| {
                const rhs = cond[rhs_start .. rhs_start + rhs_end];
                var accessor_buf: [512]u8 = undefined;
                const accessor = self.buildAccessor(lhs, &accessor_buf);
                try self.writer.print("!std.mem.eql(u8, strVal({s}), \"{s}\")", .{ accessor, rhs });
                return;
            }
        }
        // Regular field access - use buildAccessor for consistency
        var accessor_buf: [512]u8 = undefined;
        const accessor = self.buildAccessor(cond, &accessor_buf);

        // Check if this is a simple top-level field access (no dots, not a loop var or mixin param)
        const is_simple_field = std.mem.indexOfScalar(u8, cond, '.') == null and
            !self.isLoopVar(cond) and !self.isMixinParam(cond);

        if (is_simple_field) {
            // Use @hasField to make the field optional at compile time
            self.uses_data = true;
            try self.writer.print("@hasField(@TypeOf(d), \"{s}\") and truthy({s})", .{ cond, accessor });
        } else {
            try self.writer.print("truthy({s})", .{accessor});
        }
    }

    /// Emits code for an each loop (iteration over arrays/slices).
    /// Handles optional index variable and else branch for empty collections.
    fn emitEach(self: *Compiler, e: ast.Each) anyerror!void {
        try self.flush();
        try self.writeIndent();

        try self.loop_vars.append(self.allocator, e.value_name);

        var accessor_buf: [512]u8 = undefined;
        const collection_accessor = self.buildAccessor(e.collection, &accessor_buf);

        // Wrap in length check if there's an else branch
        if (e.else_children.len > 0) {
            try self.writer.print("if ({s}.len > 0) {{\n", .{collection_accessor});
            self.depth += 1;
            try self.writeIndent();
        }

        // Handle optional collections (nested fields may be nullable)
        if (std.mem.indexOfScalar(u8, e.collection, '.')) |_| {
            try self.writer.print("for (if (@typeInfo(@TypeOf({s})) == .optional) ({s} orelse &.{{}}) else {s}) |{s}", .{ collection_accessor, collection_accessor, collection_accessor, e.value_name });
        } else {
            try self.writer.print("for ({s}) |{s}", .{ collection_accessor, e.value_name });
        }
        if (e.index_name) |idx| {
            try self.writer.print(", {s}", .{idx});
        }
        try self.writer.writeAll("| {\n");

        self.depth += 1;
        for (e.children) |child| {
            try self.emitNode(child);
        }
        try self.flush();
        self.depth -= 1;

        try self.writeIndent();
        try self.writer.writeAll("}\n");

        // Handle else branch
        if (e.else_children.len > 0) {
            self.depth -= 1;
            try self.writeIndent();
            try self.writer.writeAll("} else {\n");
            self.depth += 1;
            for (e.else_children) |child| {
                try self.emitNode(child);
            }
            try self.flush();
            self.depth -= 1;
            try self.writeIndent();
            try self.writer.writeAll("}\n");
        }

        // Pop loop variable
        _ = self.loop_vars.pop();
    }

    /// Emits code for a case/when statement (switch-like construct).
    /// Generates if/else if chain since Zig switch requires comptime values.
    fn emitCase(self: *Compiler, c: ast.Case) anyerror!void {
        try self.flush();

        var accessor_buf: [512]u8 = undefined;
        const expr_accessor = self.buildAccessor(c.expression, &accessor_buf);

        var first = true;
        for (c.whens) |when| {
            try self.writeIndent();

            if (first) {
                first = false;
            } else {
                try self.writer.writeAll("} else ");
            }

            // Check if value is a string literal
            if (when.value.len >= 2 and when.value[0] == '"') {
                const str_val = when.value[1 .. when.value.len - 1];
                try self.writer.print("if (std.mem.eql(u8, strVal({s}), \"{s}\")) {{\n", .{ expr_accessor, str_val });
            } else {
                // Numeric or other comparison
                try self.writer.print("if ({s} == {s}) {{\n", .{ expr_accessor, when.value });
            }

            self.depth += 1;

            if (when.has_break) {
                // Explicit break - do nothing
            } else if (when.children.len == 0) {
                // Fall-through - we'll handle this by continuing to next case
                // For now, just skip (Zig doesn't have fall-through)
            } else {
                for (when.children) |child| {
                    try self.emitNode(child);
                }
            }
            try self.flush();
            self.depth -= 1;
        }

        // Default case
        if (c.default_children.len > 0) {
            try self.writeIndent();
            if (!first) {
                try self.writer.writeAll("} else {\n");
            } else {
                try self.writer.writeAll("{\n");
            }
            self.depth += 1;
            for (c.default_children) |child| {
                try self.emitNode(child);
            }
            try self.flush();
            self.depth -= 1;
        }

        if (!first or c.default_children.len > 0) {
            try self.writeIndent();
            try self.writer.writeAll("}\n");
        }
    }

    /// Emits a named block, applying any child template overrides.
    /// Supports replace, append, and prepend modes for inheritance.
    fn emitBlock(self: *Compiler, blk: ast.Block) anyerror!void {
        if (self.blocks.get(blk.name)) |child_block| {
            switch (child_block.mode) {
                .replace => {
                    // Child completely replaces parent block
                    for (child_block.children) |child| {
                        try self.emitNode(child);
                    }
                },
                .append => {
                    // Parent content first, then child
                    for (blk.children) |child| {
                        try self.emitNode(child);
                    }
                    for (child_block.children) |child| {
                        try self.emitNode(child);
                    }
                },
                .prepend => {
                    // Child content first, then parent
                    for (child_block.children) |child| {
                        try self.emitNode(child);
                    }
                    for (blk.children) |child| {
                        try self.emitNode(child);
                    }
                },
            }
        } else {
            // No override - render default block content
            for (blk.children) |child| {
                try self.emitNode(child);
            }
        }
    }

    /// Emits an include directive by inlining the included template's content.
    fn emitInclude(self: *Compiler, inc: ast.Include) anyerror!void {
        const included_doc = self.loadTemplate(inc.path) catch |err| {
            std.log.warn("Failed to load include '{s}': {}", .{ inc.path, err });
            return;
        };

        try self.collectMixins(included_doc.nodes);

        for (included_doc.nodes) |node| {
            try self.emitNode(node);
        }
    }

    /// Emits a mixin call (+mixinName(args)).
    /// Looks up the mixin definition, falling back to lazy-loading from mixins/ directory.
    fn emitMixinCall(self: *Compiler, call: ast.MixinCall) anyerror!void {
        const mixin_def = self.mixins.get(call.name) orelse {
            // Lazy-load from mixins/ directory
            if (self.loadMixinFromDir(call.name)) |def| {
                try self.mixins.put(def.name, def);
                try self.emitMixinCallWithDef(call, def);
                return;
            }
            std.log.warn("Mixin '{s}' not found", .{call.name});
            return;
        };

        try self.emitMixinCallWithDef(call, mixin_def);
    }

    /// Emits the actual mixin body with parameter bindings.
    /// Creates a scope block with local variables for each mixin parameter.
    /// Handles default values, rest parameters, block content, and &attributes.
    fn emitMixinCallWithDef(self: *Compiler, call: ast.MixinCall, mixin_def: ast.MixinDef) anyerror!void {
        // Save/restore mixin params to handle nested mixin calls
        const prev_params_len = self.mixin_params.items.len;
        defer self.mixin_params.items.len = prev_params_len;

        const regular_params = if (mixin_def.has_rest and mixin_def.params.len > 0)
            mixin_def.params.len - 1
        else
            mixin_def.params.len;

        try self.flush();

        // Scope block prevents variable name collisions on repeated mixin calls
        try self.writeIndent();
        try self.writer.writeAll("{\n");
        self.depth += 1;

        for (mixin_def.params[0..regular_params], 0..) |param, i| {
            try self.mixin_params.append(self.allocator, param);

            // Escape param name if it's a Zig keyword
            var ident_buf: [64]u8 = undefined;
            const safe_param = escapeIdent(param, &ident_buf);

            if (i < call.args.len) {
                // Argument provided
                const arg = call.args[i];
                // Check if it's a string literal
                if (arg.len >= 2 and (arg[0] == '"' or arg[0] == '\'')) {
                    try self.writeIndent();
                    try self.writer.print("const {s} = {s};\n", .{ safe_param, arg });
                } else {
                    // It's a variable reference
                    var accessor_buf: [512]u8 = undefined;
                    const accessor = self.buildAccessor(arg, &accessor_buf);
                    // Skip declaration if accessor equals param name (already in scope)
                    if (!std.mem.eql(u8, accessor, safe_param)) {
                        try self.writeIndent();
                        try self.writer.print("const {s} = {s};\n", .{ safe_param, accessor });
                    }
                }
            } else if (i < mixin_def.defaults.len) {
                // Use default value
                try self.writeIndent();
                if (mixin_def.defaults[i]) |default| {
                    try self.writer.print("const {s} = {s};\n", .{ safe_param, default });
                } else {
                    try self.writer.print("const {s} = \"\";\n", .{safe_param});
                }
            } else {
                // No value - use empty string
                try self.writeIndent();
                try self.writer.print("const {s} = \"\";\n", .{safe_param});
            }
        }

        // Handle rest parameters
        if (mixin_def.has_rest and mixin_def.params.len > 0) {
            const rest_param = mixin_def.params[mixin_def.params.len - 1];
            try self.mixin_params.append(self.allocator, rest_param);

            // Rest args are remaining arguments as an array
            try self.writeIndent();
            try self.writer.print("const {s} = &[_][]const u8{{", .{rest_param});

            for (call.args[regular_params..], 0..) |arg, i| {
                if (i > 0) try self.writer.writeAll(", ");
                try self.writer.print("{s}", .{arg});
            }
            try self.writer.writeAll("};\n");
        }

        // Check if mixin body actually uses &attributes before emitting the struct
        const uses_attributes = mixinUsesAttributes(mixin_def.children);

        // Save previous attrs var and restore after mixin body
        const prev_attrs_var = self.current_attrs_var;
        defer self.current_attrs_var = prev_attrs_var;

        // Only emit attributes struct if the mixin actually uses it
        if (uses_attributes) {
            // Use unique name based on mixin depth to avoid shadowing in nested mixin calls
            self.mixin_depth += 1;
            const current_depth = self.mixin_depth;

            var attr_var_buf: [32]u8 = undefined;
            const attr_var_name = std.fmt.bufPrint(&attr_var_buf, "mixin_attrs_{d}", .{current_depth}) catch "mixin_attrs";

            self.current_attrs_var = attr_var_name;
            try self.mixin_params.append(self.allocator, attr_var_name);

            try self.writeIndent();
            try self.writer.print("const {s}: struct {{\n", .{attr_var_name});
            self.depth += 1;
            try self.writeIndent();
            try self.writer.writeAll("class: []const u8 = \"\",\n");
            try self.writeIndent();
            try self.writer.writeAll("id: []const u8 = \"\",\n");
            try self.writeIndent();
            try self.writer.writeAll("style: []const u8 = \"\",\n");
            self.depth -= 1;
            try self.writeIndent();
            try self.writer.writeAll("} = .{\n");
            self.depth += 1;

            for (call.attributes) |attr| {
                if (std.mem.eql(u8, attr.name, "class") or
                    std.mem.eql(u8, attr.name, "id") or
                    std.mem.eql(u8, attr.name, "style"))
                {
                    try self.writeIndent();
                    try self.writer.print(".{s} = ", .{attr.name});
                    if (attr.value) |val| {
                        if (val.len >= 2 and (val[0] == '"' or val[0] == '\'')) {
                            try self.writer.print("{s},\n", .{val});
                        } else {
                            var accessor_buf: [512]u8 = undefined;
                            const accessor = self.buildAccessor(val, &accessor_buf);
                            try self.writer.print("{s},\n", .{accessor});
                        }
                    } else {
                        try self.writer.writeAll("\"\",\n");
                    }
                }
            }

            self.depth -= 1;
            try self.writeIndent();
            try self.writer.writeAll("};\n");
        }

        // Emit mixin body
        for (mixin_def.children) |child| {
            if (child == .mixin_block) {
                for (call.block_children) |block_child| {
                    try self.emitNode(block_child);
                }
            } else {
                try self.emitNode(child);
            }
        }

        // Close scope block
        try self.flush();
        self.depth -= 1;
        try self.writeIndent();
        try self.writer.writeAll("}\n");

        if (uses_attributes) {
            self.mixin_depth -= 1;
        }
    }

    /// Attempts to load a mixin from the mixins/ subdirectory.
    /// First tries mixins/{name}.pug, then scans all files in mixins/ for the definition.
    fn loadMixinFromDir(self: *Compiler, name: []const u8) ?ast.MixinDef {
        const specific_path = std.fs.path.join(self.allocator, &.{ self.source_dir, "mixins", name }) catch return null;
        defer self.allocator.free(specific_path);

        const with_ext = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ specific_path, self.extension }) catch return null;
        defer self.allocator.free(with_ext);

        if (std.fs.cwd().readFileAlloc(self.allocator, with_ext, 1024 * 1024)) |source| {
            if (self.parseMixinFromSource(source, name)) |def| {
                return def;
            }
        } else |_| {}

        // Try scanning all files in mixins directory
        const mixins_dir_path = std.fs.path.join(self.allocator, &.{ self.source_dir, "mixins" }) catch return null;
        defer self.allocator.free(mixins_dir_path);

        var dir = std.fs.cwd().openDir(mixins_dir_path, .{ .iterate = true }) catch return null;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch return null) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, self.extension)) {
                const file_path = std.fs.path.join(self.allocator, &.{ mixins_dir_path, entry.name }) catch continue;
                defer self.allocator.free(file_path);

                if (std.fs.cwd().readFileAlloc(self.allocator, file_path, 1024 * 1024)) |source| {
                    if (self.parseMixinFromSource(source, name)) |def| {
                        return def;
                    }
                } else |_| {}
            }
        }

        return null;
    }

    /// Parses template source to find and return a specific mixin definition by name.
    fn parseMixinFromSource(self: *Compiler, source: []const u8, name: []const u8) ?ast.MixinDef {
        var lexer = Lexer.init(self.allocator, source);
        const tokens = lexer.tokenize() catch return null;

        var parser = Parser.init(self.allocator, tokens);
        const doc = parser.parse() catch return null;

        // Find the mixin with matching name
        for (doc.nodes) |node| {
            if (node == .mixin_def) {
                if (std.mem.eql(u8, node.mixin_def.name, name)) {
                    return node.mixin_def;
                }
            }
        }

        return null;
    }
};

/// Parses a JS-style object literal into CSS property string.
/// Example: {color: 'red', background: 'green'} -> "color:red;background:green;"
/// Note: Returns slice from static buffer - safe because result is immediately consumed.
fn parseObjectToCSS(input: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\n\r");

    // Must start with { and end with }
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') {
        return input;
    }

    const content = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\n\r");
    if (content.len == 0) return "";

    // Use comptime buffer for simple cases
    var result: [1024]u8 = undefined;
    var result_len: usize = 0;

    var pos: usize = 0;
    while (pos < content.len) {
        // Skip whitespace
        while (pos < content.len and (content[pos] == ' ' or content[pos] == '\t' or content[pos] == '\n' or content[pos] == '\r')) {
            pos += 1;
        }
        if (pos >= content.len) break;

        // Parse property name
        const name_start = pos;
        while (pos < content.len and content[pos] != ':' and content[pos] != ' ') {
            pos += 1;
        }
        const name = content[name_start..pos];

        // Skip to colon
        while (pos < content.len and content[pos] != ':') {
            pos += 1;
        }
        if (pos >= content.len) break;
        pos += 1; // skip :

        // Skip whitespace
        while (pos < content.len and (content[pos] == ' ' or content[pos] == '\t')) {
            pos += 1;
        }

        // Parse value (handle quoted strings)
        var value_start = pos;
        var value_end = pos;
        if (pos < content.len and (content[pos] == '\'' or content[pos] == '"')) {
            const quote = content[pos];
            pos += 1;
            value_start = pos;
            while (pos < content.len and content[pos] != quote) {
                pos += 1;
            }
            value_end = pos;
            if (pos < content.len) pos += 1; // skip closing quote
        } else {
            // Unquoted value - read until comma or end
            while (pos < content.len and content[pos] != ',' and content[pos] != '}') {
                pos += 1;
            }
            value_end = pos;
            // Trim trailing whitespace from value
            while (value_end > value_start and (content[value_end - 1] == ' ' or content[value_end - 1] == '\t')) {
                value_end -= 1;
            }
        }
        const value = content[value_start..value_end];

        // Append name:value;
        if (result_len + name.len + 1 + value.len + 1 < result.len) {
            @memcpy(result[result_len..][0..name.len], name);
            result_len += name.len;
            result[result_len] = ':';
            result_len += 1;
            @memcpy(result[result_len..][0..value.len], value);
            result_len += value.len;
            result[result_len] = ';';
            result_len += 1;
        }

        // Skip comma and whitespace
        while (pos < content.len and (content[pos] == ',' or content[pos] == ' ' or content[pos] == '\t' or content[pos] == '\n' or content[pos] == '\r')) {
            pos += 1;
        }
    }

    // Return slice from static buffer - this works because we're building static strings
    return result[0..result_len];
}

/// Parses a JS-style object literal and extracts values as space-separated string.
/// Example: {foo: 'bar', baz: 'qux'} -> "bar qux"
fn parseObjectToSpaceSeparated(input: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\n\r");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') {
        return input;
    }

    const content = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\n\r");
    if (content.len == 0) return "";

    var result: [1024]u8 = undefined;
    var result_len: usize = 0;
    var first = true;

    var pos: usize = 0;
    while (pos < content.len) {
        // Skip whitespace
        while (pos < content.len and (content[pos] == ' ' or content[pos] == '\t' or content[pos] == '\n' or content[pos] == '\r')) {
            pos += 1;
        }
        if (pos >= content.len) break;

        // Skip property name until colon
        while (pos < content.len and content[pos] != ':') {
            pos += 1;
        }
        if (pos >= content.len) break;
        pos += 1; // skip :

        // Skip whitespace
        while (pos < content.len and (content[pos] == ' ' or content[pos] == '\t')) {
            pos += 1;
        }

        // Parse value
        var value_start = pos;
        var value_end = pos;
        if (pos < content.len and (content[pos] == '\'' or content[pos] == '"')) {
            const quote = content[pos];
            pos += 1;
            value_start = pos;
            while (pos < content.len and content[pos] != quote) {
                pos += 1;
            }
            value_end = pos;
            if (pos < content.len) pos += 1;
        } else {
            while (pos < content.len and content[pos] != ',' and content[pos] != '}') {
                pos += 1;
            }
            value_end = pos;
            while (value_end > value_start and (content[value_end - 1] == ' ' or content[value_end - 1] == '\t')) {
                value_end -= 1;
            }
        }
        const value = content[value_start..value_end];

        // Append value with space separator
        if (result_len + (if (first) @as(usize, 0) else @as(usize, 1)) + value.len < result.len) {
            if (!first) {
                result[result_len] = ' ';
                result_len += 1;
            }
            @memcpy(result[result_len..][0..value.len], value);
            result_len += value.len;
            first = false;
        }

        // Skip comma and whitespace
        while (pos < content.len and (content[pos] == ',' or content[pos] == ' ' or content[pos] == '\t' or content[pos] == '\n' or content[pos] == '\r')) {
            pos += 1;
        }
    }

    return result[0..result_len];
}

/// Parses a JS-style array literal and joins values with spaces.
/// Example: ['foo', 'bar', 'baz'] -> "foo bar baz"
fn parseArrayToSpaceSeparated(input: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\n\r");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') {
        return input;
    }

    const content = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\n\r");
    if (content.len == 0) return "";

    var result: [1024]u8 = undefined;
    var result_len: usize = 0;
    var first = true;

    var pos: usize = 0;
    while (pos < content.len) {
        // Skip whitespace
        while (pos < content.len and (content[pos] == ' ' or content[pos] == '\t' or content[pos] == '\n' or content[pos] == '\r')) {
            pos += 1;
        }
        if (pos >= content.len) break;

        // Parse value
        var value_start = pos;
        var value_end = pos;
        if (pos < content.len and (content[pos] == '\'' or content[pos] == '"')) {
            const quote = content[pos];
            pos += 1;
            value_start = pos;
            while (pos < content.len and content[pos] != quote) {
                pos += 1;
            }
            value_end = pos;
            if (pos < content.len) pos += 1;
        } else {
            while (pos < content.len and content[pos] != ',' and content[pos] != ']') {
                pos += 1;
            }
            value_end = pos;
            while (value_end > value_start and (content[value_end - 1] == ' ' or content[value_end - 1] == '\t')) {
                value_end -= 1;
            }
        }
        const value = content[value_start..value_end];

        // Append value with space separator
        if (value.len > 0 and result_len + (if (first) @as(usize, 0) else @as(usize, 1)) + value.len < result.len) {
            if (!first) {
                result[result_len] = ' ';
                result_len += 1;
            }
            @memcpy(result[result_len..][0..value.len], value);
            result_len += value.len;
            first = false;
        }

        // Skip comma and whitespace
        while (pos < content.len and (content[pos] == ',' or content[pos] == ' ' or content[pos] == '\t' or content[pos] == '\n' or content[pos] == '\r')) {
            pos += 1;
        }
    }

    return result[0..result_len];
}

/// Returns true if the tag is a void element (self-closing, no closing tag).
fn isVoidElement(tag: []const u8) bool {
    const voids = std.StaticStringMap(void).initComptime(.{
        .{ "area", {} },  .{ "base", {} }, .{ "br", {} },    .{ "col", {} },
        .{ "embed", {} }, .{ "hr", {} },   .{ "img", {} },   .{ "input", {} },
        .{ "link", {} },  .{ "meta", {} }, .{ "param", {} }, .{ "source", {} },
        .{ "track", {} }, .{ "wbr", {} },
    });
    return voids.has(tag);
}
