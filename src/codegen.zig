// codegen.zig - Zig port of pug-code-gen
//
// Compiles a Pug AST to HTML output.
// This is a direct HTML generator (unlike the JS version which generates JS code).

const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;

// Import AST types from parser
const parser = @import("parser.zig");
pub const Node = parser.Node;
pub const NodeType = parser.NodeType;
pub const Attribute = parser.Attribute;

// Import runtime for attribute handling, HTML escaping, and shared constants
const runtime = @import("runtime.zig");
pub const escapeChar = runtime.escapeChar;
pub const doctypes = runtime.doctypes;
pub const whitespace_sensitive_tags = runtime.whitespace_sensitive_tags;

// Import error types
const pug_error = @import("error.zig");
pub const PugError = pug_error.PugError;

// ============================================================================
// Void Elements
// ============================================================================

// Self-closing (void) elements in HTML5
pub const void_elements = std.StaticStringMap(void).initComptime(.{
    .{ "area", {} },
    .{ "base", {} },
    .{ "br", {} },
    .{ "col", {} },
    .{ "embed", {} },
    .{ "hr", {} },
    .{ "img", {} },
    .{ "input", {} },
    .{ "link", {} },
    .{ "meta", {} },
    .{ "param", {} },
    .{ "source", {} },
    .{ "track", {} },
    .{ "wbr", {} },
});

// ============================================================================
// Compiler Options
// ============================================================================

pub const CompilerOptions = struct {
    /// Pretty print output with indentation
    pretty: bool = false,
    /// Indentation string (default: 2 spaces)
    indent_str: []const u8 = "  ",
    /// Use terse mode (HTML5 style: boolean attrs, > instead of />)
    terse: bool = true,
    /// Doctype to use
    doctype: ?[]const u8 = null,
    /// Include debug info
    debug: bool = false,
    /// Self-closing style (true = />, false = >)
    self_closing: bool = false,
};

// ============================================================================
// Compiler Errors
// ============================================================================

pub const CompilerError = error{
    OutOfMemory,
    InvalidNode,
    UnsupportedNodeType,
    SelfClosingContent,
    InvalidDoctype,
};

// ============================================================================
// Compiler
// ============================================================================

