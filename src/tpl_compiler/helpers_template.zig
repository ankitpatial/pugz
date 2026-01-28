// Auto-generated helpers for compiled Pug templates
// This file is copied to the generated directory to provide shared utilities

const std = @import("std");

/// Append HTML-escaped string to buffer
pub fn appendEscaped(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, str: []const u8) !void {
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

/// Append an integer value to buffer (formatted as decimal string)
pub fn appendInt(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: anytype) !void {
    var tmp: [32]u8 = undefined;
    const str = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch return;
    try buf.appendSlice(allocator, str);
}

/// Append a float value to buffer (formatted with 2 decimal places)
pub fn appendFloat(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: anytype) !void {
    var tmp: [64]u8 = undefined;
    const str = std.fmt.bufPrint(&tmp, "{d:.2}", .{value}) catch return;
    try buf.appendSlice(allocator, str);
}

/// Append any value to buffer (auto-detects type)
pub fn appendValue(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int, .comptime_int => try appendInt(buf, allocator, value),
        .float, .comptime_float => try appendFloat(buf, allocator, value),
        .bool => try buf.appendSlice(allocator, if (value) "true" else "false"),
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                // String slice
                try appendEscaped(buf, allocator, value);
            } else {
                // Other slices - not directly supported
                try buf.appendSlice(allocator, "[...]");
            }
        },
        else => {
            // Fallback - try to format it
            var tmp: [128]u8 = undefined;
            const str = std.fmt.bufPrint(&tmp, "{any}", .{value}) catch "[?]";
            try buf.appendSlice(allocator, str);
        },
    }
}
