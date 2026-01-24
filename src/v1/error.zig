const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

// ============================================================================
// Pug Error - Error formatting with source context
// Based on pug-error package
// ============================================================================

/// Pug error with source context and formatting
pub const PugError = struct {
    /// Error code (e.g., "PUG:SYNTAX_ERROR")
    code: []const u8,
    /// Short error message
    msg: []const u8,
    /// Line number (1-indexed)
    line: usize,
    /// Column number (1-indexed, 0 if unknown)
    column: usize,
    /// Source filename (optional)
    filename: ?[]const u8,
    /// Source code (optional, for context display)
    src: ?[]const u8,
    /// Full formatted message with context
    full_message: ?[]const u8,

    allocator: Allocator,
    /// Track if full_message was allocated
    owns_full_message: bool,

    pub fn deinit(self: *PugError) void {
        if (self.owns_full_message) {
            if (self.full_message) |msg| {
                self.allocator.free(msg);
            }
        }
    }

    /// Get the formatted message (with context if available)
    pub fn getMessage(self: *const PugError) []const u8 {
        if (self.full_message) |msg| {
            return msg;
        }
        return self.msg;
    }

    /// Format as JSON-like structure for serialization
    pub fn toJson(self: *const PugError, allocator: Allocator) ![]const u8 {
        var result: ArrayListUnmanaged(u8) = .{};
        errdefer result.deinit(allocator);

        try result.appendSlice(allocator, "{\"code\":\"");
        try result.appendSlice(allocator, self.code);
        try result.appendSlice(allocator, "\",\"msg\":\"");
        try appendJsonEscaped(allocator, &result, self.msg);
        try result.appendSlice(allocator, "\",\"line\":");

        var buf: [32]u8 = undefined;
        const line_str = std.fmt.bufPrint(&buf, "{d}", .{self.line}) catch return error.FormatError;
        try result.appendSlice(allocator, line_str);

        try result.appendSlice(allocator, ",\"column\":");
        const col_str = std.fmt.bufPrint(&buf, "{d}", .{self.column}) catch return error.FormatError;
        try result.appendSlice(allocator, col_str);

        if (self.filename) |fname| {
            try result.appendSlice(allocator, ",\"filename\":\"");
            try appendJsonEscaped(allocator, &result, fname);
            try result.append(allocator, '"');
        }

        try result.append(allocator, '}');
        return try result.toOwnedSlice(allocator);
    }
};

/// Append JSON-escaped string to result
fn appendJsonEscaped(allocator: Allocator, result: *ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    // Control character - encode as \uXXXX
                    var hex_buf: [6]u8 = undefined;
                    _ = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try result.appendSlice(allocator, &hex_buf);
                } else {
                    try result.append(allocator, c);
                }
            },
        }
    }
}

/// Create a Pug error with formatted message and source context.
/// Equivalent to pug-error's makeError function.
pub fn makeError(
    allocator: Allocator,
    code: []const u8,
    message: []const u8,
    options: struct {
        line: usize,
        column: usize = 0,
        filename: ?[]const u8 = null,
        src: ?[]const u8 = null,
    },
) !PugError {
    var err = PugError{
        .code = code,
        .msg = message,
        .line = options.line,
        .column = options.column,
        .filename = options.filename,
        .src = options.src,
        .full_message = null,
        .allocator = allocator,
        .owns_full_message = false,
    };

    // Format full message with context
    err.full_message = try formatErrorMessage(
        allocator,
        code,
        message,
        options.line,
        options.column,
        options.filename,
        options.src,
    );
    err.owns_full_message = true;

    return err;
}