pub const Compiler = struct {
    allocator: Allocator,
    options: CompilerOptions,
    output: std.ArrayListUnmanaged(u8),
    indent_level: usize = 0,
    has_doctype: bool = false,
    has_tag: bool = false,
    escape_pretty: bool = false,
    terse: bool = true,
    doctype_str: ?[]const u8 = null,

    pub fn init(allocator: Allocator, options: CompilerOptions) Compiler {
        var compiler = Compiler{
            .allocator = allocator,
            .options = options,
            .output = .{},
            .terse = options.terse,
        };

        // Set up doctype
        if (options.doctype) |dt| {
            compiler.setDoctype(dt);
        }

        return compiler;
    }

    pub fn deinit(self: *Compiler) void {
        self.output.deinit(self.allocator);
    }

    /// Compile an AST node to HTML
    pub fn compile(self: *Compiler, node: *Node) CompilerError![]const u8 {
        try self.visit(node);
        return self.output.toOwnedSlice(self.allocator);
    }

    /// Set the doctype
    pub fn setDoctype(self: *Compiler, name: []const u8) void {
        const lower = name; // TODO: lowercase conversion
        if (doctypes.get(lower)) |dt| {
            self.doctype_str = dt;
        } else {
            // Custom doctype
            self.doctype_str = null;
        }

        // HTML5 uses terse mode
        self.terse = mem.eql(u8, lower, "html");
    }

    // ========================================================================
    // Output Helpers
    // ========================================================================

    fn write(self: *Compiler, str: []const u8) CompilerError!void {
        try self.output.appendSlice(self.allocator, str);
    }

    fn writeChar(self: *Compiler, c: u8) CompilerError!void {
        try self.output.append(self.allocator, c);
    }

    fn writeEscaped(self: *Compiler, str: []const u8) CompilerError!void {
        // For attribute values - escapes < > & "
        for (str) |c| {
            if (escapeChar(c)) |escaped| {
                try self.write(escaped);
            } else {
                try self.writeChar(c);
            }
        }
    }

    fn writeTextEscaped(self: *Compiler, str: []const u8) CompilerError!void {
        // For text content - escapes < > & (NOT quotes)
        // Preserves existing HTML entities like &#8217; or &amp;
        var i: usize = 0;
        while (i < str.len) {
            const c = str[i];
            switch (c) {
                '<' => try self.write("&lt;"),
                '>' => try self.write("&gt;"),
                '&' => {
                    // Check if this is already an HTML entity
                    if (isHtmlEntity(str[i..])) {
                        // Pass through the entity as-is
                        try self.writeChar(c);
                    } else {
                        try self.write("&amp;");
                    }
                },
                else => try self.writeChar(c),
            }
            i += 1;
        }
    }

    fn isHtmlEntity(str: []const u8) bool {
        // Check if str starts with a valid HTML entity: &name; or &#digits; or &#xhex;
        if (str.len < 3 or str[0] != '&') return false;

        var i: usize = 1;

        // Numeric entity: &#digits; or &#xhex;
        if (str[i] == '#') {
            i += 1;
            if (i >= str.len) return false;

            // Hex entity: &#x...;
            if (str[i] == 'x' or str[i] == 'X') {
                i += 1;
                if (i >= str.len) return false;
                // Need at least one hex digit
                var has_hex = false;
                while (i < str.len and i < 10) : (i += 1) {
                    const ch = str[i];
                    if (ch == ';') return has_hex;
                    if ((ch >= '0' and ch <= '9') or
                        (ch >= 'a' and ch <= 'f') or
                        (ch >= 'A' and ch <= 'F'))
                    {
                        has_hex = true;
                    } else {
                        return false;
                    }
                }
                return false;
            }

            // Decimal entity: &#digits;
            var has_digit = false;
            while (i < str.len and i < 10) : (i += 1) {
                const ch = str[i];
                if (ch == ';') return has_digit;
                if (ch >= '0' and ch <= '9') {
                    has_digit = true;
                } else {
                    return false;
                }
            }
            return false;
        }

        // Named entity: &name;
        var has_alpha = false;
        while (i < str.len and i < 32) : (i += 1) {
            const ch = str[i];
            if (ch == ';') return has_alpha;
            if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9')) {
                has_alpha = true;
            } else {
                return false;
            }
        }
        return false;
    }

    fn prettyIndent(self: *Compiler) CompilerError!void {
        if (self.options.pretty and !self.escape_pretty) {
            try self.writeChar('\n');
            for (0..self.indent_level) |_| {
                try self.write(self.options.indent_str);
            }
        }
    }

    // ========================================================================
    // Visitor Methods
    // ========================================================================

    fn visit(self: *Compiler, node: *Node) CompilerError!void {
        switch (node.type) {
            .Block, .NamedBlock => try self.visitBlock(node),
            .Tag => try self.visitTag(node),
            .InterpolatedTag => try self.visitTag(node),
            .Text => try self.visitText(node),
            .Code => try self.visitCode(node),
            .Comment => try self.visitComment(node),
            .BlockComment => try self.visitBlockComment(node),
            .Doctype => try self.visitDoctype(node),
            .Mixin => try self.visitMixin(node),
            .MixinBlock => try self.visitMixinBlock(node),
            .Case => try self.visitCase(node),
            .When => try self.visitWhen(node),
            .Conditional => try self.visitConditional(node),
            .While => try self.visitWhile(node),
            .Each => try self.visitEach(node),
            .EachOf => try self.visitEachOf(node),
            .YieldBlock, .TypeHint => {}, // No-op (TypeHint is only for compiled templates)
            .Include, .Extends, .RawInclude, .Filter, .IncludeFilter, .FileReference, .AttributeBlock => {
                // These should be processed by linker/loader before codegen
                return error.UnsupportedNodeType;
            },
        }
    }

    fn visitBlock(self: *Compiler, block: *Node) CompilerError!void {
        for (block.nodes.items) |child| {
            try self.visit(child);
        }
    }

    fn visitTag(self: *Compiler, tag: *Node) CompilerError!void {
        const name = tag.name orelse return error.InvalidNode;

        // Check for whitespace-sensitive tags - use defer to ensure state restoration
        const was_escape_pretty = self.escape_pretty;
        defer self.escape_pretty = was_escape_pretty;

        if (whitespace_sensitive_tags.has(name)) {
            self.escape_pretty = true;
        }

        // Auto-doctype for html tag
        if (!self.has_tag) {
            if (!self.has_doctype and mem.eql(u8, name, "html")) {
                try self.visitDoctype(null);
            }
            self.has_tag = true;
        }

        // Pretty indent before tag
        if (self.options.pretty and !tag.is_inline) {
            try self.prettyIndent();
        }

        self.indent_level += 1;
        defer self.indent_level -= 1;

        // Check if self-closing
        const is_void = void_elements.has(name);
        const is_self_closing = tag.self_closing or is_void;

        // Opening tag
        try self.writeChar('<');
        try self.write(name);

        // Attributes
        try self.visitAttributes(tag);

        if (is_self_closing) {
            if (self.terse and !tag.self_closing) {
                try self.writeChar('>');
            } else {
                try self.write("/>");
            }

            // Check for content in self-closing tag
            if (tag.nodes.items.len > 0) {
                return error.SelfClosingContent;
            }
        } else {
            try self.writeChar('>');

            // Visit children
            for (tag.nodes.items) |child| {
                try self.visit(child);
            }

            // Pretty indent before closing tag
            if (self.options.pretty and !tag.is_inline and !whitespace_sensitive_tags.has(name)) {
                try self.prettyIndent();
            }

            // Closing tag
            try self.write("</");
            try self.write(name);
            try self.writeChar('>');
        }
        // escape_pretty restoration handled by defer above
    }

    fn visitAttributes(self: *Compiler, tag: *Node) CompilerError!void {
        // Collect class values to merge them into a single attribute
        var class_values = std.ArrayListUnmanaged([]const u8){};
        defer class_values.deinit(self.allocator);

        // First pass: collect class values and output non-class attributes
        for (tag.attrs.items) |attr| {
            if (attr.val) |val| {
                // Check if value should be skipped (empty, null, undefined)
                const should_skip = val.len == 0 or
                    mem.eql(u8, val, "''") or
                    mem.eql(u8, val, "\"\"") or
                    mem.eql(u8, val, "null") or
                    mem.eql(u8, val, "undefined");

                if (mem.eql(u8, attr.name, "class")) {
                    // Collect class values to merge later
                    if (!should_skip) {
                        try class_values.append(self.allocator, val);
                    }
                    continue;
                }

                // Skip empty style attributes
                if (mem.eql(u8, attr.name, "style") and should_skip) {
                    continue;
                }

                // Check for boolean attributes in terse mode
                const is_bool = mem.eql(u8, val, "true") or mem.eql(u8, val, "false");
                if (self.terse and is_bool) {
                    if (mem.eql(u8, val, "true")) {
                        // Terse boolean: just the attribute name
                        try self.writeChar(' ');
                        try self.write(attr.name);
                        continue;
                    } else {
                        // false: don't output the attribute at all
                        continue;
                    }
                }

                try self.writeChar(' ');
                try self.write(attr.name);
                try self.write("=\"");
                if (attr.must_escape) {
                    try self.writeEscaped(val);
                } else {
                    try self.write(val);
                }
                try self.writeChar('"');
            } else {
                // No value - output attribute name only (boolean attribute)
                try self.writeChar(' ');
                try self.write(attr.name);
            }
        }

        // Output merged class attribute if any classes were collected
        if (class_values.items.len > 0) {
            try self.writeChar(' ');
            try self.write("class=\"");
            for (class_values.items, 0..) |class_val, i| {
                if (i > 0) {
                    try self.writeChar(' ');
                }
                try self.write(class_val);
            }
            try self.writeChar('"');
        }
    }

    fn visitText(self: *Compiler, text: *Node) CompilerError!void {
        if (text.val) |val| {
            if (text.is_html) {
                try self.write(val);
            } else {
                // Text content: only escape < > & (not quotes)
                try self.writeTextEscaped(val);
            }
        }
    }

    fn visitCode(self: *Compiler, code: *Node) CompilerError!void {
        // Code nodes contain runtime expressions
        // In a real implementation, we would evaluate these
        // For now, just output the value as-is if buffered
        if (code.buffer) {
            if (code.val) |val| {
                if (code.must_escape) {
                    try self.writeEscaped(val);
                } else {
                    try self.write(val);
                }
            }
        }

        // Visit block if present
        for (code.nodes.items) |child| {
            try self.visit(child);
        }
    }

    fn visitComment(self: *Compiler, comment: *Node) CompilerError!void {
        if (!comment.buffer) return;

        try self.prettyIndent();
        try self.write("<!--");
        if (comment.val) |val| {
            try self.write(val);
        }
        try self.write("-->");
    }

    fn visitBlockComment(self: *Compiler, comment: *Node) CompilerError!void {
        if (!comment.buffer) return;

        try self.prettyIndent();
        try self.write("<!--");
        if (comment.val) |val| {
            try self.write(val);
        }

        // Visit block content
        for (comment.nodes.items) |child| {
            try self.visit(child);
        }

        try self.prettyIndent();
        try self.write("-->");
    }

    fn visitDoctype(self: *Compiler, doctype: ?*Node) CompilerError!void {
        if (doctype) |dt| {
            if (dt.val) |val| {
                self.setDoctype(val);
            }
        }

        if (self.doctype_str) |dt_str| {
            try self.write(dt_str);
        } else {
            try self.write("<!DOCTYPE html>");
        }
        self.has_doctype = true;
    }

    fn visitMixin(self: *Compiler, mixin: *Node) CompilerError!void {
        // Mixin calls would be expanded at link time
        // For now, just visit the block if it's a definition
        if (!mixin.call) {
            // This is a definition - skip it
            return;
        }

        // Mixin call - visit block if present
        for (mixin.nodes.items) |child| {
            try self.visit(child);
        }
    }

    fn visitMixinBlock(_: *Compiler, _: *Node) CompilerError!void {
        // MixinBlock is a placeholder for mixin content
        // Handled at mixin call site
    }

    fn visitCase(self: *Compiler, case_node: *Node) CompilerError!void {
        // Case/switch - visit block
        for (case_node.nodes.items) |child| {
            try self.visit(child);
        }
    }

    fn visitWhen(self: *Compiler, when_node: *Node) CompilerError!void {
        // When - visit block if present
        for (when_node.nodes.items) |child| {
            try self.visit(child);
        }
    }

    fn visitConditional(self: *Compiler, cond: *Node) CompilerError!void {
        // In static compilation, we can't evaluate conditions
        // Visit consequent by default
        if (cond.consequent) |cons| {
            try self.visit(cons);
        }
    }

    fn visitWhile(_: *Compiler, _: *Node) CompilerError!void {
        // While loops need runtime evaluation
        // In static mode, skip
    }

    fn visitEach(_: *Compiler, _: *Node) CompilerError!void {
        // Each loops need runtime evaluation
        // In static mode, skip
    }

    fn visitEachOf(_: *Compiler, _: *Node) CompilerError!void {
        // EachOf loops need runtime evaluation
        // In static mode, skip
    }
};

