const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

// ============================================================================
// Token Types
// ============================================================================

pub const TokenType = enum {
    tag,
    id,
    class,
    text,
    text_html,
    comment,
    doctype,
    filter,
    extends,
    include,
    path,
    block,
    mixin_block,
    mixin,
    call,
    yield,
    code,
    blockcode,
    interpolation,
    interpolated_code,
    @"if",
    else_if,
    @"else",
    case,
    when,
    default,
    each,
    each_of,
    @"while",
    indent,
    outdent,
    newline,
    eos,
    dot,
    colon,
    slash,
    start_attributes,
    end_attributes,
    attribute,
    @"&attributes",
    start_pug_interpolation,
    end_pug_interpolation,
    start_pipeless_text,
    end_pipeless_text,
};

// ============================================================================
// Token Value - Tagged Union for type-safe token values
// ============================================================================

pub const TokenValue = union(enum) {
    none,
    string: []const u8,
    boolean: bool,

    pub fn isNone(self: TokenValue) bool {
        return self == .none;
    }

    pub fn getString(self: TokenValue) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn getBool(self: TokenValue) ?bool {
        return switch (self) {
            .boolean => |b| b,
            else => null,
        };
    }

    pub fn fromString(s: []const u8) TokenValue {
        return .{ .string = s };
    }

    pub fn fromBool(b: bool) TokenValue {
        return .{ .boolean = b };
    }

    pub fn format(
        self: TokenValue,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .none => try writer.writeAll("none"),
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .boolean => |b| try writer.print("{}", .{b}),
        }
    }
};

// ============================================================================
// Location and Token
// ============================================================================

pub const Location = struct {
    line: usize,
    column: usize,
};

pub const TokenLoc = struct {
    start: Location,
    end: ?Location = null,
    filename: ?[]const u8 = null,
};

pub const Token = struct {
    type: TokenType,
    val: TokenValue = .none,
    loc: TokenLoc,
    // Additional fields for specific token types
    buffer: TokenValue = .none, // boolean for comment/code tokens
    must_escape: TokenValue = .none, // boolean for code/attribute tokens
    mode: TokenValue = .none, // string: "prepend", "append", "replace" for block
    args: TokenValue = .none, // string for mixin/call
    key: TokenValue = .none, // string for each
    code: TokenValue = .none, // string for each/eachOf
    name: TokenValue = .none, // string for attribute

    /// Helper to get val as string
    pub fn getVal(self: Token) ?[]const u8 {
        return self.val.getString();
    }

    /// Helper to check if buffer is true
    pub fn isBuffered(self: Token) bool {
        return self.buffer.getBool() orelse false;
    }

    /// Helper to check if must_escape is true
    pub fn shouldEscape(self: Token) bool {
        return self.must_escape.getBool() orelse true;
    }

    /// Helper to get mode as string
    pub fn getMode(self: Token) ?[]const u8 {
        return self.mode.getString();
    }

    /// Helper to get args as string
    pub fn getArgs(self: Token) ?[]const u8 {
        return self.args.getString();
    }

    /// Helper to get key as string
    pub fn getKey(self: Token) ?[]const u8 {
        return self.key.getString();
    }

    /// Helper to get code as string
    pub fn getCode(self: Token) ?[]const u8 {
        return self.code.getString();
    }

    /// Helper to get attribute name as string
    pub fn getName(self: Token) ?[]const u8 {
        return self.name.getString();
    }
};

// ============================================================================
// Character Parser State (simplified) - Zig 0.15 style with ArrayListUnmanaged
// ============================================================================

const BracketType = enum { paren, brace, bracket };

const CharParserState = struct {
    nesting_stack: std.ArrayListUnmanaged(BracketType) = .{},
    in_string: bool = false,
    string_char: ?u8 = null,
    in_template: bool = false,
    escape_next: bool = false,

    pub fn deinit(self: *CharParserState, allocator: Allocator) void {
        self.nesting_stack.deinit(allocator);
    }

    pub fn isNesting(self: *const CharParserState) bool {
        return self.nesting_stack.items.len > 0;
    }

    pub fn isString(self: *const CharParserState) bool {
        return self.in_string or self.in_template;
    }

    pub fn getStringChar(self: *const CharParserState) ?u8 {
        if (self.in_string) return self.string_char;
        if (self.in_template) return '`';
        return null;
    }

    pub fn parseChar(self: *CharParserState, allocator: Allocator, char: u8) !void {
        if (self.escape_next) {
            self.escape_next = false;
            return;
        }

        if (char == '\\') {
            self.escape_next = true;
            return;
        }

        if (self.in_string) {
            if (char == self.string_char.?) {
                self.in_string = false;
                self.string_char = null;
            }
            return;
        }

        if (self.in_template) {
            if (char == '`') {
                self.in_template = false;
            }
            return;
        }

        switch (char) {
            '"', '\'' => {
                self.in_string = true;
                self.string_char = char;
            },
            '`' => {
                self.in_template = true;
            },
            '(' => try self.nesting_stack.append(allocator, .paren),
            '{' => try self.nesting_stack.append(allocator, .brace),
            '[' => try self.nesting_stack.append(allocator, .bracket),
            ')' => {
                if (self.nesting_stack.items.len > 0 and
                    self.nesting_stack.items[self.nesting_stack.items.len - 1] == .paren)
                {
                    _ = self.nesting_stack.pop();
                }
            },
            '}' => {
                if (self.nesting_stack.items.len > 0 and
                    self.nesting_stack.items[self.nesting_stack.items.len - 1] == .brace)
                {
                    _ = self.nesting_stack.pop();
                }
            },
            ']' => {
                if (self.nesting_stack.items.len > 0 and
                    self.nesting_stack.items[self.nesting_stack.items.len - 1] == .bracket)
                {
                    _ = self.nesting_stack.pop();
                }
            },
            else => {},
        }
    }
};

// ============================================================================
// Lexer Error
// ============================================================================

pub const LexerErrorCode = enum {
    ASSERT_FAILED,
    SYNTAX_ERROR,
    INCORRECT_NESTING,
    NO_END_BRACKET,
    BRACKET_MISMATCH,
    INVALID_ID,
    INVALID_CLASS_NAME,
    NO_EXTENDS_PATH,
    MALFORMED_EXTENDS,
    NO_INCLUDE_PATH,
    MALFORMED_INCLUDE,
    NO_CASE_EXPRESSION,
    NO_WHEN_EXPRESSION,
    DEFAULT_WITH_EXPRESSION,
    NO_WHILE_EXPRESSION,
    MALFORMED_EACH,
    MALFORMED_EACH_OF_LVAL,
    INVALID_INDENTATION,
    INCONSISTENT_INDENTATION,
    UNEXPECTED_TEXT,
    INVALID_KEY_CHARACTER,
    ELSE_CONDITION,
};

pub const LexerError = struct {
    code: LexerErrorCode,
    message: []const u8,
    line: usize,
    column: usize,
    filename: ?[]const u8,
};

// ============================================================================
// BracketExpression Result
// ============================================================================

const BracketExpressionResult = struct {
    src: []const u8,
    end: usize,
};

// ============================================================================
// Lexer - Zig 0.15 style with ArrayListUnmanaged
// ============================================================================

