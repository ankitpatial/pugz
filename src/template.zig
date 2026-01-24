// template.zig - Runtime template rendering with data binding
//
// This module provides runtime data binding for Pug templates.
// It allows passing a Zig struct and rendering dynamic content.
// Reuses utilities from runtime.zig for escaping and attribute rendering.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pug = @import("pug.zig");
const parser = @import("parser.zig");
const Node = parser.Node;
const runtime = @import("runtime.zig");

pub const TemplateError = error{
    OutOfMemory,
    LexerError,
    ParserError,
};

/// Render context tracks state like doctype mode
pub const RenderContext = struct {
    /// true = HTML5 terse mode (default), false = XHTML mode
    terse: bool = true,
};

/// Render a template with data
pub fn renderWithData(allocator: Allocator, source: []const u8, data: anytype) ![]const u8 {
    // Lex
    var lex = pug.lexer.Lexer.init(allocator, source, .{}) catch return error.OutOfMemory;
    defer lex.deinit();

    const tokens = lex.getTokens() catch return error.LexerError;

    // Strip comments
    var stripped = pug.strip_comments.stripComments(allocator, tokens, .{}) catch return error.OutOfMemory;
    defer stripped.deinit(allocator);

    // Parse
    var parse = pug.parser.Parser.init(allocator, stripped.tokens.items, null, source);
    defer parse.deinit();

    const ast = parse.parse() catch {
        return error.ParserError;
    };
    defer {
        ast.deinit(allocator);
        allocator.destroy(ast);
    }

    // Render with data
    var output = std.ArrayListUnmanaged(u8){};
    errdefer output.deinit(allocator);

    // Detect doctype to set terse mode
    var ctx = RenderContext{};
    detectDoctype(ast, &ctx);

    try renderNode(allocator, &output, ast, data, &ctx);

    return output.toOwnedSlice(allocator);
}

/// Scan AST for doctype and set terse mode accordingly
fn detectDoctype(node: *Node, ctx: *RenderContext) void {
    if (node.type == .Doctype) {
        if (node.val) |val| {
            // XHTML doctypes use non-terse mode
            if (std.mem.eql(u8, val, "xml") or
                std.mem.eql(u8, val, "strict") or
                std.mem.eql(u8, val, "transitional") or
                std.mem.eql(u8, val, "frameset") or
                std.mem.eql(u8, val, "1.1") or
                std.mem.eql(u8, val, "basic") or
                std.mem.eql(u8, val, "mobile"))
            {
                ctx.terse = false;
            }
        }
        return;
    }

    // Check children
    for (node.nodes.items) |child| {
        detectDoctype(child, ctx);
        if (!ctx.terse) return;
    }
}

fn renderNode(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), node: *Node, data: anytype, ctx: *const RenderContext) Allocator.Error!void {
    switch (node.type) {
        .Block, .NamedBlock => {
            for (node.nodes.items) |child| {
                try renderNode(allocator, output, child, data, ctx);
            }
        },
        .Tag, .InterpolatedTag => try renderTag(allocator, output, node, data, ctx),
        .Text => try renderText(allocator, output, node, data),
        .Code => try renderCode(allocator, output, node, data, ctx),
        .Comment => try renderComment(allocator, output, node),
        .BlockComment => try renderBlockComment(allocator, output, node, data, ctx),
        .Doctype => try renderDoctype(allocator, output, node),
        .Each => try renderEach(allocator, output, node, data, ctx),
        .Mixin => {
            // Mixin definitions are skipped (only mixin calls render)
            if (!node.call) return;
            for (node.nodes.items) |child| {
                try renderNode(allocator, output, child, data, ctx);
            }
        },
        else => {
            for (node.nodes.items) |child| {
                try renderNode(allocator, output, child, data, ctx);
            }
        },
    }
}

