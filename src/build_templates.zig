//! Pugz Build Step - Compile .pug templates to Zig code at build time.
//!
//! Generates a single `generated.zig` file in the views folder containing:
//! - Shared helper functions (esc, truthy)
//! - All compiled template render functions
//!
//! Supports full Pugz features:
//! - Template inheritance (extends/block)
//! - Mixins (definitions and calls)
//! - Includes
//! - Case/when statements
//! - Conditionals (if/else if/else/unless)
//! - Iteration (each)
//! - All element features (classes, ids, attributes, interpolation)
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
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const ast = @import("ast.zig");

pub const Options = struct {
    source_dir: []const u8 = "views",
    extension: []const u8 = ".pug",
};

/// Pre compile templates from source_dir/*.pug to source_dir/generated.zig to avoid lexer/parser phase on render.
pub fn compileTemplates(b: *std.Build, options: Options) *std.Build.Module {
    const step = CompileTemplatesStep.create(b, options);
    return b.createModule(.{
        .root_source_file = step.getOutput(),
    });
}

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

const TemplateInfo = struct {
    rel_path: []const u8,
    zig_name: []const u8,
};

/// Walk source directory recursively to find pug files
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

    // escape chars
    for (path, 0..) |c, i| {
        result[i + offset] = switch (c) {
            '/', '\\', '-', '.' => '_',
            else => c,
        };
    }

    return result;
}

/// Block definition for template inheritance
const BlockDef = struct {
    mode: ast.Block.Mode,
    children: []const ast.Node,
};

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
        std.log.err("Tokenize error in '{s}': {}", .{ name, err });
        return err;
    };

    var parser = Parser.init(allocator, tokens);
    const doc = parser.parse() catch |err| {
        std.log.err("Parse error in '{s}': {}", .{ name, err });
        return err;
    };

    // Create compiler with template resolution context
    var compiler = Compiler.init(allocator, w, source_dir, extension);

    // Handle template inheritance - resolve extends chain
    const resolved_nodes = try compiler.resolveInheritance(doc);

    // Check if template has content after resolution
    var has_content = false;
    for (resolved_nodes) |node| {
        if (nodeHasOutput(node)) {
            has_content = true;
            break;
        }
    }

    // Check if template has any dynamic content
    var has_dynamic = false;
    for (resolved_nodes) |node| {
        if (nodeHasDynamic(node)) {
            has_dynamic = true;
            break;
        }
    }

    try w.print("pub fn {s}(a: Allocator, d: anytype) Allocator.Error![]u8 {{\n", .{name});

    if (!has_content) {
        // Empty template (mixin definitions only, etc.)
        try w.writeAll("    _ = .{ a, d };\n");
        try w.writeAll("    return \"\";\n");
    } else if (!has_dynamic) {
        // Static-only template - return literal string, no allocation
        try w.writeAll("    _ = .{ a, d };\n");
        try w.writeAll("    return ");
        for (resolved_nodes) |node| {
            try compiler.emitNode(node);
        }
        try compiler.flushAsReturn();
    } else {
        // Dynamic template - needs ArrayList
        try w.writeAll("    var o: ArrayList = .empty;\n");

        for (resolved_nodes) |node| {
            try compiler.emitNode(node);
        }
        try compiler.flush();

        // If 'd' parameter wasn't used, discard it to avoid unused parameter error
        if (!compiler.uses_data) {
            try w.writeAll("    _ = d;\n");
        }

        try w.writeAll("    return o.items;\n");
    }

    try w.writeAll("}\n\n");
}

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

/// Zig reserved keywords that need escaping with @"..."
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

/// Returns the identifier escaped if it's a Zig keyword
fn escapeIdent(ident: []const u8, buf: []u8) []const u8 {
    if (zig_keywords.has(ident)) {
        return std.fmt.bufPrint(buf, "@\"{s}\"", .{ident}) catch ident;
    }
    return ident;
}