pub const Lexer = struct {
    allocator: Allocator,
    input: []const u8,
    input_allocated: []const u8, // Keep reference to allocated memory for cleanup
    original_input: []const u8,
    filename: ?[]const u8,
    interpolated: bool,
    lineno: usize,
    colno: usize,
    indent_stack: std.ArrayListUnmanaged(usize) = .{},
    indent_re_type: ?IndentType = null,
    interpolation_allowed: bool,
    tokens: std.ArrayListUnmanaged(Token) = .{},
    ended: bool,
    last_error: ?LexerError = null,

    const IndentType = enum { tabs, spaces };

    pub fn init(allocator: Allocator, str: []const u8, options: LexerOptions) !Lexer {
        // Strip UTF-8 BOM if present
        var input = str;
        if (input.len >= 3 and input[0] == 0xEF and input[1] == 0xBB and input[2] == 0xBF) {
            input = input[3..];
        }

        // Normalize line endings
        var normalized: std.ArrayListUnmanaged(u8) = .{};
        errdefer normalized.deinit(allocator);

        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == '\r') {
                if (i + 1 < input.len and input[i + 1] == '\n') {
                    try normalized.append(allocator, '\n');
                    i += 2;
                } else {
                    try normalized.append(allocator, '\n');
                    i += 1;
                }
            } else {
                try normalized.append(allocator, input[i]);
                i += 1;
            }
        }

        var indent_stack: std.ArrayListUnmanaged(usize) = .{};
        try indent_stack.append(allocator, 0);

        const input_slice = try normalized.toOwnedSlice(allocator);

        return Lexer{
            .allocator = allocator,
            .input = input_slice,
            .input_allocated = input_slice,
            .original_input = str,
            .filename = options.filename,
            .interpolated = options.interpolated,
            .lineno = options.starting_line,
            .colno = options.starting_column,
            .indent_stack = indent_stack,
            .interpolation_allowed = true,
            .tokens = .{},
            .ended = false,
        };
    }

    pub fn deinit(self: *Lexer) void {
        self.indent_stack.deinit(self.allocator);
        self.tokens.deinit(self.allocator);
        if (self.input_allocated.len > 0) {
            self.allocator.free(self.input_allocated);
        }
    }

    // ========================================================================
    // Error handling
    // ========================================================================

    fn setError(self: *Lexer, err_code: LexerErrorCode, message: []const u8) void {
        self.last_error = LexerError{
            .code = err_code,
            .message = message,
            .line = self.lineno,
            .column = self.colno,
            .filename = self.filename,
        };
    }

    /// Set error and return false - common pattern for scan functions
    fn failWith(self: *Lexer, err_code: LexerErrorCode, message: []const u8) bool {
        self.setError(err_code, message);
        return false;
    }

    /// Set error and return LexerError - for functions with error unions
    fn failWithError(self: *Lexer, err_code: LexerErrorCode, message: []const u8) error{LexerError} {
        self.setError(err_code, message);
        return error.LexerError;
    }

    // ========================================================================
    // Token creation
    // ========================================================================

    fn tok(self: *Lexer, token_type: TokenType, val: TokenValue) Token {
        return Token{
            .type = token_type,
            .val = val,
            .loc = TokenLoc{
                .start = Location{
                    .line = self.lineno,
                    .column = self.colno,
                },
                .filename = self.filename,
            },
        };
    }

    fn tokWithString(self: *Lexer, token_type: TokenType, val: ?[]const u8) Token {
        return self.tok(token_type, if (val) |v| TokenValue.fromString(v) else .none);
    }

    fn tokEnd(self: *Lexer, token: *Token) void {
        token.loc.end = Location{
            .line = self.lineno,
            .column = self.colno,
        };
    }

    /// Helper to emit a token with common boilerplate:
    /// 1. Creates token with type and string value
    /// 2. Appends to tokens list
    /// 3. Increments column by specified amount
    /// 4. Sets token end location
    /// Returns false on allocation failure.
    fn emitToken(self: *Lexer, token_type: TokenType, val: ?[]const u8, col_increment: usize) bool {
        var token = self.tokWithString(token_type, val);
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(col_increment);
        self.tokEnd(&token);
        return true;
    }

    /// Helper to emit a token with a TokenValue (for non-string values)
    fn emitTokenVal(self: *Lexer, token_type: TokenType, val: TokenValue, col_increment: usize) bool {
        var token = self.tok(token_type, val);
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(col_increment);
        self.tokEnd(&token);
        return true;
    }

    // ========================================================================
    // Position tracking
    // ========================================================================

    fn incrementLine(self: *Lexer, increment: usize) void {
        self.lineno += increment;
        if (increment > 0) {
            self.colno = 1;
        }
    }

    fn incrementColumn(self: *Lexer, increment: usize) void {
        self.colno += increment;
    }

    fn consume(self: *Lexer, len: usize) void {
        self.input = self.input[len..];
    }

    // ========================================================================
    // Scanning helpers
    // ========================================================================

    fn isWhitespace(char: u8) bool {
        return char == ' ' or char == '\n' or char == '\t';
    }

    // ========================================================================
    // Bracket expression parsing
    // ========================================================================

    fn bracketExpression(self: *Lexer, skip: usize) !BracketExpressionResult {
        if (skip >= self.input.len) {
            return self.failWithError(.NO_END_BRACKET, "Empty input for bracket expression");
        }

        const start_char = self.input[skip];
        const end_char: u8 = switch (start_char) {
            '(' => ')',
            '{' => '}',
            '[' => ']',
            else => {
                return self.failWithError(.ASSERT_FAILED, "The start character should be '(', '{' or '['");
            },
        };

        var state: CharParserState = .{};
        defer state.deinit(self.allocator);

        var i = skip + 1;

        // Use fixed-size stack buffer for bracket tracking (avoids allocations)
        // 256 levels of nesting should be more than enough for any real code
        var bracket_stack: [256]u8 = undefined;
        var bracket_depth: usize = 1;
        bracket_stack[0] = start_char;

        while (i < self.input.len) {
            const char = self.input[i];

            try state.parseChar(self.allocator, char);

            if (!state.isString()) {
                // Check for opening brackets
                if (char == '(' or char == '[' or char == '{') {
                    if (bracket_depth >= bracket_stack.len) {
                        return self.failWithError(.BRACKET_MISMATCH, "Bracket nesting too deep (max 256 levels)");
                    }
                    bracket_stack[bracket_depth] = char;
                    bracket_depth += 1;
                }
                // Check for closing brackets
                else if (char == ')' or char == ']' or char == '}') {
                    // Check for bracket type mismatch
                    if (bracket_depth > 0) {
                        const last_open = bracket_stack[bracket_depth - 1];
                        const expected_close: u8 = switch (last_open) {
                            '(' => ')',
                            '[' => ']',
                            '{' => '}',
                            else => 0,
                        };
                        if (char != expected_close) {
                            return self.failWithError(.BRACKET_MISMATCH, "Mismatched bracket - expected different closing bracket");
                        }
                        bracket_depth -= 1;
                    }

                    if (char == end_char and bracket_depth == 0) {
                        return BracketExpressionResult{
                            .src = self.input[skip + 1 .. i],
                            .end = i,
                        };
                    }
                }
            }

            i += 1;
        }

        return self.failWithError(.NO_END_BRACKET, "The end of the string reached with no closing bracket found.");
    }

    // ========================================================================
    // Indentation scanning
    // ========================================================================

    fn scanIndentation(self: *Lexer) ?struct { indent: []const u8, total_len: usize } {
        if (self.input.len == 0 or self.input[0] != '\n') {
            return null;
        }

        const indent_start: usize = 1;

        // Single-pass: detect indent type from first whitespace character
        if (indent_start >= self.input.len) {
            return .{ .indent = "", .total_len = 1 };
        }

        const first_char = self.input[indent_start];

        // Determine indent type from first character (or use existing type)
        if (first_char == '\t') {
            // Tab-based indentation
            if (self.indent_re_type == .spaces) {
                // Already using spaces, but found tab - scan tabs then trailing spaces
                var i = indent_start;
                while (i < self.input.len and self.input[i] == '\t') : (i += 1) {}
                const tab_end = i;
                // Skip trailing spaces after tabs
                while (i < self.input.len and self.input[i] == ' ') : (i += 1) {}
                return .{ .indent = self.input[indent_start..tab_end], .total_len = i };
            }
            // Using tabs or undetermined
            self.indent_re_type = .tabs;
            var i = indent_start;
            while (i < self.input.len and self.input[i] == '\t') : (i += 1) {}
            const tab_end = i;
            // Skip trailing spaces after tabs
            while (i < self.input.len and self.input[i] == ' ') : (i += 1) {}
            return .{ .indent = self.input[indent_start..tab_end], .total_len = i };
        } else if (first_char == ' ') {
            // Space-based indentation
            self.indent_re_type = .spaces;
            var i = indent_start;
            while (i < self.input.len and self.input[i] == ' ') : (i += 1) {}
            return .{ .indent = self.input[indent_start..i], .total_len = i };
        }

        // Just a newline with no indentation
        return .{ .indent = "", .total_len = 1 };
    }

    // ========================================================================
    // Token parsing methods
    // ========================================================================

    fn eos(self: *Lexer) bool {
        if (self.input.len > 0) return false;

        if (self.interpolated) {
            self.setError(.NO_END_BRACKET, "End of line was reached with no closing bracket for interpolation.");
            return false;
        }

        // Add outdent tokens for remaining indentation
        var i: usize = 0;
        while (i < self.indent_stack.items.len and self.indent_stack.items[i] > 0) : (i += 1) {
            var outdent_tok = self.tok(.outdent, .none);
            self.tokEnd(&outdent_tok);
            self.tokens.append(self.allocator, outdent_tok) catch return false;
        }

        var eos_tok = self.tok(.eos, .none);
        self.tokEnd(&eos_tok);
        self.tokens.append(self.allocator, eos_tok) catch return false;
        self.ended = true;
        return true;
    }

    fn blank(self: *Lexer) bool {
        // Match /^\n[ \t]*\n/
        if (self.input.len < 2 or self.input[0] != '\n') return false;

        var i: usize = 1;
        while (i < self.input.len and (self.input[i] == ' ' or self.input[i] == '\t')) {
            i += 1;
        }

        if (i < self.input.len and self.input[i] == '\n') {
            self.consume(i); // Don't consume the second newline
            self.incrementLine(1);
            return true;
        }

        return false;
    }

    fn comment(self: *Lexer) bool {
        // Match /^\/\/(-)?([^\n]*)/
        if (self.input.len < 2 or self.input[0] != '/' or self.input[1] != '/') {
            return false;
        }

        var i: usize = 2;
        var buffer = true;

        if (i < self.input.len and self.input[i] == '-') {
            buffer = false;
            i += 1;
        }

        const comment_start = i;
        while (i < self.input.len and self.input[i] != '\n') {
            i += 1;
        }

        const comment_text = self.input[comment_start..i];
        self.consume(i);

        var token = self.tokWithString(.comment, comment_text);
        token.buffer = TokenValue.fromBool(buffer);
        self.interpolation_allowed = buffer;
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(i);
        self.tokEnd(&token);

        _ = self.pipelessText(null);
        return true;
    }

    fn interpolation(self: *Lexer) bool {
        // Match /^#\{/
        if (self.input.len < 2 or self.input[0] != '#' or self.input[1] != '{') {
            return false;
        }

        const match = self.bracketExpression(1) catch return false;
        self.consume(match.end + 1);

        var token = self.tokWithString(.interpolation, match.src);
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(2); // '#{'

        // Count newlines in expression
        var lines: usize = 0;
        var last_line_len: usize = 0;
        for (match.src) |c| {
            if (c == '\n') {
                lines += 1;
                last_line_len = 0;
            } else {
                last_line_len += 1;
            }
        }

        self.incrementLine(lines);
        self.incrementColumn(last_line_len + 1); // + 1 for '}'
        self.tokEnd(&token);
        return true;
    }

    fn tag(self: *Lexer) bool {
        // Match /^(\w(?:[-:\w]*\w)?)/
        if (self.input.len == 0) return false;

        const first = self.input[0];
        if (!isWordChar(first)) return false;

        var end: usize = 1;
        while (end < self.input.len) {
            const c = self.input[end];
            if (isWordChar(c) or c == '-' or c == ':') {
                end += 1;
            } else {
                break;
            }
        }

        // Ensure it doesn't end with - or :
        while (end > 1 and (self.input[end - 1] == '-' or self.input[end - 1] == ':')) {
            end -= 1;
        }

        if (end == 0) return false;

        const name = self.input[0..end];
        self.consume(end);

        var token = self.tokWithString(.tag, name);
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(end);
        self.tokEnd(&token);
        return true;
    }

    fn isWordChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
    }

    fn filter(self: *Lexer, in_include: bool) bool {
        // Match /^:([\w\-]+)/
        if (self.input.len < 2 or self.input[0] != ':') return false;

        var end: usize = 1;
        while (end < self.input.len) {
            const c = self.input[end];
            if (isWordChar(c) or c == '-') {
                end += 1;
            } else {
                break;
            }
        }

        if (end == 1) return false;

        const filter_name = self.input[1..end];
        self.consume(end);

        var token = self.tokWithString(.filter, filter_name);
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(filter_name.len);
        self.tokEnd(&token);
        _ = self.attrs();

        if (!in_include) {
            self.interpolation_allowed = false;
            _ = self.pipelessText(null);
        }
        return true;
    }

    fn doctype(self: *Lexer) bool {
        // Match /^doctype *([^\n]*)/
        const prefix = "doctype";
        if (!mem.startsWith(u8, self.input, prefix)) return false;

        var i = prefix.len;

        // Skip spaces
        while (i < self.input.len and self.input[i] == ' ') {
            i += 1;
        }

        // Find end of line
        var end = i;
        while (end < self.input.len and self.input[end] != '\n') {
            end += 1;
        }

        const doctype_val = self.input[i..end];
        self.consume(end);

        var token = self.tokWithString(.doctype, if (doctype_val.len > 0) doctype_val else null);
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(end);
        self.tokEnd(&token);
        return true;
    }

    fn id(self: *Lexer) bool {
        // Match /^#([\w-]+)/
        if (self.input.len < 2 or self.input[0] != '#') return false;

        // Check it's not #{
        if (self.input[1] == '{') return false;

        var end: usize = 1;
        while (end < self.input.len) {
            const c = self.input[end];
            if (isWordChar(c) or c == '-') {
                end += 1;
            } else {
                break;
            }
        }

        if (end == 1) {
            self.setError(.INVALID_ID, "Invalid ID");
            return false;
        }

        const id_val = self.input[1..end];
        self.consume(end);

        var token = self.tokWithString(.id, id_val);
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(id_val.len);
        self.tokEnd(&token);
        return true;
    }

    fn className(self: *Lexer) bool {
        // Match /^\.([_a-z0-9\-]*[_a-z][_a-z0-9\-]*)/i
        if (self.input.len < 2 or self.input[0] != '.') return false;

        var end: usize = 1;
        var has_letter = false;

        while (end < self.input.len) {
            const c = self.input[end];
            if (isWordChar(c) or c == '-') {
                if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_') {
                    has_letter = true;
                }
                end += 1;
            } else {
                break;
            }
        }

        if (end == 1 or !has_letter) {
            if (end > 1) {
                self.setError(.INVALID_CLASS_NAME, "Class names must contain at least one letter or underscore.");
            }
            return false;
        }

        const class_name = self.input[1..end];
        self.consume(end);

        var token = self.tokWithString(.class, class_name);
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(class_name.len);
        self.tokEnd(&token);
        return true;
    }

    fn endInterpolation(self: *Lexer) bool {
        if (self.interpolated and self.input.len > 0 and self.input[0] == ']') {
            self.consume(1);
            self.ended = true;
            return true;
        }
        return false;
    }

    fn text(self: *Lexer) bool {
        // Match /^(?:\| ?| )([^\n]+)/ or /^( )/ or /^\|( ?)/
        // This handles:
        // 1. "| text" - piped text
        // 2. " text" - inline text after tag (space followed by text)
        // 3. "|" or "| " - empty pipe
        if (self.input.len == 0) return false;

        // Case 1: Pipe syntax "| text" or "|"
        if (self.input[0] == '|') {
            var i: usize = 1;
            // Skip optional space after |
            if (i < self.input.len and self.input[i] == ' ') {
                i += 1;
            }

            // Find end of line
            var end = i;
            while (end < self.input.len and self.input[end] != '\n') {
                end += 1;
            }

            const text_val = self.input[i..end];
            self.consume(end);

            self.addText(.text, text_val, "", 0);
            return true;
        }

        // Case 2: Inline text after tag " text" (space followed by content)
        if (self.input[0] == ' ') {
            // Find end of potential text (until newline)
            var end: usize = 1;
            while (end < self.input.len and self.input[end] != '\n') {
                end += 1;
            }

            // Check what's in the rest of the line after the space
            const rest = self.input[1..end];

            // If it's only whitespace, don't treat as text (let indent handle newlines)
            var all_whitespace = true;
            for (rest) |c| {
                if (c != ' ' and c != '\t') {
                    all_whitespace = false;
                    break;
                }
            }

            if (all_whitespace) {
                // Only whitespace until newline - consume it but don't create text token
                self.consume(end);
                self.incrementColumn(end);
                return true;
            }

            // Check if it's just " /" pattern (self-closing tag with space)
            var trimmed_start: usize = 0;
            while (trimmed_start < rest.len and rest[trimmed_start] == ' ') {
                trimmed_start += 1;
            }
            if (trimmed_start < rest.len and rest[trimmed_start] == '/' and
                (trimmed_start + 1 >= rest.len or rest[trimmed_start + 1] == ' ' or rest[trimmed_start + 1] == '\n'))
            {
                // This is "tag /" pattern - consume spaces, let slash handler deal with /
                self.consume(1 + trimmed_start);
                self.incrementColumn(1 + trimmed_start);
                return true;
            }

            const text_val = self.input[1..end];
            self.consume(end);

            self.addText(.text, text_val, "", 0);
            return true;
        }

        return false;
    }

    fn textHtml(self: *Lexer) bool {
        // Match /^(<[^\n]*)/
        if (self.input.len == 0 or self.input[0] != '<') return false;

        var end: usize = 1;
        while (end < self.input.len and self.input[end] != '\n') {
            end += 1;
        }

        const html_val = self.input[0..end];
        self.consume(end);

        self.addText(.text_html, html_val, "", 0);
        return true;
    }

    fn dot(self: *Lexer) bool {
        // Match /^\./
        if (self.input.len == 0 or self.input[0] != '.') return false;

        // Check if it's followed by end of line or colon
        if (self.input.len == 1 or self.input[1] == '\n' or self.input[1] == ':') {
            self.consume(1);
            var token = self.tok(.dot, .none);
            self.tokens.append(self.allocator, token) catch return false;
            self.incrementColumn(1);
            self.tokEnd(&token);
            _ = self.pipelessText(null);
            return true;
        }

        return false;
    }

    fn extendsToken(self: *Lexer) bool {
        // Match /^extends?(?= |$|\n)/
        if (mem.startsWith(u8, self.input, "extends")) {
            const after = if (self.input.len > 7) self.input[7] else 0;
            if (after == 0 or after == ' ' or after == '\n') {
                self.consume(7);
                var token = self.tok(.extends, .none);
                self.tokens.append(self.allocator, token) catch return false;
                self.incrementColumn(7);
                self.tokEnd(&token);

                if (!self.path()) {
                    self.setError(.NO_EXTENDS_PATH, "missing path for extends");
                    return true;
                }
                return true;
            }
            // "extends" followed by something else (like "(") - malformed
            if (after != 0) {
                self.setError(.MALFORMED_EXTENDS, "malformed extends");
                return true;
            }
        } else if (mem.startsWith(u8, self.input, "extend")) {
            const after = if (self.input.len > 6) self.input[6] else 0;
            if (after == 0 or after == ' ' or after == '\n') {
                self.consume(6);
                var token = self.tok(.extends, .none);
                self.tokens.append(self.allocator, token) catch return false;
                self.incrementColumn(6);
                self.tokEnd(&token);

                if (!self.path()) {
                    self.setError(.NO_EXTENDS_PATH, "missing path for extends");
                    return true;
                }
                return true;
            }
            // "extend" followed by something else (like "(") - malformed
            if (after != 0 and after != 's') {
                self.setError(.MALFORMED_EXTENDS, "malformed extends");
                return true;
            }
        }
        return false;
    }

    fn prepend(self: *Lexer) bool {
        return self.blockHelper("prepend", .prepend);
    }

    fn append(self: *Lexer) bool {
        return self.blockHelper("append", .append);
    }

    fn blockToken(self: *Lexer) bool {
        return self.blockHelper("block", .replace);
    }

    const BlockMode = enum { prepend, append, replace };

    fn blockHelper(self: *Lexer, keyword: []const u8, mode: BlockMode) bool {
        const full_prefix = switch (mode) {
            .prepend => "prepend ",
            .append => "append ",
            .replace => "block ",
        };
        const block_prefix = switch (mode) {
            .prepend => "block prepend ",
            .append => "block append ",
            .replace => "block ",
        };

        var name_start: usize = 0;

        if (mem.startsWith(u8, self.input, block_prefix)) {
            name_start = block_prefix.len;
        } else if (mem.startsWith(u8, self.input, full_prefix)) {
            name_start = full_prefix.len;
        } else {
            _ = keyword;
            return false;
        }

        // Find end of line
        var end = name_start;
        while (end < self.input.len and self.input[end] != '\n') {
            end += 1;
        }

        // Extract name (trim and handle comments)
        var name_end = end;
        // Check for comment
        var i = name_start;
        while (i < end) {
            if (i + 1 < end and self.input[i] == '/' and self.input[i + 1] == '/') {
                name_end = i;
                break;
            }
            i += 1;
        }

        // Trim whitespace
        while (name_end > name_start and isWhitespace(self.input[name_end - 1])) {
            name_end -= 1;
        }

        if (name_end <= name_start) return false;

        const name = self.input[name_start..name_end];
        self.consume(end);

        var token = self.tokWithString(.block, name);
        token.mode = TokenValue.fromString(switch (mode) {
            .prepend => "prepend",
            .append => "append",
            .replace => "replace",
        });
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(end);
        self.tokEnd(&token);
        return true;
    }

    fn mixinBlock(self: *Lexer) bool {
        if (!mem.startsWith(u8, self.input, "block")) return false;

        // Check if followed by end of line, colon, or only whitespace until newline
        var consume_len: usize = 5;
        var is_mixin_block = false;

        if (self.input.len == 5 or self.input[5] == '\n' or self.input[5] == ':') {
            is_mixin_block = true;
        } else if (self.input[5] == ' ' or self.input[5] == '\t') {
            // Check if only whitespace until newline
            var i: usize = 5;
            while (i < self.input.len and (self.input[i] == ' ' or self.input[i] == '\t')) {
                i += 1;
            }
            if (i >= self.input.len or self.input[i] == '\n') {
                is_mixin_block = true;
                consume_len = i;
            }
        }

        if (is_mixin_block) {
            self.consume(consume_len);
            var token = self.tok(.mixin_block, .none);
            self.tokens.append(self.allocator, token) catch return false;
            self.incrementColumn(consume_len);
            self.tokEnd(&token);
            return true;
        }

        return false;
    }

    fn yieldToken(self: *Lexer) bool {
        if (!mem.startsWith(u8, self.input, "yield")) return false;

        if (self.input.len == 5 or self.input[5] == '\n' or self.input[5] == ':') {
            self.consume(5);
            var token = self.tok(.yield, .none);
            self.tokens.append(self.allocator, token) catch return false;
            self.incrementColumn(5);
            self.tokEnd(&token);
            return true;
        }

        return false;
    }

    fn includeToken(self: *Lexer) bool {
        if (!mem.startsWith(u8, self.input, "include")) return false;

        const after = if (self.input.len > 7) self.input[7] else 0;
        if (after != 0 and after != ' ' and after != ':' and after != '\n') {
            // "include" followed by something else (like "(") - malformed
            self.setError(.MALFORMED_INCLUDE, "malformed include");
            return true;
        }

        self.consume(7);
        var token = self.tok(.include, .none);
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(7);
        self.tokEnd(&token);

        // Parse filters
        while (self.filter(true)) {}

        if (!self.path()) {
            self.setError(.NO_INCLUDE_PATH, "missing path for include");
            return true;
        }
        return true;
    }

    fn path(self: *Lexer) bool {
        // Match /^ ([^\n]+)/
        if (self.input.len == 0 or self.input[0] != ' ') return false;

        var i: usize = 1;
        // Skip leading spaces
        while (i < self.input.len and self.input[i] == ' ') {
            i += 1;
        }

        var end = i;
        while (end < self.input.len and self.input[end] != '\n') {
            end += 1;
        }

        // Trim trailing spaces
        var path_end = end;
        while (path_end > i and self.input[path_end - 1] == ' ') {
            path_end -= 1;
        }

        if (path_end <= i) return false;

        const path_val = self.input[i..path_end];
        self.consume(end);

        var token = self.tokWithString(.path, path_val);
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(end);
        self.tokEnd(&token);
        return true;
    }

    fn caseToken(self: *Lexer) bool {
        // Match /^case +([^\n]+)/
        if (!mem.startsWith(u8, self.input, "case")) return false;

        // Check if followed by word boundary
        if (self.input.len > 4 and self.input[4] != ' ' and self.input[4] != '\n') {
            return false;
        }

        // Check for "case" without expression
        if (self.input.len == 4 or self.input[4] == '\n') {
            self.consume(4);
            self.incrementColumn(4);
            self.setError(.NO_CASE_EXPRESSION, "missing expression for case");
            return false;
        }

        var i: usize = 5;
        while (i < self.input.len and self.input[i] == ' ') {
            i += 1;
        }

        // If only spaces after "case", that's also an error
        if (i >= self.input.len or self.input[i] == '\n') {
            self.consume(i);
            self.incrementColumn(i);
            self.setError(.NO_CASE_EXPRESSION, "missing expression for case");
            return false;
        }

        var end = i;
        while (end < self.input.len and self.input[end] != '\n') {
            end += 1;
        }

        if (end <= i) {
            self.setError(.NO_CASE_EXPRESSION, "missing expression for case");
            return false;
        }

        const expr = self.input[i..end];

        // Validate brackets are balanced in the expression
        if (!self.validateExpressionBrackets(expr)) {
            self.consume(end);
            self.incrementColumn(end);
            return true; // Error already set
        }

        self.consume(end);

        var token = self.tokWithString(.case, expr);
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(end);
        self.tokEnd(&token);
        return true;
    }

    /// Validates that brackets in an expression are balanced
    fn validateExpressionBrackets(self: *Lexer, expr: []const u8) bool {
        var bracket_stack = std.ArrayListUnmanaged(u8){};
        defer bracket_stack.deinit(self.allocator);

        var in_string: u8 = 0;
        var i: usize = 0;

        while (i < expr.len) {
            const c = expr[i];
            if (in_string != 0) {
                if (c == in_string and (i == 0 or expr[i - 1] != '\\')) {
                    in_string = 0;
                }
            } else {
                if (c == '"' or c == '\'' or c == '`') {
                    in_string = c;
                } else if (c == '(' or c == '[' or c == '{') {
                    bracket_stack.append(self.allocator, c) catch return false;
                } else if (c == ')' or c == ']' or c == '}') {
                    if (bracket_stack.items.len == 0) {
                        self.setError(.BRACKET_MISMATCH, "Unexpected closing bracket in expression");
                        return false;
                    }
                    const last_open = bracket_stack.items[bracket_stack.items.len - 1];
                    const expected_close: u8 = switch (last_open) {
                        '(' => ')',
                        '[' => ']',
                        '{' => '}',
                        else => 0,
                    };
                    if (c != expected_close) {
                        self.setError(.BRACKET_MISMATCH, "Mismatched bracket in expression");
                        return false;
                    }
                    _ = bracket_stack.pop();
                }
            }
            i += 1;
        }

        if (bracket_stack.items.len > 0) {
            self.setError(.NO_END_BRACKET, "Unclosed bracket in expression");
            return false;
        }

        return true;
    }

    fn when(self: *Lexer) bool {
        // Match /^when +([^:\n]+)/ but handle colons inside strings
        if (!mem.startsWith(u8, self.input, "when")) return false;

        // Check if followed by word boundary (space, newline, or end)
        if (self.input.len > 4 and self.input[4] != ' ' and self.input[4] != '\n') {
            return false;
        }

        // Check for "when" without expression (just "when" or "when\n")
        if (self.input.len == 4 or self.input[4] == '\n') {
            self.consume(4);
            self.incrementColumn(4);
            self.setError(.NO_WHEN_EXPRESSION, "missing expression for when");
            return false;
        }

        var i: usize = 5;
        while (i < self.input.len and self.input[i] == ' ') {
            i += 1;
        }

        // If only spaces after "when", that's also an error
        if (i >= self.input.len or self.input[i] == '\n') {
            self.consume(i);
            self.incrementColumn(i);
            self.setError(.NO_WHEN_EXPRESSION, "missing expression for when");
            return false;
        }

        // Parse until colon or newline, but handle strings properly
        var end = i;
        var in_string = false;
        var string_char: u8 = 0;
        var escape_next = false;
        var brace_depth: usize = 0;

        while (end < self.input.len and self.input[end] != '\n') {
            const c = self.input[end];

            if (escape_next) {
                escape_next = false;
                end += 1;
                continue;
            }

            if (c == '\\') {
                escape_next = true;
                end += 1;
                continue;
            }

            if (in_string) {
                if (c == string_char) {
                    in_string = false;
                }
                end += 1;
                continue;
            }

            // Not in string
            if (c == '\'' or c == '"' or c == '`') {
                in_string = true;
                string_char = c;
                end += 1;
                continue;
            }

            // Track braces for object literals like {tim: 'g'}
            if (c == '{') {
                brace_depth += 1;
                end += 1;
                continue;
            }
            if (c == '}') {
                if (brace_depth > 0) brace_depth -= 1;
                end += 1;
                continue;
            }

            // Colon outside string and outside braces ends the expression
            if (c == ':' and brace_depth == 0) {
                break;
            }

            end += 1;
        }

        if (end <= i) {
            self.setError(.NO_WHEN_EXPRESSION, "missing expression for when");
            return false;
        }

        const expr = self.input[i..end];
        self.consume(end);

        var token = self.tokWithString(.when, expr);
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(end);
        self.tokEnd(&token);
        return true;
    }

    fn defaultToken(self: *Lexer) bool {
        if (!mem.startsWith(u8, self.input, "default")) return false;

        if (self.input.len == 7 or self.input[7] == '\n' or self.input[7] == ':') {
            self.consume(7);
            var token = self.tok(.default, .none);
            self.tokens.append(self.allocator, token) catch return false;
            self.incrementColumn(7);
            self.tokEnd(&token);
            return true;
        }

        // Check if "default" is followed by something other than whitespace/newline/colon
        // "default foo" should error
        if (self.input[7] == ' ') {
            // Skip spaces and check if there's content after
            var i: usize = 8;
            while (i < self.input.len and self.input[i] == ' ') {
                i += 1;
            }
            if (i < self.input.len and self.input[i] != '\n' and self.input[i] != ':') {
                self.consume(i);
                self.incrementColumn(i);
                self.setError(.DEFAULT_WITH_EXPRESSION, "`default` cannot have an expression");
                return true; // Return true to stop advance chain, error is set
            }
            // Just spaces then newline/colon or end of input is fine
            self.consume(7);
            var token = self.tok(.default, .none);
            self.tokens.append(self.allocator, token) catch return false;
            self.incrementColumn(7);
            self.tokEnd(&token);
            return true;
        }

        return false;
    }

    fn call(self: *Lexer) bool {
        // Match /^\+(\s*)(([-\w]+)|(#\{))/
        if (self.input.len < 2 or self.input[0] != '+') return false;

        var i: usize = 1;
        // Skip whitespace
        while (i < self.input.len and (self.input[i] == ' ' or self.input[i] == '\t')) {
            i += 1;
        }

        // Check for interpolated call #{
        if (i + 1 < self.input.len and self.input[i] == '#' and self.input[i + 1] == '{') {
            const match = self.bracketExpression(i + 1) catch return false;
            const increment = match.end + 1;
            self.consume(increment);

            var token = self.tok(.call, .none);
            // Store the interpolated expression - use the original slice from input
            // Format: #{expression} - we store just the expression part, prefixed with #{
            // The value points to input[i..match.end+1] which includes #{ and }
            token.val = TokenValue.fromString(self.original_input[self.original_input.len - self.input.len - increment + i .. self.original_input.len - self.input.len - increment + match.end + 1]);
            self.incrementColumn(increment);
            token.args = .none;

            // Check for args
            if (self.input.len > 0 and self.input[0] == '(') {
                if (self.bracketExpression(0)) |args_match| {
                    self.incrementColumn(1);
                    self.consume(args_match.end + 1);
                    token.args = TokenValue.fromString(args_match.src);
                } else |_| {}
            }

            self.tokens.append(self.allocator, token) catch return false;
            self.tokEnd(&token);
            return true;
        }

        // Simple call
        var end = i;
        while (end < self.input.len) {
            const c = self.input[end];
            if (isWordChar(c) or c == '-') {
                end += 1;
            } else {
                break;
            }
        }

        if (end == i) return false;

        const name = self.input[i..end];
        self.consume(end);

        var token = self.tokWithString(.call, name);
        self.incrementColumn(end);
        token.args = .none;

        // Check for args (not attributes)
        if (self.input.len > 0) {
            var j: usize = 0;
            while (j < self.input.len and self.input[j] == ' ') {
                j += 1;
            }
            if (j < self.input.len and self.input[j] == '(') {
                if (self.bracketExpression(j)) |args_match| {
                    // Check if it looks like args, not attributes
                    var is_args = true;
                    var k: usize = 0;
                    while (k < args_match.src.len and (args_match.src[k] == ' ' or args_match.src[k] == '\t')) {
                        k += 1;
                    }
                    // Check for key= pattern (attributes)
                    var key_end = k;
                    while (key_end < args_match.src.len and (isWordChar(args_match.src[key_end]) or args_match.src[key_end] == '-')) {
                        key_end += 1;
                    }
                    if (key_end < args_match.src.len) {
                        var eq_pos = key_end;
                        while (eq_pos < args_match.src.len and args_match.src[eq_pos] == ' ') {
                            eq_pos += 1;
                        }
                        if (eq_pos < args_match.src.len and args_match.src[eq_pos] == '=') {
                            is_args = false;
                        }
                    }

                    if (is_args) {
                        self.incrementColumn(j + 1);
                        self.consume(j + args_match.end + 1);
                        token.args = TokenValue.fromString(args_match.src);
                    }
                } else |_| {}
            }
        }

        self.tokens.append(self.allocator, token) catch return false;
        self.tokEnd(&token);
        return true;
    }

    fn mixin(self: *Lexer) bool {
        // Match /^mixin +([-\w]+)(?: *\((.*)\))? */
        if (!mem.startsWith(u8, self.input, "mixin ")) return false;

        var i: usize = 6;
        while (i < self.input.len and self.input[i] == ' ') {
            i += 1;
        }

        // Get mixin name
        var name_end = i;
        while (name_end < self.input.len) {
            const c = self.input[name_end];
            if (isWordChar(c) or c == '-') {
                name_end += 1;
            } else {
                break;
            }
        }

        if (name_end == i) return false;

        const name = self.input[i..name_end];
        var end = name_end;

        // Skip spaces
        while (end < self.input.len and self.input[end] == ' ') {
            end += 1;
        }

        var args: TokenValue = .none;

        // Check for args
        if (end < self.input.len and self.input[end] == '(') {
            const bracket_result = self.bracketExpression(end) catch return false;
            args = TokenValue.fromString(bracket_result.src);
            end = bracket_result.end + 1;
        }

        self.consume(end);

        var token = self.tokWithString(.mixin, name);
        token.args = args;
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(end);
        self.tokEnd(&token);
        return true;
    }

    fn conditional(self: *Lexer) bool {
        // Match /^(if|unless|else if|else)\b([^\n]*)/
        var keyword: []const u8 = undefined;
        var token_type: TokenType = undefined;

        if (mem.startsWith(u8, self.input, "else if")) {
            keyword = "else if";
            token_type = .else_if;
        } else if (mem.startsWith(u8, self.input, "if")) {
            keyword = "if";
            token_type = .@"if";
        } else if (mem.startsWith(u8, self.input, "unless")) {
            keyword = "unless";
            token_type = .@"if"; // unless becomes if with negated condition
        } else if (mem.startsWith(u8, self.input, "else")) {
            keyword = "else";
            token_type = .@"else";
        } else {
            return false;
        }

        // Check word boundary
        if (self.input.len > keyword.len) {
            const next = self.input[keyword.len];
            if (isWordChar(next)) return false;
        }

        const i = keyword.len;

        // Get expression
        var end = i;
        while (end < self.input.len and self.input[end] != '\n') {
            end += 1;
        }

        var js = self.input[i..end];
        // Trim
        while (js.len > 0 and (js[0] == ' ' or js[0] == '\t')) {
            js = js[1..];
        }
        while (js.len > 0 and (js[js.len - 1] == ' ' or js[js.len - 1] == '\t')) {
            js = js[0 .. js.len - 1];
        }

        self.consume(end);

        var token = self.tokWithString(token_type, if (js.len > 0) js else null);

        // Handle else with condition
        if (token_type == .@"else" and js.len > 0) {
            self.setError(.ELSE_CONDITION, "`else` cannot have a condition, perhaps you meant `else if`");
            return true; // Return true to stop advance chain, error is set
        }

        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(end);
        self.tokEnd(&token);
        return true;
    }

    fn whileToken(self: *Lexer) bool {
        // Match /^while +([^\n]+)/
        if (!mem.startsWith(u8, self.input, "while")) return false;

        // Check if followed by word boundary
        if (self.input.len > 5 and self.input[5] != ' ' and self.input[5] != '\n') {
            return false;
        }

        // Check for "while" without expression
        if (self.input.len == 5 or self.input[5] == '\n') {
            self.consume(5);
            self.incrementColumn(5);
            self.setError(.NO_WHILE_EXPRESSION, "missing expression for while");
            return false;
        }

        var i: usize = 6;
        while (i < self.input.len and self.input[i] == ' ') {
            i += 1;
        }

        // If only spaces after "while", that's also an error
        if (i >= self.input.len or self.input[i] == '\n') {
            self.consume(i);
            self.incrementColumn(i);
            self.setError(.NO_WHILE_EXPRESSION, "missing expression for while");
            return false;
        }

        var end = i;
        while (end < self.input.len and self.input[end] != '\n') {
            end += 1;
        }

        if (end <= i) {
            self.setError(.NO_WHILE_EXPRESSION, "missing expression for while");
            return false;
        }

        const expr = self.input[i..end];
        self.consume(end);

        var token = self.tokWithString(.@"while", expr);
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(end);
        self.tokEnd(&token);
        return true;
    }

    fn each(self: *Lexer) bool {
        const is_each = mem.startsWith(u8, self.input, "each ");
        const is_for = mem.startsWith(u8, self.input, "for ");

        if (!is_each and !is_for) return false;

        const prefix_len: usize = if (is_each) 5 else 4;
        var i = prefix_len;

        // Skip spaces
        while (i < self.input.len and self.input[i] == ' ') {
            i += 1;
        }

        // Get first identifier
        if (i >= self.input.len or !isIdentStart(self.input[i])) {
            return self.eachOf();
        }

        var ident_end = i + 1;
        while (ident_end < self.input.len and isIdentChar(self.input[ident_end])) {
            ident_end += 1;
        }

        const val_name = self.input[i..ident_end];
        i = ident_end;

        // Skip spaces
        while (i < self.input.len and self.input[i] == ' ') {
            i += 1;
        }

        var key_name: TokenValue = .none;

        // Check for , key
        if (i < self.input.len and self.input[i] == ',') {
            i += 1;
            while (i < self.input.len and self.input[i] == ' ') {
                i += 1;
            }

            if (i < self.input.len and isIdentStart(self.input[i])) {
                var key_end = i + 1;
                while (key_end < self.input.len and isIdentChar(self.input[key_end])) {
                    key_end += 1;
                }
                key_name = TokenValue.fromString(self.input[i..key_end]);
                i = key_end;
            }
        }

        // Skip spaces
        while (i < self.input.len and self.input[i] == ' ') {
            i += 1;
        }

        // Check for 'in' or 'of'
        if (mem.startsWith(u8, self.input[i..], "of ")) {
            return self.eachOf();
        }

        if (!mem.startsWith(u8, self.input[i..], "in ")) {
            self.setError(.MALFORMED_EACH, "Malformed each statement");
            return false;
        }

        i += 3; // skip "in "

        while (i < self.input.len and self.input[i] == ' ') {
            i += 1;
        }

        // Get expression
        var end = i;
        while (end < self.input.len and self.input[end] != '\n') {
            end += 1;
        }

        if (end <= i) {
            self.setError(.MALFORMED_EACH, "missing expression for each");
            return false;
        }

        const expr = self.input[i..end];
        self.consume(end);

        var token = self.tokWithString(.each, val_name);
        token.key = key_name;
        token.code = TokenValue.fromString(expr);
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(end);
        self.tokEnd(&token);
        return true;
    }

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
    }

    fn isIdentChar(c: u8) bool {
        return isIdentStart(c) or (c >= '0' and c <= '9');
    }

    fn eachOf(self: *Lexer) bool {
        const is_each = mem.startsWith(u8, self.input, "each ");
        const is_for = mem.startsWith(u8, self.input, "for ");

        if (!is_each and !is_for) return false;

        const prefix_len: usize = if (is_each) 5 else 4;
        var i = prefix_len;

        // Find " of "
        var of_pos: ?usize = null;
        var j = i;
        while (j + 3 < self.input.len) {
            if (self.input[j] == ' ' and self.input[j + 1] == 'o' and self.input[j + 2] == 'f' and self.input[j + 3] == ' ') {
                of_pos = j;
                break;
            }
            if (self.input[j] == '\n') break;
            j += 1;
        }

        if (of_pos == null) return false;

        const value = self.input[i..of_pos.?];

        i = of_pos.? + 4; // skip " of "
        while (i < self.input.len and self.input[i] == ' ') {
            i += 1;
        }

        var end = i;
        while (end < self.input.len and self.input[end] != '\n') {
            end += 1;
        }

        if (end <= i) return false;

        const expr = self.input[i..end];
        self.consume(end);

        var token = self.tokWithString(.each_of, value);
        token.code = TokenValue.fromString(expr);
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(end);
        self.tokEnd(&token);
        return true;
    }

    fn code(self: *Lexer) bool {
        if (self.input.len == 0) return false;

        var flags_end: usize = 0;
        var must_escape = false;
        var buffer = false;

        if (self.input[0] == '-') {
            flags_end = 1;
            buffer = false;
        } else if (self.input[0] == '=') {
            flags_end = 1;
            must_escape = true;
            buffer = true;
        } else if (self.input.len >= 2 and self.input[0] == '!' and self.input[1] == '=') {
            flags_end = 2;
            must_escape = false;
            buffer = true;
        } else {
            return false;
        }

        var i = flags_end;
        // Skip spaces/tabs
        while (i < self.input.len and (self.input[i] == ' ' or self.input[i] == '\t')) {
            i += 1;
        }

        // Check for old-style "- each" or "- for" prefixed syntax
        if (flags_end == 1 and self.input[0] == '-') {
            const rest = self.input[i..];
            // Match: each/for VAR(, VAR)? in EXPR
            if (mem.startsWith(u8, rest, "each ") or mem.startsWith(u8, rest, "for ")) {
                // Check if it looks like the old prefixed each/for syntax
                var j: usize = 0;
                if (mem.startsWith(u8, rest, "each ")) {
                    j = 5;
                } else {
                    j = 4;
                }
                // Skip whitespace
                while (j < rest.len and (rest[j] == ' ' or rest[j] == '\t')) {
                    j += 1;
                }
                // Check for identifier
                if (j < rest.len and (std.ascii.isAlphabetic(rest[j]) or rest[j] == '_' or rest[j] == '$')) {
                    // This looks like "- each var in expr" which is old syntax
                    self.setError(.MALFORMED_EACH, "Pug each and for should no longer be prefixed with a dash (\"-\"). They are pug keywords and not part of JavaScript.");
                    return true;
                }
            }
        }

        var end = i;
        while (end < self.input.len and self.input[end] != '\n') {
            end += 1;
        }

        const code_val = self.input[i..end];
        self.consume(end);

        var token = self.tokWithString(.code, code_val);
        token.must_escape = TokenValue.fromBool(must_escape);
        token.buffer = TokenValue.fromBool(buffer);
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(end);
        self.tokEnd(&token);
        return true;
    }

    fn blockCode(self: *Lexer) bool {
        if (self.input.len == 0 or self.input[0] != '-') return false;

        // Must be followed by end of line
        if (self.input.len > 1 and self.input[1] != '\n' and self.input[1] != ':') {
            return false;
        }

        self.consume(1);
        var token = self.tok(.blockcode, .none);
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(1);
        self.tokEnd(&token);
        self.interpolation_allowed = false;
        _ = self.pipelessText(null);
        return true;
    }

    fn attrs(self: *Lexer) bool {
        if (self.input.len == 0 or self.input[0] != '(') return false;

        var token = self.tok(.start_attributes, .none);
        const bracket_result = self.bracketExpression(0) catch return false;
        const str = self.input[1..bracket_result.end];

        self.incrementColumn(1);
        self.tokens.append(self.allocator, token) catch return false;
        self.tokEnd(&token);
        self.consume(bracket_result.end + 1);

        // Parse attributes from str
        self.parseAttributes(str);

        // Check if parseAttributes set an error
        if (self.last_error != null) {
            return true; // Error is set, return true to stop further parsing
        }

        var end_token = self.tok(.end_attributes, .none);
        self.incrementColumn(1);
        self.tokens.append(self.allocator, end_token) catch return false;
        self.tokEnd(&end_token);
        return true;
    }

    fn parseAttributes(self: *Lexer, str: []const u8) void {
        var i: usize = 0;

        while (i < str.len) {
            // Skip whitespace
            while (i < str.len and isWhitespace(str[i])) {
                if (str[i] == '\n') {
                    self.incrementLine(1);
                } else {
                    self.incrementColumn(1);
                }
                i += 1;
            }

            if (i >= str.len) break;

            var attr_token = self.tok(.attribute, .none);

            // Check for quoted key
            var key: []const u8 = undefined;

            if (str[i] == '"' or str[i] == '\'') {
                const quote = str[i];
                self.incrementColumn(1);
                i += 1;
                const key_start = i;
                while (i < str.len and str[i] != quote) {
                    if (str[i] == '\n') {
                        self.incrementLine(1);
                    } else {
                        self.incrementColumn(1);
                    }
                    i += 1;
                }
                key = str[key_start..i];
                if (i < str.len) {
                    self.incrementColumn(1);
                    i += 1;
                }
            } else {
                // Unquoted key
                const key_start = i;
                while (i < str.len and !isWhitespace(str[i]) and str[i] != '!' and str[i] != '=' and str[i] != ',') {
                    if (str[i] == '\n') {
                        self.incrementLine(1);
                    } else {
                        self.incrementColumn(1);
                    }
                    i += 1;
                }
                key = str[key_start..i];
            }

            attr_token.name = TokenValue.fromString(key);

            // Skip whitespace
            while (i < str.len and (str[i] == ' ' or str[i] == '\t')) {
                self.incrementColumn(1);
                i += 1;
            }

            // Check for value
            var must_escape = true;
            if (i < str.len and str[i] == '!') {
                must_escape = false;
                self.incrementColumn(1);
                i += 1;
            }

            if (i < str.len and str[i] == '=') {
                self.incrementColumn(1);
                i += 1;

                // Skip whitespace (including newlines)
                while (i < str.len and isWhitespace(str[i])) {
                    if (str[i] == '\n') {
                        self.incrementLine(1);
                    } else {
                        self.incrementColumn(1);
                    }
                    i += 1;
                }

                // Parse value
                var state: CharParserState = .{};
                defer state.deinit(self.allocator);

                const val_start = i;
                var has_content = false; // Track if we've seen non-whitespace
                while (i < str.len) {
                    const char = str[i];
                    state.parseChar(self.allocator, char) catch break;

                    if (!isWhitespace(char)) {
                        has_content = true;
                    }

                    if (!state.isNesting() and !state.isString() and has_content) {
                        if (isWhitespace(char) or char == ',') {
                            break;
                        }
                    }

                    // Check for invalid newline inside single/double quoted string
                    // (template literals with backticks can have newlines)
                    if (char == '\n') {
                        if (state.isString()) {
                            const quote_char = state.getStringChar();
                            if (quote_char) |qc| {
                                if (qc == '\'' or qc == '"') {
                                    self.setError(.SYNTAX_ERROR, "Invalid newline in string literal");
                                    return;
                                }
                            }
                        }
                    }

                    if (str[i] == '\n') {
                        self.incrementLine(1);
                    } else {
                        self.incrementColumn(1);
                    }
                    i += 1;
                }

                attr_token.val = TokenValue.fromString(str[val_start..i]);
                attr_token.must_escape = TokenValue.fromBool(must_escape);
            } else {
                // Boolean attribute
                attr_token.val = TokenValue.fromBool(true);
                attr_token.must_escape = TokenValue.fromBool(true);
            }

            self.tokens.append(self.allocator, attr_token) catch return;
            self.tokEnd(&attr_token);

            // Skip whitespace and comma
            while (i < str.len and (isWhitespace(str[i]) or str[i] == ',')) {
                if (str[i] == '\n') {
                    self.incrementLine(1);
                } else {
                    self.incrementColumn(1);
                }
                i += 1;
            }
        }
    }

    fn attributesBlock(self: *Lexer) bool {
        if (!mem.startsWith(u8, self.input, "&attributes")) return false;

        if (self.input.len > 11 and isWordChar(self.input[11])) return false;

        self.consume(11);
        var token = self.tok(.@"&attributes", .none);
        self.incrementColumn(11);

        const args = self.bracketExpression(0) catch return false;
        self.consume(args.end + 1);
        token.val = TokenValue.fromString(args.src);
        self.incrementColumn(args.end + 1);

        self.tokens.append(self.allocator, token) catch return false;
        self.tokEnd(&token);
        return true;
    }

    fn indent(self: *Lexer) bool {
        const captures = self.scanIndentation() orelse return false;

        const indents = captures.indent.len;

        self.incrementLine(1);
        self.consume(captures.total_len);

        // Blank line
        if (self.input.len > 0 and self.input[0] == '\n') {
            self.interpolation_allowed = true;
            var newline_token = self.tok(.newline, .none);
            self.tokEnd(&newline_token);
            return true;
        }

        // Outdent
        if (indents < self.indent_stack.items[0]) {
            var outdent_count: usize = 0;
            while (self.indent_stack.items[0] > indents) {
                if (self.indent_stack.items.len > 1 and self.indent_stack.items[1] < indents) {
                    self.setError(.INCONSISTENT_INDENTATION, "Inconsistent indentation");
                    return false;
                }
                outdent_count += 1;
                _ = self.indent_stack.orderedRemove(0);
            }
            while (outdent_count > 0) : (outdent_count -= 1) {
                self.colno = 1;
                var outdent_token = self.tok(.outdent, .none);
                self.colno = self.indent_stack.items[0] + 1;
                self.tokens.append(self.allocator, outdent_token) catch return false;
                self.tokEnd(&outdent_token);
            }
        } else if (indents > 0 and indents != self.indent_stack.items[0]) {
            // Indent
            var indent_token = self.tok(.indent, .none);
            self.colno = 1 + indents;
            self.tokens.append(self.allocator, indent_token) catch return false;
            self.tokEnd(&indent_token);
            self.indent_stack.insert(self.allocator, 0, indents) catch return false;
        } else {
            // Newline
            var newline_token = self.tok(.newline, .none);
            self.colno = 1 + @min(self.indent_stack.items[0], indents);
            self.tokens.append(self.allocator, newline_token) catch return false;
            self.tokEnd(&newline_token);
        }

        self.interpolation_allowed = true;
        return true;
    }

    fn pipelessText(self: *Lexer, forced_indents: ?usize) bool {
        while (self.blank()) {}

        const captures = self.scanIndentation() orelse return false;
        const indents = forced_indents orelse captures.indent.len;

        if (indents <= self.indent_stack.items[0]) return false;

        var start_token = self.tok(.start_pipeless_text, .none);
        self.tokEnd(&start_token);
        self.tokens.append(self.allocator, start_token) catch return false;

        var string_ptr: usize = 0;
        var tokens_list: std.ArrayListUnmanaged([]const u8) = .{};
        var token_indent_list: std.ArrayListUnmanaged(bool) = .{};
        defer tokens_list.deinit(self.allocator);
        defer token_indent_list.deinit(self.allocator);

        while (string_ptr < self.input.len) {
            // text has `\n` as a prefix
            const line_start = string_ptr + 1; // skip the \n
            if (string_ptr >= self.input.len or self.input[string_ptr] != '\n') {
                break;
            }

            // Find end of line
            var line_end = line_start;
            while (line_end < self.input.len and self.input[line_end] != '\n') {
                line_end += 1;
            }

            const str = self.input[line_start..line_end];

            // Check indentation of this line (count leading whitespace)
            var line_indent: usize = 0;
            for (str) |c| {
                if (c == ' ' or c == '\t') {
                    line_indent += 1;
                } else {
                    break;
                }
            }

            const is_match = line_indent >= indents;
            token_indent_list.append(self.allocator, is_match) catch return false;

            // Match if indented enough OR if line is empty/whitespace
            const trimmed = mem.trim(u8, str, " \t");
            if (is_match or trimmed.len == 0) {
                // consume line along with `\n` prefix
                string_ptr = line_end;
                // Extract text after the indent
                const text_content = if (str.len > indents) str[indents..] else "";
                tokens_list.append(self.allocator, text_content) catch return false;
            } else if (line_indent > self.indent_stack.items[0]) {
                // line is indented less than the first line but is still indented
                // need to retry lexing the text block with new indent level
                _ = self.tokens.pop();
                return self.pipelessText(line_indent);
            } else {
                break;
            }
        }

        self.consume(string_ptr);

        // Remove trailing empty lines when input is exhausted
        while (self.input.len == 0 and tokens_list.items.len > 0 and tokens_list.items[tokens_list.items.len - 1].len == 0) {
            _ = tokens_list.pop();
        }

        for (tokens_list.items, 0..) |token_text, ii| {
            self.incrementLine(1);
            if (ii != 0) {
                var newline_token = self.tok(.newline, .none);
                self.tokens.append(self.allocator, newline_token) catch return false;
                self.tokEnd(&newline_token);
            }
            if (ii < token_indent_list.items.len and token_indent_list.items[ii]) {
                self.incrementColumn(indents);
            }
            self.addText(.text, token_text, "", 0);
        }

        var end_token = self.tok(.end_pipeless_text, .none);
        self.tokEnd(&end_token);
        self.tokens.append(self.allocator, end_token) catch return false;
        return true;
    }

    fn slash(self: *Lexer) bool {
        if (self.input.len == 0 or self.input[0] != '/') return false;

        self.consume(1);
        var token = self.tok(.slash, .none);
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(1);
        self.tokEnd(&token);
        return true;
    }

    fn colon(self: *Lexer) bool {
        if (self.input.len < 2 or self.input[0] != ':' or self.input[1] != ' ') return false;

        var i: usize = 2;
        while (i < self.input.len and self.input[i] == ' ') {
            i += 1;
        }

        self.consume(i);
        var token = self.tok(.colon, .none);
        self.tokens.append(self.allocator, token) catch return false;
        self.incrementColumn(i);
        self.tokEnd(&token);
        return true;
    }

    fn fail(self: *Lexer) void {
        self.setError(.UNEXPECTED_TEXT, "unexpected text");
    }

    fn addText(self: *Lexer, token_type: TokenType, value: []const u8, prefix: []const u8, escaped: usize) void {
        if (value.len + prefix.len == 0) return;

        // Check for unclosed or mismatched tag interpolations #[...]
        // Note: Inside #[...] is full Pug syntax, so we need to track ALL bracket types
        if (self.interpolation_allowed) {
            var i: usize = 0;
            while (i + 1 < value.len) {
                // Skip escaped \#[
                if (value[i] == '\\' and i + 2 < value.len and value[i + 1] == '#' and value[i + 2] == '[') {
                    i += 3;
                    continue;
                }
                if (value[i] == '#' and value[i + 1] == '[') {
                    // Found start of tag interpolation, look for matching ]
                    var j = i + 2;
                    var in_string: u8 = 0;

                    // Track bracket stack - inside #[...] you can have (...) and {...} for attrs/code
                    var bracket_stack = std.ArrayListUnmanaged(u8){};
                    defer bracket_stack.deinit(self.allocator);
                    bracket_stack.append(self.allocator, '[') catch return;

                    while (j < value.len and bracket_stack.items.len > 0) {
                        const c = value[j];
                        if (in_string != 0) {
                            if (c == in_string and (j == i + 2 or value[j - 1] != '\\')) {
                                in_string = 0;
                            }
                        } else {
                            if (c == '"' or c == '\'' or c == '`') {
                                in_string = c;
                            } else if (c == '[' or c == '(' or c == '{') {
                                bracket_stack.append(self.allocator, c) catch return;
                            } else if (c == ']' or c == ')' or c == '}') {
                                if (bracket_stack.items.len > 0) {
                                    const last_open = bracket_stack.items[bracket_stack.items.len - 1];
                                    const expected_close: u8 = switch (last_open) {
                                        '[' => ']',
                                        '(' => ')',
                                        '{' => '}',
                                        else => 0,
                                    };
                                    if (c != expected_close) {
                                        // Mismatched bracket type
                                        self.setError(.BRACKET_MISMATCH, "Mismatched bracket in tag interpolation");
                                        return;
                                    }
                                    _ = bracket_stack.pop();
                                }
                            }
                        }
                        j += 1;
                    }
                    if (bracket_stack.items.len > 0) {
                        // Unclosed interpolation
                        self.setError(.NO_END_BRACKET, "Unclosed tag interpolation - missing ]");
                        return;
                    }
                    i = j;
                } else {
                    i += 1;
                }
            }
        }

        var token = self.tokWithString(token_type, value);
        self.incrementColumn(value.len + escaped);
        self.tokens.append(self.allocator, token) catch return;
        self.tokEnd(&token);
    }

    // ========================================================================
    // Main advance and getTokens
    // ========================================================================

    fn advance(self: *Lexer) bool {
        return self.blank() or
            self.eos() or
            self.endInterpolation() or
            self.yieldToken() or
            self.doctype() or
            self.interpolation() or
            self.caseToken() or
            self.when() or
            self.defaultToken() or
            self.extendsToken() or
            self.append() or
            self.prepend() or
            self.blockToken() or
            self.mixinBlock() or
            self.includeToken() or
            self.mixin() or
            self.call() or
            self.conditional() or
            self.eachOf() or
            self.each() or
            self.whileToken() or
            self.tag() or
            self.filter(false) or
            self.blockCode() or
            self.code() or
            self.id() or
            self.dot() or
            self.className() or
            self.attrs() or
            self.attributesBlock() or
            self.indent() or
            self.text() or
            self.textHtml() or
            self.comment() or
            self.slash() or
            self.colon() or
            blk: {
                self.fail();
                break :blk false;
            };
    }

    pub fn getTokens(self: *Lexer) ![]Token {
        while (!self.ended) {
            const advanced = self.advance();
            // Check for errors after every advance, regardless of return value
            if (self.last_error) |err| {
                std.debug.print("Lexer error at {d}:{d}: {s}\n", .{ err.line, err.column, err.message });
                return error.LexerError;
            }
            if (!advanced) {
                break;
            }
        }
        return self.tokens.items;
    }
};

