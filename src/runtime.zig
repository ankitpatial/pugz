//! Pugz Runtime - Evaluates templates with data context.
//!
//! The runtime takes a parsed AST and a data context, then produces
//! the final HTML output by:
//! - Substituting variables in interpolations
//! - Evaluating conditionals
//! - Iterating over collections
//! - Calling mixins
//! - Template inheritance (extends/block)
//! - Includes
//!
//! **Memory Management**: Use an arena allocator for best performance and
//! automatic cleanup. The runtime allocates intermediate strings during
//! template processing that are cleaned up when the arena is reset/deinitialized.
//!
//! ```zig
//! var arena = std.heap.ArenaAllocator.init(gpa.allocator());
//! defer arena.deinit();
//!
//! const html = try engine.renderTpl(arena.allocator(), template, data);
//! // Use html... arena.deinit() frees everything
//! ```

const std = @import("std");
const ast = @import("ast.zig");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;

const log = std.log.scoped(.@"pugz/runtime");

/// A value in the template context.
pub const Value = union(enum) {
    /// Null/undefined value.
    null,
    /// Boolean value.
    bool: bool,
    /// Integer value.
    int: i64,
    /// Floating point value.
    float: f64,
    /// String value.
    string: []const u8,
    /// Array of values.
    array: []const Value,
    /// Object/map of string keys to values.
    object: std.StringHashMapUnmanaged(Value),

    /// Returns the value as a string for output.
    /// For integers, uses pre-computed strings for small values to avoid allocation.
    pub fn toString(self: Value, allocator: std.mem.Allocator) ![]const u8 {
        // Fast path: strings are most common in templates (branch hint)
        if (self == .string) {
            @branchHint(.likely);
            return self.string;
        }
        return switch (self) {
            .string => unreachable, // handled above
            .null => "",
            .bool => |b| if (b) "true" else "false",
            .int => |i| blk: {
                // Fast path for common small integers (0-99)
                if (i >= 0 and i < 100) {
                    break :blk small_int_strings[@intCast(i)];
                }
                // Allocate for larger integers
                break :blk try std.fmt.allocPrint(allocator, "{d}", .{i});
            },
            .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
            .array => "[Array]",
            .object => "[Object]",
        };
    }

    /// Pre-computed strings for small integers 0-99 (common in loops)
    const small_int_strings = [_][]const u8{
        "0",  "1",  "2",  "3",  "4",  "5",  "6",  "7",  "8",  "9",
        "10", "11", "12", "13", "14", "15", "16", "17", "18", "19",
        "20", "21", "22", "23", "24", "25", "26", "27", "28", "29",
        "30", "31", "32", "33", "34", "35", "36", "37", "38", "39",
        "40", "41", "42", "43", "44", "45", "46", "47", "48", "49",
        "50", "51", "52", "53", "54", "55", "56", "57", "58", "59",
        "60", "61", "62", "63", "64", "65", "66", "67", "68", "69",
        "70", "71", "72", "73", "74", "75", "76", "77", "78", "79",
        "80", "81", "82", "83", "84", "85", "86", "87", "88", "89",
        "90", "91", "92", "93", "94", "95", "96", "97", "98", "99",
    };

    /// Returns the value as a boolean for conditionals.
    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .null => false,
            .bool => |b| b,
            .int => |i| i != 0,
            .float => |f| f != 0.0,
            .string => |s| s.len > 0,
            .array => |a| a.len > 0,
            .object => true,
        };
    }

    /// Creates a string value.
    pub fn str(s: []const u8) Value {
        return .{ .string = s };
    }

    /// Creates an integer value.
    pub fn integer(i: i64) Value {
        return .{ .int = i };
    }

    /// Creates a boolean value.
    pub fn boolean(b: bool) Value {
        return .{ .bool = b };
    }
};

/// Runtime errors.
pub const RuntimeError = error{
    OutOfMemory,
    UndefinedVariable,
    TypeError,
    InvalidExpression,
    ParseError,
};

/// Template rendering context with variable scopes.
pub const Context = struct {
    allocator: std.mem.Allocator,
    /// Stack of variable scopes (innermost last).
    /// We keep all scopes allocated and track active depth with scope_depth.
    scopes: std.ArrayListUnmanaged(std.StringHashMapUnmanaged(Value)),
    /// Current active scope depth (scopes[0..scope_depth] are active).
    scope_depth: usize,
    /// Mixin definitions available in this context.
    mixins: std.StringHashMapUnmanaged(ast.MixinDef),

    pub fn init(allocator: std.mem.Allocator) Context {
        return .{
            .allocator = allocator,
            .scopes = .empty,
            .scope_depth = 0,
            .mixins = .empty,
        };
    }

    pub fn deinit(self: *Context) void {
        for (self.scopes.items) |*scope| {
            scope.*.deinit(self.allocator);
        }
        self.scopes.deinit(self.allocator);
        self.mixins.deinit(self.allocator);
    }

    /// Pushes a new scope onto the stack.
    /// Reuses previously allocated scopes when possible to avoid allocation overhead.
    pub fn pushScope(self: *Context) !void {
        if (self.scope_depth < self.scopes.items.len) {
            // Reuse existing scope slot (already cleared on pop)
        } else {
            // Need to allocate a new scope
            try self.scopes.append(self.allocator, .empty);
        }
        self.scope_depth += 1;
    }

    /// Pops the current scope from the stack.
    /// Clears scope for reuse but does NOT deallocate.
    pub fn popScope(self: *Context) void {
        if (self.scope_depth > 0) {
            self.scope_depth -= 1;
            // Clear the scope so old values don't leak into next use
            self.scopes.items[self.scope_depth].clearRetainingCapacity();
        }
    }

    /// Sets a variable in the current scope.
    pub fn set(self: *Context, name: []const u8, value: Value) !void {
        if (self.scope_depth == 0) {
            try self.pushScope();
        }
        const current = &self.scopes.items[self.scope_depth - 1];
        try current.put(self.allocator, name, value);
    }

    /// Gets or creates a slot for a variable, returning a pointer to the value.
    /// Use this for loop variables that are updated repeatedly.
    pub fn getOrPutPtr(self: *Context, name: []const u8) !*Value {
        if (self.scope_depth == 0) {
            try self.pushScope();
        }
        const current = &self.scopes.items[self.scope_depth - 1];
        const gop = try current.getOrPut(self.allocator, name);
        if (!gop.found_existing) {
            gop.value_ptr.* = Value.null;
        }
        return gop.value_ptr;
    }

    /// Gets a variable, searching from innermost to outermost scope.
    pub fn get(self: *Context, name: []const u8) ?Value {
        // Fast path: most lookups are in the innermost scope
        if (self.scope_depth > 0) {
            @branchHint(.likely);
            if (self.scopes.items[self.scope_depth - 1].get(name)) |value| {
                return value;
            }
        }
        // Search remaining scopes (less common)
        var i = self.scope_depth -| 1;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |value| {
                return value;
            }
        }
        return null;
    }

    /// Registers a mixin definition.
    pub fn defineMixin(self: *Context, mixin: ast.MixinDef) !void {
        try self.mixins.put(self.allocator, mixin.name, mixin);
    }

    /// Gets a mixin definition by name.
    pub fn getMixin(self: *Context, name: []const u8) ?ast.MixinDef {
        return self.mixins.get(name);
    }
};