const Compiler = struct {
    allocator: std.mem.Allocator,
    writer: std.ArrayList(u8).Writer,
    source_dir: []const u8,
    extension: []const u8,
    buf: std.ArrayList(u8), // Buffer for merging static strings
    depth: usize,
    loop_vars: std.ArrayList([]const u8), // Track loop variable names
    mixin_params: std.ArrayList([]const u8), // Track current mixin parameter names
    mixins: std.StringHashMap(ast.MixinDef), // Collected mixin definitions
    blocks: std.StringHashMap(BlockDef), // Collected block definitions for inheritance
    uses_data: bool, // Track whether the data parameter 'd' is actually used

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
        };
    }

    /// Resolves template inheritance by loading parent templates and merging blocks
    fn resolveInheritance(self: *Compiler, doc: ast.Document) ![]const ast.Node {
        // First, collect all mixin definitions from this template
        try self.collectMixins(doc.nodes);

        // Check if this template extends another
        if (doc.extends_path) |extends_path| {
            // Collect blocks from child template
            try self.collectBlocks(doc.nodes);

            // Load and parse parent template
            const parent_doc = try self.loadTemplate(extends_path);

            // Collect mixins from parent too
            try self.collectMixins(parent_doc.nodes);

            // Recursively resolve parent's inheritance
            return try self.resolveInheritance(parent_doc);
        }

        // No extends - return nodes as-is (blocks will be resolved during emission)
        return doc.nodes;
    }

    /// Collects mixin definitions from nodes
    fn collectMixins(self: *Compiler, nodes: []const ast.Node) !void {
        for (nodes) |node| {
            switch (node) {
                .mixin_def => |def| {
                    try self.mixins.put(def.name, def);
                },
                .element => |e| {
                    try self.collectMixins(e.children);
                },
                .conditional => |c| {
                    for (c.branches) |br| {
                        try self.collectMixins(br.children);
                    }
                },
                .each => |e| {
                    try self.collectMixins(e.children);
                    try self.collectMixins(e.else_children);
                },
                .block => |b| {
                    try self.collectMixins(b.children);
                },
                else => {},
            }
        }
    }

    /// Collects block definitions from child template
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

    /// Loads and parses a template file
    fn loadTemplate(self: *Compiler, path: []const u8) !ast.Document {
        // Build full path
        const full_path = blk: {
            // Check if path already has extension
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
            std.log.err("Tokenize error in included template '{s}': {}", .{ path, err });
            return err;
        };

        var parser = Parser.init(self.allocator, tokens);
        return parser.parse() catch |err| {
            std.log.err("Parse error in included template '{s}': {}", .{ path, err });
            return err;
        };
    }

    fn flush(self: *Compiler) !void {
        if (self.buf.items.len > 0) {
            try self.writeIndent();
            try self.writer.writeAll("try o.appendSlice(a, \"");
            try self.writer.writeAll(self.buf.items);
            try self.writer.writeAll("\");\n");
            self.buf.items.len = 0;
        }
    }

    fn flushAsReturn(self: *Compiler) !void {
        // For static-only templates - return string literal directly
        try self.writer.writeAll("\"");
        try self.writer.writeAll(self.buf.items);
        try self.writer.writeAll("\";\n");
        self.buf.items.len = 0;
    }

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

    /// Appends string content with normalized whitespace (for backtick template literals).
    /// Collapses newlines and multiple spaces into single spaces, trims leading/trailing whitespace.
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
                    '"' => "\\\"",
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

    fn emitElement(self: *Compiler, e: ast.Element) anyerror!void {
        const is_void = isVoidElement(e.tag) or e.self_closing;

        // Open tag
        try self.appendStatic("<");
        try self.appendStatic(e.tag);

        if (e.id) |id| {
            try self.appendStatic(" id=\"");
            try self.appendStatic(id);
            try self.appendStatic("\"");
        }

        if (e.classes.len > 0) {
            try self.appendStatic(" class=\"");
            for (e.classes, 0..) |cls, i| {
                if (i > 0) try self.appendStatic(" ");
                try self.appendStatic(cls);
            }
            try self.appendStatic("\"");
        }

        for (e.attributes) |attr| {
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

    fn emitExpr(self: *Compiler, expr: []const u8, escaped: bool) !void {
        try self.flush(); // Dynamic content - flush static buffer first
        try self.writeIndent();

        // Generate the accessor expression
        var accessor_buf: [512]u8 = undefined;
        const accessor = self.buildAccessor(expr, &accessor_buf);

        // Use strVal helper to handle type conversion
        if (escaped) {
            try self.writer.print("try esc(&o, a, strVal({s}));\n", .{accessor});
        } else {
            try self.writer.print("try o.appendSlice(a, strVal({s}));\n", .{accessor});
        }
    }

    /// Emits an attribute with its value, handling string concatenation expressions
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

    /// Find the + operator for string concatenation, accounting for quoted strings
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

    /// Emit a concatenation expression like "btn btn-" + type
    fn emitConcatExpr(self: *Compiler, value: []const u8, concat_pos: usize) !void {
        // Split on the + operator
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

    /// Emit expression inline (for attribute values) - doesn't flush or write indent
    fn emitExprInline(self: *Compiler, expr: []const u8, escaped: bool) !void {
        // For now, we need to flush and emit as separate statement
        // This is a limitation - dynamic attribute values need special handling
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

    fn buildAccessor(self: *Compiler, expr: []const u8, buf: []u8) []const u8 {
        // Handle nested field access like friend.name, subFriend.id
        if (std.mem.indexOfScalar(u8, expr, '.')) |dot| {
            const base = expr[0..dot];
            const rest = expr[dot + 1 ..];
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

    fn emitCondition(self: *Compiler, cond: []const u8) !void {
        // Handle string equality: status == "closed" -> std.mem.eql(u8, status, "closed")
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
        try self.writer.print("truthy({s})", .{accessor});
    }

    fn emitEach(self: *Compiler, e: ast.Each) anyerror!void {
        try self.flush();
        try self.writeIndent();

        // Track this loop variable
        try self.loop_vars.append(self.allocator, e.value_name);

        // Build accessor for collection
        var accessor_buf: [512]u8 = undefined;
        const collection_accessor = self.buildAccessor(e.collection, &accessor_buf);

        // Check if we need else branch handling
        if (e.else_children.len > 0) {
            // Need to check length first for else branch
            try self.writer.print("if ({s}.len > 0) {{\n", .{collection_accessor});
            self.depth += 1;
            try self.writeIndent();
        }

        // Generate the for loop - handle optional collections with orelse
        if (std.mem.indexOfScalar(u8, e.collection, '.')) |_| {
            // Nested field - may be optional
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

    fn emitCase(self: *Compiler, c: ast.Case) anyerror!void {
        try self.flush();

        // Build accessor for the expression
        var accessor_buf: [512]u8 = undefined;
        const expr_accessor = self.buildAccessor(c.expression, &accessor_buf);

        // Generate a series of if/else if statements to match case values
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

    fn emitBlock(self: *Compiler, blk: ast.Block) anyerror!void {
        // Check if child template overrides this block
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

    fn emitInclude(self: *Compiler, inc: ast.Include) anyerror!void {
        // Load and parse the included template
        const included_doc = self.loadTemplate(inc.path) catch |err| {
            std.log.warn("Failed to load include '{s}': {}", .{ inc.path, err });
            return;
        };

        // Collect mixins from included template
        try self.collectMixins(included_doc.nodes);

        // Emit included content inline
        for (included_doc.nodes) |node| {
            try self.emitNode(node);
        }
    }

    fn emitMixinCall(self: *Compiler, call: ast.MixinCall) anyerror!void {
        // Look up mixin definition
        const mixin_def = self.mixins.get(call.name) orelse {
            // Try to load from mixins directory
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

    fn emitMixinCallWithDef(self: *Compiler, call: ast.MixinCall, mixin_def: ast.MixinDef) anyerror!void {
        // For each mixin parameter, we need to create a local binding
        // This is complex in compiled mode - we inline the mixin body

        // Save current mixin params
        const prev_params_len = self.mixin_params.items.len;
        defer self.mixin_params.items.len = prev_params_len;

        // Calculate regular params (excluding rest param)
        const regular_params = if (mixin_def.has_rest and mixin_def.params.len > 0)
            mixin_def.params.len - 1
        else
            mixin_def.params.len;

        // Emit local variable declarations for mixin parameters
        try self.flush();

        for (mixin_def.params[0..regular_params], 0..) |param, i| {
            try self.mixin_params.append(self.allocator, param);

            // Escape param name if it's a Zig keyword
            var ident_buf: [64]u8 = undefined;
            const safe_param = escapeIdent(param, &ident_buf);

            try self.writeIndent();
            if (i < call.args.len) {
                // Argument provided
                const arg = call.args[i];
                // Check if it's a string literal
                if (arg.len >= 2 and (arg[0] == '"' or arg[0] == '\'')) {
                    try self.writer.print("const {s} = {s};\n", .{ safe_param, arg });
                } else {
                    // It's a variable reference
                    var accessor_buf: [512]u8 = undefined;
                    const accessor = self.buildAccessor(arg, &accessor_buf);
                    try self.writer.print("const {s} = {s};\n", .{ safe_param, accessor });
                }
            } else if (i < mixin_def.defaults.len) {
                // Use default value
                if (mixin_def.defaults[i]) |default| {
                    try self.writer.print("const {s} = {s};\n", .{ safe_param, default });
                } else {
                    try self.writer.print("const {s} = \"\";\n", .{safe_param});
                }
            } else {
                // No value - use empty string
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

        // Emit mixin body
        // Note: block content (call.block_children) is handled by mixin_block nodes
        // For now, we'll inline the mixin body directly
        for (mixin_def.children) |child| {
            // Handle mixin_block specially - replace with call's block_children
            if (child == .mixin_block) {
                for (call.block_children) |block_child| {
                    try self.emitNode(block_child);
                }
            } else {
                try self.emitNode(child);
            }
        }
    }

    /// Try to load a mixin from the mixins directory
    fn loadMixinFromDir(self: *Compiler, name: []const u8) ?ast.MixinDef {
        // Try specific file first: mixins/{name}.pug
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

    /// Parse source and extract a specific mixin definition
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

fn isVoidElement(tag: []const u8) bool {
    const voids = std.StaticStringMap(void).initComptime(.{
        .{ "area", {} },  .{ "base", {} }, .{ "br", {} },    .{ "col", {} },
        .{ "embed", {} }, .{ "hr", {} },   .{ "img", {} },   .{ "input", {} },
        .{ "link", {} },  .{ "meta", {} }, .{ "param", {} }, .{ "source", {} },
        .{ "track", {} }, .{ "wbr", {} },
    });
    return voids.has(tag);
}