// ============================================================================
// Options
// ============================================================================

pub const LexerOptions = struct {
    filename: ?[]const u8 = null,
    interpolated: bool = false,
    starting_line: usize = 1,
    starting_column: usize = 1,
};

// ============================================================================
// Public API
// ============================================================================

/// Lexes the input string and returns a slice of tokens.
/// IMPORTANT: The caller must keep the Lexer alive while using the returned tokens,
/// as token string values are slices into the lexer's input buffer.
/// For simpler usage, use Lexer.init() and Lexer.getTokens() directly.
pub fn lex(allocator: Allocator, str: []const u8, options: LexerOptions) !struct { tokens: []Token, lexer: *Lexer } {
    const lexer = try allocator.create(Lexer);
    lexer.* = try Lexer.init(allocator, str, options);
    const tokens = try lexer.getTokens();
    return .{ .tokens = tokens, .lexer = lexer };
}

/// Frees resources from a lex() call
pub fn freeLexResult(allocator: Allocator, lexer: *Lexer) void {
    lexer.deinit();
    allocator.destroy(lexer);
}

// ============================================================================
// Tests
// ============================================================================

test "TokenValue - none" {
    const val: TokenValue = .none;
    try std.testing.expect(val.isNone());
    try std.testing.expect(val.getString() == null);
    try std.testing.expect(val.getBool() == null);
}

