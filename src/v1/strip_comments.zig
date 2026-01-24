// strip_comments.zig - Zig port of pug-strip-comments
//
// Filters out comment tokens from a token stream.
// Handles both buffered and unbuffered comments with pipeless text support.

const std = @import("std");
const Allocator = std.mem.Allocator;

// Import token types from lexer
const lexer = @import("lexer.zig");
pub const Token = lexer.Token;
pub const TokenType = lexer.TokenType;

// Import error types
const pug_error = @import("error.zig");
pub const PugError = pug_error.PugError;

// ============================================================================
// Strip Comments Options
// ============================================================================

pub const StripCommentsOptions = struct {
    /// Strip unbuffered comments (default: true)
    strip_unbuffered: bool = true,
    /// Strip buffered comments (default: false)
    strip_buffered: bool = false,
    /// Source filename for error messages
    filename: ?[]const u8 = null,
};

// ============================================================================
// Errors
// ============================================================================

pub const StripCommentsError = error{
    OutOfMemory,
    UnexpectedToken,
};

// ============================================================================
// Strip Comments Result
// ============================================================================

pub const StripCommentsResult = struct {
    tokens: std.ArrayListUnmanaged(Token),
    err: ?PugError = null,

    pub fn deinit(self: *StripCommentsResult, allocator: Allocator) void {
        self.tokens.deinit(allocator);
    }
};

// ============================================================================
// Strip Comments Implementation
// ============================================================================

/// Strip comments from a token stream
/// Returns filtered tokens with comments removed based on options
pub fn stripComments(
    allocator: Allocator,
    input: []const Token,
    options: StripCommentsOptions,
) StripCommentsError!StripCommentsResult {
    var result = StripCommentsResult{
        .tokens = .{},
    };

    // State tracking
    var in_comment = false;
    var in_pipeless_text = false;
    var comment_is_buffered = false;

    for (input) |tok| {
        const should_include = switch (tok.type) {
            .comment => blk: {
                if (in_comment) {
                    // Unexpected comment while already in comment
                    result.err = pug_error.makeError(
                        allocator,
                        "UNEXPECTED_TOKEN",
                        "`comment` encountered when already in a comment",
                        .{
                            .line = tok.loc.start.line,
                            .column = tok.loc.start.column,
                            .filename = options.filename,
                            .src = null,
                        },
                    ) catch null;
                    return error.UnexpectedToken;
                }
                // Check if this is a buffered comment
                comment_is_buffered = tok.isBuffered();

                // Determine if we should strip this comment
                if (comment_is_buffered) {
                    in_comment = options.strip_buffered;
                } else {
                    in_comment = options.strip_unbuffered;
                }
                break :blk !in_comment;
            },

            .start_pipeless_text => blk: {
                if (!in_comment) {
                    break :blk true;
                }
                if (in_pipeless_text) {
                    // Unexpected start_pipeless_text
                    result.err = pug_error.makeError(
                        allocator,
                        "UNEXPECTED_TOKEN",
                        "`start-pipeless-text` encountered when already in pipeless text mode",
                        .{
                            .line = tok.loc.start.line,
                            .column = tok.loc.start.column,
                            .filename = options.filename,
                            .src = null,
                        },
                    ) catch null;
                    return error.UnexpectedToken;
                }
                in_pipeless_text = true;
                break :blk false;
            },

            .end_pipeless_text => blk: {
                if (!in_comment) {
                    break :blk true;
                }
                if (!in_pipeless_text) {
                    // Unexpected end_pipeless_text
                    result.err = pug_error.makeError(
                        allocator,
                        "UNEXPECTED_TOKEN",
                        "`end-pipeless-text` encountered when not in pipeless text mode",
                        .{
                            .line = tok.loc.start.line,
                            .column = tok.loc.start.column,
                            .filename = options.filename,
                            .src = null,
                        },
                    ) catch null;
                    return error.UnexpectedToken;
                }
                in_pipeless_text = false;
                in_comment = false;
                break :blk false;
            },

            // Text tokens right after comment but before pipeless text
            .text, .text_html => !in_comment,

            // All other tokens
            else => blk: {
                if (in_pipeless_text) {
                    break :blk false;
                }
                in_comment = false;
                break :blk true;
            },
        };

        if (should_include) {
            try result.tokens.append(allocator, tok);
        }
    }

    return result;
}

/// Convenience function - strip with default options (unbuffered only)
pub fn stripUnbufferedComments(
    allocator: Allocator,
    input: []const Token,
) StripCommentsError!StripCommentsResult {
    return stripComments(allocator, input, .{});
}

/// Convenience function - strip all comments
pub fn stripAllComments(
    allocator: Allocator,
    input: []const Token,
) StripCommentsError!StripCommentsResult {
    return stripComments(allocator, input, .{
        .strip_unbuffered = true,
        .strip_buffered = true,
    });
}