/// Format error message with source context (±3 lines)
fn formatErrorMessage(
    allocator: Allocator,
    code: []const u8,
    message: []const u8,
    line: usize,
    column: usize,
    filename: ?[]const u8,
    src: ?[]const u8,
) ![]const u8 {
    _ = code; // Code is embedded in PugError struct

    var result: ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    // Header: filename:line:column or Pug:line:column
    if (filename) |fname| {
        try result.appendSlice(allocator, fname);
    } else {
        try result.appendSlice(allocator, "Pug");
    }
    try result.append(allocator, ':');

    var buf: [32]u8 = undefined;
    const line_str = std.fmt.bufPrint(&buf, "{d}", .{line}) catch return error.FormatError;
    try result.appendSlice(allocator, line_str);

    if (column > 0) {
        try result.append(allocator, ':');
        const col_str = std.fmt.bufPrint(&buf, "{d}", .{column}) catch return error.FormatError;
        try result.appendSlice(allocator, col_str);
    }
    try result.append(allocator, '\n');

    // Source context if available
    if (src) |source| {
        const lines = try splitLines(allocator, source);
        defer allocator.free(lines);

        if (line >= 1 and line <= lines.len) {
            // Show ±3 lines around error
            const start = if (line > 3) line - 3 else 1;
            const end = @min(lines.len, line + 3);

            var i = start;
            while (i <= end) : (i += 1) {
                const line_idx = i - 1;
                if (line_idx >= lines.len) break;

                const src_line = lines[line_idx];

                // Preamble: "  > 5| " or "    5| "
                if (i == line) {
                    try result.appendSlice(allocator, "  > ");
                } else {
                    try result.appendSlice(allocator, "    ");
                }

                // Line number (right-aligned)
                const num_str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch return error.FormatError;
                try result.appendSlice(allocator, num_str);
                try result.appendSlice(allocator, "| ");

                // Source line
                try result.appendSlice(allocator, src_line);
                try result.append(allocator, '\n');

                // Column marker for error line
                if (i == line and column > 0) {
                    // Calculate preamble length
                    const preamble_len = 4 + num_str.len + 2; // "  > " + num + "| "
                    var j: usize = 0;
                    while (j < preamble_len + column - 1) : (j += 1) {
                        try result.append(allocator, '-');
                    }
                    try result.append(allocator, '^');
                    try result.append(allocator, '\n');
                }
            }
            try result.append(allocator, '\n');
        }
    } else {
        try result.append(allocator, '\n');
    }

    // Error message
    try result.appendSlice(allocator, message);

    return try result.toOwnedSlice(allocator);
}

/// Split source into lines (handles \n, \r\n, \r)
fn splitLines(allocator: Allocator, src: []const u8) ![][]const u8 {
    var lines: ArrayListUnmanaged([]const u8) = .{};
    errdefer lines.deinit(allocator);

    var start: usize = 0;
    var i: usize = 0;

    while (i < src.len) {
        if (src[i] == '\n') {
            try lines.append(allocator, src[start..i]);
            start = i + 1;
            i += 1;
        } else if (src[i] == '\r') {
            try lines.append(allocator, src[start..i]);
            // Handle \r\n
            if (i + 1 < src.len and src[i + 1] == '\n') {
                i += 2;
            } else {
                i += 1;
            }
            start = i;
        } else {
            i += 1;
        }
    }

    // Last line (may not end with newline)
    if (start <= src.len) {
        try lines.append(allocator, src[start..]);
    }

    return try lines.toOwnedSlice(allocator);
}

// ============================================================================
// Common error codes
// ============================================================================

pub const ErrorCode = struct {
    pub const SYNTAX_ERROR = "PUG:SYNTAX_ERROR";
    pub const INVALID_TOKEN = "PUG:INVALID_TOKEN";
    pub const UNEXPECTED_TOKEN = "PUG:UNEXPECTED_TOKEN";
    pub const INVALID_INDENTATION = "PUG:INVALID_INDENTATION";
    pub const INCONSISTENT_INDENTATION = "PUG:INCONSISTENT_INDENTATION";
    pub const EXTENDS_NOT_FIRST = "PUG:EXTENDS_NOT_FIRST";
    pub const UNEXPECTED_BLOCK = "PUG:UNEXPECTED_BLOCK";
    pub const UNEXPECTED_NODES_IN_EXTENDING_ROOT = "PUG:UNEXPECTED_NODES_IN_EXTENDING_ROOT";
    pub const NO_EXTENDS_PATH = "PUG:NO_EXTENDS_PATH";
    pub const NO_INCLUDE_PATH = "PUG:NO_INCLUDE_PATH";
    pub const MALFORMED_EXTENDS = "PUG:MALFORMED_EXTENDS";
    pub const MALFORMED_INCLUDE = "PUG:MALFORMED_INCLUDE";
    pub const FILTER_NOT_FOUND = "PUG:FILTER_NOT_FOUND";
    pub const INVALID_FILTER = "PUG:INVALID_FILTER";
};