fn renderTag(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), tag: *Node, data: anytype, ctx: *const RenderContext) Allocator.Error!void {
    const name = tag.name orelse "div";

    try output.appendSlice(allocator, "<");
    try output.appendSlice(allocator, name);

    // Render attributes using runtime.attr()
    for (tag.attrs.items) |attr| {
        const attr_val = try evaluateAttrValue(allocator, attr.val, data);
        const attr_str = runtime.attr(allocator, attr.name, attr_val, true, ctx.terse) catch |err| switch (err) {
            error.FormatError => return error.OutOfMemory,
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer allocator.free(attr_str);
        try output.appendSlice(allocator, attr_str);
    }

    // Self-closing logic differs by mode:
    // - HTML5 terse: void elements are self-closing without />
    // - XHTML/XML: only explicit / makes tags self-closing
    const is_void = isSelfClosing(name);
    const is_self_closing = if (ctx.terse)
        tag.self_closing or is_void
    else
        tag.self_closing;

    if (is_self_closing and tag.nodes.items.len == 0 and tag.val == null) {
        if (ctx.terse and !tag.self_closing) {
            try output.appendSlice(allocator, ">");
        } else {
            try output.appendSlice(allocator, "/>");
        }
        return;
    }

    try output.appendSlice(allocator, ">");

    // Render text content
    if (tag.val) |val| {
        try processInterpolation(allocator, output, val, false, data);
    }

    // Render children
    for (tag.nodes.items) |child| {
        try renderNode(allocator, output, child, data, ctx);
    }

    // Close tag
    if (!is_self_closing) {
        try output.appendSlice(allocator, "</");
        try output.appendSlice(allocator, name);
        try output.appendSlice(allocator, ">");
    }
}

/// Evaluate attribute value from AST to runtime.AttrValue
fn evaluateAttrValue(allocator: Allocator, val: ?[]const u8, data: anytype) !runtime.AttrValue {
    _ = allocator;
    const v = val orelse return .{ .boolean = true }; // No value = boolean attribute

    // Handle boolean literals
    if (std.mem.eql(u8, v, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, v, "false")) return .{ .boolean = false };
    if (std.mem.eql(u8, v, "null") or std.mem.eql(u8, v, "undefined")) return .none;

    // Quoted string - extract inner value
    if (v.len >= 2 and (v[0] == '"' or v[0] == '\'')) {
        return .{ .string = v[1 .. v.len - 1] };
    }

    // Expression - try to look up in data
    if (getFieldValue(data, v)) |value| {
        return .{ .string = value };
    }

    // Unknown expression - return as string literal
    return .{ .string = v };
}

fn renderText(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), text: *Node, data: anytype) Allocator.Error!void {
    if (text.val) |val| {
        try processInterpolation(allocator, output, val, false, data);
    }
}

fn renderCode(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), code: *Node, data: anytype, ctx: *const RenderContext) Allocator.Error!void {
    if (code.buffer) {
        if (code.val) |val| {
            // Check if it's a string literal (quoted)
            if (val.len >= 2 and (val[0] == '"' or val[0] == '\'')) {
                const inner = val[1 .. val.len - 1];
                if (code.must_escape) {
                    try runtime.appendEscaped(allocator, output, inner);
                } else {
                    try output.appendSlice(allocator, inner);
                }
            } else if (getFieldValue(data, val)) |value| {
                if (code.must_escape) {
                    try runtime.appendEscaped(allocator, output, value);
                } else {
                    try output.appendSlice(allocator, value);
                }
            }
        }
    }

    for (code.nodes.items) |child| {
        try renderNode(allocator, output, child, data, ctx);
    }
}

fn renderEach(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), each: *Node, data: anytype, ctx: *const RenderContext) Allocator.Error!void {
    const collection_name = each.obj orelse return;
    const item_name = each.val orelse "item";
    _ = item_name;

    const T = @TypeOf(data);
    const info = @typeInfo(T);

    if (info != .@"struct") return;

    inline for (info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, collection_name)) {
            const collection = @field(data, field.name);
            const CollType = @TypeOf(collection);
            const coll_info = @typeInfo(CollType);

            if (coll_info == .pointer and coll_info.pointer.size == .slice) {
                for (collection) |item| {
                    const ItemType = @TypeOf(item);
                    if (ItemType == []const u8) {
                        for (each.nodes.items) |child| {
                            try renderNodeWithItem(allocator, output, child, data, item, ctx);
                        }
                    } else {
                        for (each.nodes.items) |child| {
                            try renderNode(allocator, output, child, data, ctx);
                        }
                    }
                }
                return;
            }
        }
    }

    if (each.alternate) |alt| {
        try renderNode(allocator, output, alt, data, ctx);
    }
}

fn renderNodeWithItem(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), node: *Node, data: anytype, item: []const u8, ctx: *const RenderContext) Allocator.Error!void {
    switch (node.type) {
        .Block, .NamedBlock => {
            for (node.nodes.items) |child| {
                try renderNodeWithItem(allocator, output, child, data, item, ctx);
            }
        },
        .Tag, .InterpolatedTag => try renderTagWithItem(allocator, output, node, data, item, ctx),
        .Text => try renderTextWithItem(allocator, output, node, item),
        .Code => {
            if (node.buffer) {
                if (node.must_escape) {
                    try runtime.appendEscaped(allocator, output, item);
                } else {
                    try output.appendSlice(allocator, item);
                }
            }
        },
        else => {
            for (node.nodes.items) |child| {
                try renderNodeWithItem(allocator, output, child, data, item, ctx);
            }
        },
    }
}