test "TokenValue - string" {
    const val = TokenValue.fromString("hello");
    try std.testing.expect(!val.isNone());
    try std.testing.expectEqualStrings("hello", val.getString().?);
    try std.testing.expect(val.getBool() == null);
}

test "TokenValue - boolean" {
    const val_true = TokenValue.fromBool(true);
    const val_false = TokenValue.fromBool(false);

    try std.testing.expect(!val_true.isNone());
    try std.testing.expect(val_true.getBool().? == true);
    try std.testing.expect(val_true.getString() == null);

    try std.testing.expect(val_false.getBool().? == false);
}

test "basic tag lexing" {
    const allocator = std.testing.allocator;
    var lexer = try Lexer.init(allocator, "div", .{});
    defer lexer.deinit();

    const tokens = try lexer.getTokens();

    try std.testing.expect(tokens.len >= 2);
    try std.testing.expectEqual(TokenType.tag, tokens[0].type);
    try std.testing.expectEqualStrings("div", tokens[0].getVal().?);
}

test "tag with id" {
    const allocator = std.testing.allocator;
    var lexer = try Lexer.init(allocator, "div#main", .{});
    defer lexer.deinit();

    const tokens = try lexer.getTokens();

    try std.testing.expect(tokens.len >= 3);
    try std.testing.expectEqual(TokenType.tag, tokens[0].type);
    try std.testing.expectEqual(TokenType.id, tokens[1].type);
    try std.testing.expectEqualStrings("main", tokens[1].getVal().?);
}

