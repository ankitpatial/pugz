//! Test helper for Pugz engine
//! Provides common utilities for template testing

const std = @import("std");
const pugz = @import("pugz");

/// Normalizes HTML by removing indentation/formatting whitespace.
/// This allows comparing pretty vs non-pretty output.
fn normalizeHtml(allocator: std.mem.Allocator, html: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    var i: usize = 0;
    var in_tag = false;
    var last_was_space = false;

    while (i < html.len) {
        const c = html[i];

        if (c == '<') {
            in_tag = true;
            last_was_space = false;
            try result.append(allocator, c);
        } else if (c == '>') {
            in_tag = false;
            last_was_space = false;
            try result.append(allocator, c);
        } else if (c == '\n' or c == '\r') {
            // Skip newlines
            i += 1;
            continue;
        } else if (c == ' ' or c == '\t') {
            if (in_tag) {
                // Preserve single space in tags for attribute separation
                if (!last_was_space) {
                    try result.append(allocator, ' ');
                    last_was_space = true;
                }
            } else {
                // Outside tags: skip leading whitespace after >
                if (result.items.len > 0 and result.items[result.items.len - 1] != '>') {
                    if (!last_was_space) {
                        try result.append(allocator, ' ');
                        last_was_space = true;
                    }
                }
            }
            i += 1;
            continue;
        } else {
            last_was_space = false;
            try result.append(allocator, c);
        }
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

/// Expects the template to produce the expected output when rendered with the given data.
/// Uses arena allocator for automatic cleanup.
/// Normalizes whitespace/formatting so pretty-print differences don't cause failures.
pub fn expectOutput(template: []const u8, data: anytype, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const raw_result = try pugz.renderTemplate(allocator, template, data);
    const result = std.mem.trimRight(u8, raw_result, "\n");
    const expected_trimmed = std.mem.trimRight(u8, expected, "\n");

    // Normalize both for comparison (ignores pretty-print differences)
    const norm_result = try normalizeHtml(allocator, result);
    const norm_expected = try normalizeHtml(allocator, expected_trimmed);

    try std.testing.expectEqualStrings(norm_expected, norm_result);
}