fn renderTagWithItem(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), tag: *Node, data: anytype, item: []const u8, ctx: *const RenderContext) Allocator.Error!void {
    const name = tag.name orelse "div";

    try output.appendSlice(allocator, "<");
    try output.appendSlice(allocator, name);

    // Render attributes using runtime.attr()
    for (tag.attrs.items) |attr| {
        const attr_val = try evaluateAttrValue(allocator, attr.val, data);
        const attr_str = runtime.attr(allocator, attr.name, attr_val, true, ctx.terse) catch |err| switch (err) {
            error.FormatError => return error.OutOfMemory,
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer allocator.free(attr_str);
        try output.appendSlice(allocator, attr_str);
    }

    const is_void = isSelfClosing(name);
    const is_self_closing = if (ctx.terse)
        tag.self_closing or is_void
    else
        tag.self_closing;

    if (is_self_closing and tag.nodes.items.len == 0 and tag.val == null) {
        if (ctx.terse and !tag.self_closing) {
            try output.appendSlice(allocator, ">");
        } else {
            try output.appendSlice(allocator, "/>");
        }
        return;
    }

    try output.appendSlice(allocator, ">");

    if (tag.val) |val| {
        try processInterpolationWithItem(allocator, output, val, true, data, item);
    }

    for (tag.nodes.items) |child| {
        try renderNodeWithItem(allocator, output, child, data, item, ctx);
    }

    if (!is_self_closing) {
        try output.appendSlice(allocator, "</");
        try output.appendSlice(allocator, name);
        try output.appendSlice(allocator, ">");
    }
}

fn renderTextWithItem(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), text: *Node, item: []const u8) Allocator.Error!void {
    if (text.val) |val| {
        try runtime.appendEscaped(allocator, output, val);
        _ = item;
    }
}

fn processInterpolationWithItem(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), text: []const u8, escape: bool, data: anytype, item: []const u8) Allocator.Error!void {
    _ = data;
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '#' and text[i + 1] == '{') {
            var j = i + 2;
            var brace_count: usize = 1;
            while (j < text.len and brace_count > 0) {
                if (text[j] == '{') brace_count += 1;
                if (text[j] == '}') brace_count -= 1;
                j += 1;
            }
            if (brace_count == 0) {
                if (escape) {
                    try runtime.appendEscaped(allocator, output, item);
                } else {
                    try output.appendSlice(allocator, item);
                }
                i = j;
                continue;
            }
        }
        if (escape) {
            if (runtime.escapeChar(text[i])) |esc| {
                try output.appendSlice(allocator, esc);
            } else {
                try output.append(allocator, text[i]);
            }
        } else {
            try output.append(allocator, text[i]);
        }
        i += 1;
    }
}

fn renderComment(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), comment: *Node) Allocator.Error!void {
    if (!comment.buffer) return;
    try output.appendSlice(allocator, "<!--");
    if (comment.val) |val| {
        try output.appendSlice(allocator, val);
    }
    try output.appendSlice(allocator, "-->");
}

fn renderBlockComment(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), comment: *Node, data: anytype, ctx: *const RenderContext) Allocator.Error!void {
    if (!comment.buffer) return;
    try output.appendSlice(allocator, "<!--");
    if (comment.val) |val| {
        try output.appendSlice(allocator, val);
    }
    for (comment.nodes.items) |child| {
        try renderNode(allocator, output, child, data, ctx);
    }
    try output.appendSlice(allocator, "-->");
}

// Doctype mappings
const doctypes = std.StaticStringMap([]const u8).initComptime(.{
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

fn renderDoctype(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), doctype: *Node) Allocator.Error!void {
    if (doctype.val) |val| {
        if (doctypes.get(val)) |dt| {
            try output.appendSlice(allocator, dt);
        } else {
            try output.appendSlice(allocator, "<!DOCTYPE ");
            try output.appendSlice(allocator, val);
            try output.appendSlice(allocator, ">");
        }
    } else {
        try output.appendSlice(allocator, "<!DOCTYPE html>");
    }
}

/// Process interpolation #{expr} in text
/// escape_quotes: true for attribute values (escape "), false for text content
fn processInterpolation(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), text: []const u8, escape_quotes: bool, data: anytype) Allocator.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '#' and text[i + 1] == '{') {
            var j = i + 2;
            var brace_count: usize = 1;
            while (j < text.len and brace_count > 0) {
                if (text[j] == '{') brace_count += 1;
                if (text[j] == '}') brace_count -= 1;
                j += 1;
            }
            if (brace_count == 0) {
                const expr = std.mem.trim(u8, text[i + 2 .. j - 1], " \t");
                if (getFieldValue(data, expr)) |value| {
                    if (escape_quotes) {
                        try runtime.appendEscaped(allocator, output, value);
                    } else {
                        // Text content: escape < > & but not quotes
                        try appendTextEscaped(allocator, output, value);
                    }
                }
                i = j;
                continue;
            }
        }
        // Regular character - use appropriate escaping
        const c = text[i];
        if (escape_quotes) {
            if (runtime.escapeChar(c)) |esc| {
                try output.appendSlice(allocator, esc);
            } else {
                try output.append(allocator, c);
            }
        } else {
            // Text content: escape < > & but not quotes, preserve HTML entities
            switch (c) {
                '<' => try output.appendSlice(allocator, "&lt;"),
                '>' => try output.appendSlice(allocator, "&gt;"),
                '&' => {
                    if (isHtmlEntity(text[i..])) {
                        try output.append(allocator, c);
                    } else {
                        try output.appendSlice(allocator, "&amp;");
                    }
                },
                else => try output.append(allocator, c),
            }
        }
        i += 1;
    }
}

