const std = @import("std");
const pugz = @import("pugz");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    // Use arena allocator - recommended for templates (all memory freed at once)
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("=== Pugz Template Engine ===\n\n", .{});

    // Simple API: renderTemplate - one function call does everything
    std.debug.print("--- Simple API (recommended for servers) ---\n", .{});
    const html = try pugz.renderTemplate(allocator,
        \\doctype html
        \\html
        \\  head
        \\    title= title
        \\  body
        \\    h1 Hello, #{name}!
        \\    p Welcome to Pugz.
        \\    ul
        \\      each item in items
        \\        li= item
    , .{
        .title = "My Page",
        .name = "World",
        .items = &[_][]const u8{ "First", "Second", "Third" },
    });
    std.debug.print("{s}\n", .{html});

    // Advanced API: parse once, render multiple times with different data
    std.debug.print("--- Advanced API (parse once, render many) ---\n", .{});

    const source =
        \\p Hello, #{name}!
    ;

    // Tokenize & Parse (do this once)
    var lexer = pugz.Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    var parser = pugz.Parser.init(allocator, tokens);
    const doc = try parser.parse();

    // Render multiple times with different data
    const html1 = try pugz.render(allocator, doc, .{ .name = "Alice" });
    const html2 = try pugz.render(allocator, doc, .{ .name = "Bob" });

    std.debug.print("Render 1: {s}", .{html1});
    std.debug.print("Render 2: {s}", .{html2});
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