/// File resolver function type for loading templates.
/// Takes a path and returns the file contents, or null if not found.
pub const FileResolver = *const fn (allocator: std.mem.Allocator, path: []const u8) ?[]const u8;

/// Block definition collected from child templates.
const BlockDef = struct {
    name: []const u8,
    mode: ast.Block.Mode,
    children: []const ast.Node,
};

/// Runtime engine for evaluating templates.
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    context: *Context,
    output: std.ArrayListUnmanaged(u8),
    depth: usize,
    options: Options,
    /// File resolver for loading external templates.
    file_resolver: ?FileResolver,
    /// Base directory for resolving relative paths.
    base_dir: []const u8,
    /// Directory containing mixin files for lazy-loading.
    mixins_dir: []const u8,
    /// Block definitions from child template (for inheritance).
    blocks: std.StringHashMapUnmanaged(BlockDef),
    /// Current mixin block content (for `block` keyword inside mixins).
    mixin_block_content: ?[]const ast.Node,
    /// Current mixin attributes (for `attributes` variable inside mixins).
    mixin_attributes: ?[]const ast.Attribute,

    pub const Options = struct {
        pretty: bool = true,
        indent_str: []const u8 = "  ",
        self_closing: bool = true,
        /// Base directory for resolving template paths.
        base_dir: []const u8 = "",
        /// File resolver for loading templates.
        file_resolver: ?FileResolver = null,
        /// Directory containing mixin files for lazy-loading.
        /// If set, mixins not found in template will be loaded from here.
        mixins_dir: []const u8 = "",
    };

    /// Error type for runtime operations.
    pub const Error = RuntimeError || std.mem.Allocator.Error || error{TemplateNotFound};

    pub fn init(allocator: std.mem.Allocator, context: *Context, options: Options) Runtime {
        return .{
            .allocator = allocator,
            .context = context,
            .output = .empty,
            .depth = 0,
            .options = options,
            .file_resolver = options.file_resolver,
            .base_dir = options.base_dir,
            .mixins_dir = options.mixins_dir,
            .blocks = .empty,
            .mixin_block_content = null,
            .mixin_attributes = null,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.output.deinit(self.allocator);
        self.blocks.deinit(self.allocator);
    }

    /// Renders the document and returns the HTML output.
    pub fn render(self: *Runtime, doc: ast.Document) Error![]const u8 {
        // Pre-allocate buffer - 256KB handles most large templates without realloc
        try self.output.ensureTotalCapacity(self.allocator, 256 * 1024);

        // Handle template inheritance
        if (doc.extends_path) |extends_path| {
            // Collect blocks from child template
            try self.collectBlocks(doc.nodes);

            // Load and render parent template
            const parent_doc = try self.loadTemplate(extends_path);
            return self.render(parent_doc);
        }

        for (doc.nodes) |node| {
            try self.visitNode(node);
        }

        return self.output.items;
    }

    /// Collects block definitions from child template nodes.
    fn collectBlocks(self: *Runtime, nodes: []const ast.Node) Error!void {
        for (nodes) |node| {
            switch (node) {
                .block => |blk| {
                    try self.blocks.put(self.allocator, blk.name, .{
                        .name = blk.name,
                        .mode = blk.mode,
                        .children = blk.children,
                    });
                },
                else => {},
            }
        }
    }

    /// Loads and parses a template file.
    fn loadTemplate(self: *Runtime, path: []const u8) Error!ast.Document {
        const resolver = self.file_resolver orelse return error.TemplateNotFound;

        // Resolve path (add .pug extension if needed)
        var resolved_path: []const u8 = path;
        if (!std.mem.endsWith(u8, path, ".pug")) {
            resolved_path = try std.fmt.allocPrint(self.allocator, "{s}.pug", .{path});
        }

        // Prepend base directory if path is relative
        var full_path = resolved_path;
        if (self.base_dir.len > 0 and !std.fs.path.isAbsolute(resolved_path)) {
            full_path = try std.fs.path.join(self.allocator, &.{ self.base_dir, resolved_path });
        }

        const source = resolver(self.allocator, full_path) orelse return error.TemplateNotFound;

        // Parse the template
        var lexer = Lexer.init(self.allocator, source);
        const tokens = lexer.tokenize() catch return error.TemplateNotFound;

        var parser = Parser.init(self.allocator, tokens);
        return parser.parse() catch return error.TemplateNotFound;
    }

    /// Renders and returns an owned copy of the output.
    pub fn renderOwned(self: *Runtime, doc: ast.Document) Error![]u8 {
        const result = try self.render(doc);
        return try self.allocator.dupe(u8, result);
    }

    fn visitNode(self: *Runtime, node: ast.Node) Error!void {
        switch (node) {
            .doctype => |dt| try self.visitDoctype(dt),
            .element => |elem| try self.visitElement(elem),
            .text => |text| try self.visitText(text),
            .comment => |comment| try self.visitComment(comment),
            .conditional => |cond| try self.visitConditional(cond),
            .each => |each| try self.visitEach(each),
            .@"while" => |whl| try self.visitWhile(whl),
            .case => |c| try self.visitCase(c),
            .mixin_def => |def| try self.context.defineMixin(def),
            .mixin_call => |call| try self.visitMixinCall(call),
            .mixin_block => try self.visitMixinBlock(),
            .code => |code| try self.visitCode(code),
            .raw_text => |raw| try self.visitRawText(raw),
            .block => |blk| try self.visitBlock(blk),
            .include => |inc| try self.visitInclude(inc),
            .extends => {}, // Handled at document level
            .document => |doc| {
                for (doc.nodes) |child| {
                    try self.visitNode(child);
                }
            },
        }
    }

    /// Doctype shortcuts mapping
    const doctype_shortcuts = std.StaticStringMap([]const u8).initComptime(.{
        .{ "html", "<!DOCTYPE html>" },
        .{ "xml", "<?xml version=\"1.0\" encoding=\"utf-8\" ?>" },
        .{ "transitional", "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Transitional//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd\">" },
        .{ "strict", "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\">" },
        .{ "frameset", "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Frameset//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-frameset.dtd\">" },
        .{ "1.1", "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">" },
        .{ "basic", "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML Basic 1.1//EN\" \"http://www.w3.org/TR/xhtml-basic/xhtml-basic11.dtd\">" },
        .{ "mobile", "<!DOCTYPE html PUBLIC \"-//WAPFORUM//DTD XHTML Mobile 1.2//EN\" \"http://www.openmobilealliance.org/tech/DTD/xhtml-mobile12.dtd\">" },
        .{ "plist", "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" },
    });

    fn visitDoctype(self: *Runtime, dt: ast.Doctype) Error!void {
        // Look up shortcut or use custom doctype
        if (doctype_shortcuts.get(dt.value)) |output| {
            try self.write(output);
        } else {
            // Custom doctype: output as-is with <!DOCTYPE prefix
            try self.write("<!DOCTYPE ");
            try self.write(dt.value);
            try self.write(">");
        }
        try self.writeNewline();
    }

    fn visitElement(self: *Runtime, elem: ast.Element) Error!void {
        const is_void = isVoidElement(elem.tag) or elem.self_closing;

        try self.writeIndent();
        try self.write("<");
        try self.write(elem.tag);

        if (elem.id) |id| {
            try self.write(" id=\"");
            try self.writeEscaped(id);
            try self.write("\"");
        }

        // Collect all classes: shorthand classes + class attributes (may be arrays)
        var all_classes = std.ArrayListUnmanaged(u8).empty;
        defer all_classes.deinit(self.allocator);

        // Add shorthand classes first (e.g., .bang)
        for (elem.classes, 0..) |class, i| {
            if (i > 0) try all_classes.append(self.allocator, ' ');
            try all_classes.appendSlice(self.allocator, class);
        }

        // Process attributes, collecting class values separately
        for (elem.attributes) |attr| {
            if (std.mem.eql(u8, attr.name, "class")) {
                // Handle class attribute - may be array literal or expression
                if (attr.value) |value| {
                    var evaluated: []const u8 = undefined;

                    // Check if it's an array literal
                    if (value.len >= 1 and value[0] == '[') {
                        evaluated = try parseArrayToSpaceSeparated(self.allocator, value);
                    } else {
                        // Evaluate as expression (handles "str" + var concatenation)
                        const expr_value = self.evaluateExpression(value);
                        evaluated = try expr_value.toString(self.allocator);
                    }

                    if (evaluated.len > 0) {
                        if (all_classes.items.len > 0) {
                            try all_classes.append(self.allocator, ' ');
                        }
                        try all_classes.appendSlice(self.allocator, evaluated);
                    }
                }
                continue; // Don't output class as regular attribute
            }

            if (attr.value) |value| {
                // Handle boolean literals: true -> checked="checked", false -> omit
                if (std.mem.eql(u8, value, "true")) {
                    // true becomes attribute="attribute"
                    try self.write(" ");
                    try self.write(attr.name);
                    try self.write("=\"");
                    try self.write(attr.name);
                    try self.write("\"");
                } else if (std.mem.eql(u8, value, "false")) {
                    // false omits the attribute entirely
                    continue;
                } else {
                    try self.write(" ");
                    try self.write(attr.name);
                    try self.write("=\"");
                    // Evaluate attribute value - could be a quoted string, object/array literal, or variable
                    var evaluated: []const u8 = undefined;

                    // Check if it's a quoted string, object literal, or array literal
                    if (value.len >= 2 and (value[0] == '"' or value[0] == '\'' or value[0] == '`')) {
                        // Quoted string - strip quotes
                        evaluated = try self.evaluateString(value);
                    } else if (value.len >= 1 and (value[0] == '{' or value[0] == '[')) {
                        // Object or array literal - use as-is
                        evaluated = value;
                    } else {
                        // Unquoted - evaluate as expression (variable lookup)
                        const expr_value = self.evaluateExpression(value);
                        evaluated = try expr_value.toString(self.allocator);
                    }

                    // Special handling for style attribute with object literal
                    if (std.mem.eql(u8, attr.name, "style") and evaluated.len > 0 and evaluated[0] == '{') {
                        evaluated = try parseObjectToCSS(self.allocator, evaluated);
                    }

                    if (attr.escaped) {
                        try self.writeEscaped(evaluated);
                    } else {
                        try self.write(evaluated);
                    }
                    try self.write("\"");
                }
            } else {
                // Boolean attribute: checked -> checked="checked"
                try self.write(" ");
                try self.write(attr.name);
                try self.write("=\"");
                try self.write(attr.name);
                try self.write("\"");
            }
        }

        // Output combined class attribute
        if (all_classes.items.len > 0) {
            try self.write(" class=\"");
            try self.writeEscaped(all_classes.items);
            try self.write("\"");
        }

        // Output spread attributes: &attributes({'data-foo': 'bar'}) or &attributes(attributes)
        if (elem.spread_attributes) |spread| {
            // First try to evaluate as a variable (for mixin attributes)
            const value = self.evaluateExpression(spread);
            switch (value) {
                .object => |obj| {
                    // Render object properties as attributes
                    var iter = obj.iterator();
                    while (iter.next()) |entry| {
                        const attr_value = entry.value_ptr.*;
                        const str = try attr_value.toString(self.allocator);
                        try self.write(" ");
                        try self.write(entry.key_ptr.*);
                        try self.write("=\"");
                        try self.writeEscaped(str);
                        try self.write("\"");
                    }
                },
                else => {
                    // Fall back to parsing as object literal string
                    try self.writeSpreadAttributes(spread);
                },
            }
        }

        if (is_void and self.options.self_closing) {
            try self.write(" />");
            try self.writeNewline();
            return;
        }

        try self.write(">");

        const has_inline = elem.inline_text != null and elem.inline_text.?.len > 0;
        const has_buffered = elem.buffered_code != null;
        const has_children = elem.children.len > 0;

        if (has_inline) {
            try self.writeTextSegments(elem.inline_text.?);
        }

        if (has_buffered) {
            const code = elem.buffered_code.?;
            const value = self.evaluateExpression(code.expression);
            const str = try value.toString(self.allocator);
            if (code.escaped) {
                try self.writeEscaped(str);
            } else {
                try self.write(str);
            }
        }

        if (has_children) {
            if (!has_inline and !has_buffered) try self.writeNewline();
            self.depth += 1;
            for (elem.children) |child| {
                try self.visitNode(child);
            }
            self.depth -= 1;
            if (!has_inline and !has_buffered) try self.writeIndent();
        }

        try self.write("</");
        try self.write(elem.tag);
        try self.write(">");
        try self.writeNewline();
    }

    fn visitText(self: *Runtime, text: ast.Text) Error!void {
        try self.writeIndent();
        try self.writeTextSegments(text.segments);
        try self.writeNewline();
    }

    fn visitComment(self: *Runtime, comment: ast.Comment) Error!void {
        if (!comment.rendered) return;

        try self.writeIndent();
        try self.write("<!--");
        if (comment.content.len > 0) {
            try self.write(" ");
            try self.write(comment.content);
            try self.write(" ");
        }
        try self.write("-->");
        try self.writeNewline();
    }

    fn visitConditional(self: *Runtime, cond: ast.Conditional) Error!void {
        for (cond.branches) |branch| {
            const should_render = if (branch.condition) |condition| blk: {
                const value = self.evaluateExpression(condition);
                const truthy = value.isTruthy();
                break :blk if (branch.is_unless) !truthy else truthy;
            } else true; // else branch

            if (should_render) {
                for (branch.children) |child| {
                    try self.visitNode(child);
                }
                return; // Only render first matching branch
            }
        }
    }

    fn visitEach(self: *Runtime, each: ast.Each) Error!void {
        const collection = self.evaluateExpression(each.collection);

        switch (collection) {
            .array => |items| {
                if (items.len == 0) {
                    // Render else branch if collection is empty
                    for (each.else_children) |child| {
                        try self.visitNode(child);
                    }
                    return;
                }

                // Push scope once before the loop - reuse for all iterations
                try self.context.pushScope();
                defer self.context.popScope();

                // Get direct pointers to loop variables - avoids hash lookup per iteration
                const value_ptr = try self.context.getOrPutPtr(each.value_name);
                const index_ptr: ?*Value = if (each.index_name) |idx_name|
                    try self.context.getOrPutPtr(idx_name)
                else
                    null;

                for (items, 0..) |item, index| {
                    // Direct pointer update - no hash lookup!
                    value_ptr.* = item;
                    if (index_ptr) |ptr| {
                        ptr.* = Value.integer(@intCast(index));
                    }

                    for (each.children) |child| {
                        try self.visitNode(child);
                    }
                }
            },
            .object => |obj| {
                if (obj.count() == 0) {
                    for (each.else_children) |child| {
                        try self.visitNode(child);
                    }
                    return;
                }

                // Push scope once before the loop - reuse for all iterations
                try self.context.pushScope();
                defer self.context.popScope();

                // Get direct pointers to loop variables
                const value_ptr = try self.context.getOrPutPtr(each.value_name);
                const index_ptr: ?*Value = if (each.index_name) |idx_name|
                    try self.context.getOrPutPtr(idx_name)
                else
                    null;

                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    // Direct pointer update - no hash lookup!
                    value_ptr.* = entry.value_ptr.*;
                    if (index_ptr) |ptr| {
                        ptr.* = Value.str(entry.key_ptr.*);
                    }

                    for (each.children) |child| {
                        try self.visitNode(child);
                    }
                }
            },
            else => {
                // Not iterable - render else branch
                for (each.else_children) |child| {
                    try self.visitNode(child);
                }
            },
        }
    }

    fn visitWhile(self: *Runtime, whl: ast.While) Error!void {
        var iterations: usize = 0;
        const max_iterations: usize = 10000; // Safety limit

        while (iterations < max_iterations) {
            const condition = self.evaluateExpression(whl.condition);
            if (!condition.isTruthy()) break;

            for (whl.children) |child| {
                try self.visitNode(child);
            }
            iterations += 1;
        }
    }

    fn visitCase(self: *Runtime, c: ast.Case) Error!void {
        const expr_value = self.evaluateExpression(c.expression);

        // Find matching when clause
        var matched = false;
        var fall_through = false;

        for (c.whens) |when| {
            // Check if we're falling through from previous match
            if (fall_through) {
                if (when.has_break) {
                    // Explicit break - stop here without output
                    return;
                }
                if (when.children.len > 0) {
                    // Has content - render it
                    for (when.children) |child| {
                        try self.visitNode(child);
                    }
                    return;
                }
                // Empty body - continue falling through
                continue;
            }

            // Parse when value and compare
            const when_value = self.evaluateExpression(when.value);

            if (self.valuesEqual(expr_value, when_value)) {
                matched = true;

                if (when.has_break) {
                    // Explicit break - output nothing
                    return;
                }

                if (when.children.len == 0) {
                    // Empty body - fall through to next
                    fall_through = true;
                    continue;
                }

                // Render matching case
                for (when.children) |child| {
                    try self.visitNode(child);
                }
                return;
            }
        }

        // No match - render default if present
        if (!matched or fall_through) {
            for (c.default_children) |child| {
                try self.visitNode(child);
            }
        }
    }

    /// Compares two Values for equality.
    fn valuesEqual(self: *Runtime, a: Value, b: Value) bool {
        _ = self;
        return switch (a) {
            .int => |ai| switch (b) {
                .int => |bi| ai == bi,
                .float => |bf| @as(f64, @floatFromInt(ai)) == bf,
                .string => |bs| blk: {
                    const parsed = std.fmt.parseInt(i64, bs, 10) catch break :blk false;
                    break :blk ai == parsed;
                },
                else => false,
            },
            .float => |af| switch (b) {
                .int => |bi| af == @as(f64, @floatFromInt(bi)),
                .float => |bf| af == bf,
                else => false,
            },
            .string => |as| switch (b) {
                .string => |bs| std.mem.eql(u8, as, bs),
                .int => |bi| blk: {
                    const parsed = std.fmt.parseInt(i64, as, 10) catch break :blk false;
                    break :blk parsed == bi;
                },
                else => false,
            },
            .bool => |ab| switch (b) {
                .bool => |bb| ab == bb,
                else => false,
            },
            else => false,
        };
    }

    fn visitMixinCall(self: *Runtime, call: ast.MixinCall) Error!void {
        // First check if mixin is defined in current context (same template or preloaded)
        var mixin = self.context.getMixin(call.name);

        // If not found and mixins_dir is configured, try loading from mixins directory
        if (mixin == null and self.mixins_dir.len > 0) {
            if (self.loadMixinFromDir(call.name)) |loaded_mixin| {
                try self.context.defineMixin(loaded_mixin);
                mixin = loaded_mixin;
            }
        }

        // If still not found, log warning and skip this mixin call
        const mixin_def = mixin orelse {
            log.warn("skipping, mixin '{s}' not found", .{call.name});
            return;
        };

        try self.context.pushScope();
        defer self.context.popScope();

        // Save previous mixin context
        const prev_block_content = self.mixin_block_content;
        const prev_attributes = self.mixin_attributes;
        defer {
            self.mixin_block_content = prev_block_content;
            self.mixin_attributes = prev_attributes;
        }

        // Set current mixin's block content and attributes
        self.mixin_block_content = if (call.block_children.len > 0) call.block_children else null;
        self.mixin_attributes = if (call.attributes.len > 0) call.attributes else null;

        // Set 'attributes' variable with the passed attributes as an object
        if (call.attributes.len > 0) {
            var attrs_obj = std.StringHashMapUnmanaged(Value).empty;
            for (call.attributes) |attr| {
                if (attr.value) |val| {
                    // Strip quotes from attribute value for the object
                    const clean_val = try self.evaluateString(val);
                    attrs_obj.put(self.allocator, attr.name, Value.str(clean_val)) catch |err| {
                        log.warn("skipping attribute, failed to set '{s}': {}", .{ attr.name, err });
                    };
                } else {
                    attrs_obj.put(self.allocator, attr.name, Value.boolean(true)) catch |err| {
                        log.warn("skipping attribute, failed to set '{s}': {}", .{ attr.name, err });
                    };
                }
            }
            try self.context.set("attributes", .{ .object = attrs_obj });
        } else {
            try self.context.set("attributes", .{ .object = std.StringHashMapUnmanaged(Value).empty });
        }

        // Bind arguments to parameters
        const regular_params = if (mixin_def.has_rest and mixin_def.params.len > 0)
            mixin_def.params.len - 1
        else
            mixin_def.params.len;

        // Bind regular parameters
        for (mixin_def.params[0..regular_params], 0..) |param, i| {
            const value = if (i < call.args.len)
                self.evaluateExpression(call.args[i])
            else if (i < mixin_def.defaults.len and mixin_def.defaults[i] != null)
                self.evaluateExpression(mixin_def.defaults[i].?)
            else
                Value.null;

            try self.context.set(param, value);
        }

        // Bind rest parameter if present
        if (mixin_def.has_rest and mixin_def.params.len > 0) {
            const rest_param = mixin_def.params[mixin_def.params.len - 1];
            const rest_start = regular_params;

            if (rest_start < call.args.len) {
                // Collect remaining arguments into an array
                const rest_count = call.args.len - rest_start;
                const rest_array = self.allocator.alloc(Value, rest_count) catch return error.OutOfMemory;
                for (call.args[rest_start..], 0..) |arg, i| {
                    rest_array[i] = self.evaluateExpression(arg);
                }
                try self.context.set(rest_param, .{ .array = rest_array });
            } else {
                // No rest arguments, set empty array
                const empty = self.allocator.alloc(Value, 0) catch return error.OutOfMemory;
                try self.context.set(rest_param, .{ .array = empty });
            }
        }

        // Render mixin body
        for (mixin_def.children) |child| {
            try self.visitNode(child);
        }
    }

    /// Loads a mixin from the mixins directory by name.
    /// Searches for files named {name}.pug or iterates through all .pug files.
    /// Note: The source file memory is intentionally not freed to keep AST slices valid.
    fn loadMixinFromDir(self: *Runtime, name: []const u8) ?ast.MixinDef {
        const resolver = self.file_resolver orelse return null;

        // First try: look for a file named {name}.pug
        const specific_path = std.fs.path.join(self.allocator, &.{ self.mixins_dir, name }) catch |err| {
            log.warn("skipping mixin lookup, failed to join path for '{s}': {}", .{ name, err });
            return null;
        };
        defer self.allocator.free(specific_path);

        const with_ext = std.fmt.allocPrint(self.allocator, "{s}.pug", .{specific_path}) catch |err| {
            log.warn("skipping mixin lookup, failed to allocate path for '{s}': {}", .{ name, err });
            return null;
        };
        defer self.allocator.free(with_ext);

        if (resolver(self.allocator, with_ext)) |source| {
            // Note: source is intentionally not freed - AST nodes contain slices into it
            if (self.parseMixinFromSource(source, name)) |mixin_def| {
                return mixin_def;
            }
            // Only free if we didn't find the mixin we wanted
            self.allocator.free(source);
        }

        // Second try: iterate through all .pug files in mixins directory
        // Use cwd().openDir for relative paths, openDirAbsolute for absolute paths
        var dir = if (std.fs.path.isAbsolute(self.mixins_dir))
            std.fs.openDirAbsolute(self.mixins_dir, .{ .iterate = true }) catch |err| {
                log.warn("skipping mixins directory scan, failed to open '{s}': {}", .{ self.mixins_dir, err });
                return null;
            }
        else
            std.fs.cwd().openDir(self.mixins_dir, .{ .iterate = true }) catch |err| {
                log.warn("skipping mixins directory scan, failed to open '{s}': {}", .{ self.mixins_dir, err });
                return null;
            };
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch |err| {
            log.warn("skipping mixins directory scan, iteration failed: {}", .{err});
            return null;
        }) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".pug")) continue;

            const file_path = std.fs.path.join(self.allocator, &.{ self.mixins_dir, entry.name }) catch |err| {
                log.warn("skipping mixin file, failed to join path for '{s}': {}", .{ entry.name, err });
                continue;
            };
            defer self.allocator.free(file_path);

            if (resolver(self.allocator, file_path)) |source| {
                // Note: source is intentionally not freed - AST nodes contain slices into it
                if (self.parseMixinFromSource(source, name)) |mixin_def| {
                    return mixin_def;
                }
                // Only free if we didn't find the mixin we wanted
                self.allocator.free(source);
            }
        }

        return null;
    }

    /// Parses a source file and extracts a mixin definition by name.
    fn parseMixinFromSource(self: *Runtime, source: []const u8, name: []const u8) ?ast.MixinDef {
        var lexer = Lexer.init(self.allocator, source);
        const tokens = lexer.tokenize() catch |err| {
            log.warn("skipping mixin file, tokenize failed for '{s}': {}", .{ name, err });
            return null;
        };
        // Note: lexer is not deinitialized - tokens contain slices into source

        var parser = Parser.init(self.allocator, tokens);
        const doc = parser.parse() catch |err| {
            log.warn("skipping mixin file, parse failed for '{s}': {}", .{ name, err });
            return null;
        };

        // Find the mixin definition with the matching name
        for (doc.nodes) |node| {
            if (node == .mixin_def) {
                if (std.mem.eql(u8, node.mixin_def.name, name)) {
                    return node.mixin_def;
                }
            }
        }

        return null;
    }

    /// Renders the mixin block content (for `block` keyword inside mixins).
    fn visitMixinBlock(self: *Runtime) Error!void {
        if (self.mixin_block_content) |block_children| {
            for (block_children) |child| {
                try self.visitNode(child);
            }
        }
    }

    fn visitCode(self: *Runtime, code: ast.Code) Error!void {
        const value = self.evaluateExpression(code.expression);
        const str = try value.toString(self.allocator);

        try self.writeIndent();
        if (code.escaped) {
            try self.writeEscaped(str);
        } else {
            try self.write(str);
        }
        try self.writeNewline();
    }

    fn visitRawText(self: *Runtime, raw: ast.RawText) Error!void {
        // Raw text already includes its own indentation, don't add extra
        try self.write(raw.content);
        try self.writeNewline();
    }

    /// Visits a block node, handling inheritance (replace/append/prepend).
    fn visitBlock(self: *Runtime, blk: ast.Block) Error!void {
        // Check if child template overrides this block
        if (self.blocks.get(blk.name)) |child_block| {
            switch (child_block.mode) {
                .replace => {
                    // Child completely replaces parent block
                    for (child_block.children) |child| {
                        try self.visitNode(child);
                    }
                },
                .append => {
                    // Parent content first, then child content
                    for (blk.children) |child| {
                        try self.visitNode(child);
                    }
                    for (child_block.children) |child| {
                        try self.visitNode(child);
                    }
                },
                .prepend => {
                    // Child content first, then parent content
                    for (child_block.children) |child| {
                        try self.visitNode(child);
                    }
                    for (blk.children) |child| {
                        try self.visitNode(child);
                    }
                },
            }
        } else {
            // No override - render default block content
            for (blk.children) |child| {
                try self.visitNode(child);
            }
        }
    }

    /// Visits an include node, loading and rendering the included template.
    fn visitInclude(self: *Runtime, inc: ast.Include) Error!void {
        const included_doc = try self.loadTemplate(inc.path);

        // TODO: Handle filters (inc.filter) like :markdown

        // Render included template inline
        for (included_doc.nodes) |node| {
            try self.visitNode(node);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Expression evaluation
    // ─────────────────────────────────────────────────────────────────────────

    /// Evaluates a simple expression (variable lookup or literal).
    /// Optimized for common cases: simple variable names without operators.
    fn evaluateExpression(self: *Runtime, expr: []const u8) Value {
        // Fast path: empty expression
        if (expr.len == 0) return Value.null;

        const first = expr[0];

        // Ultra-fast path: identifier starting with a-z (most common case)
        // Covers: friend, name, friend.name, friend.email, tag, etc.
        if (first >= 'a' and first <= 'z') {
            // Scan for operators - if none found, direct variable lookup
            for (expr) |c| {
                // Check for operators that require complex evaluation
                if (c == '+' or c == '[' or c == '(' or c == '{' or c == ' ' or c == '\t') {
                    break;
                }
            } else {
                // No operators found - direct variable lookup (most common path)
                return self.lookupVariable(expr);
            }
        }

        // Fast path: check if expression needs trimming
        const last = expr[expr.len - 1];
        const needs_trim = first == ' ' or first == '\t' or last == ' ' or last == '\t';
        const trimmed = if (needs_trim) std.mem.trim(u8, expr, " \t") else expr;

        if (trimmed.len == 0) return Value.null;

        // Fast path: simple variable lookup (no special chars except dots)
        // Most expressions in templates are just variable names like "name" or "friend.email"
        const first_char = trimmed[0];
        if (first_char != '"' and first_char != '\'' and first_char != '-' and
            (first_char < '0' or first_char > '9'))
        {
            // Quick scan: if no special operators, go straight to variable lookup
            var has_operator = false;
            for (trimmed) |c| {
                if (c == '+' or c == '[' or c == '(' or c == '{') {
                    has_operator = true;
                    break;
                }
            }
            if (!has_operator) {
                // Check for boolean/null literals
                if (trimmed.len <= 5) {
                    if (std.mem.eql(u8, trimmed, "true")) return Value.boolean(true);
                    if (std.mem.eql(u8, trimmed, "false")) return Value.boolean(false);
                    if (std.mem.eql(u8, trimmed, "null")) return Value.null;
                }
                // Simple variable lookup
                return self.lookupVariable(trimmed);
            }
        }

        // Check for string concatenation with + operator
        // e.g., "btn btn-" + type or "hello " + name + "!"
        if (self.findConcatOperator(trimmed)) |op_pos| {
            const left = std.mem.trim(u8, trimmed[0..op_pos], " \t");
            const right = std.mem.trim(u8, trimmed[op_pos + 1 ..], " \t");

            const left_val = self.evaluateExpression(left);
            const right_val = self.evaluateExpression(right);

            const left_str = left_val.toString(self.allocator) catch return Value.null;
            const right_str = right_val.toString(self.allocator) catch return Value.null;

            const result = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ left_str, right_str }) catch return Value.null;
            return Value.str(result);
        }

        // Check for string literal
        if (trimmed.len >= 2) {
            if ((first_char == '"' and trimmed[trimmed.len - 1] == '"') or
                (first_char == '\'' and trimmed[trimmed.len - 1] == '\''))
            {
                return Value.str(trimmed[1 .. trimmed.len - 1]);
            }
        }

        // Check for numeric literal
        if (std.fmt.parseInt(i64, trimmed, 10)) |i| {
            return Value.integer(i);
        } else |_| {}

        // Check for boolean literals (fallback for complex expressions)
        if (std.mem.eql(u8, trimmed, "true")) return Value.boolean(true);
        if (std.mem.eql(u8, trimmed, "false")) return Value.boolean(false);
        if (std.mem.eql(u8, trimmed, "null")) return Value.null;

        // Variable lookup (supports dot notation: user.name)
        return self.lookupVariable(trimmed);
    }

    /// Finds the position of a + operator that's not inside quotes or brackets.
    /// Returns null if no such operator exists.
    fn findConcatOperator(_: *Runtime, expr: []const u8) ?usize {
        var in_string: u8 = 0; // 0 = not in string, '"' or '\'' = in that type of string
        var bracket_depth: usize = 0;
        var paren_depth: usize = 0;
        var brace_depth: usize = 0;

        for (expr, 0..) |c, i| {
            if (in_string != 0) {
                if (c == in_string) {
                    in_string = 0;
                } else if (c == '\\' and i + 1 < expr.len) {
                    // Skip escaped character - we'll handle it in next iteration
                    continue;
                }
            } else {
                switch (c) {
                    '"', '\'' => in_string = c,
                    '[' => bracket_depth += 1,
                    ']' => bracket_depth -|= 1,
                    '(' => paren_depth += 1,
                    ')' => paren_depth -|= 1,
                    '{' => brace_depth += 1,
                    '}' => brace_depth -|= 1,
                    '+' => {
                        if (bracket_depth == 0 and paren_depth == 0 and brace_depth == 0) {
                            return i;
                        }
                    },
                    else => {},
                }
            }
        }

        return null;
    }

    /// Looks up a variable with dot notation support.
    /// Optimized for the common case of single property access (e.g., "friend.name").
    fn lookupVariable(self: *Runtime, path: []const u8) Value {
        // Fast path: find first dot position
        var dot_pos: ?usize = null;
        for (path, 0..) |c, i| {
            if (c == '.') {
                dot_pos = i;
                break;
            }
        }

        if (dot_pos == null) {
            // No dots - simple variable lookup
            return self.context.get(path) orelse Value.null;
        }

        // Has dots - get base variable first
        const base_name = path[0..dot_pos.?];
        var current = self.context.get(base_name) orelse return Value.null;

        // Property access loop - objects are most common
        var pos = dot_pos.? + 1;
        while (pos < path.len) {
            // Find next dot or end
            var end = pos;
            while (end < path.len and path[end] != '.') {
                end += 1;
            }
            const prop = path[pos..end];

            // Most values are objects in property chains (branch hint)
            if (current == .object) {
                @branchHint(.likely);
                current = current.object.get(prop) orelse return Value.null;
            } else {
                return Value.null;
            }

            pos = end + 1;
        }

        return current;
    }

    /// Evaluates a string value, stripping surrounding quotes if present.
    /// Used for HTML attribute values.
    fn evaluateString(_: *Runtime, str: []const u8) ![]const u8 {
        // Strip surrounding quotes if present (single, double, or backtick)
        if (str.len >= 2) {
            const first = str[0];
            const last = str[str.len - 1];
            if ((first == '"' and last == '"') or
                (first == '\'' and last == '\'') or
                (first == '`' and last == '`'))
            {
                return str[1 .. str.len - 1];
            }
        }
        return str;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Output helpers
    // ─────────────────────────────────────────────────────────────────────────

    fn writeTextSegments(self: *Runtime, segments: []const ast.TextSegment) Error!void {
        for (segments) |seg| {
            switch (seg) {
                .literal => |lit| try self.writeEscaped(lit),
                .interp_escaped => |expr| {
                    const value = self.evaluateExpression(expr);
                    const str = try value.toString(self.allocator);
                    try self.writeEscaped(str);
                },
                .interp_unescaped => |expr| {
                    const value = self.evaluateExpression(expr);
                    const str = try value.toString(self.allocator);
                    try self.write(str);
                },
                .interp_tag => |inline_tag| {
                    try self.writeInlineTag(inline_tag);
                },
            }
        }
    }

    /// Writes an inline tag from tag interpolation: #[em text]
    fn writeInlineTag(self: *Runtime, tag: ast.InlineTag) Error!void {
        try self.write("<");
        try self.write(tag.tag);

        // Write ID if present
        if (tag.id) |id| {
            try self.write(" id=\"");
            try self.writeEscaped(id);
            try self.write("\"");
        }

        // Write classes if present
        if (tag.classes.len > 0) {
            try self.write(" class=\"");
            for (tag.classes, 0..) |class, i| {
                if (i > 0) try self.write(" ");
                try self.writeEscaped(class);
            }
            try self.write("\"");
        }

        // Write attributes
        for (tag.attributes) |attr| {
            if (attr.value) |value| {
                try self.write(" ");
                try self.write(attr.name);
                try self.write("=\"");
                const evaluated = try self.evaluateString(value);
                if (attr.escaped) {
                    try self.writeEscaped(evaluated);
                } else {
                    try self.write(evaluated);
                }
                try self.write("\"");
            } else {
                // Boolean attribute
                try self.write(" ");
                try self.write(attr.name);
                try self.write("=\"");
                try self.write(attr.name);
                try self.write("\"");
            }
        }

        try self.write(">");

        // Write text content (may contain nested interpolations)
        try self.writeTextSegments(tag.text_segments);

        try self.write("</");
        try self.write(tag.tag);
        try self.write(">");
    }

    /// Writes spread attributes from an object literal: {'data-foo': 'bar', 'data-baz': 'qux'}
    fn writeSpreadAttributes(self: *Runtime, spread: []const u8) Error!void {
        const trimmed = std.mem.trim(u8, spread, " \t\n\r");

        // Must start with { and end with }
        if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') {
            return;
        }

        const content = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\n\r");
        if (content.len == 0) return;

        var pos: usize = 0;
        while (pos < content.len) {
            // Skip whitespace
            while (pos < content.len and (content[pos] == ' ' or content[pos] == '\t' or content[pos] == '\n' or content[pos] == '\r')) {
                pos += 1;
            }
            if (pos >= content.len) break;

            // Parse property name (may be quoted with ' or ")
            var name_start = pos;
            var name_end = pos;
            if (content[pos] == '\'' or content[pos] == '"') {
                const quote = content[pos];
                pos += 1;
                name_start = pos;
                while (pos < content.len and content[pos] != quote) {
                    pos += 1;
                }
                name_end = pos;
                if (pos < content.len) pos += 1; // skip closing quote
            } else {
                // Unquoted name
                while (pos < content.len and content[pos] != ':' and content[pos] != ' ') {
                    pos += 1;
                }
                name_end = pos;
            }
            const name = content[name_start..name_end];

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
                // Unquoted value
                while (pos < content.len and content[pos] != ',' and content[pos] != '}') {
                    pos += 1;
                }
                value_end = pos;
                // Trim trailing whitespace
                while (value_end > value_start and (content[value_end - 1] == ' ' or content[value_end - 1] == '\t')) {
                    value_end -= 1;
                }
            }
            const value = content[value_start..value_end];

            // Write attribute
            if (name.len > 0) {
                try self.write(" ");
                try self.write(name);
                try self.write("=\"");
                try self.writeEscaped(value);
                try self.write("\"");
            }

            // Skip comma
            while (pos < content.len and (content[pos] == ' ' or content[pos] == ',' or content[pos] == '\t' or content[pos] == '\n' or content[pos] == '\r')) {
                pos += 1;
            }
        }
    }

    fn writeIndent(self: *Runtime) Error!void {
        if (!self.options.pretty) return;
        for (0..self.depth) |_| {
            try self.write(self.options.indent_str);
        }
    }

    fn writeNewline(self: *Runtime) Error!void {
        if (!self.options.pretty) return;
        try self.write("\n");
    }

    fn write(self: *Runtime, str: []const u8) Error!void {
        // Use addManyAsSlice for potentially faster bulk copy
        const dest = try self.output.addManyAsSlice(self.allocator, str.len);
        @memcpy(dest, str);
    }

    fn writeEscaped(self: *Runtime, str: []const u8) Error!void {
        // Fast path: use SIMD-friendly byte scan for escape characters
        // Check if any escaping needed using a simple loop (compiler can vectorize)
        var escape_needed: usize = str.len;
        for (str, 0..) |c, i| {
            // Use a lookup instead of multiple comparisons
            if (escape_table[c]) {
                escape_needed = i;
                break;
            }
        }

        // No escaping needed - single fast write
        if (escape_needed == str.len) {
            const dest = try self.output.addManyAsSlice(self.allocator, str.len);
            @memcpy(dest, str);
            return;
        }

        // Write prefix that doesn't need escaping
        if (escape_needed > 0) {
            const dest = try self.output.addManyAsSlice(self.allocator, escape_needed);
            @memcpy(dest, str[0..escape_needed]);
        }

        // Slow path: escape remaining characters
        var start = escape_needed;
        for (str[escape_needed..], escape_needed..) |c, i| {
            if (escape_table[c]) {
                // Write accumulated non-escaped chars first
                if (i > start) {
                    const chunk = str[start..i];
                    const dest = try self.output.addManyAsSlice(self.allocator, chunk.len);
                    @memcpy(dest, chunk);
                }
                const esc = escape_strings[c];
                const dest = try self.output.addManyAsSlice(self.allocator, esc.len);
                @memcpy(dest, esc);
                start = i + 1;
            }
        }
        // Write remaining non-escaped chars
        if (start < str.len) {
            const chunk = str[start..];
            const dest = try self.output.addManyAsSlice(self.allocator, chunk.len);
            @memcpy(dest, chunk);
        }
    }

    /// Lookup table for characters that need HTML escaping
    const escape_table = blk: {
        var table: [256]bool = [_]bool{false} ** 256;
        table['&'] = true;
        table['<'] = true;
        table['>'] = true;
        table['"'] = true;
        table['\''] = true;
        break :blk table;
    };

    /// Escape strings for each character
    const escape_strings = blk: {
        var strings: [256][]const u8 = [_][]const u8{""} ** 256;
        strings['&'] = "&amp;";
        strings['<'] = "&lt;";
        strings['>'] = "&gt;";
        strings['"'] = "&quot;";
        strings['\''] = "&#x27;";
        break :blk strings;
    };
};

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