// ============================================================================
// Convenience Functions
// ============================================================================

/// Compile an AST to HTML with default options
pub fn compile(allocator: Allocator, ast: *Node) CompilerError![]const u8 {
    var compiler = Compiler.init(allocator, .{});
    defer compiler.deinit();
    return compiler.compile(ast);
}

/// Compile an AST to HTML with custom options
pub fn compileWithOptions(allocator: Allocator, ast: *Node, options: CompilerOptions) CompilerError![]const u8 {
    var compiler = Compiler.init(allocator, options);
    defer compiler.deinit();
    return compiler.compile(ast);
}

/// Compile an AST to pretty-printed HTML
pub fn compilePretty(allocator: Allocator, ast: *Node) CompilerError![]const u8 {
    return compileWithOptions(allocator, ast, .{ .pretty = true });
}

// ============================================================================
// Tests
// ============================================================================

test "compile - simple text" {
    const allocator = std.testing.allocator;

    const text = try allocator.create(Node);
    text.* = Node{
        .type = .Text,
        .val = "Hello, World!",
        .line = 1,
        .column = 1,
    };

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, text);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    const output = try compile(allocator, root);
    defer allocator.free(output);

    try std.testing.expectEqualStrings("Hello, World!", output);
}

test "compile - simple tag" {
    const allocator = std.testing.allocator;

    const tag = try allocator.create(Node);
    tag.* = Node{
        .type = .Tag,
        .name = "div",
        .line = 1,
        .column = 1,
    };

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, tag);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    const output = try compile(allocator, root);
    defer allocator.free(output);

    try std.testing.expectEqualStrings("<div></div>", output);
}

