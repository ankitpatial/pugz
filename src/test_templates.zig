//! Template test cases for Pugz engine
//!
//! Run with: zig build test
//! Or run specific: zig test src/test_templates.zig

const std = @import("std");
const pugz = @import("root.zig");

/// Helper to compile and render a template with data
fn render(allocator: std.mem.Allocator, source: []const u8, setData: fn (*pugz.Context) anyerror!void) ![]u8 {
    var lexer = pugz.Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();

    var parser = pugz.Parser.init(allocator, tokens);
    const doc = try parser.parse();

    var ctx = pugz.Context.init(allocator);
    defer ctx.deinit();

    try ctx.pushScope();
    try setData(&ctx);

    var runtime = pugz.Runtime.init(allocator, &ctx, .{ .pretty = false });
    defer runtime.deinit();

    return runtime.renderOwned(doc);
}

/// Helper for templates with no data
fn renderNoData(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    return render(allocator, source, struct {
        fn set(_: *pugz.Context) anyerror!void {}
    }.set);
}

// ─────────────────────────────────────────────────────────────────────────────
// Test Cases
// ─────────────────────────────────────────────────────────────────────────────

test "simple tag" {
    const allocator = std.testing.allocator;
    const html = try renderNoData(allocator, "p Hello");
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<p>Hello</p>", html);
}

test "tag with class" {
    const allocator = std.testing.allocator;
    const html = try renderNoData(allocator, "p.intro Hello");
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<p class=\"intro\">Hello</p>", html);
}

test "tag with id" {
    const allocator = std.testing.allocator;
    const html = try renderNoData(allocator, "div#main");
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<div id=\"main\"></div>", html);
}

test "tag with id and class" {
    const allocator = std.testing.allocator;
    const html = try renderNoData(allocator, "div#main.container");
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<div id=\"main\" class=\"container\"></div>", html);
}

test "multiple classes" {
    const allocator = std.testing.allocator;
    const html = try renderNoData(allocator, "div.foo.bar.baz");
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<div class=\"foo bar baz\"></div>", html);
}

test "interpolation with data" {
    const allocator = std.testing.allocator;
    const html = try render(allocator, "p #{name}'s code", struct {
        fn set(ctx: *pugz.Context) anyerror!void {
            try ctx.set("name", pugz.Value.str("ankit patial"));
        }
    }.set);
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<p>ankit patial&#x27;s code</p>", html);
}

test "interpolation at start of text" {
    const allocator = std.testing.allocator;
    const html = try render(allocator, "title #{title}", struct {
        fn set(ctx: *pugz.Context) anyerror!void {
            try ctx.set("title", pugz.Value.str("My Page"));
        }
    }.set);
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<title>My Page</title>", html);
}

test "multiple interpolations" {
    const allocator = std.testing.allocator;
    const html = try render(allocator, "p #{a} and #{b}", struct {
        fn set(ctx: *pugz.Context) anyerror!void {
            try ctx.set("a", pugz.Value.str("foo"));
            try ctx.set("b", pugz.Value.str("bar"));
        }
    }.set);
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<p>foo and bar</p>", html);
}

test "integer interpolation" {
    const allocator = std.testing.allocator;
    const html = try render(allocator, "p Count: #{count}", struct {
        fn set(ctx: *pugz.Context) anyerror!void {
            try ctx.set("count", pugz.Value.integer(42));
        }
    }.set);
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<p>Count: 42</p>", html);
}

test "void element br" {
    const allocator = std.testing.allocator;
    const html = try renderNoData(allocator, "br");
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<br />", html);
}

test "void element img with attributes" {
    const allocator = std.testing.allocator;
    const html = try renderNoData(allocator, "img(src=\"logo.png\" alt=\"Logo\")");
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<img src=\"logo.png\" alt=\"Logo\" />", html);
}

test "attribute with single quotes" {
    const allocator = std.testing.allocator;
    const html = try renderNoData(allocator, "a(href='//google.com')");
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<a href=\"//google.com\"></a>", html);
}

test "attribute with double quotes" {
    const allocator = std.testing.allocator;
    const html = try renderNoData(allocator, "a(href=\"//google.com\")");
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<a href=\"//google.com\"></a>", html);
}

