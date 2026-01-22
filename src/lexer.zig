//! Pug Lexer - Tokenizes Pug template source into a stream of tokens.
//!
//! The lexer handles indentation-based nesting (emitting indent/dedent tokens),
//! Pug-specific syntax (tags, classes, IDs, attributes), and text content
//! including interpolation markers.

const std = @import("std");

/// All possible token types produced by the lexer.
pub const TokenType = enum {
    // Structure tokens for indentation-based nesting
    indent, // Increased indentation level
    dedent, // Decreased indentation level
    newline, // Line terminator
    eof, // End of source

    // Element tokens
    tag, // HTML tag name: div, p, a, span, etc.
    class, // Class selector: .classname
    id, // ID selector: #idname

    // Attribute tokens for (attr=value) syntax
    lparen, // Opening paren: (
    rparen, // Closing paren: )
    attr_name, // Attribute name: href, class, data-id
    attr_eq, // Assignment: = or !=
    attr_value, // Attribute value (quoted or unquoted)
    comma, // Attribute separator: ,

    // Text content tokens
    text, // Plain text content
    buffered_text, // Escaped output: = expr
    unescaped_text, // Raw output: != expr
    pipe_text, // Piped text: | text
    dot_block, // Text block marker: .
    literal_html, // Literal HTML: <tag>...
    self_close, // Self-closing marker: /

    // Interpolation tokens for #{} and !{} syntax
    interp_start, // Escaped interpolation: #{
    interp_start_unesc, // Unescaped interpolation: !{
    interp_end, // Interpolation end: }

    // Tag interpolation tokens for #[tag text] syntax
    tag_interp_start, // Tag interpolation start: #[
    tag_interp_end, // Tag interpolation end: ]

    // Control flow keywords
    kw_if,
    kw_else,
    kw_unless,
    kw_each,
    kw_for, // alias for each
    kw_while,
    kw_in,
    kw_case,
    kw_when,
    kw_default,

    // Template structure keywords
    kw_doctype,
    kw_mixin,
    kw_block,
    kw_extends,
    kw_include,
    kw_append,
    kw_prepend,

    // Mixin invocation: +mixinName
    mixin_call,

    // Comment tokens
    comment, // Rendered comment: //
    comment_unbuffered, // Silent comment: //-

    // Miscellaneous
    colon, // Block expansion: :
    ampersand_attrs, // Attribute spread: &attributes
};

/// A single token with its type, value, and source location.
pub const Token = struct {
    type: TokenType,
    value: []const u8, // Slice into source (no allocation)
    line: usize,
    column: usize,
};

/// Errors that can occur during lexing.
pub const LexerError = error{
    UnterminatedString,
    UnmatchedBrace,
    OutOfMemory,
};

/// Static map for keyword lookup. Using comptime perfect hashing would be ideal,
/// but a simple StaticStringMap is efficient for small keyword sets.
const keywords = std.StaticStringMap(TokenType).initComptime(.{
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "unless", .kw_unless },
    .{ "each", .kw_each },
    .{ "for", .kw_for },
    .{ "while", .kw_while },
    .{ "case", .kw_case },
    .{ "when", .kw_when },
    .{ "default", .kw_default },
    .{ "doctype", .kw_doctype },
    .{ "mixin", .kw_mixin },
    .{ "block", .kw_block },
    .{ "extends", .kw_extends },
    .{ "include", .kw_include },
    .{ "append", .kw_append },
    .{ "prepend", .kw_prepend },
    .{ "in", .kw_in },
});