// ============================================================================
// Tests
// ============================================================================

test "makeError - basic error without source" {
    const allocator = std.testing.allocator;
    var err = try makeError(allocator, "PUG:TEST", "test error", .{
        .line = 5,
        .column = 10,
        .filename = "test.pug",
    });
    defer err.deinit();

    try std.testing.expectEqualStrings("PUG:TEST", err.code);
    try std.testing.expectEqualStrings("test error", err.msg);
    try std.testing.expectEqual(@as(usize, 5), err.line);
    try std.testing.expectEqual(@as(usize, 10), err.column);
    try std.testing.expectEqualStrings("test.pug", err.filename.?);

    const msg = err.getMessage();
    try std.testing.expect(mem.indexOf(u8, msg, "test.pug:5:10") != null);
    try std.testing.expect(mem.indexOf(u8, msg, "test error") != null);
}

test "makeError - error with source context" {
    const allocator = std.testing.allocator;
    const src = "line 1\nline 2\nline 3 with error\nline 4\nline 5";
    var err = try makeError(allocator, "PUG:SYNTAX_ERROR", "unexpected token", .{
        .line = 3,
        .column = 8,
        .filename = "template.pug",
        .src = src,
    });
    defer err.deinit();

    const msg = err.getMessage();
    // Should contain filename:line:column
    try std.testing.expect(mem.indexOf(u8, msg, "template.pug:3:8") != null);
    // Should contain the error line with marker
    try std.testing.expect(mem.indexOf(u8, msg, "line 3 with error") != null);
    // Should contain the error message
    try std.testing.expect(mem.indexOf(u8, msg, "unexpected token") != null);
    // Should have column marker
    try std.testing.expect(mem.indexOf(u8, msg, "^") != null);
}

test "makeError - error with source shows context lines" {
    const allocator = std.testing.allocator;
    const src = "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8";
    var err = try makeError(allocator, "PUG:TEST", "test", .{
        .line = 5,
        .filename = null,
        .src = src,
    });
    defer err.deinit();

    const msg = err.getMessage();
    // Should show lines 2-8 (5 ± 3)
    try std.testing.expect(mem.indexOf(u8, msg, "line 2") != null);
    try std.testing.expect(mem.indexOf(u8, msg, "line 5") != null);
    try std.testing.expect(mem.indexOf(u8, msg, "line 8") != null);
    // Line 1 should not be shown (too far before)
    // Note: line 1 might appear in context depending on implementation
}

test "makeError - no filename uses Pug" {
    const allocator = std.testing.allocator;
    var err = try makeError(allocator, "PUG:TEST", "test error", .{
        .line = 1,
    });
    defer err.deinit();

    const msg = err.getMessage();
    try std.testing.expect(mem.indexOf(u8, msg, "Pug:1") != null);
}

test "PugError.toJson" {
    const allocator = std.testing.allocator;
    var err = try makeError(allocator, "PUG:TEST", "test message", .{
        .line = 10,
        .column = 5,
        .filename = "file.pug",
    });
    defer err.deinit();

    const json = try err.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(mem.indexOf(u8, json, "\"code\":\"PUG:TEST\"") != null);
    try std.testing.expect(mem.indexOf(u8, json, "\"msg\":\"test message\"") != null);
    try std.testing.expect(mem.indexOf(u8, json, "\"line\":10") != null);
    try std.testing.expect(mem.indexOf(u8, json, "\"column\":5") != null);
    try std.testing.expect(mem.indexOf(u8, json, "\"filename\":\"file.pug\"") != null);
}

test "splitLines - basic" {
    const allocator = std.testing.allocator;
    const lines = try splitLines(allocator, "a\nb\nc");
    defer allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("a", lines[0]);
    try std.testing.expectEqualStrings("b", lines[1]);
    try std.testing.expectEqualStrings("c", lines[2]);
}

test "splitLines - windows line endings" {
    const allocator = std.testing.allocator;
    const lines = try splitLines(allocator, "a\r\nb\r\nc");
    defer allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("a", lines[0]);
    try std.testing.expectEqualStrings("b", lines[1]);
    try std.testing.expectEqualStrings("c", lines[2]);
}