test "multiple attributes with comma" {
    const allocator = std.testing.allocator;
    const html = try renderNoData(allocator, "a(class='btn', href='/link')");
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<a class=\"btn\" href=\"/link\"></a>", html);
}

test "multiple attributes without comma" {
    const allocator = std.testing.allocator;
    const html = try renderNoData(allocator, "a(class='btn' href='/link')");
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<a class=\"btn\" href=\"/link\"></a>", html);
}

test "boolean attribute" {
    const allocator = std.testing.allocator;
    const html = try renderNoData(allocator, "input(type=\"checkbox\" checked)");
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<input type=\"checkbox\" checked />", html);
}

test "html comment" {
    const allocator = std.testing.allocator;
    const html = try renderNoData(allocator, "// This is a comment");
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<!--  This is a comment -->", html);
}

test "unbuffered comment not rendered" {
    const allocator = std.testing.allocator;
    const html = try renderNoData(allocator, "//- Hidden comment");
    defer allocator.free(html);
    try std.testing.expectEqualStrings("", html);
}

test "nested elements" {
    const allocator = std.testing.allocator;
    const html = try renderNoData(allocator,
        \\div
        \\  p Hello
    );
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<div><p>Hello</p></div>", html);
}

test "deeply nested elements" {
    const allocator = std.testing.allocator;
    const html = try renderNoData(allocator,
        \\html
        \\  body
        \\    div
        \\      p Text
    );
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<html><body><div><p>Text</p></div></body></html>", html);
}

test "sibling elements" {
    const allocator = std.testing.allocator;
    const html = try renderNoData(allocator,
        \\ul
        \\  li One
        \\  li Two
        \\  li Three
    );
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<ul><li>One</li><li>Two</li><li>Three</li></ul>", html);
}

test "div shorthand with class only" {
    const allocator = std.testing.allocator;
    const html = try renderNoData(allocator, ".container");
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<div class=\"container\"></div>", html);
}

test "div shorthand with id only" {
    const allocator = std.testing.allocator;
    const html = try renderNoData(allocator, "#main");
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<div id=\"main\"></div>", html);
}

test "class and id on div shorthand" {
    const allocator = std.testing.allocator;
    const html = try renderNoData(allocator, "#main.container.active");
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<div id=\"main\" class=\"container active\"></div>", html);
}

test "html escaping in text" {
    const allocator = std.testing.allocator;
    const html = try renderNoData(allocator, "p <script>alert('xss')</script>");
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<p>&lt;script&gt;alert(&#x27;xss&#x27;)&lt;/script&gt;</p>", html);
}

test "html escaping in interpolation" {
    const allocator = std.testing.allocator;
    const html = try render(allocator, "p #{code}", struct {
        fn set(ctx: *pugz.Context) anyerror!void {
            try ctx.set("code", pugz.Value.str("<b>bold</b>"));
        }
    }.set);
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<p>&lt;b&gt;bold&lt;/b&gt;</p>", html);
}

// ─────────────────────────────────────────────────────────────────────────────
// Known Issues / TODO Tests (these document expected behavior not yet working)
// ─────────────────────────────────────────────────────────────────────────────

// TODO: Inline text after attributes
// test "inline text after attributes" {
//     const allocator = std.testing.allocator;
//     const html = try renderNoData(allocator, "a(href='//google.com') Google");
//     defer allocator.free(html);
//     try std.testing.expectEqualStrings("<a href=\"//google.com\">Google</a>", html);
// }

// TODO: Pipe text for newlines
// test "pipe text" {
//     const allocator = std.testing.allocator;
//     const html = try renderNoData(allocator,
//         \\p
//         \\  | Line 1
//         \\  | Line 2
//     );
//     defer allocator.free(html);
//     try std.testing.expectEqualStrings("<p>Line 1Line 2</p>", html);
// }

// TODO: Block expansion with colon
// test "block expansion" {
//     const allocator = std.testing.allocator;
//     const html = try renderNoData(allocator, "ul: li Item");
//     defer allocator.free(html);
//     try std.testing.expectEqualStrings("<ul><li>Item</li></ul>", html);
// }