/// Get a field value from the data struct by name
fn getFieldValue(data: anytype, name: []const u8) ?[]const u8 {
    const T = @TypeOf(data);
    const info = @typeInfo(T);

    if (info != .@"struct") return null;

    inline for (info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            const value = @field(data, field.name);
            const ValueType = @TypeOf(value);

            if (ValueType == []const u8) {
                return value;
            }

            const value_info = @typeInfo(ValueType);
            if (value_info == .pointer) {
                const ptr = value_info.pointer;
                if (ptr.size == .one) {
                    const child_info = @typeInfo(ptr.child);
                    if (child_info == .array and child_info.array.child == u8) {
                        return value;
                    }
                }
            }
        }
    }
    return null;
}

/// Escape for text content - escapes < > & (NOT quotes)
/// Preserves existing HTML entities like &#8217;
fn appendTextEscaped(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), str: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < str.len) {
        const c = str[i];
        switch (c) {
            '<' => try output.appendSlice(allocator, "&lt;"),
            '>' => try output.appendSlice(allocator, "&gt;"),
            '&' => {
                if (isHtmlEntity(str[i..])) {
                    try output.append(allocator, c);
                } else {
                    try output.appendSlice(allocator, "&amp;");
                }
            },
            else => try output.append(allocator, c),
        }
        i += 1;
    }
}

/// Check if string starts with a valid HTML entity
fn isHtmlEntity(str: []const u8) bool {
    if (str.len < 3 or str[0] != '&') return false;

    var i: usize = 1;

    // Numeric entity: &#digits; or &#xhex;
    if (str[i] == '#') {
        i += 1;
        if (i >= str.len) return false;

        if (str[i] == 'x' or str[i] == 'X') {
            i += 1;
            if (i >= str.len) return false;
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

fn isSelfClosing(name: []const u8) bool {
    const self_closing_tags = [_][]const u8{
        "area", "base", "br",    "col",    "embed", "hr",  "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    };
    for (self_closing_tags) |tag| {
        if (std.mem.eql(u8, name, tag)) return true;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "simple interpolation" {
    const allocator = std.testing.allocator;

    const html = try renderWithData(allocator, "p Hello, #{name}!", .{ .name = "World" });
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<p>Hello, World!</p>", html);
}

test "multiple interpolations" {
    const allocator = std.testing.allocator;

    const html = try renderWithData(allocator, "p #{greeting}, #{name}!", .{
        .greeting = "Hello",
        .name = "World",
    });
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<p>Hello, World!</p>", html);
}

test "attribute with data" {
    const allocator = std.testing.allocator;

    const html = try renderWithData(allocator, "a(href=url) Click", .{ .url = "/home" });
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<a href=\"/home\">Click</a>", html);
}

test "buffered code" {
    const allocator = std.testing.allocator;

    const html = try renderWithData(allocator, "p= message", .{ .message = "Hello" });
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<p>Hello</p>", html);
}

test "escape html" {
    const allocator = std.testing.allocator;

    const html = try renderWithData(allocator, "p #{content}", .{ .content = "<b>bold</b>" });
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<p>&lt;b&gt;bold&lt;/b&gt;</p>", html);
}

test "no data - static template" {
    const allocator = std.testing.allocator;

    const html = try renderWithData(allocator, "p Hello, World!", .{});
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<p>Hello, World!</p>", html);
}

test "nested tags with data" {
    const allocator = std.testing.allocator;

    const html = try renderWithData(allocator,
        \\div
        \\  h1 #{title}
        \\  p #{body}
    , .{
        .title = "Welcome",
        .body = "Hello there!",
    });
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<div><h1>Welcome</h1><p>Hello there!</p></div>", html);
}
