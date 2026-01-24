// template.zig - Runtime template rendering with data binding
//
// This module provides runtime data binding for Pug templates.
// It allows passing a Zig struct and rendering dynamic content.
//
// Example usage:
//   const html = try pug.renderWithData(allocator, "p Hello, #{name}!", .{ .name = "World" });
//   // Result: <p>Hello, World!</p>

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
    defer parse.deinit(); // Clean up parser state (deferred tokens, etc.)

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

    try renderNode(allocator, &output, ast, data);

    return output.toOwnedSlice(allocator);
}

fn renderNode(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), node: *Node, data: anytype) Allocator.Error!void {
    switch (node.type) {
        .Block => {
            for (node.nodes.items) |child| {
                try renderNode(allocator, output, child, data);
            }
        },
        .Tag, .InterpolatedTag => try renderTag(allocator, output, node, data),
        .Text => try renderText(allocator, output, node, data),
        .Code => try renderCode(allocator, output, node, data),
        .Comment => try renderComment(allocator, output, node),
        .BlockComment => try renderBlockComment(allocator, output, node, data),
        .Doctype => try renderDoctype(allocator, output, node),
        else => {
            for (node.nodes.items) |child| {
                try renderNode(allocator, output, child, data);
            }
        },
    }
}

fn renderTag(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), tag: *Node, data: anytype) Allocator.Error!void {
    const name = tag.name orelse "div";

    try output.appendSlice(allocator, "<");
    try output.appendSlice(allocator, name);

    // Render attributes
    for (tag.attrs.items) |attr| {
        try output.appendSlice(allocator, " ");
        try output.appendSlice(allocator, attr.name);
        if (attr.val) |val| {
            try output.appendSlice(allocator, "=\"");
            // Check if val is a quoted string or expression
            if (val.len >= 2 and (val[0] == '"' or val[0] == '\'')) {
                // Quoted string - output without outer quotes, process interpolation
                try processInterpolation(allocator, output, val[1 .. val.len - 1], true, data);
            } else {
                // Expression - try to evaluate
                if (getFieldValue(data, val)) |value| {
                    try appendEscaped(allocator, output, value);
                } else {
                    try appendEscaped(allocator, output, val);
                }
            }
            try output.appendSlice(allocator, "\"");
        }
    }

    // Self-closing tags
    const self_closing = isSelfClosing(name);
    if (self_closing and tag.nodes.items.len == 0 and tag.val == null) {
        try output.appendSlice(allocator, ">");
        return;
    }

    try output.appendSlice(allocator, ">");

    // Render text content
    if (tag.val) |val| {
        try processInterpolation(allocator, output, val, true, data);
    }

    // Render children
    for (tag.nodes.items) |child| {
        try renderNode(allocator, output, child, data);
    }

    // Close tag
    if (!self_closing) {
        try output.appendSlice(allocator, "</");
        try output.appendSlice(allocator, name);
        try output.appendSlice(allocator, ">");
    }
}

fn renderText(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), text: *Node, data: anytype) Allocator.Error!void {
    if (text.val) |val| {
        try processInterpolation(allocator, output, val, true, data);
    }
}

fn renderCode(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), code: *Node, data: anytype) Allocator.Error!void {
    if (code.buffer) {
        if (code.val) |val| {
            if (getFieldValue(data, val)) |value| {
                if (code.must_escape) {
                    try appendEscaped(allocator, output, value);
                } else {
                    try output.appendSlice(allocator, value);
                }
            }
        }
    }

    for (code.nodes.items) |child| {
        try renderNode(allocator, output, child, data);
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

fn renderBlockComment(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), comment: *Node, data: anytype) Allocator.Error!void {
    if (!comment.buffer) return;
    try output.appendSlice(allocator, "<!--");
    if (comment.val) |val| {
        try output.appendSlice(allocator, val);
    }
    for (comment.nodes.items) |child| {
        try renderNode(allocator, output, child, data);
    }
    try output.appendSlice(allocator, "-->");
}

fn renderDoctype(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), doctype: *Node) Allocator.Error!void {
    if (doctype.val) |val| {
        if (std.mem.eql(u8, val, "html")) {
            try output.appendSlice(allocator, "<!DOCTYPE html>");
        } else if (std.mem.eql(u8, val, "xml")) {
            try output.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"utf-8\" ?>");
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
fn processInterpolation(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), text: []const u8, escape: bool, data: anytype) Allocator.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        // Look for #{
        if (i + 1 < text.len and text[i] == '#' and text[i + 1] == '{') {
            // Find closing }
            var j = i + 2;
            var brace_count: usize = 1;
            while (j < text.len and brace_count > 0) {
                if (text[j] == '{') brace_count += 1;
                if (text[j] == '}') brace_count -= 1;
                j += 1;
            }
            if (brace_count == 0) {
                // Extract expression
                const expr = std.mem.trim(u8, text[i + 2 .. j - 1], " \t");
                if (getFieldValue(data, expr)) |value| {
                    if (escape) {
                        try appendEscaped(allocator, output, value);
                    } else {
                        try output.appendSlice(allocator, value);
                    }
                }
                i = j;
                continue;
            }
        }
        // Regular character
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

/// Get a field value from the data struct by name
fn getFieldValue(data: anytype, name: []const u8) ?[]const u8 {
    const T = @TypeOf(data);
    const info = @typeInfo(T);

    if (info != .@"struct") return null;

    inline for (info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            const value = @field(data, field.name);
            const ValueType = @TypeOf(value);

            // Handle []const u8
            if (ValueType == []const u8) {
                return value;
            }

            // Handle string literals (*const [N:0]u8)
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

fn appendEscaped(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), str: []const u8) Allocator.Error!void {
    for (str) |c| {
        if (runtime.escapeChar(c)) |esc| {
            try output.appendSlice(allocator, esc);
        } else {
            try output.append(allocator, c);
        }
    }
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