test "compile - tag with text" {
    const allocator = std.testing.allocator;

    const text = try allocator.create(Node);
    text.* = Node{
        .type = .Text,
        .val = "Hello",
        .line = 1,
        .column = 5,
    };

    const tag = try allocator.create(Node);
    tag.* = Node{
        .type = .Tag,
        .name = "p",
        .line = 1,
        .column = 1,
    };
    try tag.nodes.append(allocator, text);

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, tag);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    const output = try compile(allocator, root);
    defer allocator.free(output);

    try std.testing.expectEqualStrings("<p>Hello</p>", output);
}

test "compile - tag with attributes" {
    const allocator = std.testing.allocator;

    const tag = try allocator.create(Node);
    tag.* = Node{
        .type = .Tag,
        .name = "a",
        .line = 1,
        .column = 1,
    };
    try tag.attrs.append(allocator, .{
        .name = "href",
        .val = "/home",
        .line = 1,
        .column = 3,
        .filename = null,
        .must_escape = true,
    });

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, tag);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    const output = try compile(allocator, root);
    defer allocator.free(output);

    try std.testing.expectEqualStrings("<a href=\"/home\"></a>", output);
}

test "compile - self-closing tag" {
    const allocator = std.testing.allocator;

    const tag = try allocator.create(Node);
    tag.* = Node{
        .type = .Tag,
        .name = "br",
        .line = 1,
        .column = 1,
    };

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, tag);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    const output = try compile(allocator, root);
    defer allocator.free(output);

    try std.testing.expectEqualStrings("<br>", output);
}