// ============================================================================
// Tests
// ============================================================================

test "stripComments - no comments" {
    const allocator = std.testing.allocator;

    const tokens = [_]Token{
        .{ .type = .tag, .loc = .{ .start = .{ .line = 1, .column = 1 } }, .val = .{ .string = "div" } },
        .{ .type = .newline, .loc = .{ .start = .{ .line = 1, .column = 4 } } },
        .{ .type = .eos, .loc = .{ .start = .{ .line = 2, .column = 1 } } },
    };

    var result = try stripComments(allocator, &tokens, .{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), result.tokens.items.len);
}

test "stripComments - strip unbuffered comment" {
    const allocator = std.testing.allocator;

    const tokens = [_]Token{
        .{ .type = .tag, .loc = .{ .start = .{ .line = 1, .column = 1 } }, .val = .{ .string = "div" } },
        .{ .type = .newline, .loc = .{ .start = .{ .line = 1, .column = 4 } } },
        .{ .type = .comment, .loc = .{ .start = .{ .line = 2, .column = 1 } }, .buffer = .{ .boolean = false } },
        .{ .type = .text, .loc = .{ .start = .{ .line = 2, .column = 4 } }, .val = .{ .string = "comment text" } },
        .{ .type = .newline, .loc = .{ .start = .{ .line = 2, .column = 16 } } },
        .{ .type = .tag, .loc = .{ .start = .{ .line = 3, .column = 1 } }, .val = .{ .string = "span" } },
        .{ .type = .eos, .loc = .{ .start = .{ .line = 4, .column = 1 } } },
    };

    var result = try stripComments(allocator, &tokens, .{});
    defer result.deinit(allocator);

    // Should strip comment and its text, keep tags and structure
    try std.testing.expectEqual(@as(usize, 5), result.tokens.items.len);
    try std.testing.expectEqual(TokenType.tag, result.tokens.items[0].type);
    try std.testing.expectEqual(TokenType.newline, result.tokens.items[1].type);
    try std.testing.expectEqual(TokenType.newline, result.tokens.items[2].type);
    try std.testing.expectEqual(TokenType.tag, result.tokens.items[3].type);
    try std.testing.expectEqual(TokenType.eos, result.tokens.items[4].type);
}

test "stripComments - keep buffered comment by default" {
    const allocator = std.testing.allocator;

    const tokens = [_]Token{
        .{ .type = .tag, .loc = .{ .start = .{ .line = 1, .column = 1 } }, .val = .{ .string = "div" } },
        .{ .type = .newline, .loc = .{ .start = .{ .line = 1, .column = 4 } } },
        .{ .type = .comment, .loc = .{ .start = .{ .line = 2, .column = 1 } }, .buffer = .{ .boolean = true } },
        .{ .type = .text, .loc = .{ .start = .{ .line = 2, .column = 4 } }, .val = .{ .string = "buffered comment" } },
        .{ .type = .newline, .loc = .{ .start = .{ .line = 2, .column = 20 } } },
        .{ .type = .eos, .loc = .{ .start = .{ .line = 3, .column = 1 } } },
    };

    var result = try stripComments(allocator, &tokens, .{});
    defer result.deinit(allocator);

    // Should keep buffered comment
    try std.testing.expectEqual(@as(usize, 6), result.tokens.items.len);
}

test "stripComments - strip buffered when option set" {
    const allocator = std.testing.allocator;

    const tokens = [_]Token{
        .{ .type = .tag, .loc = .{ .start = .{ .line = 1, .column = 1 } }, .val = .{ .string = "div" } },
        .{ .type = .newline, .loc = .{ .start = .{ .line = 1, .column = 4 } } },
        .{ .type = .comment, .loc = .{ .start = .{ .line = 2, .column = 1 } }, .buffer = .{ .boolean = true } },
        .{ .type = .text, .loc = .{ .start = .{ .line = 2, .column = 4 } }, .val = .{ .string = "buffered comment" } },
        .{ .type = .newline, .loc = .{ .start = .{ .line = 2, .column = 20 } } },
        .{ .type = .eos, .loc = .{ .start = .{ .line = 3, .column = 1 } } },
    };

    var result = try stripComments(allocator, &tokens, .{ .strip_buffered = true });
    defer result.deinit(allocator);

    // Should strip buffered comment
    try std.testing.expectEqual(@as(usize, 4), result.tokens.items.len);
}