test "tag with class" {
    const allocator = std.testing.allocator;
    var lexer = try Lexer.init(allocator, "div.container", .{});
    defer lexer.deinit();

    const tokens = try lexer.getTokens();

    try std.testing.expect(tokens.len >= 3);
    try std.testing.expectEqual(TokenType.tag, tokens[0].type);
    try std.testing.expectEqual(TokenType.class, tokens[1].type);
    try std.testing.expectEqualStrings("container", tokens[1].getVal().?);
}

test "doctype" {
    const allocator = std.testing.allocator;
    var lexer = try Lexer.init(allocator, "doctype html", .{});
    defer lexer.deinit();

    const tokens = try lexer.getTokens();

    try std.testing.expect(tokens.len >= 2);
    try std.testing.expectEqual(TokenType.doctype, tokens[0].type);
    try std.testing.expectEqualStrings("html", tokens[0].getVal().?);
}

test "comment with buffer" {
    const allocator = std.testing.allocator;
    var lexer = try Lexer.init(allocator, "// this is a comment", .{});
    defer lexer.deinit();

    const tokens = try lexer.getTokens();

    try std.testing.expect(tokens.len >= 2);
    try std.testing.expectEqual(TokenType.comment, tokens[0].type);
    try std.testing.expect(tokens[0].isBuffered() == true);
}