/// Lexer for Pug template syntax.
///
/// Converts source text into a sequence of tokens. Handles:
/// - Indentation tracking with indent/dedent tokens
/// - Tag, class, and ID shorthand syntax
/// - Attribute parsing within parentheses
/// - Text content and interpolation
/// - Comments and keywords
pub const Lexer = struct {
    source: []const u8,
    pos: usize,
    line: usize,
    column: usize,
    indent_stack: std.ArrayList(usize),
    tokens: std.ArrayList(Token),
    allocator: std.mem.Allocator,
    at_line_start: bool,
    current_indent: usize,
    in_raw_block: bool,
    raw_block_indent: usize,
    raw_block_started: bool,

    /// Creates a new lexer for the given source.
    /// Does not allocate; allocations happen during tokenize().
    pub fn init(allocator: std.mem.Allocator, source: []const u8) Lexer {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .column = 1,
            .indent_stack = .empty,
            .tokens = .empty,
            .allocator = allocator,
            .at_line_start = true,
            .current_indent = 0,
            .in_raw_block = false,
            .raw_block_indent = 0,
            .raw_block_started = false,
        };
    }

    /// Releases all allocated memory (tokens and indent stack).
    /// Call this when done with the lexer, typically via defer.
    pub fn deinit(self: *Lexer) void {
        self.indent_stack.deinit(self.allocator);
        self.tokens.deinit(self.allocator);
    }

    /// Tokenizes the source and returns the token slice.
    ///
    /// Returns a slice of tokens owned by the Lexer. The slice remains valid
    /// until deinit() is called. On error, calls reset() via errdefer to
    /// restore the lexer to a clean state for potential retry or inspection.
    pub fn tokenize(self: *Lexer) ![]Token {
        // Pre-allocate with estimated capacity: ~1 token per 10 chars is a reasonable heuristic
        const estimated_tokens = @max(16, self.source.len / 10);
        try self.tokens.ensureTotalCapacity(self.allocator, estimated_tokens);
        try self.indent_stack.ensureTotalCapacity(self.allocator, 16); // Reasonable nesting depth

        try self.indent_stack.append(self.allocator, 0);
        errdefer self.reset();

        while (!self.isAtEnd()) {
            try self.scanToken();
        }

        // Emit dedents for any remaining indentation levels
        while (self.indent_stack.items.len > 1) {
            _ = self.indent_stack.pop();
            try self.addToken(.dedent, "");
        }

        try self.addToken(.eof, "");
        return self.tokens.items;
    }

    /// Resets lexer state while retaining allocated capacity.
    /// Called on error to restore clean state for reuse.
    pub fn reset(self: *Lexer) void {
        self.tokens.clearRetainingCapacity();
        self.indent_stack.clearRetainingCapacity();
        self.pos = 0;
        self.line = 1;
        self.column = 1;
        self.at_line_start = true;
        self.current_indent = 0;
    }

    /// Appends a token to the output list.
    fn addToken(self: *Lexer, token_type: TokenType, value: []const u8) !void {
        try self.tokens.append(self.allocator, .{
            .type = token_type,
            .value = value,
            .line = self.line,
            .column = self.column,
        });
    }

    /// Main token dispatch. Processes one token based on current character.
    /// Handles indentation at line start, then dispatches to specific scanners.
    fn scanToken(self: *Lexer) !void {
        if (self.at_line_start) {
            // In raw block mode, handle indentation specially
            if (self.in_raw_block) {
                // Remember position before consuming indent
                const line_start = self.pos;
                const indent = self.measureIndent();
                self.current_indent = indent;

                if (indent > self.raw_block_indent) {
                    // First line in raw block - emit indent token
                    if (!self.raw_block_started) {
                        self.raw_block_started = true;
                        try self.indent_stack.append(self.allocator, indent);
                        try self.addToken(.indent, "");
                    }
                    // Scan line as raw text, preserving relative indentation
                    try self.scanRawLineFrom(line_start);
                    self.at_line_start = false;
                    return;
                } else {
                    // Exiting raw block - emit dedent and process normally
                    self.in_raw_block = false;
                    self.raw_block_started = false;
                    if (self.indent_stack.items.len > 1) {
                        _ = self.indent_stack.pop();
                        try self.addToken(.dedent, "");
                    }
                    try self.processIndentation();
                    self.at_line_start = false;
                    return;
                }
            }

            try self.processIndentation();
            self.at_line_start = false;
        }

        if (self.isAtEnd()) return;

        const c = self.peek();

        // Whitespace (not at line start - already handled)
        if (c == ' ' or c == '\t') {
            self.advance();
            return;
        }

        // Newline: emit token and mark next line start
        if (c == '\n') {
            try self.addToken(.newline, "\n");
            self.advance();
            self.line += 1;
            self.column = 1;
            self.at_line_start = true;
            return;
        }

        // Handle \r\n (Windows) and \r (old Mac)
        if (c == '\r') {
            self.advance();
            if (self.peek() == '\n') {
                self.advance();
            }
            try self.addToken(.newline, "\n");
            self.line += 1;
            self.column = 1;
            self.at_line_start = true;
            return;
        }

        // Comments: // or //-
        if (c == '/' and self.peekNext() == '/') {
            try self.scanComment();
            return;
        }

        // Self-closing marker: / at end of tag (before newline or space)
        if (c == '/') {
            const next = self.peekNext();
            if (next == '\n' or next == '\r' or next == ' ' or next == 0) {
                self.advance();
                try self.addToken(.self_close, "/");
                return;
            }
        }

        // Dot: either .class or . (text block)
        if (c == '.') {
            const next = self.peekNext();
            if (next == '\n' or next == '\r' or next == 0) {
                self.advance();
                try self.addToken(.dot_block, ".");
                // Mark that we're entering a raw text block
                self.in_raw_block = true;
                self.raw_block_indent = self.current_indent;
                return;
            }
            if (isAlpha(next) or next == '-' or next == '_') {
                try self.scanClass();
                return;
            }
        }

        // Hash: either #id, #{interpolation}, or #[tag interpolation]
        if (c == '#') {
            const next = self.peekNext();
            if (next == '{') {
                self.advance();
                self.advance();
                try self.addToken(.interp_start, "#{");
                return;
            }
            if (next == '[') {
                self.advance();
                self.advance();
                try self.addToken(.tag_interp_start, "#[");
                return;
            }
            if (isAlpha(next) or next == '-' or next == '_') {
                try self.scanId();
                return;
            }
        }

        // Unescaped interpolation: !{
        if (c == '!' and self.peekNext() == '{') {
            self.advance();
            self.advance();
            try self.addToken(.interp_start_unesc, "!{");
            return;
        }

        // Attributes: (...)
        if (c == '(') {
            try self.scanAttributes();
            return;
        }

        // Pipe text: | text
        if (c == '|') {
            try self.scanPipeText();
            return;
        }

        // Literal HTML: lines starting with <
        if (c == '<') {
            try self.scanLiteralHtml();
            return;
        }

        // Buffered output: = expression
        if (c == '=') {
            self.advance();
            try self.addToken(.buffered_text, "=");
            try self.scanInlineText();
            return;
        }

        // Unescaped output: != expression
        if (c == '!' and self.peekNext() == '=') {
            self.advance();
            self.advance();
            try self.addToken(.unescaped_text, "!=");
            try self.scanInlineText();
            return;
        }

        // Mixin call: +name
        if (c == '+') {
            try self.scanMixinCall();
            return;
        }

        // Block expansion: tag: nested
        if (c == ':') {
            self.advance();
            try self.addToken(.colon, ":");
            return;
        }

        // Attribute spread: &attributes(obj)
        if (c == '&') {
            try self.scanAmpersandAttrs();
            return;
        }

        // Interpolation end
        if (c == '}') {
            self.advance();
            try self.addToken(.interp_end, "}");
            return;
        }

        // Tag name or keyword
        if (isAlpha(c) or c == '_') {
            try self.scanTagOrKeyword();
            return;
        }

        // Fallback: treat remaining content as text
        try self.scanInlineText();
    }

    /// Processes leading whitespace at line start to emit indent/dedent tokens.
    /// Measures indentation at current position and advances past whitespace.
    /// Returns the indent level (spaces=1, tabs=2).
    fn measureIndent(self: *Lexer) usize {
        var indent: usize = 0;

        // Count spaces (1 each) and tabs (2 each)
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == ' ') {
                indent += 1;
                self.advance();
            } else if (c == '\t') {
                indent += 2;
                self.advance();
            } else {
                break;
            }
        }

        return indent;
    }

    /// Processes leading whitespace at line start to emit indent/dedent tokens.
    /// Tracks indentation levels on a stack to handle nested blocks.
    fn processIndentation(self: *Lexer) !void {
        const indent = self.measureIndent();

        // Empty lines don't affect indentation
        if (!self.isAtEnd() and (self.peek() == '\n' or self.peek() == '\r')) {
            return;
        }

        // Comment-only lines preserve current indent context
        if (!self.isAtEnd() and self.peek() == '/' and self.peekNext() == '/') {
            self.current_indent = indent;
            return;
        }

        self.current_indent = indent;
        const current_stack_indent = self.indent_stack.items[self.indent_stack.items.len - 1];

        if (indent > current_stack_indent) {
            // Deeper nesting: push new level and emit indent
            try self.indent_stack.append(self.allocator, indent);
            try self.addToken(.indent, "");
        } else if (indent < current_stack_indent) {
            // Shallower nesting: pop levels and emit dedents
            while (self.indent_stack.items.len > 1 and
                self.indent_stack.items[self.indent_stack.items.len - 1] > indent)
            {
                _ = self.indent_stack.pop();
                try self.addToken(.dedent, "");

                // Exit raw block mode when dedenting to or below original level
                if (self.in_raw_block and indent <= self.raw_block_indent) {
                    self.in_raw_block = false;
                }
            }
        }
    }

    /// Scans a comment (// or //-) until end of line.
    /// Unbuffered comments (//-) are not rendered in output.
    fn scanComment(self: *Lexer) !void {
        self.advance(); // skip first /
        self.advance(); // skip second /

        const is_unbuffered = self.peek() == '-';
        if (is_unbuffered) {
            self.advance();
        }

        const start = self.pos;
        while (!self.isAtEnd() and self.peek() != '\n' and self.peek() != '\r') {
            self.advance();
        }

        const value = self.source[start..self.pos];
        try self.addToken(if (is_unbuffered) .comment_unbuffered else .comment, value);
    }

    /// Scans a class selector: .classname
    /// After the class, checks for inline text if no more selectors follow.
    fn scanClass(self: *Lexer) !void {
        self.advance(); // skip .
        const start = self.pos;

        while (!self.isAtEnd()) {
            const c = self.peek();
            if (isAlphaNumeric(c) or c == '-' or c == '_') {
                self.advance();
            } else {
                break;
            }
        }

        try self.addToken(.class, self.source[start..self.pos]);

        // Check for inline text after class (if no more selectors/attrs follow)
        try self.tryInlineTextAfterSelector();
    }

    /// Scans an ID selector: #idname
    /// After the ID, checks for inline text if no more selectors follow.
    fn scanId(self: *Lexer) !void {
        self.advance(); // skip #
        const start = self.pos;

        while (!self.isAtEnd()) {
            const c = self.peek();
            if (isAlphaNumeric(c) or c == '-' or c == '_') {
                self.advance();
            } else {
                break;
            }
        }

        try self.addToken(.id, self.source[start..self.pos]);

        // Check for inline text after ID (if no more selectors/attrs follow)
        try self.tryInlineTextAfterSelector();
    }

    /// Scans attribute list: (name=value, name2=value2, boolean)
    /// Also handles mixin arguments: ('value', expr, name=value)
    /// Handles quoted strings, expressions, and boolean attributes.
    fn scanAttributes(self: *Lexer) !void {
        self.advance(); // skip (
        try self.addToken(.lparen, "(");

        while (!self.isAtEnd() and self.peek() != ')') {
            self.skipWhitespaceInAttrs();
            if (self.peek() == ')') break;

            // Comma separator
            if (self.peek() == ',') {
                self.advance();
                try self.addToken(.comma, ",");
                continue;
            }

            const c = self.peek();

            // Check for quoted attribute name: '(click)'='play()' or "(click)"="play()"
            if (c == '"' or c == '\'') {
                // Look ahead to see if this is a quoted attribute name (followed by =)
                const quote = c;
                var lookahead = self.pos + 1;
                while (lookahead < self.source.len and self.source[lookahead] != quote) {
                    lookahead += 1;
                }
                if (lookahead < self.source.len) {
                    lookahead += 1; // skip closing quote
                    // Skip whitespace
                    while (lookahead < self.source.len and (self.source[lookahead] == ' ' or self.source[lookahead] == '\t')) {
                        lookahead += 1;
                    }
                    // Check if followed by = (attribute name) or not (bare value)
                    if (lookahead < self.source.len and (self.source[lookahead] == '=' or
                        (self.source[lookahead] == '!' and lookahead + 1 < self.source.len and self.source[lookahead + 1] == '=')))
                    {
                        // This is a quoted attribute name
                        self.advance(); // skip opening quote
                        const name_start = self.pos;
                        while (!self.isAtEnd() and self.peek() != quote) {
                            self.advance();
                        }
                        const attr_name = self.source[name_start..self.pos];
                        if (self.peek() == quote) self.advance(); // skip closing quote
                        try self.addToken(.attr_name, attr_name);

                        self.skipWhitespaceInAttrs();

                        // Value assignment: = or !=
                        if (self.peek() == '!' and self.peekNext() == '=') {
                            self.advance();
                            self.advance();
                            try self.addToken(.attr_eq, "!=");
                            self.skipWhitespaceInAttrs();
                            try self.scanAttrValue();
                        } else if (self.peek() == '=') {
                            self.advance();
                            try self.addToken(.attr_eq, "=");
                            self.skipWhitespaceInAttrs();
                            try self.scanAttrValue();
                        }
                        continue;
                    }
                }
                // Not followed by =, treat as bare value (mixin argument)
                try self.scanAttrValue();
                continue;
            }

            // Check for bare value (mixin argument): starts with backtick, brace, bracket, or digit
            if (c == '`' or c == '{' or c == '[' or isDigit(c)) {
                // This is a bare value (mixin argument), not name=value
                try self.scanAttrValue();
                continue;
            }

            // Check for parenthesized attribute name: (click)='play()'
            // This is valid when preceded by comma or at start of attributes
            if (c == '(') {
                const name_start = self.pos;
                self.advance(); // skip (
                var paren_depth: usize = 1;
                while (!self.isAtEnd() and paren_depth > 0) {
                    const ch = self.peek();
                    if (ch == '(') {
                        paren_depth += 1;
                    } else if (ch == ')') {
                        paren_depth -= 1;
                    }
                    if (paren_depth > 0) self.advance();
                }
                if (self.peek() == ')') self.advance(); // skip closing )
                const attr_name = self.source[name_start..self.pos];
                try self.addToken(.attr_name, attr_name);

                self.skipWhitespaceInAttrs();

                // Value assignment: = or !=
                if (self.peek() == '!' and self.peekNext() == '=') {
                    self.advance();
                    self.advance();
                    try self.addToken(.attr_eq, "!=");
                    self.skipWhitespaceInAttrs();
                    try self.scanAttrValue();
                } else if (self.peek() == '=') {
                    self.advance();
                    try self.addToken(.attr_eq, "=");
                    self.skipWhitespaceInAttrs();
                    try self.scanAttrValue();
                }
                continue;
            }

            // Check for rest parameter: ...name
            const name_start = self.pos;
            if (c == '.' and self.peekAt(1) == '.' and self.peekAt(2) == '.') {
                // Skip the three dots, include them in attr_name
                self.advance();
                self.advance();
                self.advance();
            }

            // Attribute name (supports data-*, @event, :bind)
            while (!self.isAtEnd()) {
                const ch = self.peek();
                if (isAlphaNumeric(ch) or ch == '-' or ch == '_' or ch == ':' or ch == '@') {
                    self.advance();
                } else {
                    break;
                }
            }

            if (self.pos > name_start) {
                try self.addToken(.attr_name, self.source[name_start..self.pos]);
            } else {
                // No attribute name found - skip unknown character to prevent infinite loop
                // This can happen with operators like + in expressions
                self.advance();
                continue;
            }

            self.skipWhitespaceInAttrs();

            // Value assignment: = or !=
            if (self.peek() == '!' and self.peekNext() == '=') {
                self.advance();
                self.advance();
                try self.addToken(.attr_eq, "!=");
                self.skipWhitespaceInAttrs();
                try self.scanAttrValue();
            } else if (self.peek() == '=') {
                self.advance();
                try self.addToken(.attr_eq, "=");
                self.skipWhitespaceInAttrs();
                try self.scanAttrValue();
            }
            // No = means boolean attribute (e.g., checked, disabled)
        }

        if (self.peek() == ')') {
            self.advance();
            try self.addToken(.rparen, ")");

            // Check for inline text after attributes: a(href='...') Click me
            if (self.peek() == ' ') {
                const next = self.peekAt(1);
                // Don't consume if followed by selector, attr, or special syntax
                if (next != '.' and next != '#' and next != '(' and next != '=' and next != ':' and
                    next != '\n' and next != '\r' and next != 0)
                {
                    self.advance(); // skip space
                    try self.scanInlineText();
                }
            }
        }
    }

    /// Scans an attribute value: "string", 'string', `template`, {object}, or expression.
    /// Handles expression continuation with operators like + for string concatenation.
    /// Emits a single token for the entire expression (e.g., "btn btn-" + type).
    fn scanAttrValue(self: *Lexer) !void {
        const start = self.pos;
        var after_operator = false; // Track if we just passed an operator

        // Scan the complete expression including operators
        while (!self.isAtEnd()) {
            const c = self.peek();

            if (c == '"' or c == '\'') {
                // Quoted string
                const quote = c;
                self.advance();
                while (!self.isAtEnd() and self.peek() != quote) {
                    if (self.peek() == '\\' and self.peekNext() == quote) {
                        self.advance(); // skip backslash
                    }
                    self.advance();
                }
                if (self.peek() == quote) self.advance();
                after_operator = false;
            } else if (c == '`') {
                // Template literal
                self.advance();
                while (!self.isAtEnd() and self.peek() != '`') {
                    self.advance();
                }
                if (self.peek() == '`') self.advance();
                after_operator = false;
            } else if (c == '{') {
                // Object literal - scan matching braces
                var depth: usize = 0;
                while (!self.isAtEnd()) {
                    const ch = self.peek();
                    if (ch == '{') depth += 1;
                    if (ch == '}') {
                        depth -= 1;
                        self.advance();
                        if (depth == 0) break;
                        continue;
                    }
                    self.advance();
                }
                after_operator = false;
            } else if (c == '[') {
                // Array literal - scan matching brackets
                var depth: usize = 0;
                while (!self.isAtEnd()) {
                    const ch = self.peek();
                    if (ch == '[') depth += 1;
                    if (ch == ']') {
                        depth -= 1;
                        self.advance();
                        if (depth == 0) break;
                        continue;
                    }
                    self.advance();
                }
                after_operator = false;
            } else if (c == '(') {
                // Function call - scan matching parens
                var depth: usize = 0;
                while (!self.isAtEnd()) {
                    const ch = self.peek();
                    if (ch == '(') depth += 1;
                    if (ch == ')') {
                        depth -= 1;
                        self.advance();
                        if (depth == 0) break;
                        continue;
                    }
                    self.advance();
                }
                after_operator = false;
            } else if (c == ')' or c == ',') {
                // End of attribute value
                break;
            } else if (c == ' ' or c == '\t') {
                // Whitespace handling depends on context
                if (after_operator) {
                    // After an operator, skip whitespace and continue to get the operand
                    while (self.peek() == ' ' or self.peek() == '\t') {
                        self.advance();
                    }
                    after_operator = false;
                    continue;
                } else {
                    // Not after operator - check if followed by operator (continue) or not (end)
                    const ws_start = self.pos;
                    while (self.peek() == ' ' or self.peek() == '\t') {
                        self.advance();
                    }
                    const next = self.peek();
                    if (next == '+' or next == '-' or next == '*' or next == '/') {
                        // Operator follows - continue scanning (include whitespace)
                        continue;
                    } else {
                        // Not an operator - rewind and end
                        self.pos = ws_start;
                        break;
                    }
                }
            } else if (c == '+' or c == '-' or c == '*' or c == '/') {
                // Operator - include it and mark that we need to continue for the operand
                self.advance();
                after_operator = true;
            } else if (c == '\n' or c == '\r') {
                // Newline ends the value
                break;
            } else {
                // Regular character (alphanumeric, etc.)
                self.advance();
                after_operator = false;
            }
        }

        const value = std.mem.trim(u8, self.source[start..self.pos], " \t");
        if (value.len > 0) {
            try self.addToken(.attr_value, value);
        }
    }

    /// Scans an object literal {...} handling nested braces.
    /// Returns error if braces are unmatched.
    fn scanObjectLiteral(self: *Lexer) !void {
        const start = self.pos;
        var brace_depth: usize = 0;

        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == '{') {
                brace_depth += 1;
            } else if (c == '}') {
                if (brace_depth == 0) {
                    // Unmatched closing brace - shouldn't happen if called correctly
                    return LexerError.UnmatchedBrace;
                }
                brace_depth -= 1;
                if (brace_depth == 0) {
                    self.advance();
                    break;
                }
            }
            self.advance();
        }

        // Check for unterminated object literal
        if (brace_depth > 0) {
            return LexerError.UnterminatedString;
        }

        try self.addToken(.attr_value, self.source[start..self.pos]);
    }

    /// Scans an array literal [...] handling nested brackets.
    fn scanArrayLiteral(self: *Lexer) !void {
        const start = self.pos;
        var bracket_depth: usize = 0;

        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == '[') {
                bracket_depth += 1;
            } else if (c == ']') {
                if (bracket_depth == 0) {
                    return LexerError.UnmatchedBrace;
                }
                bracket_depth -= 1;
                if (bracket_depth == 0) {
                    self.advance();
                    break;
                }
            }
            self.advance();
        }

        if (bracket_depth > 0) {
            return LexerError.UnterminatedString;
        }

        try self.addToken(.attr_value, self.source[start..self.pos]);
    }

    /// Skips whitespace within attribute lists (allows multi-line attributes).
    /// Properly tracks line and column for error reporting.
    fn skipWhitespaceInAttrs(self: *Lexer) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            switch (c) {
                ' ', '\t' => self.advance(),
                '\n' => {
                    self.pos += 1;
                    self.line += 1;
                    self.column = 1;
                },
                '\r' => {
                    self.pos += 1;
                    if (!self.isAtEnd() and self.source[self.pos] == '\n') {
                        self.pos += 1;
                    }
                    self.line += 1;
                    self.column = 1;
                },
                else => break,
            }
        }
    }

    /// Scans pipe text: | followed by text content.
    fn scanPipeText(self: *Lexer) !void {
        self.advance(); // skip |
        if (self.peek() == ' ') self.advance(); // skip optional space

        try self.addToken(.pipe_text, "|");
        try self.scanInlineText();
    }

    /// Scans literal HTML: lines starting with < are passed through as-is.
    fn scanLiteralHtml(self: *Lexer) !void {
        const start = self.pos;

        // Scan until end of line
        while (!self.isAtEnd() and self.peek() != '\n' and self.peek() != '\r') {
            self.advance();
        }

        const html = self.source[start..self.pos];
        try self.addToken(.literal_html, html);
    }

    /// Scans a raw line of text (used inside dot blocks).
    /// Captures everything until end of line as a single text token.
    /// Preserves indentation relative to the base raw block indent.
    /// Takes line_start position to include proper indentation from source.
    fn scanRawLineFrom(self: *Lexer, line_start: usize) !void {
        // Scan until end of line
        while (!self.isAtEnd() and self.peek() != '\n' and self.peek() != '\r') {
            self.advance();
        }

        // Include all content from line_start, preserving the indentation from source
        if (self.pos > line_start) {
            const text = self.source[line_start..self.pos];
            try self.addToken(.text, text);
        }
    }

    /// Scans inline text until end of line, handling interpolation markers.
    /// Uses iterative approach instead of recursion to avoid stack overflow.
    fn scanInlineText(self: *Lexer) !void {
        if (self.peek() == ' ') self.advance(); // skip leading space

        while (!self.isAtEnd() and self.peek() != '\n' and self.peek() != '\r') {
            const start = self.pos;

            // Scan until interpolation or end of line
            while (!self.isAtEnd() and self.peek() != '\n' and self.peek() != '\r') {
                const c = self.peek();
                const next = self.peekNext();

                // Check for interpolation start: #{, !{, or #[
                if ((c == '#' or c == '!') and next == '{') {
                    break;
                }
                if (c == '#' and next == '[') {
                    break;
                }
                self.advance();
            }

            // Emit text before interpolation (if any)
            if (self.pos > start) {
                try self.addToken(.text, self.source[start..self.pos]);
            }

            // Handle interpolation if found
            if (!self.isAtEnd() and self.peek() != '\n' and self.peek() != '\r') {
                const c = self.peek();
                if (c == '#' and self.peekNext() == '{') {
                    self.advance();
                    self.advance();
                    try self.addToken(.interp_start, "#{");
                    try self.scanInterpolationContent();
                } else if (c == '!' and self.peekNext() == '{') {
                    self.advance();
                    self.advance();
                    try self.addToken(.interp_start_unesc, "!{");
                    try self.scanInterpolationContent();
                } else if (c == '#' and self.peekNext() == '[') {
                    self.advance();
                    self.advance();
                    try self.addToken(.tag_interp_start, "#[");
                    try self.scanTagInterpolation();
                }
            }
        }
    }

    /// Scans tag interpolation content: #[tag(attrs) text]
    /// This needs to handle the tag, optional attributes, optional text, and closing ]
    fn scanTagInterpolation(self: *Lexer) !void {
        // Skip whitespace
        while (self.peek() == ' ' or self.peek() == '\t') {
            self.advance();
        }

        // Scan tag name
        if (isAlpha(self.peek()) or self.peek() == '_') {
            const tag_start = self.pos;
            while (!self.isAtEnd()) {
                const c = self.peek();
                if (isAlphaNumeric(c) or c == '-' or c == '_') {
                    self.advance();
                } else {
                    break;
                }
            }
            try self.addToken(.tag, self.source[tag_start..self.pos]);
        }

        // Scan classes and ids (inline to avoid circular dependencies)
        while (self.peek() == '.' or self.peek() == '#') {
            if (self.peek() == '.') {
                // Inline class scanning
                self.advance(); // skip .
                const class_start = self.pos;
                while (!self.isAtEnd()) {
                    const c = self.peek();
                    if (isAlphaNumeric(c) or c == '-' or c == '_') {
                        self.advance();
                    } else {
                        break;
                    }
                }
                try self.addToken(.class, self.source[class_start..self.pos]);
            } else if (self.peek() == '#' and self.peekNext() != '[' and self.peekNext() != '{') {
                // Inline id scanning
                self.advance(); // skip #
                const id_start = self.pos;
                while (!self.isAtEnd()) {
                    const c = self.peek();
                    if (isAlphaNumeric(c) or c == '-' or c == '_') {
                        self.advance();
                    } else {
                        break;
                    }
                }
                try self.addToken(.id, self.source[id_start..self.pos]);
            } else {
                break;
            }
        }

        // Scan attributes if present (inline to avoid circular dependencies)
        if (self.peek() == '(') {
            self.advance(); // skip (
            try self.addToken(.lparen, "(");

            while (!self.isAtEnd() and self.peek() != ')') {
                // Skip whitespace
                while (self.peek() == ' ' or self.peek() == '\t' or self.peek() == '\n' or self.peek() == '\r') {
                    if (self.peek() == '\n' or self.peek() == '\r') {
                        self.line += 1;
                        self.column = 1;
                    }
                    self.advance();
                }
                if (self.peek() == ')') break;

                // Comma separator
                if (self.peek() == ',') {
                    self.advance();
                    try self.addToken(.comma, ",");
                    continue;
                }

                // Attribute name
                const name_start = self.pos;
                while (!self.isAtEnd()) {
                    const c = self.peek();
                    if (isAlphaNumeric(c) or c == '-' or c == '_' or c == ':' or c == '@') {
                        self.advance();
                    } else {
                        break;
                    }
                }
                if (self.pos > name_start) {
                    try self.addToken(.attr_name, self.source[name_start..self.pos]);
                }

                // Skip whitespace
                while (self.peek() == ' ' or self.peek() == '\t') {
                    self.advance();
                }

                // Value assignment
                if (self.peek() == '!' and self.peekNext() == '=') {
                    self.advance();
                    self.advance();
                    try self.addToken(.attr_eq, "!=");
                    while (self.peek() == ' ' or self.peek() == '\t') {
                        self.advance();
                    }
                    try self.scanAttrValue();
                } else if (self.peek() == '=') {
                    self.advance();
                    try self.addToken(.attr_eq, "=");
                    while (self.peek() == ' ' or self.peek() == '\t') {
                        self.advance();
                    }
                    try self.scanAttrValue();
                }
            }

            if (self.peek() == ')') {
                self.advance();
                try self.addToken(.rparen, ")");
            }
        }

        // Skip whitespace before text content
        while (self.peek() == ' ' or self.peek() == '\t') {
            self.advance();
        }

        // Scan text content until ] (handling nested #[ ])
        if (self.peek() != ']') {
            const text_start = self.pos;
            var bracket_depth: usize = 1;

            while (!self.isAtEnd() and bracket_depth > 0) {
                const c = self.peek();
                if (c == '#' and self.peekNext() == '[') {
                    bracket_depth += 1;
                    self.advance();
                } else if (c == ']') {
                    bracket_depth -= 1;
                    if (bracket_depth == 0) break;
                } else if (c == '\n' or c == '\r') {
                    break;
                }
                self.advance();
            }

            if (self.pos > text_start) {
                try self.addToken(.text, self.source[text_start..self.pos]);
            }
        }

        // Emit closing ]
        if (self.peek() == ']') {
            self.advance();
            try self.addToken(.tag_interp_end, "]");
        }
    }

    /// Scans interpolation content between { and }, handling nested braces.
    fn scanInterpolationContent(self: *Lexer) !void {
        const start = self.pos;
        var brace_depth: usize = 1;

        while (!self.isAtEnd() and brace_depth > 0) {
            const c = self.peek();
            if (c == '{') {
                brace_depth += 1;
            } else if (c == '}') {
                brace_depth -= 1;
                if (brace_depth == 0) break;
            }
            self.advance();
        }

        try self.addToken(.text, self.source[start..self.pos]);

        if (!self.isAtEnd() and self.peek() == '}') {
            self.advance();
            try self.addToken(.interp_end, "}");
        }
    }

    /// Scans a mixin call: +mixinName
    fn scanMixinCall(self: *Lexer) !void {
        self.advance(); // skip +
        const start = self.pos;

        while (!self.isAtEnd()) {
            const c = self.peek();
            if (isAlphaNumeric(c) or c == '-' or c == '_') {
                self.advance();
            } else {
                break;
            }
        }

        try self.addToken(.mixin_call, self.source[start..self.pos]);
    }

    /// Scans &attributes syntax for attribute spreading.
    fn scanAmpersandAttrs(self: *Lexer) !void {
        const start = self.pos;
        const remaining = self.source.len - self.pos;

        if (remaining >= 11 and std.mem.eql(u8, self.source[self.pos..][0..11], "&attributes")) {
            self.pos += 11;
            self.column += 11;
            try self.addToken(.ampersand_attrs, "&attributes");

            // Parse the (...) that follows &attributes
            if (self.peek() == '(') {
                self.advance(); // skip (
                const obj_start = self.pos;
                var paren_depth: usize = 1;

                while (!self.isAtEnd() and paren_depth > 0) {
                    const c = self.peek();
                    if (c == '(') {
                        paren_depth += 1;
                    } else if (c == ')') {
                        paren_depth -= 1;
                    }
                    if (paren_depth > 0) self.advance();
                }

                try self.addToken(.attr_value, self.source[obj_start..self.pos]);
                if (self.peek() == ')') self.advance(); // skip )
            }
        } else {
            // Lone & treated as text
            self.advance();
            try self.addToken(.text, self.source[start..self.pos]);
        }
    }

    /// Checks if inline text follows after a class/ID selector.
    /// Only scans inline text if the next char is space followed by non-selector content.
    fn tryInlineTextAfterSelector(self: *Lexer) !void {
        if (self.peek() != ' ') return;

        const next = self.peekAt(1);
        const next2 = self.peekAt(2);

        // Don't consume if followed by another selector, attribute, or special syntax
        // BUT: #{...} and #[...] are interpolation, not ID selectors
        const is_id_selector = next == '#' and next2 != '{' and next2 != '[';
        if (next == '.' or is_id_selector or next == '(' or next == '=' or next == ':' or
            next == '\n' or next == '\r' or next == 0)
        {
            return;
        }

        self.advance(); // skip space
        try self.scanInlineText();
    }

    /// Scans a tag name or keyword, then optionally inline text.
    /// Uses static map for O(1) keyword lookup.
    fn scanTagOrKeyword(self: *Lexer) !void {
        const start = self.pos;

        while (!self.isAtEnd()) {
            const c = self.peek();
            if (isAlphaNumeric(c) or c == '-' or c == '_') {
                self.advance();
            } else {
                break;
            }
        }

        const value = self.source[start..self.pos];

        // O(1) keyword lookup using static map
        const token_type = keywords.get(value) orelse .tag;

        try self.addToken(token_type, value);

        // Keywords that take expressions: scan rest of line as text
        // This allows `if user.description` to keep the dot notation intact
        switch (token_type) {
            .kw_if, .kw_unless, .kw_each, .kw_for, .kw_while, .kw_case, .kw_when, .kw_doctype, .kw_extends, .kw_include => {
                // Skip whitespace after keyword
                while (self.peek() == ' ' or self.peek() == '\t') {
                    self.advance();
                }
                // Scan rest of line as expression/path text
                if (!self.isAtEnd() and self.peek() != '\n') {
                    try self.scanExpressionText();
                }
            },
            .tag => {
                // Tags may have inline text: p Hello world
                if (self.peek() == ' ') {
                    const next = self.peekAt(1);
                    // Don't consume text if followed by selector/attr syntax
                    // Note: # followed by { is interpolation, not ID selector
                    const is_id_selector = next == '#' and self.peekAt(2) != '{';
                    if (next != '.' and !is_id_selector and next != '(' and next != '=' and next != ':') {
                        self.advance();
                        try self.scanInlineText();
                    }
                }
            },
            else => {},
        }
    }

    /// Scans expression text (rest of line) preserving dots and other chars.
    fn scanExpressionText(self: *Lexer) !void {
        const start = self.pos;

        // Scan until end of line
        while (!self.isAtEnd() and self.peek() != '\n') {
            self.advance();
        }

        const text = self.source[start..self.pos];
        if (text.len > 0) {
            try self.addToken(.text, text);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helper functions for character inspection and position management
    // ─────────────────────────────────────────────────────────────────────────

    /// Returns true if at end of source.
    inline fn isAtEnd(self: *const Lexer) bool {
        return self.pos >= self.source.len;
    }

    /// Returns current character or 0 if at end.
    inline fn peek(self: *const Lexer) u8 {
        if (self.pos >= self.source.len) return 0;
        return self.source[self.pos];
    }

    /// Returns next character or 0 if at/past end.
    inline fn peekNext(self: *const Lexer) u8 {
        if (self.pos + 1 >= self.source.len) return 0;
        return self.source[self.pos + 1];
    }

    /// Returns character at pos + offset or 0 if out of bounds.
    inline fn peekAt(self: *const Lexer, offset: usize) u8 {
        const target = self.pos + offset;
        if (target >= self.source.len) return 0;
        return self.source[target];
    }

    /// Advances position and column by one.
    inline fn advance(self: *Lexer) void {
        if (self.pos < self.source.len) {
            self.pos += 1;
            self.column += 1;
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Character classification utilities (inlined for performance)
// ─────────────────────────────────────────────────────────────────────────────

inline fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

inline fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

inline fn isAlphaNumeric(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "tokenize simple tag" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(allocator, "div");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqual(TokenType.tag, tokens[0].type);
    try std.testing.expectEqualStrings("div", tokens[0].value);
}

test "tokenize tag with class" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(allocator, "div.container");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(TokenType.tag, tokens[0].type);
    try std.testing.expectEqual(TokenType.class, tokens[1].type);
    try std.testing.expectEqualStrings("container", tokens[1].value);
}

test "tokenize tag with id" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(allocator, "div#main");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(TokenType.tag, tokens[0].type);
    try std.testing.expectEqual(TokenType.id, tokens[1].type);
    try std.testing.expectEqualStrings("main", tokens[1].value);
}

test "tokenize nested tags" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(allocator,
        \\div
        \\  p Hello
    );
    defer lexer.deinit();

    const tokens = try lexer.tokenize();

    var found_indent = false;
    var found_dedent = false;
    for (tokens) |token| {
        if (token.type == .indent) found_indent = true;
        if (token.type == .dedent) found_dedent = true;
    }
    try std.testing.expect(found_indent);
    try std.testing.expect(found_dedent);
}

test "tokenize attributes" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(allocator, "a(href=\"/link\" target=\"_blank\")");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();

    try std.testing.expectEqual(TokenType.tag, tokens[0].type);
    try std.testing.expectEqual(TokenType.lparen, tokens[1].type);
    try std.testing.expectEqual(TokenType.attr_name, tokens[2].type);
    try std.testing.expectEqualStrings("href", tokens[2].value);
    try std.testing.expectEqual(TokenType.attr_eq, tokens[3].type);
    try std.testing.expectEqual(TokenType.attr_value, tokens[4].type);
    // Quotes are preserved in token value for expression evaluation
    try std.testing.expectEqualStrings("\"/link\"", tokens[4].value);
}