fn isVoidElement(tag: []const u8) bool {
    const void_elements = std.StaticStringMap(void).initComptime(.{
        .{ "area", {} },  .{ "base", {} },  .{ "br", {} },
        .{ "col", {} },   .{ "embed", {} }, .{ "hr", {} },
        .{ "img", {} },   .{ "input", {} }, .{ "link", {} },
        .{ "meta", {} },  .{ "param", {} }, .{ "source", {} },
        .{ "track", {} }, .{ "wbr", {} },
    });
    return void_elements.has(tag);
}

/// Parses a JS array literal and converts it to space-separated string.
/// Input: ['foo', 'bar', 'baz']
/// Output: foo bar baz
fn parseArrayToSpaceSeparated(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\n\r");

    // Must start with [ and end with ]
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') {
        return input; // Not an array, return as-is
    }

    const content = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\n\r");
    if (content.len == 0) return "";

    var result = std.ArrayListUnmanaged(u8).empty;
    errdefer result.deinit(allocator);

    var pos: usize = 0;
    var first = true;
    while (pos < content.len) {
        // Skip whitespace and commas
        while (pos < content.len and (content[pos] == ' ' or content[pos] == '\t' or content[pos] == ',' or content[pos] == '\n' or content[pos] == '\r')) {
            pos += 1;
        }
        if (pos >= content.len) break;

        // Parse value (handle quoted strings)
        var value_start = pos;
        var value_end = pos;
        if (content[pos] == '\'' or content[pos] == '"') {
            const quote = content[pos];
            pos += 1;
            value_start = pos;
            while (pos < content.len and content[pos] != quote) {
                pos += 1;
            }
            value_end = pos;
            if (pos < content.len) pos += 1; // skip closing quote
        } else {
            // Unquoted value
            while (pos < content.len and content[pos] != ',' and content[pos] != ']') {
                pos += 1;
            }
            value_end = pos;
            // Trim trailing whitespace
            while (value_end > value_start and (content[value_end - 1] == ' ' or content[value_end - 1] == '\t')) {
                value_end -= 1;
            }
        }

        const value = content[value_start..value_end];
        if (value.len > 0) {
            if (!first) {
                try result.append(allocator, ' ');
            }
            try result.appendSlice(allocator, value);
            first = false;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Parses a JS object literal and converts it to CSS style string.
/// Input: {color: 'red', background: 'green'}
/// Output: color:red;background:green;
fn parseObjectToCSS(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\n\r");

    // Must start with { and end with }
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') {
        return input; // Not an object, return as-is
    }

    const content = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\n\r");
    if (content.len == 0) return "";

    var result = std.ArrayListUnmanaged(u8).empty;
    errdefer result.deinit(allocator);

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
            // Unquoted value
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

        // Append property:value;
        try result.appendSlice(allocator, name);
        try result.append(allocator, ':');
        try result.appendSlice(allocator, value);
        try result.append(allocator, ';');

        // Skip comma
        while (pos < content.len and (content[pos] == ' ' or content[pos] == ',' or content[pos] == '\t' or content[pos] == '\n' or content[pos] == '\r')) {
            pos += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

// ─────────────────────────────────────────────────────────────────────────────
// Convenience function
// ─────────────────────────────────────────────────────────────────────────────

/// Compiles and renders a template string with the given data context.
/// This is the simplest API for server use - one function call does everything.
///
/// **Recommended:** Use an arena allocator for automatic cleanup:
/// ```zig
/// var arena = std.heap.ArenaAllocator.init(base_allocator);
/// defer arena.deinit(); // Frees all template memory at once
///
/// const html = try pugz.renderTemplate(arena.allocator(),
///     \\html
///     \\  head
///     \\    title= title
///     \\  body
///     \\    h1 Hello, #{name}!
/// , .{ .title = "My Page", .name = "World" });
/// // Use html... arena.deinit() frees everything
/// ```
pub fn renderTemplate(allocator: std.mem.Allocator, source: []const u8, data: anytype) ![]u8 {
    // Tokenize
    var lexer = Lexer.init(allocator, source);
    defer lexer.deinit();
    const tokens = lexer.tokenize() catch return error.ParseError;

    // Parse
    var parser = Parser.init(allocator, tokens);
    const doc = parser.parse() catch return error.ParseError;

    // Render with data
    return render(allocator, doc, data);
}

/// Renders a pre-parsed document with the given data context.
/// Use this when you want to parse once and render multiple times with different data.
pub fn render(allocator: std.mem.Allocator, doc: ast.Document, data: anytype) ![]u8 {
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Populate context from data struct
    try ctx.pushScope();
    inline for (std.meta.fields(@TypeOf(data))) |field| {
        const value = @field(data, field.name);
        try ctx.set(field.name, toValue(allocator, value));
    }

    var runtime = Runtime.init(allocator, &ctx, .{});
    defer runtime.deinit();

    return runtime.renderOwned(doc);
}

/// Converts a Zig value to a runtime Value.
/// For best performance, use an arena allocator.
pub fn toValue(allocator: std.mem.Allocator, v: anytype) Value {
    const T = @TypeOf(v);

    if (T == Value) return v;

    switch (@typeInfo(T)) {
        .bool => return Value.boolean(v),
        .int, .comptime_int => return Value.integer(@intCast(v)),
        .float, .comptime_float => return .{ .float = @floatCast(v) },
        .pointer => |ptr| {
            // Handle *const [N]u8 (string literals)
            if (ptr.size == .one) {
                const child_info = @typeInfo(ptr.child);
                if (child_info == .array and child_info.array.child == u8) {
                    return Value.str(v);
                }
                // Handle pointer to array of non-u8 (e.g., *const [3][]const u8)
                if (child_info == .array) {
                    const arr = allocator.alloc(Value, child_info.array.len) catch return Value.null;
                    for (v, 0..) |item, i| {
                        arr[i] = toValue(allocator, item);
                    }
                    return .{ .array = arr };
                }
            }
            // Handle []const u8 and []u8
            if (ptr.size == .slice and ptr.child == u8) {
                return Value.str(v);
            }
            if (ptr.size == .slice) {
                // Convert slice to array value
                const arr = allocator.alloc(Value, v.len) catch return Value.null;
                for (v, 0..) |item, i| {
                    arr[i] = toValue(allocator, item);
                }
                return .{ .array = arr };
            }
            return Value.null;
        },
        .optional => {
            if (v) |inner| {
                return toValue(allocator, inner);
            }
            return Value.null;
        },
        .@"struct" => |info| {
            // Convert struct to object - pre-allocate for known field count
            var obj = std.StringHashMapUnmanaged(Value).empty;
            obj.ensureTotalCapacity(allocator, info.fields.len) catch return Value.null;
            inline for (info.fields) |field| {
                const field_value = @field(v, field.name);
                obj.putAssumeCapacity(field.name, toValue(allocator, field_value));
            }
            return .{ .object = obj };
        },
        else => return Value.null,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "context variable lookup" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.pushScope();
    try ctx.set("name", Value.str("World"));
    try ctx.set("count", Value.integer(42));

    try std.testing.expectEqualStrings("World", ctx.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 42), ctx.get("count").?.int);
    try std.testing.expect(ctx.get("undefined") == null);
}

test "context scoping" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.pushScope();
    try ctx.set("x", Value.integer(1));

    try ctx.pushScope();
    try ctx.set("x", Value.integer(2));
    try std.testing.expectEqual(@as(i64, 2), ctx.get("x").?.int);

    ctx.popScope();
    try std.testing.expectEqual(@as(i64, 1), ctx.get("x").?.int);
}

test "value truthiness" {
    const null_val: Value = .null;
    try std.testing.expect(!null_val.isTruthy());
    try std.testing.expect(!Value.boolean(false).isTruthy());
    try std.testing.expect(Value.boolean(true).isTruthy());
    try std.testing.expect(!Value.integer(0).isTruthy());
    try std.testing.expect(Value.integer(1).isTruthy());
    try std.testing.expect(!Value.str("").isTruthy());
    try std.testing.expect(Value.str("hello").isTruthy());
}

test "toValue conversion" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(Value.boolean(true), toValue(allocator, true));
    try std.testing.expectEqual(Value.integer(42), toValue(allocator, @as(i32, 42)));
    try std.testing.expectEqualStrings("hello", toValue(allocator, "hello").string);
}

test "renderTemplate convenience function" {
    // Use arena allocator - recommended pattern for server use
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const html = try renderTemplate(allocator,
        \\p Hello, #{name}!
    , .{ .name = "World" });
    try std.testing.expectEqualStrings("<p>Hello, World!</p>\n", html);
}
