//! Pugz Code Generator - Converts AST to HTML output.
//!
//! This module traverses the AST and generates HTML strings. It handles:
//! - Element rendering with tags, classes, IDs, and attributes
//! - Text content with interpolation placeholders
//! - Proper indentation for pretty-printed output
//! - Self-closing tags (void elements)
//! - Comment rendering

const std = @import("std");
const ast = @import("ast.zig");

/// Configuration options for code generation.
pub const Options = struct {
    /// Enable pretty-printing with indentation and newlines.
    pretty: bool = true,
    /// Indentation string (spaces or tabs).
    indent_str: []const u8 = "  ",
    /// Enable self-closing tag syntax for void elements.
    self_closing: bool = true,
};

/// Errors that can occur during code generation.
pub const CodeGenError = error{
    OutOfMemory,
};

/// HTML void elements that should not have closing tags.
const void_elements = std.StaticStringMap(void).initComptime(.{
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

/// Whitespace-sensitive elements where pretty-printing should be disabled.
const whitespace_sensitive = std.StaticStringMap(void).initComptime(.{
    .{ "pre", {} },
    .{ "textarea", {} },
    .{ "script", {} },
    .{ "style", {} },
});

/// Code generator that converts AST to HTML.
pub const CodeGen = struct {
    allocator: std.mem.Allocator,
    options: Options,
    output: std.ArrayListUnmanaged(u8),
    depth: usize,
    /// Track if we're inside a whitespace-sensitive element.
    preserve_whitespace: bool,

    /// Creates a new code generator with the given options.
    pub fn init(allocator: std.mem.Allocator, options: Options) CodeGen {
        return .{
            .allocator = allocator,
            .options = options,
            .output = .empty,
            .depth = 0,
            .preserve_whitespace = false,
        };
    }

    /// Releases allocated memory.
    pub fn deinit(self: *CodeGen) void {
        self.output.deinit(self.allocator);
    }

    /// Generates HTML from the given document AST.
    /// Returns a slice of the generated HTML owned by the CodeGen.
    pub fn generate(self: *CodeGen, doc: ast.Document) CodeGenError![]const u8 {
        // Pre-allocate reasonable capacity
        try self.output.ensureTotalCapacity(self.allocator, 1024);

        for (doc.nodes) |node| {
            try self.visitNode(node);
        }

        return self.output.items;
    }

    /// Generates HTML and returns an owned copy.
    /// Caller must free the returned slice.
    pub fn generateOwned(self: *CodeGen, doc: ast.Document) CodeGenError![]u8 {
        const result = try self.generate(doc);
        return try self.allocator.dupe(u8, result);
    }

    /// Visits a single AST node and generates corresponding HTML.
    fn visitNode(self: *CodeGen, node: ast.Node) CodeGenError!void {
        switch (node) {
            .doctype => |dt| try self.visitDoctype(dt),
            .element => |elem| try self.visitElement(elem),
            .text => |text| try self.visitText(text),
            .comment => |comment| try self.visitComment(comment),
            .conditional => |cond| try self.visitConditional(cond),
            .each => |each| try self.visitEach(each),
            .@"while" => |whl| try self.visitWhile(whl),
            .case => |c| try self.visitCase(c),
            .mixin_def => {}, // Mixin definitions don't produce direct output
            .mixin_call => |call| try self.visitMixinCall(call),
            .mixin_block => {}, // Mixin block placeholder - handled at mixin call site
            .include => |inc| try self.visitInclude(inc),
            .extends => {}, // Handled at document level
            .block => |blk| try self.visitBlock(blk),
            .raw_text => |raw| try self.visitRawText(raw),
            .code => |code| try self.visitCode(code),
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

    /// Generates doctype declaration.
    fn visitDoctype(self: *CodeGen, dt: ast.Doctype) CodeGenError!void {
        if (doctype_shortcuts.get(dt.value)) |output| {
            try self.write(output);
        } else {
            try self.write("<!DOCTYPE ");
            try self.write(dt.value);
            try self.write(">");
        }
        try self.writeNewline();
    }

    /// Generates HTML for an element node.
    fn visitElement(self: *CodeGen, elem: ast.Element) CodeGenError!void {
        const is_void = void_elements.has(elem.tag) or elem.self_closing;
        const was_preserving = self.preserve_whitespace;

        // Check if entering whitespace-sensitive element
        if (whitespace_sensitive.has(elem.tag)) {
            self.preserve_whitespace = true;
        }

        // Opening tag
        try self.writeIndent();
        try self.write("<");
        try self.write(elem.tag);

        // ID attribute
        if (elem.id) |id| {
            try self.write(" id=\"");
            try self.writeEscaped(id);
            try self.write("\"");
        }

        // Class attribute
        if (elem.classes.len > 0) {
            try self.write(" class=\"");
            for (elem.classes, 0..) |class, i| {
                if (i > 0) try self.write(" ");
                try self.writeEscaped(class);
            }
            try self.write("\"");
        }

        // Other attributes
        for (elem.attributes) |attr| {
            try self.write(" ");
            try self.write(attr.name);
            if (attr.value) |value| {
                try self.write("=\"");
                if (attr.escaped) {
                    try self.writeEscaped(value);
                } else {
                    try self.write(value);
                }
                try self.write("\"");
            } else {
                // Boolean attribute: checked -> checked="checked"
                try self.write("=\"");
                try self.write(attr.name);
                try self.write("\"");
            }
        }

        // Close opening tag
        if (is_void and self.options.self_closing) {
            try self.write(" />");
            try self.writeNewline();
            self.preserve_whitespace = was_preserving;
            return;
        }

        try self.write(">");

        // Inline text
        const has_inline_text = elem.inline_text != null and elem.inline_text.?.len > 0;
        const has_children = elem.children.len > 0;

        if (has_inline_text) {
            try self.writeTextSegments(elem.inline_text.?);
        }

        // Children
        if (has_children) {
            if (!self.preserve_whitespace) {
                try self.writeNewline();
            }
            self.depth += 1;
            for (elem.children) |child| {
                try self.visitNode(child);
            }
            self.depth -= 1;
            if (!self.preserve_whitespace) {
                try self.writeIndent();
            }
        }

        // Closing tag (not for void elements)
        if (!is_void) {
            try self.write("</");
            try self.write(elem.tag);
            try self.write(">");
            try self.writeNewline();
        }

        self.preserve_whitespace = was_preserving;
    }

    /// Generates output for a text node.
    fn visitText(self: *CodeGen, text: ast.Text) CodeGenError!void {
        try self.writeIndent();
        try self.writeTextSegments(text.segments);
        try self.writeNewline();
    }

    /// Generates HTML comment.
    fn visitComment(self: *CodeGen, comment: ast.Comment) CodeGenError!void {
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

    /// Generates placeholder for conditional (runtime evaluation needed).
    fn visitConditional(self: *CodeGen, cond: ast.Conditional) CodeGenError!void {
        // Output each branch with placeholder comments
        for (cond.branches, 0..) |branch, i| {
            try self.writeIndent();
            if (i == 0) {
                if (branch.is_unless) {
                    try self.write("<!-- unless ");
                } else {
                    try self.write("<!-- if ");
                }
                if (branch.condition) |condition| {
                    try self.write(condition);
                }
                try self.write(" -->");
            } else if (branch.condition) |condition| {
                try self.write("<!-- else if ");
                try self.write(condition);
                try self.write(" -->");
            } else {
                try self.write("<!-- else -->");
            }
            try self.writeNewline();

            self.depth += 1;
            for (branch.children) |child| {
                try self.visitNode(child);
            }
            self.depth -= 1;
        }

        try self.writeIndent();
        try self.write("<!-- endif -->");
        try self.writeNewline();
    }

    /// Generates placeholder for each loop (runtime evaluation needed).
    fn visitEach(self: *CodeGen, each: ast.Each) CodeGenError!void {
        try self.writeIndent();
        try self.write("<!-- each ");
        try self.write(each.value_name);
        if (each.index_name) |idx| {
            try self.write(", ");
            try self.write(idx);
        }
        try self.write(" in ");
        try self.write(each.collection);
        try self.write(" -->");
        try self.writeNewline();

        self.depth += 1;
        for (each.children) |child| {
            try self.visitNode(child);
        }
        self.depth -= 1;

        if (each.else_children.len > 0) {
            try self.writeIndent();
            try self.write("<!-- else -->");
            try self.writeNewline();
            self.depth += 1;
            for (each.else_children) |child| {
                try self.visitNode(child);
            }
            self.depth -= 1;
        }

        try self.writeIndent();
        try self.write("<!-- endeach -->");
        try self.writeNewline();
    }

    /// Generates placeholder for while loop (runtime evaluation needed).
    fn visitWhile(self: *CodeGen, whl: ast.While) CodeGenError!void {
        try self.writeIndent();
        try self.write("<!-- while ");
        try self.write(whl.condition);
        try self.write(" -->");
        try self.writeNewline();

        self.depth += 1;
        for (whl.children) |child| {
            try self.visitNode(child);
        }
        self.depth -= 1;

        try self.writeIndent();
        try self.write("<!-- endwhile -->");
        try self.writeNewline();
    }

    /// Generates placeholder for case statement (runtime evaluation needed).
    fn visitCase(self: *CodeGen, c: ast.Case) CodeGenError!void {
        try self.writeIndent();
        try self.write("<!-- case ");
        try self.write(c.expression);
        try self.write(" -->");
        try self.writeNewline();

        for (c.whens) |when| {
            try self.writeIndent();
            try self.write("<!-- when ");
            try self.write(when.value);
            try self.write(" -->");
            try self.writeNewline();

            self.depth += 1;
            for (when.children) |child| {
                try self.visitNode(child);
            }
            self.depth -= 1;
        }

        if (c.default_children.len > 0) {
            try self.writeIndent();
            try self.write("<!-- default -->");
            try self.writeNewline();
            self.depth += 1;
            for (c.default_children) |child| {
                try self.visitNode(child);
            }
            self.depth -= 1;
        }

        try self.writeIndent();
        try self.write("<!-- endcase -->");
        try self.writeNewline();
    }

    /// Generates placeholder for mixin call (runtime evaluation needed).
    fn visitMixinCall(self: *CodeGen, call: ast.MixinCall) CodeGenError!void {
        try self.writeIndent();
        try self.write("<!-- +");
        try self.write(call.name);
        try self.write(" -->");
        try self.writeNewline();
    }

    /// Generates placeholder for include (file loading needed).
    fn visitInclude(self: *CodeGen, inc: ast.Include) CodeGenError!void {
        try self.writeIndent();
        try self.write("<!-- include ");
        try self.write(inc.path);
        try self.write(" -->");
        try self.writeNewline();
    }

    /// Generates content for a named block.
    fn visitBlock(self: *CodeGen, blk: ast.Block) CodeGenError!void {
        try self.writeIndent();
        try self.write("<!-- block ");
        try self.write(blk.name);
        try self.write(" -->");
        try self.writeNewline();

        self.depth += 1;
        for (blk.children) |child| {
            try self.visitNode(child);
        }
        self.depth -= 1;

        try self.writeIndent();
        try self.write("<!-- endblock -->");
        try self.writeNewline();
    }

    /// Generates raw text content (for script/style blocks).
    fn visitRawText(self: *CodeGen, raw: ast.RawText) CodeGenError!void {
        try self.writeIndent();
        try self.write(raw.content);
        try self.writeNewline();
    }

    /// Generates code output (escaped or unescaped).
    fn visitCode(self: *CodeGen, code: ast.Code) CodeGenError!void {
        try self.writeIndent();
        if (code.escaped) {
            try self.write("{{ ");
        } else {
            try self.write("{{{ ");
        }
        try self.write(code.expression);
        if (code.escaped) {
            try self.write(" }}");
        } else {
            try self.write(" }}}");
        }
        try self.writeNewline();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Output helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// Writes text segments, handling interpolation.
    fn writeTextSegments(self: *CodeGen, segments: []const ast.TextSegment) CodeGenError!void {
        for (segments) |seg| {
            switch (seg) {
                .literal => |lit| try self.writeEscaped(lit),
                .interp_escaped => |expr| {
                    try self.write("{{ ");
                    try self.write(expr);
                    try self.write(" }}");
                },
                .interp_unescaped => |expr| {
                    try self.write("{{{ ");
                    try self.write(expr);
                    try self.write(" }}}");
                },
                .interp_tag => |inline_tag| {
                    try self.writeInlineTag(inline_tag);
                },
            }
        }
    }

    /// Writes an inline tag from tag interpolation.
    fn writeInlineTag(self: *CodeGen, tag: ast.InlineTag) CodeGenError!void {
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
                if (attr.escaped) {
                    try self.writeEscaped(value);
                } else {
                    try self.write(value);
                }
                try self.write("\"");
            } else {
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

    /// Writes indentation based on current depth.
    fn writeIndent(self: *CodeGen) CodeGenError!void {
        if (!self.options.pretty or self.preserve_whitespace) return;

        for (0..self.depth) |_| {
            try self.write(self.options.indent_str);
        }
    }

    /// Writes a newline if pretty-printing is enabled.
    fn writeNewline(self: *CodeGen) CodeGenError!void {
        if (!self.options.pretty or self.preserve_whitespace) return;
        try self.write("\n");
    }

    /// Writes a string directly to output.
    fn write(self: *CodeGen, str: []const u8) CodeGenError!void {
        try self.output.appendSlice(self.allocator, str);
    }

    /// Writes a string with HTML entity escaping.
    fn writeEscaped(self: *CodeGen, str: []const u8) CodeGenError!void {
        for (str) |c| {
            switch (c) {
                '&' => try self.write("&amp;"),
                '<' => try self.write("&lt;"),
                '>' => try self.write("&gt;"),
                '"' => try self.write("&quot;"),
                '\'' => try self.write("&#x27;"),
                else => try self.output.append(self.allocator, c),
            }
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Convenience function
// ─────────────────────────────────────────────────────────────────────────────

/// Generates HTML from an AST document with default options.
/// Returns an owned slice that the caller must free.
pub fn generate(allocator: std.mem.Allocator, doc: ast.Document) CodeGenError![]u8 {
    var gen = CodeGen.init(allocator, .{});
    defer gen.deinit();
    return gen.generateOwned(doc);
}

/// Generates HTML with custom options.
/// Returns an owned slice that the caller must free.
pub fn generateWithOptions(allocator: std.mem.Allocator, doc: ast.Document, options: Options) CodeGenError![]u8 {
    var gen = CodeGen.init(allocator, options);
    defer gen.deinit();
    return gen.generateOwned(doc);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "generate simple element" {
    const allocator = std.testing.allocator;

    const doc = ast.Document{
        .nodes = @constCast(&[_]ast.Node{
            .{ .element = .{
                .tag = "div",
                .id = null,
                .classes = &.{},
                .attributes = &.{},
                .inline_text = null,
                .children = &.{},
                .self_closing = false,
            } },
        }),
    };

    const html = try generate(allocator, doc);
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<div></div>\n", html);
}

test "generate element with id and class" {
    const allocator = std.testing.allocator;

    const doc = ast.Document{
        .nodes = @constCast(&[_]ast.Node{
            .{ .element = .{
                .tag = "div",
                .id = "main",
                .classes = &.{ "container", "active" },
                .attributes = &.{},
                .inline_text = null,
                .children = &.{},
                .self_closing = false,
            } },
        }),
    };

    const html = try generate(allocator, doc);
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<div id=\"main\" class=\"container active\"></div>\n", html);
}

test "generate void element" {
    const allocator = std.testing.allocator;

    const doc = ast.Document{
        .nodes = @constCast(&[_]ast.Node{
            .{ .element = .{
                .tag = "br",
                .id = null,
                .classes = &.{},
                .attributes = &.{},
                .inline_text = null,
                .children = &.{},
                .self_closing = false,
            } },
        }),
    };

    const html = try generate(allocator, doc);
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<br />\n", html);
}

test "generate nested elements" {
    const allocator = std.testing.allocator;

    var inner_text = [_]ast.TextSegment{.{ .literal = "Hello" }};
    var inner_node = [_]ast.Node{
        .{ .element = .{
            .tag = "p",
            .id = null,
            .classes = &.{},
            .attributes = &.{},
            .inline_text = &inner_text,
            .children = &.{},
            .self_closing = false,
        } },
    };

    const doc = ast.Document{
        .nodes = @constCast(&[_]ast.Node{
            .{ .element = .{
                .tag = "div",
                .id = null,
                .classes = &.{},
                .attributes = &.{},
                .inline_text = null,
                .children = &inner_node,
                .self_closing = false,
            } },
        }),
    };

    const html = try generate(allocator, doc);
    defer allocator.free(html);

    const expected =
        \\<div>
        \\  <p>Hello</p>
        \\</div>
        \\
    ;

    try std.testing.expectEqualStrings(expected, html);
}

test "generate with interpolation" {
    const allocator = std.testing.allocator;

    var inline_text = [_]ast.TextSegment{
        .{ .literal = "Hello, " },
        .{ .interp_escaped = "name" },
        .{ .literal = "!" },
    };

    const doc = ast.Document{
        .nodes = @constCast(&[_]ast.Node{
            .{ .element = .{
                .tag = "p",
                .id = null,
                .classes = &.{},
                .attributes = &.{},
                .inline_text = &inline_text,
                .children = &.{},
                .self_closing = false,
            } },
        }),
    };

    const html = try generate(allocator, doc);
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<p>Hello, {{ name }}!</p>\n", html);
}

test "generate html comment" {
    const allocator = std.testing.allocator;

    const doc = ast.Document{
        .nodes = @constCast(&[_]ast.Node{
            .{ .comment = .{
                .content = "This is a comment",
                .rendered = true,
                .children = &.{},
            } },
        }),
    };

    const html = try generate(allocator, doc);
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<!-- This is a comment -->\n", html);
}

test "escape html entities" {
    const allocator = std.testing.allocator;

    var inline_text = [_]ast.TextSegment{.{ .literal = "<script>alert('xss')</script>" }};

    const doc = ast.Document{
        .nodes = @constCast(&[_]ast.Node{
            .{ .element = .{
                .tag = "p",
                .id = null,
                .classes = &.{},
                .attributes = &.{},
                .inline_text = &inline_text,
                .children = &.{},
                .self_closing = false,
            } },
        }),
    };

    const html = try generate(allocator, doc);
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<p>&lt;script&gt;alert(&#x27;xss&#x27;)&lt;/script&gt;</p>\n", html);
}