test "tokenize interpolation" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(allocator, "p Hello #{name}!");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();

    var found_interp_start = false;
    var found_interp_end = false;
    for (tokens) |token| {
        if (token.type == .interp_start) found_interp_start = true;
        if (token.type == .interp_end) found_interp_end = true;
    }
    try std.testing.expect(found_interp_start);
    try std.testing.expect(found_interp_end);
}

test "tokenize multiple interpolations" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(allocator, "p #{a} and #{b} and #{c}");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();

    var interp_count: usize = 0;
    for (tokens) |token| {
        if (token.type == .interp_start) interp_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), interp_count);
}

test "tokenize if keyword" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(allocator, "if condition");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(TokenType.kw_if, tokens[0].type);
}

test "tokenize each keyword" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(allocator, "each item in items");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(TokenType.kw_each, tokens[0].type);
    // Rest of line is captured as text for parser to handle
    try std.testing.expectEqual(TokenType.text, tokens[1].type);
    try std.testing.expectEqualStrings("item in items", tokens[1].value);
}

test "tokenize mixin call" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(allocator, "+button");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(TokenType.mixin_call, tokens[0].type);
    try std.testing.expectEqualStrings("button", tokens[0].value);
}

test "tokenize comment" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(allocator, "// This is a comment");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(TokenType.comment, tokens[0].type);
}

test "tokenize unbuffered comment" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(allocator, "//- Hidden comment");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(TokenType.comment_unbuffered, tokens[0].type);
}

test "tokenize object literal in attributes" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(allocator, "div(style={color: 'red', nested: {a: 1}})");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();

    // Find the attr_value token with object literal
    var found_object = false;
    for (tokens) |token| {
        if (token.type == .attr_value and token.value.len > 0 and token.value[0] == '{') {
            found_object = true;
            break;
        }
    }
    try std.testing.expect(found_object);
}

test "tokenize dot block" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(allocator,
        \\script.
        \\  if (usingPug)
        \\    console.log('hi')
    );
    defer lexer.deinit();

    const tokens = try lexer.tokenize();

    var found_dot_block = false;
    var text_count: usize = 0;
    for (tokens) |token| {
        if (token.type == .dot_block) found_dot_block = true;
        if (token.type == .text) text_count += 1;
    }
    try std.testing.expect(found_dot_block);
    try std.testing.expectEqual(@as(usize, 2), text_count);
}