test "compile - nested tags" {
    const allocator = std.testing.allocator;

    const span = try allocator.create(Node);
    span.* = Node{
        .type = .Tag,
        .name = "span",
        .line = 2,
        .column = 3,
    };

    const div = try allocator.create(Node);
    div.* = Node{
        .type = .Tag,
        .name = "div",
        .line = 1,
        .column = 1,
    };
    try div.nodes.append(allocator, span);

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, div);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    const output = try compile(allocator, root);
    defer allocator.free(output);

    try std.testing.expectEqualStrings("<div><span></span></div>", output);
}

test "compile - doctype" {
    const allocator = std.testing.allocator;

    const doctype = try allocator.create(Node);
    doctype.* = Node{
        .type = .Doctype,
        .val = "html",
        .line = 1,
        .column = 1,
    };

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, doctype);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    const output = try compile(allocator, root);
    defer allocator.free(output);

    try std.testing.expectEqualStrings("<!DOCTYPE html>", output);
}

test "compile - comment" {
    const allocator = std.testing.allocator;

    const comment = try allocator.create(Node);
    comment.* = Node{
        .type = .Comment,
        .val = " this is a comment ",
        .buffer = true,
        .line = 1,
        .column = 1,
    };

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, comment);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    const output = try compile(allocator, root);
    defer allocator.free(output);

    try std.testing.expectEqualStrings("<!-- this is a comment -->", output);
}

test "compile - text escaping" {
    const allocator = std.testing.allocator;

    const text = try allocator.create(Node);
    text.* = Node{
        .type = .Text,
        .val = "<script>alert('xss')</script>",
        .line = 1,
        .column = 1,
    };

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, text);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    const output = try compile(allocator, root);
    defer allocator.free(output);

    try std.testing.expectEqualStrings("&lt;script&gt;alert('xss')&lt;/script&gt;", output);
}

test "compile - pretty print" {
    const allocator = std.testing.allocator;

    const inner = try allocator.create(Node);
    inner.* = Node{
        .type = .Tag,
        .name = "span",
        .line = 2,
        .column = 3,
    };

    const outer = try allocator.create(Node);
    outer.* = Node{
        .type = .Tag,
        .name = "div",
        .line = 1,
        .column = 1,
    };
    try outer.nodes.append(allocator, inner);

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, outer);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    const output = try compilePretty(allocator, root);
    defer allocator.free(output);

    // Pretty output has newlines and indentation
    try std.testing.expect(mem.indexOf(u8, output, "\n") != null);
}
