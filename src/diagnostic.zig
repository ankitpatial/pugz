//! Diagnostic - Rich error reporting for Pug template parsing.
//!
//! Provides structured error information including:
//! - Line and column numbers
//! - Source code snippet showing the error location
//! - Descriptive error messages
//! - Optional fix suggestions
//!
//! ## Usage
//! ```zig
//! var lexer = Lexer.init(allocator, source);
//! const tokens = lexer.tokenize() catch |err| {
//!     if (lexer.getDiagnostic()) |diag| {
//!         std.debug.print("{}\n", .{diag});
//!     }
//!     return err;
//! };
//! ```

const std = @import("std");

/// Severity level for diagnostics.
pub const Severity = enum {
    @"error",
    warning,
    hint,

    pub fn toString(self: Severity) []const u8 {
        return switch (self) {
            .@"error" => "error",
            .warning => "warning",
            .hint => "hint",
        };
    }
};

/// A diagnostic message with rich context about an error or warning.
pub const Diagnostic = struct {
    /// Severity level (error, warning, hint)
    severity: Severity = .@"error",
    /// 1-based line number where the error occurred
    line: u32,
    /// 1-based column number where the error occurred
    column: u32,
    /// Length of the problematic span (0 if unknown)
    length: u32 = 0,
    /// Human-readable error message
    message: []const u8,
    /// Source line containing the error (for snippet display)
    source_line: ?[]const u8 = null,
    /// Optional suggestion for fixing the error
    suggestion: ?[]const u8 = null,
    /// Optional error code for programmatic handling
    code: ?[]const u8 = null,

    /// Formats the diagnostic for display.
    /// Output format:
    /// ```
    /// error[E001]: Unterminated string
    ///  --> template.pug:5:12
    ///   |
    /// 5 | p Hello #{name
    ///   |            ^^^^ unterminated interpolation
    ///   |
    ///   = hint: Add closing }
    /// ```
    pub fn format(
        self: Diagnostic,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        // Header: error[CODE]: message
        try writer.print("{s}", .{self.severity.toString()});
        if (self.code) |code| {
            try writer.print("[{s}]", .{code});
        }
        try writer.print(": {s}\n", .{self.message});

        // Location: --> file:line:column
        try writer.print(" --> line {d}:{d}\n", .{ self.line, self.column });

        // Source snippet with caret pointer
        if (self.source_line) |src| {
            const line_num_width = digitCount(self.line);

            // Empty line with gutter
            try writer.writeByteNTimes(' ', line_num_width + 1);
            try writer.writeAll("|\n");

            // Source line
            try writer.print("{d} | {s}\n", .{ self.line, src });

            // Caret line pointing to error
            try writer.writeByteNTimes(' ', line_num_width + 1);
            try writer.writeAll("| ");

            // Spaces before caret (account for tabs)
            var col: u32 = 1;
            for (src) |c| {
                if (col >= self.column) break;
                if (c == '\t') {
                    try writer.writeAll("    "); // 4-space tab
                } else {
                    try writer.writeByte(' ');
                }
                col += 1;
            }

            // Carets for the error span
            const caret_count = if (self.length > 0) self.length else 1;
            try writer.writeByteNTimes('^', caret_count);
            try writer.writeByte('\n');
        }

        // Suggestion hint
        if (self.suggestion) |hint| {
            try writer.print("  = hint: {s}\n", .{hint});
        }
    }

    /// Creates a simple diagnostic without source context.
    pub fn simple(line: u32, column: u32, message: []const u8) Diagnostic {
        return .{
            .line = line,
            .column = column,
            .message = message,
        };
    }

    /// Creates a diagnostic with full context.
    pub fn withContext(
        line: u32,
        column: u32,
        message: []const u8,
        source_line: []const u8,
        suggestion: ?[]const u8,
    ) Diagnostic {
        return .{
            .line = line,
            .column = column,
            .message = message,
            .source_line = source_line,
            .suggestion = suggestion,
        };
    }
};

/// Returns the number of digits in a number (for alignment).
fn digitCount(n: u32) usize {
    if (n == 0) return 1;
    var count: usize = 0;
    var val = n;
    while (val > 0) : (val /= 10) {
        count += 1;
    }
    return count;
}

/// Extracts a line from source text given a position.
/// Returns the line content and updates line_start to the beginning of the line.
pub fn extractSourceLine(source: []const u8, position: usize) ?[]const u8 {
    if (position >= source.len) return null;

    // Find line start
    var line_start: usize = position;
    while (line_start > 0 and source[line_start - 1] != '\n') {
        line_start -= 1;
    }

    // Find line end
    var line_end: usize = position;
    while (line_end < source.len and source[line_end] != '\n') {
        line_end += 1;
    }

    return source[line_start..line_end];
}

/// Calculates line and column from a byte position in source.
pub fn positionToLineCol(source: []const u8, position: usize) struct { line: u32, column: u32 } {
    var line: u32 = 1;
    var col: u32 = 1;
    var i: usize = 0;

    while (i < position and i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }

    return .{ .line = line, .column = col };
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Diagnostic formatting" {
    const diag = Diagnostic{
        .line = 5,
        .column = 12,
        .message = "Unterminated interpolation",
        .source_line = "p Hello #{name",
        .suggestion = "Add closing }",
        .code = "E001",
    };

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try diag.format("", .{}, fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "error[E001]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Unterminated interpolation") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "line 5:12") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "p Hello #{name") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hint: Add closing }") != null);
}

test "extractSourceLine" {
    const source = "line one\nline two\nline three";

    // Position in middle of "line two"
    const line = extractSourceLine(source, 12);
    try std.testing.expect(line != null);
    try std.testing.expectEqualStrings("line two", line.?);
}

test "positionToLineCol" {
    const source = "ab\ncde\nfghij";

    // Position 0 = line 1, col 1
    var pos = positionToLineCol(source, 0);
    try std.testing.expectEqual(@as(u32, 1), pos.line);
    try std.testing.expectEqual(@as(u32, 1), pos.column);

    // Position 4 = line 2, col 2 (the 'd' in "cde")
    pos = positionToLineCol(source, 4);
    try std.testing.expectEqual(@as(u32, 2), pos.line);
    try std.testing.expectEqual(@as(u32, 2), pos.column);

    // Position 7 = line 3, col 1 (the 'f' in "fghij")
    pos = positionToLineCol(source, 7);
    try std.testing.expectEqual(@as(u32, 3), pos.line);
    try std.testing.expectEqual(@as(u32, 1), pos.column);
}
