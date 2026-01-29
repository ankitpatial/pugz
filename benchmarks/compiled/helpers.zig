// Auto-generated helpers for compiled Pug templates
// This file is copied to the generated directory to provide shared utilities

const std = @import("std");

/// Append HTML-escaped string to buffer
pub fn appendEscaped(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '&' => try buf.appendSlice(allocator, "&amp;"),
            '<' => try buf.appendSlice(allocator, "&lt;"),
            '>' => try buf.appendSlice(allocator, "&gt;"),
            '"' => try buf.appendSlice(allocator, "&quot;"),
            '\'' => try buf.appendSlice(allocator, "&#39;"),
            else => try buf.append(allocator, c),
        }
    }
}

/// Check if a value is truthy (for conditionals)
pub fn isTruthy(val: anytype) bool {
    const T = @TypeOf(val);
    return switch (@typeInfo(T)) {
        .bool => val,
        .int, .float => val != 0,
        .pointer => |ptr| switch (ptr.size) {
            .slice => val.len > 0,
            else => true,
        },
        .optional => if (val) |v| isTruthy(v) else false,
        else => true,
    };
}