test "comment without buffer" {
    const allocator = std.testing.allocator;
    var lexer = try Lexer.init(allocator, "//- this is a silent comment", .{});
    defer lexer.deinit();

    const tokens = try lexer.getTokens();

    try std.testing.expect(tokens.len >= 2);
    try std.testing.expectEqual(TokenType.comment, tokens[0].type);
    try std.testing.expect(tokens[0].isBuffered() == false);
}

test "code with escape" {
    const allocator = std.testing.allocator;
    var lexer = try Lexer.init(allocator, "= foo", .{});
    defer lexer.deinit();

    const tokens = try lexer.getTokens();

    try std.testing.expect(tokens.len >= 2);
    try std.testing.expectEqual(TokenType.code, tokens[0].type);
    try std.testing.expect(tokens[0].shouldEscape() == true);
    try std.testing.expect(tokens[0].isBuffered() == true);
}

test "code without escape" {
    const allocator = std.testing.allocator;
    var lexer = try Lexer.init(allocator, "!= foo", .{});
    defer lexer.deinit();

    const tokens = try lexer.getTokens();

    try std.testing.expect(tokens.len >= 2);
    try std.testing.expectEqual(TokenType.code, tokens[0].type);
    try std.testing.expect(tokens[0].shouldEscape() == false);
    try std.testing.expect(tokens[0].isBuffered() == true);
}

test "boolean attribute" {
    const allocator = std.testing.allocator;
    var lexer = try Lexer.init(allocator, "input(disabled)", .{});
    defer lexer.deinit();

    const tokens = try lexer.getTokens();

    // Find the attribute token
    var attr_found = false;
    for (tokens) |tok| {
        if (tok.type == .attribute) {
            attr_found = true;
            try std.testing.expectEqualStrings("disabled", tok.getName().?);
            // Boolean attribute should have boolean true value
            try std.testing.expect(tok.val.getBool().? == true);
            break;
        }
    }
    try std.testing.expect(attr_found);
}