test "stripComments - pipeless text in comment" {
    const allocator = std.testing.allocator;

    const tokens = [_]Token{
        .{ .type = .comment, .loc = .{ .start = .{ .line = 1, .column = 1 } }, .buffer = .{ .boolean = false } },
        .{ .type = .start_pipeless_text, .loc = .{ .start = .{ .line = 1, .column = 1 } } },
        .{ .type = .text, .loc = .{ .start = .{ .line = 2, .column = 3 } }, .val = .{ .string = "line 1" } },
        .{ .type = .text, .loc = .{ .start = .{ .line = 3, .column = 3 } }, .val = .{ .string = "line 2" } },
        .{ .type = .end_pipeless_text, .loc = .{ .start = .{ .line = 4, .column = 1 } } },
        .{ .type = .tag, .loc = .{ .start = .{ .line = 5, .column = 1 } }, .val = .{ .string = "div" } },
        .{ .type = .eos, .loc = .{ .start = .{ .line = 6, .column = 1 } } },
    };

    var result = try stripComments(allocator, &tokens, .{});
    defer result.deinit(allocator);

    // Should strip everything in the comment including pipeless text
    try std.testing.expectEqual(@as(usize, 2), result.tokens.items.len);
    try std.testing.expectEqual(TokenType.tag, result.tokens.items[0].type);
    try std.testing.expectEqual(TokenType.eos, result.tokens.items[1].type);
}

test "stripComments - pipeless text outside comment" {
    const allocator = std.testing.allocator;

    const tokens = [_]Token{
        .{ .type = .tag, .loc = .{ .start = .{ .line = 1, .column = 1 } }, .val = .{ .string = "script" } },
        .{ .type = .dot, .loc = .{ .start = .{ .line = 1, .column = 7 } } },
        .{ .type = .start_pipeless_text, .loc = .{ .start = .{ .line = 1, .column = 8 } } },
        .{ .type = .text, .loc = .{ .start = .{ .line = 2, .column = 3 } }, .val = .{ .string = "var x = 1;" } },
        .{ .type = .end_pipeless_text, .loc = .{ .start = .{ .line = 3, .column = 1 } } },
        .{ .type = .eos, .loc = .{ .start = .{ .line = 4, .column = 1 } } },
    };

    var result = try stripComments(allocator, &tokens, .{});
    defer result.deinit(allocator);

    // Should keep all tokens - no comments
    try std.testing.expectEqual(@as(usize, 6), result.tokens.items.len);
}

test "stripComments - keep unbuffered when option disabled" {
    const allocator = std.testing.allocator;

    const tokens = [_]Token{
        .{ .type = .comment, .loc = .{ .start = .{ .line = 1, .column = 1 } }, .buffer = .{ .boolean = false } },
        .{ .type = .text, .loc = .{ .start = .{ .line = 1, .column = 4 } }, .val = .{ .string = "keep me" } },
        .{ .type = .newline, .loc = .{ .start = .{ .line = 1, .column = 11 } } },
        .{ .type = .eos, .loc = .{ .start = .{ .line = 2, .column = 1 } } },
    };

    var result = try stripComments(allocator, &tokens, .{ .strip_unbuffered = false });
    defer result.deinit(allocator);

    // Should keep unbuffered comment
    try std.testing.expectEqual(@as(usize, 4), result.tokens.items.len);
}

test "stripAllComments - strips both types" {
    const allocator = std.testing.allocator;

    const tokens = [_]Token{
        .{ .type = .comment, .loc = .{ .start = .{ .line = 1, .column = 1 } }, .buffer = .{ .boolean = false } },
        .{ .type = .text, .loc = .{ .start = .{ .line = 1, .column = 4 } }, .val = .{ .string = "unbuffered" } },
        .{ .type = .newline, .loc = .{ .start = .{ .line = 1, .column = 14 } } },
        .{ .type = .comment, .loc = .{ .start = .{ .line = 2, .column = 1 } }, .buffer = .{ .boolean = true } },
        .{ .type = .text, .loc = .{ .start = .{ .line = 2, .column = 4 } }, .val = .{ .string = "buffered" } },
        .{ .type = .newline, .loc = .{ .start = .{ .line = 2, .column = 12 } } },
        .{ .type = .tag, .loc = .{ .start = .{ .line = 3, .column = 1 } }, .val = .{ .string = "div" } },
        .{ .type = .eos, .loc = .{ .start = .{ .line = 4, .column = 1 } } },
    };

    var result = try stripAllComments(allocator, &tokens);
    defer result.deinit(allocator);

    // Should strip both comments, keep tag and structure
    try std.testing.expectEqual(@as(usize, 4), result.tokens.items.len);
    try std.testing.expectEqual(TokenType.newline, result.tokens.items[0].type);
    try std.testing.expectEqual(TokenType.newline, result.tokens.items[1].type);
    try std.testing.expectEqual(TokenType.tag, result.tokens.items[2].type);
    try std.testing.expectEqual(TokenType.eos, result.tokens.items[3].type);
}
