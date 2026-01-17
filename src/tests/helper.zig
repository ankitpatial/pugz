//! Test helper for Pugz engine
//! Provides common utilities for template testing

const std = @import("std");
const pugz = @import("pugz");

/// Expects the template to produce the expected output when rendered with the given data.
/// Uses arena allocator for automatic cleanup.
pub fn expectOutput(template: []const u8, data: anytype, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var lexer = pugz.Lexer.init(allocator, template);
    const tokens = try lexer.tokenize();

    var parser = pugz.Parser.init(allocator, tokens);
    const doc = try parser.parse();

    const raw_result = try pugz.render(allocator, doc, data);
    const result = std.mem.trimRight(u8, raw_result, "\n");

    try std.testing.expectEqualStrings(expected, result);
}
