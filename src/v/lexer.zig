const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

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
// Character Parser State (simplified)
// ============================================================================

const BracketType = enum { paren, brace, bracket };

const CharParserState = struct {
    nesting_stack: ArrayList(BracketType),
    in_string: bool = false,
    string_char: ?u8 = null,
    in_template: bool = false,
    template_depth: usize = 0,
    escape_next: bool = false,

    pub fn init(allocator: Allocator) CharParserState {
        return .{
            .nesting_stack = ArrayList(BracketType).init(allocator),
        };
    }

    pub fn deinit(self: *CharParserState) void {
        self.nesting_stack.deinit();
    }

    pub fn isNesting(self: *const CharParserState) bool {
        return self.nesting_stack.items.len > 0;
    }

    pub fn isString(self: *const CharParserState) bool {
        return self.in_string or self.in_template;
    }

    pub fn parseChar(self: *CharParserState, char: u8) !void {
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
            // Handle ${} in template literals
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
            '(' => try self.nesting_stack.append(.paren),
            '{' => try self.nesting_stack.append(.brace),
            '[' => try self.nesting_stack.append(.bracket),
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
// Lexer
// ============================================================================

pub const Lexer = struct {
    allocator: Allocator,
    input: []const u8,
    original_input: []const u8,
    filename: ?[]const u8,
    interpolated: bool,
    lineno: usize,
    colno: usize,
    indent_stack: ArrayList(usize),
    indent_re_type: ?IndentType = null,
    interpolation_allowed: bool,
    tokens: ArrayList(Token),
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
        var normalized = ArrayList(u8).init(allocator);
        errdefer normalized.deinit();

        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == '\r') {
                if (i + 1 < input.len and input[i + 1] == '\n') {
                    try normalized.append('\n');
                    i += 2;
                } else {
                    try normalized.append('\n');
                    i += 1;
                }
            } else {
                try normalized.append(input[i]);
                i += 1;
            }
        }

        var indent_stack = ArrayList(usize).init(allocator);
        try indent_stack.append(0);

        return Lexer{
            .allocator = allocator,
            .input = try normalized.toOwnedSlice(),
            .original_input = str,
            .filename = options.filename,
            .interpolated = options.interpolated,
            .lineno = options.starting_line,
            .colno = options.starting_column,
            .indent_stack = indent_stack,
            .interpolation_allowed = true,
            .tokens = ArrayList(Token).init(allocator),
            .ended = false,
        };
    }

    pub fn deinit(self: *Lexer) void {
        self.indent_stack.deinit();
        self.tokens.deinit();
        self.allocator.free(self.input);
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

    fn assert(self: *Lexer, value: bool, message: []const u8) bool {
        if (!value) {
            self.setError(.ASSERT_FAILED, message);
            return false;
        }
        return true;
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

    /// Scan for a simple prefix pattern and return a token
    fn scan(self: *Lexer, pattern: []const u8, token_type: TokenType) ?Token {
        if (mem.startsWith(u8, self.input, pattern)) {
            const len = pattern.len;
            var token = self.tok(token_type, .none);
            self.consume(len);
            self.incrementColumn(len);
            return token;
        }
        return null;
    }

    // ========================================================================
    // Bracket expression parsing
    // ========================================================================

    fn bracketExpression(self: *Lexer, skip: usize) !BracketExpressionResult {
        if (skip >= self.input.len) {
            self.setError(.NO_END_BRACKET, "Empty input for bracket expression");
            return error.LexerError;
        }

        const start_char = self.input[skip];
        const end_char: u8 = switch (start_char) {
            '(' => ')',
            '{' => '}',
            '[' => ']',
            else => {
                self.setError(.ASSERT_FAILED, "The start character should be '(', '{' or '['");
                return error.LexerError;
            },
        };

        var state = CharParserState.init(self.allocator);
        defer state.deinit();

        var i = skip + 1;
        var depth: usize = 1;

        while (i < self.input.len) {
            const char = self.input[i];

            try state.parseChar(char);

            if (!state.isString()) {
                if (char == start_char) {
                    depth += 1;
                } else if (char == end_char) {
                    depth -= 1;
                    if (depth == 0) {
                        return BracketExpressionResult{
                            .src = self.input[skip + 1 .. i],
                            .end = i,
                        };
                    }
                }
            }

            i += 1;
        }

        self.setError(.NO_END_BRACKET, "The end of the string reached with no closing bracket found.");
        return error.LexerError;
    }

    // ========================================================================
    // Indentation scanning
    // ========================================================================

    fn scanIndentation(self: *Lexer) ?struct { indent: []const u8, total_len: usize } {
        if (self.input.len == 0 or self.input[0] != '\n') {
            return null;
        }

        var i: usize = 1;
        const indent_start = i;

        // Check for tabs first
        if (self.indent_re_type == .tabs or self.indent_re_type == null) {
            while (i < self.input.len and self.input[i] == '\t') {
                i += 1;
            }
            // Skip trailing spaces after tabs
            while (i < self.input.len and self.input[i] == ' ') {
                i += 1;
            }
            if (i > indent_start) {
                const indent = self.input[indent_start..i];
                // Count only tabs
                var tab_count: usize = 0;
                for (indent) |c| {
                    if (c == '\t') tab_count += 1;
                }
                if (tab_count > 0) {
                    self.indent_re_type = .tabs;
                    // Return tab-only portion
                    var tab_end = indent_start;
                    while (tab_end < self.input.len and self.input[tab_end] == '\t') {
                        tab_end += 1;
                    }
                    return .{ .indent = self.input[indent_start..tab_end], .total_len = i };
                }
            }
        }

        // Check for spaces
        i = 1;
        while (i < self.input.len and self.input[i] == ' ') {
            i += 1;
        }
        if (i > indent_start) {
            self.indent_re_type = .spaces;
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
            self.tokens.append(outdent_tok) catch return false;
        }

        var eos_tok = self.tok(.eos, .none);
        self.tokEnd(&eos_tok);
        self.tokens.append(eos_tok) catch return false;
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
        self.tokens.append(token) catch return false;
        self.incrementColumn(i);
        self.tokEnd(&token);

        self.pipelessText(null);
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
        self.tokens.append(token) catch return false;
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
        self.tokens.append(token) catch return false;
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
        self.tokens.append(token) catch return false;
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
        self.tokens.append(token) catch return false;
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
        self.tokens.append(token) catch return false;
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
        self.tokens.append(token) catch return false;
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
        if (self.input.len == 0) return false;

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
            self.tokens.append(token) catch return false;
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
                self.tokens.append(token) catch return false;
                self.incrementColumn(7);
                self.tokEnd(&token);

                if (!self.path()) {
                    self.setError(.NO_EXTENDS_PATH, "missing path for extends");
                    return false;
                }
                return true;
            }
        } else if (mem.startsWith(u8, self.input, "extend")) {
            const after = if (self.input.len > 6) self.input[6] else 0;
            if (after == 0 or after == ' ' or after == '\n') {
                self.consume(6);
                var token = self.tok(.extends, .none);
                self.tokens.append(token) catch return false;
                self.incrementColumn(6);
                self.tokEnd(&token);

                if (!self.path()) {
                    self.setError(.NO_EXTENDS_PATH, "missing path for extends");
                    return false;
                }
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
        self.tokens.append(token) catch return false;
        self.incrementColumn(end);
        self.tokEnd(&token);
        return true;
    }

    fn mixinBlock(self: *Lexer) bool {
        if (!mem.startsWith(u8, self.input, "block")) return false;

        // Check if followed by end of line or colon
        if (self.input.len == 5 or self.input[5] == '\n' or self.input[5] == ':') {
            self.consume(5);
            var token = self.tok(.mixin_block, .none);
            self.tokens.append(token) catch return false;
            self.incrementColumn(5);
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
            self.tokens.append(token) catch return false;
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
            return false;
        }

        self.consume(7);
        var token = self.tok(.include, .none);
        self.tokens.append(token) catch return false;
        self.incrementColumn(7);
        self.tokEnd(&token);

        // Parse filters
        while (self.filter(true)) {}

        if (!self.path()) {
            self.setError(.NO_INCLUDE_PATH, "missing path for include");
            return false;
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
        self.tokens.append(token) catch return false;
        self.incrementColumn(end);
        self.tokEnd(&token);
        return true;
    }

    fn caseToken(self: *Lexer) bool {
        // Match /^case +([^\n]+)/
        if (!mem.startsWith(u8, self.input, "case ")) return false;

        var i: usize = 5;
        while (i < self.input.len and self.input[i] == ' ') {
            i += 1;
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
        self.consume(end);

        var token = self.tokWithString(.case, expr);
        self.tokens.append(token) catch return false;
        self.incrementColumn(end);
        self.tokEnd(&token);
        return true;
    }

    fn when(self: *Lexer) bool {
        // Match /^when +([^:\n]+)/
        if (!mem.startsWith(u8, self.input, "when ")) return false;

        var i: usize = 5;
        while (i < self.input.len and self.input[i] == ' ') {
            i += 1;
        }

        var end = i;
        while (end < self.input.len and self.input[end] != '\n' and self.input[end] != ':') {
            end += 1;
        }

        if (end <= i) {
            self.setError(.NO_WHEN_EXPRESSION, "missing expression for when");
            return false;
        }

        const expr = self.input[i..end];
        self.consume(end);

        var token = self.tokWithString(.when, expr);
        self.tokens.append(token) catch return false;
        self.incrementColumn(end);
        self.tokEnd(&token);
        return true;
    }

    fn defaultToken(self: *Lexer) bool {
        if (!mem.startsWith(u8, self.input, "default")) return false;

        if (self.input.len == 7 or self.input[7] == '\n' or self.input[7] == ':') {
            self.consume(7);
            var token = self.tok(.default, .none);
            self.tokens.append(token) catch return false;
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
            // Store the interpolated expression
            var buf: [256]u8 = undefined;
            const result = std.fmt.bufPrint(&buf, "#{{{s}}}", .{match.src}) catch return false;
            token.val = TokenValue.fromString(result);
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

            self.tokens.append(token) catch return false;
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

        self.tokens.append(token) catch return false;
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
        self.tokens.append(token) catch return false;
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

        // Handle unless - note: in full implementation would negate the expression
        // Handle else with condition
        if (token_type == .@"else" and js.len > 0) {
            self.setError(.ELSE_CONDITION, "`else` cannot have a condition, perhaps you meant `else if`");
            return false;
        }

        self.tokens.append(token) catch return false;
        self.incrementColumn(end);
        self.tokEnd(&token);
        return true;
    }

    fn whileToken(self: *Lexer) bool {
        // Match /^while +([^\n]+)/
        if (!mem.startsWith(u8, self.input, "while ")) return false;

        var i: usize = 6;
        while (i < self.input.len and self.input[i] == ' ') {
            i += 1;
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
        self.tokens.append(token) catch return false;
        self.incrementColumn(end);
        self.tokEnd(&token);
        return true;
    }

    fn each(self: *Lexer) bool {
        // Match /^(?:each|for) +([a-zA-Z_$][\w$]*)(?: *, *([a-zA-Z_$][\w$]*))? * in *([^\n]+)/
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
            // This is eachOf syntax
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
        self.tokens.append(token) catch return false;
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
        // Match /^(?:each|for) (.*?) of *([^\n]+)/
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
        self.tokens.append(token) catch return false;
        self.incrementColumn(end);
        self.tokEnd(&token);
        return true;
    }

    fn code(self: *Lexer) bool {
        // Match /^(!?=|-)[ \t]*([^\n]+)/
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

        var end = i;
        while (end < self.input.len and self.input[end] != '\n') {
            end += 1;
        }

        const code_val = self.input[i..end];
        self.consume(end);

        var token = self.tokWithString(.code, code_val);
        token.must_escape = TokenValue.fromBool(must_escape);
        token.buffer = TokenValue.fromBool(buffer);
        self.tokens.append(token) catch return false;
        self.incrementColumn(end);
        self.tokEnd(&token);
        return true;
    }

    fn blockCode(self: *Lexer) bool {
        // Match /^-/
        if (self.input.len == 0 or self.input[0] != '-') return false;

        // Must be followed by end of line
        if (self.input.len > 1 and self.input[1] != '\n' and self.input[1] != ':') {
            return false;
        }

        self.consume(1);
        var token = self.tok(.blockcode, .none);
        self.tokens.append(token) catch return false;
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
        self.tokens.append(token) catch return false;
        self.tokEnd(&token);
        self.consume(bracket_result.end + 1);

        // Parse attributes from str
        self.parseAttributes(str);

        var end_token = self.tok(.end_attributes, .none);
        self.incrementColumn(1);
        self.tokens.append(end_token) catch return false;
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

                // Skip whitespace
                while (i < str.len and (str[i] == ' ' or str[i] == '\t')) {
                    self.incrementColumn(1);
                    i += 1;
                }

                // Parse value
                var state = CharParserState.init(self.allocator);
                defer state.deinit();

                const val_start = i;
                while (i < str.len) {
                    state.parseChar(str[i]) catch break;

                    if (!state.isNesting() and !state.isString()) {
                        if (isWhitespace(str[i]) or str[i] == ',') {
                            break;
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

            self.tokens.append(attr_token) catch return;
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
        // Match /^&attributes\b/
        if (!mem.startsWith(u8, self.input, "&attributes")) return false;

        if (self.input.len > 11 and isWordChar(self.input[11])) return false;

        self.consume(11);
        var token = self.tok(.@"&attributes", .none);
        self.incrementColumn(11);

        const args = self.bracketExpression(0) catch return false;
        self.consume(args.end + 1);
        token.val = TokenValue.fromString(args.src);
        self.incrementColumn(args.end + 1);

        self.tokens.append(token) catch return false;
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
                self.tokens.append(outdent_token) catch return false;
                self.tokEnd(&outdent_token);
            }
        } else if (indents > 0 and indents != self.indent_stack.items[0]) {
            // Indent
            var indent_token = self.tok(.indent, .none);
            self.colno = 1 + indents;
            self.tokens.append(indent_token) catch return false;
            self.tokEnd(&indent_token);
            self.indent_stack.insert(0, indents) catch return false;
        } else {
            // Newline
            var newline_token = self.tok(.newline, .none);
            self.colno = 1 + @min(self.indent_stack.items[0], indents);
            self.tokens.append(newline_token) catch return false;
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
        self.tokens.append(start_token) catch return false;

        var string_ptr: usize = 0;
        var tokens_list = ArrayList([]const u8).init(self.allocator);
        defer tokens_list.deinit();

        while (string_ptr < self.input.len) {
            // Find end of line
            var line_end = string_ptr;
            if (self.input[line_end] == '\n') {
                line_end += 1;
            }
            while (line_end < self.input.len and self.input[line_end] != '\n') {
                line_end += 1;
            }

            const line = self.input[string_ptr..line_end];

            // Check indentation of this line
            var line_indent: usize = 0;
            if (line.len > 0 and line[0] == '\n') {
                var ii: usize = 1;
                while (ii < line.len and (line[ii] == ' ' or line[ii] == '\t')) {
                    ii += 1;
                }
                line_indent = ii - 1;
            }

            if (line_indent >= indents or line.len == 0 or mem.trim(u8, line, " \t\n").len == 0) {
                string_ptr = line_end;
                const text_start = if (line.len > indents + 1) indents + 1 else line.len;
                tokens_list.append(if (line.len > 0 and line[0] == '\n') line[text_start..] else line) catch return false;
            } else {
                break;
            }
        }

        self.consume(string_ptr);

        // Remove trailing empty lines
        while (tokens_list.items.len > 0 and tokens_list.items[tokens_list.items.len - 1].len == 0) {
            _ = tokens_list.pop();
        }

        for (tokens_list.items, 0..) |token_text, ii| {
            self.incrementLine(1);
            if (ii != 0) {
                var newline_token = self.tok(.newline, .none);
                self.tokens.append(newline_token) catch return false;
                self.tokEnd(&newline_token);
            }
            self.incrementColumn(indents);
            self.addText(.text, token_text, "", 0);
        }

        var end_token = self.tok(.end_pipeless_text, .none);
        self.tokEnd(&end_token);
        self.tokens.append(end_token) catch return false;
        return true;
    }

    fn slash(self: *Lexer) bool {
        if (self.input.len == 0 or self.input[0] != '/') return false;

        self.consume(1);
        var token = self.tok(.slash, .none);
        self.tokens.append(token) catch return false;
        self.incrementColumn(1);
        self.tokEnd(&token);
        return true;
    }

    fn colon(self: *Lexer) bool {
        // Match /^: +/
        if (self.input.len < 2 or self.input[0] != ':' or self.input[1] != ' ') return false;

        var i: usize = 2;
        while (i < self.input.len and self.input[i] == ' ') {
            i += 1;
        }

        self.consume(i);
        var token = self.tok(.colon, .none);
        self.tokens.append(token) catch return false;
        self.incrementColumn(i);
        self.tokEnd(&token);
        return true;
    }

    fn fail(self: *Lexer) void {
        self.setError(.UNEXPECTED_TEXT, "unexpected text");
    }

    fn addText(self: *Lexer, token_type: TokenType, value: []const u8, prefix: []const u8, escaped: usize) void {
        if (value.len + prefix.len == 0) return;

        // Simplified version - in full implementation would handle interpolation
        var token = self.tokWithString(token_type, value);
        self.incrementColumn(value.len + escaped);
        self.tokens.append(token) catch return;
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
            if (!self.advance()) {
                if (self.last_error) |err| {
                    std.debug.print("Lexer error at {d}:{d}: {s}\n", .{ err.line, err.column, err.message });
                    return error.LexerError;
                }
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

pub fn lex(allocator: Allocator, str: []const u8, options: LexerOptions) ![]Token {
    var lexer = try Lexer.init(allocator, str, options);
    defer lexer.deinit();
    return try lexer.getTokens();
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
