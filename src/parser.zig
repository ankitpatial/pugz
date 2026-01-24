//! Pug Parser - Converts token stream into an AST.
//!
//! The parser processes tokens from the lexer and builds a hierarchical
//! AST representing the document structure. It handles:
//! - Indentation-based nesting via indent/dedent tokens
//! - Element construction (tag, classes, id, attributes)
//! - Control flow (if/else, each, while)
//! - Mixins, includes, and template inheritance
//!
//! ## Error Diagnostics
//! When parsing fails, call `getDiagnostic()` to get rich error info:
//! ```zig
//! var parser = Parser.init(allocator, tokens);
//! const doc = parser.parse() catch |err| {
//!     if (parser.getDiagnostic()) |diag| {
//!         std.debug.print("{}\n", .{diag});
//!     }
//!     return err;
//! };
//! ```

const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const diagnostic = @import("diagnostic.zig");

const Token = lexer.Token;
const TokenType = lexer.TokenType;
const Node = ast.Node;
const Attribute = ast.Attribute;
const TextSegment = ast.TextSegment;

pub const Diagnostic = diagnostic.Diagnostic;

/// Errors that can occur during parsing.
pub const ParserError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidSyntax,
    MissingCondition,
    MissingIterator,
    MissingCollection,
    MissingMixinName,
    MissingBlockName,
    MissingPath,
    OutOfMemory,
};

/// Combined error set for all parser operations.
pub const Error = ParserError || std.mem.Allocator.Error;

/// Parser for Pug templates.
///
/// Converts a token slice into an AST. Uses an arena allocator for all
/// AST node allocations, making cleanup simple and efficient.
pub const Parser = struct {
    tokens: []const Token,
    pos: usize,
    allocator: std.mem.Allocator,
    /// Original source text (for error snippets)
    source: ?[]const u8,
    /// Last error diagnostic (populated on error)
    last_diagnostic: ?Diagnostic,

    /// Creates a new parser for the given tokens.
    pub fn init(allocator: std.mem.Allocator, tokens: []const Token) Parser {
        return .{
            .tokens = tokens,
            .pos = 0,
            .allocator = allocator,
            .source = null,
            .last_diagnostic = null,
        };
    }

    /// Creates a parser with source text for better error messages.
    pub fn initWithSource(allocator: std.mem.Allocator, tokens: []const Token, source: []const u8) Parser {
        return .{
            .tokens = tokens,
            .pos = 0,
            .allocator = allocator,
            .source = source,
            .last_diagnostic = null,
        };
    }

    /// Returns the last error diagnostic, if any.
    /// Call this after parse() returns an error to get detailed error info.
    pub fn getDiagnostic(self: *const Parser) ?Diagnostic {
        return self.last_diagnostic;
    }

    /// Sets a diagnostic error with context from the current token.
    fn setDiagnostic(self: *Parser, message: []const u8, suggestion: ?[]const u8) void {
        const token = if (self.pos < self.tokens.len) self.tokens[self.pos] else self.tokens[self.tokens.len - 1];
        const source_line = if (self.source) |src|
            diagnostic.extractSourceLine(src, 0) // Would need position mapping
        else
            null;

        self.last_diagnostic = .{
            .line = @intCast(token.line),
            .column = @intCast(token.column),
            .message = message,
            .source_line = source_line,
            .suggestion = suggestion,
        };
    }

    /// Sets a diagnostic error for a specific token.
    fn setDiagnosticAtToken(self: *Parser, token: Token, message: []const u8, suggestion: ?[]const u8) void {
        self.last_diagnostic = .{
            .line = @intCast(token.line),
            .column = @intCast(token.column),
            .message = message,
            .source_line = null,
            .suggestion = suggestion,
        };
    }

    /// Parses all tokens and returns the document AST.
    pub fn parse(self: *Parser) Error!ast.Document {
        var nodes = std.ArrayList(Node).empty;
        errdefer nodes.deinit(self.allocator);

        var extends_path: ?[]const u8 = null;

        // Check for extends directive (must be first)
        if (self.check(.kw_extends)) {
            extends_path = try self.parseExtends();
            self.skipNewlines();
        }

        // Parse all top-level nodes
        while (!self.isAtEnd()) {
            self.skipNewlines();
            if (self.isAtEnd()) break;

            const node = try self.parseNode();
            if (node) |n| {
                try nodes.append(self.allocator, n);
            }
        }

        return .{
            .nodes = try nodes.toOwnedSlice(self.allocator),
            .extends_path = extends_path,
        };
    }

    /// Parses a single node based on current token.
    fn parseNode(self: *Parser) Error!?Node {
        self.skipNewlines();
        if (self.isAtEnd()) return null;

        const token = self.peek();

        return switch (token.type) {
            .tag => try self.parseElement(),
            .class, .id => try self.parseElement(), // div-less element
            .kw_doctype => try self.parseDoctype(),
            .kw_if => try self.parseConditional(),
            .kw_unless => try self.parseConditional(),
            .kw_each, .kw_for => try self.parseEach(),
            .kw_while => try self.parseWhile(),
            .kw_case => try self.parseCase(),
            .kw_mixin => try self.parseMixinDef(),
            .mixin_call => try self.parseMixinCall(),
            .kw_include => try self.parseInclude(),
            .kw_block => try self.parseBlock(),
            .kw_append => try self.parseBlockShorthand(.append),
            .kw_prepend => try self.parseBlockShorthand(.prepend),
            .pipe_text => try self.parsePipeText(),
            .comment, .comment_unbuffered => try self.parseComment(),
            .unbuffered_code => {
                // Unbuffered JS code (- var x = 1) - skip entire line
                _ = self.advance();
                return null;
            },
            .buffered_text => try self.parseBufferedCode(true),
            .unescaped_text => try self.parseBufferedCode(false),
            .text => try self.parseText(),
            .literal_html => try self.parseLiteralHtml(),
            .newline, .eof => null,
            .indent, .dedent => {
                // Consume structural tokens to prevent infinite loops
                _ = self.advance();
                return null;
            },
            else => {
                // Skip unknown tokens to prevent infinite loops
                _ = self.advance();
                return null;
            },
        };
    }

    /// Parses an HTML element with optional tag, classes, id, attributes, and children.
    fn parseElement(self: *Parser) Error!Node {
        var tag: []const u8 = "div"; // default tag
        var classes = std.ArrayList([]const u8).empty;
        var id: ?[]const u8 = null;
        var attributes = std.ArrayList(Attribute).empty;
        var spread_attributes: ?[]const u8 = null;
        var self_closing = false;

        errdefer classes.deinit(self.allocator);
        errdefer attributes.deinit(self.allocator);

        // Parse tag name if present
        if (self.check(.tag)) {
            tag = self.advance().value;
        }

        // Parse classes and ids in any order
        while (self.check(.class) or self.check(.id)) {
            if (self.check(.class)) {
                try classes.append(self.allocator, self.advance().value);
            } else if (self.check(.id)) {
                id = self.advance().value;
            }
        }

        // Parse attributes
        if (self.check(.lparen)) {
            _ = self.advance(); // skip (
            try self.parseAttributes(&attributes);
            if (self.check(.rparen)) {
                _ = self.advance(); // skip )
            }
        }

        // Parse additional classes and ids after attributes (e.g., a.foo(href='/').bar)
        while (self.check(.class) or self.check(.id)) {
            if (self.check(.class)) {
                try classes.append(self.allocator, self.advance().value);
            } else if (self.check(.id)) {
                id = self.advance().value;
            }
        }

        // Parse &attributes({...})
        if (self.check(.ampersand_attrs)) {
            _ = self.advance(); // skip &attributes
            if (self.check(.attr_value)) {
                spread_attributes = self.advance().value;
            }
        }

        // Check for self-closing marker (foo/ or foo(attr)/)
        if (self.check(.self_close)) {
            _ = self.advance();
            self_closing = true;
        }

        // Check for block expansion (`:`)
        if (self.check(.colon)) {
            _ = self.advance();
            self.skipWhitespace();

            // Parse the inline nested element
            var children = std.ArrayList(Node).empty;
            errdefer children.deinit(self.allocator);

            if (try self.parseNode()) |child| {
                try children.append(self.allocator, child);
            }

            return .{
                .element = .{
                    .tag = tag,
                    .classes = try classes.toOwnedSlice(self.allocator),
                    .id = id,
                    .attributes = try attributes.toOwnedSlice(self.allocator),
                    .spread_attributes = spread_attributes,
                    .children = try children.toOwnedSlice(self.allocator),
                    .self_closing = self_closing,
                    .inline_text = null,
                    .buffered_code = null,
                    .is_inline = true, // Block expansion renders children inline
                },
            };
        }

        // Parse inline text or buffered code if present
        var inline_text: ?[]TextSegment = null;
        var buffered_code: ?ast.Code = null;

        if (self.check(.buffered_text) or self.check(.unescaped_text)) {
            // Handle p= expr or p!= expr
            const escaped = self.peek().type == .buffered_text;
            _ = self.advance(); // skip = or !=

            // Get the expression
            var expr: []const u8 = "";
            if (self.check(.text)) {
                expr = self.advance().value;
            }
            buffered_code = .{ .expression = expr, .escaped = escaped };
        } else if (self.check(.text) or self.check(.interp_start) or self.check(.interp_start_unesc)) {
            inline_text = try self.parseTextSegments();
        }

        // Check for dot block (raw text)
        if (self.check(.dot_block)) {
            _ = self.advance();
            self.skipNewlines();

            // Parse raw text block
            if (self.check(.indent)) {
                _ = self.advance();
                const raw_content = try self.parseRawTextBlock();

                var children = std.ArrayList(Node).empty;
                errdefer children.deinit(self.allocator);
                try children.append(self.allocator, .{ .raw_text = .{ .content = raw_content } });

                return .{ .element = .{
                    .tag = tag,
                    .classes = try classes.toOwnedSlice(self.allocator),
                    .id = id,
                    .attributes = try attributes.toOwnedSlice(self.allocator),
                    .spread_attributes = spread_attributes,
                    .children = try children.toOwnedSlice(self.allocator),
                    .self_closing = self_closing,
                    .inline_text = inline_text,
                    .buffered_code = buffered_code,
                } };
            }
        }

        // Skip newline after element declaration
        self.skipNewlines();

        // Parse children if indented
        var children = std.ArrayList(Node).empty;
        errdefer children.deinit(self.allocator);

        if (self.check(.indent)) {
            _ = self.advance();
            try self.parseChildren(&children);
        }

        return .{ .element = .{
            .tag = tag,
            .classes = try classes.toOwnedSlice(self.allocator),
            .id = id,
            .attributes = try attributes.toOwnedSlice(self.allocator),
            .spread_attributes = spread_attributes,
            .children = try children.toOwnedSlice(self.allocator),
            .self_closing = self_closing,
            .inline_text = inline_text,
            .buffered_code = buffered_code,
        } };
    }

    /// Parses attributes within parentheses.
    fn parseAttributes(self: *Parser, attributes: *std.ArrayList(Attribute)) Error!void {
        while (!self.check(.rparen) and !self.isAtEnd()) {
            // Skip commas
            if (self.check(.comma)) {
                _ = self.advance();
                continue;
            }

            // Parse attribute name
            if (!self.check(.attr_name)) break;
            const name = self.advance().value;

            // Check for value
            var value: ?[]const u8 = null;
            var escaped = true;

            if (self.check(.attr_eq)) {
                const eq_token = self.advance();
                escaped = !std.mem.eql(u8, eq_token.value, "!=");

                if (self.check(.attr_value)) {
                    value = self.advance().value;
                }
            }

            try attributes.append(self.allocator, .{
                .name = name,
                .value = value,
                .escaped = escaped,
            });
        }
    }

    /// Parses text segments (literals and interpolations).
    fn parseTextSegments(self: *Parser) Error![]TextSegment {
        var segments = std.ArrayList(TextSegment).empty;
        errdefer segments.deinit(self.allocator);

        while (self.check(.text) or self.check(.interp_start) or self.check(.interp_start_unesc) or self.check(.tag_interp_start)) {
            if (self.check(.text)) {
                try segments.append(self.allocator, .{ .literal = self.advance().value });
            } else if (self.check(.interp_start)) {
                _ = self.advance(); // skip #{
                if (self.check(.text)) {
                    try segments.append(self.allocator, .{ .interp_escaped = self.advance().value });
                }
                if (self.check(.interp_end)) {
                    _ = self.advance(); // skip }
                }
            } else if (self.check(.interp_start_unesc)) {
                _ = self.advance(); // skip !{
                if (self.check(.text)) {
                    try segments.append(self.allocator, .{ .interp_unescaped = self.advance().value });
                }
                if (self.check(.interp_end)) {
                    _ = self.advance(); // skip }
                }
            } else if (self.check(.tag_interp_start)) {
                const inline_tag = try self.parseTagInterpolation();
                try segments.append(self.allocator, .{ .interp_tag = inline_tag });
            }
        }

        return segments.toOwnedSlice(self.allocator);
    }

    /// Parses tag interpolation: #[tag.class#id(attrs) text]
    fn parseTagInterpolation(self: *Parser) Error!ast.InlineTag {
        _ = self.advance(); // skip #[

        var tag: []const u8 = "span"; // default tag
        var classes = std.ArrayList([]const u8).empty;
        var id: ?[]const u8 = null;
        var attributes = std.ArrayList(Attribute).empty;

        errdefer classes.deinit(self.allocator);
        errdefer attributes.deinit(self.allocator);

        // Parse tag name if present
        if (self.check(.tag)) {
            tag = self.advance().value;
        }

        // Parse classes and ids
        while (self.check(.class) or self.check(.id)) {
            if (self.check(.class)) {
                try classes.append(self.allocator, self.advance().value);
            } else if (self.check(.id)) {
                id = self.advance().value;
            }
        }

        // Parse attributes if present
        if (self.check(.lparen)) {
            _ = self.advance(); // skip (
            try self.parseAttributes(&attributes);
            if (self.check(.rparen)) {
                _ = self.advance(); // skip )
            }
        }

        // Parse inner text segments (may contain nested interpolations)
        var text_segments = std.ArrayList(TextSegment).empty;
        errdefer text_segments.deinit(self.allocator);

        while (!self.check(.tag_interp_end) and !self.check(.newline) and !self.isAtEnd()) {
            if (self.check(.text)) {
                try text_segments.append(self.allocator, .{ .literal = self.advance().value });
            } else if (self.check(.interp_start)) {
                _ = self.advance(); // skip #{
                if (self.check(.text)) {
                    try text_segments.append(self.allocator, .{ .interp_escaped = self.advance().value });
                }
                if (self.check(.interp_end)) {
                    _ = self.advance(); // skip }
                }
            } else if (self.check(.interp_start_unesc)) {
                _ = self.advance(); // skip !{
                if (self.check(.text)) {
                    try text_segments.append(self.allocator, .{ .interp_unescaped = self.advance().value });
                }
                if (self.check(.interp_end)) {
                    _ = self.advance(); // skip }
                }
            } else if (self.check(.tag_interp_start)) {
                // Nested tag interpolation
                const nested_tag = try self.parseTagInterpolation();
                try text_segments.append(self.allocator, .{ .interp_tag = nested_tag });
            } else {
                break;
            }
        }

        // Skip closing ]
        if (self.check(.tag_interp_end)) {
            _ = self.advance();
        }

        return .{
            .tag = tag,
            .classes = try classes.toOwnedSlice(self.allocator),
            .id = id,
            .attributes = try attributes.toOwnedSlice(self.allocator),
            .text_segments = try text_segments.toOwnedSlice(self.allocator),
        };
    }

    /// Parses children within an indented block.
    fn parseChildren(self: *Parser, children: *std.ArrayList(Node)) Error!void {
        while (!self.check(.dedent) and !self.isAtEnd()) {
            self.skipNewlines();
            if (self.check(.dedent) or self.isAtEnd()) break;

            if (try self.parseNode()) |child| {
                try children.append(self.allocator, child);
            }
        }

        // Consume dedent
        if (self.check(.dedent)) {
            _ = self.advance();
        }
    }

    /// Parses a raw text block (after `.`).
    fn parseRawTextBlock(self: *Parser) Error![]const u8 {
        var lines = std.ArrayList(u8).empty;
        errdefer lines.deinit(self.allocator);

        var line_count: usize = 0;
        while (!self.check(.dedent) and !self.isAtEnd()) {
            if (self.check(.text)) {
                // Add newline before each line except the first
                if (line_count > 0) {
                    try lines.append(self.allocator, '\n');
                }
                line_count += 1;
                const text = self.advance().value;
                try lines.appendSlice(self.allocator, text);
            } else if (self.check(.newline)) {
                _ = self.advance();
            } else {
                break;
            }
        }

        // Add trailing newline only for multi-line content (for proper formatting)
        if (line_count > 1) {
            try lines.append(self.allocator, '\n');
        }

        if (self.check(.dedent)) {
            _ = self.advance();
        }

        return lines.toOwnedSlice(self.allocator);
    }

    /// Parses doctype declaration.
    fn parseDoctype(self: *Parser) Error!Node {
        _ = self.advance(); // skip 'doctype'

        // Get the doctype value (rest of line), defaults to "html" if empty
        var value: []const u8 = "html";
        if (self.check(.text)) {
            value = self.advance().value;
        }

        return .{ .doctype = .{ .value = value } };
    }

    /// Parses conditional (if/else if/else/unless).
    fn parseConditional(self: *Parser) Error!Node {
        var branches = std.ArrayList(ast.Conditional.Branch).empty;
        errdefer branches.deinit(self.allocator);

        // Parse initial if/unless
        const is_unless = self.check(.kw_unless);
        _ = self.advance(); // skip if/unless

        // Parse condition (rest of line as text)
        const condition = try self.parseRestOfLine();

        self.skipNewlines();

        // Parse body
        var body = std.ArrayList(Node).empty;
        errdefer body.deinit(self.allocator);

        if (self.check(.indent)) {
            _ = self.advance();
            try self.parseChildren(&body);
        }

        try branches.append(self.allocator, .{
            .condition = condition,
            .is_unless = is_unless,
            .children = try body.toOwnedSlice(self.allocator),
        });

        // Parse else if / else branches
        while (self.check(.kw_else)) {
            _ = self.advance(); // skip else

            var else_condition: ?[]const u8 = null;
            const else_is_unless = false;

            // Check for "else if"
            if (self.check(.kw_if)) {
                _ = self.advance();
                else_condition = try self.parseRestOfLine();
            }

            self.skipNewlines();

            var else_body = std.ArrayList(Node).empty;
            errdefer else_body.deinit(self.allocator);

            if (self.check(.indent)) {
                _ = self.advance();
                try self.parseChildren(&else_body);
            }

            try branches.append(self.allocator, .{
                .condition = else_condition,
                .is_unless = else_is_unless,
                .children = try else_body.toOwnedSlice(self.allocator),
            });

            // Plain else (no condition) is the last branch
            if (else_condition == null) break;
        }

        return .{ .conditional = .{
            .branches = try branches.toOwnedSlice(self.allocator),
        } };
    }

    /// Parses each loop.
    fn parseEach(self: *Parser) Error!Node {
        _ = self.advance(); // skip 'each' or 'for'

        // Parse: each value[, index] in collection
        var value_name: []const u8 = "";
        var index_name: ?[]const u8 = null;
        var collection: []const u8 = "";

        // The lexer captures "item in items" or "item, idx in items" as a single text token
        if (self.check(.text)) {
            const text = self.advance().value;

            // Parse: value[, index] in collection
            // Find "in " to split the text
            if (std.mem.indexOf(u8, text, " in ")) |in_pos| {
                const before_in = std.mem.trim(u8, text[0..in_pos], " \t");
                collection = std.mem.trim(u8, text[in_pos + 4 ..], " \t");

                // Check for comma (index variable)
                if (std.mem.indexOf(u8, before_in, ",")) |comma_pos| {
                    value_name = std.mem.trim(u8, before_in[0..comma_pos], " \t");
                    index_name = std.mem.trim(u8, before_in[comma_pos + 1 ..], " \t");
                } else {
                    value_name = before_in;
                }
            } else {
                self.setDiagnostic(
                    "Missing collection in 'each' loop - expected 'in' keyword",
                    "Use syntax: each item in collection",
                );
                return ParserError.MissingCollection;
            }
        } else if (self.check(.tag)) {
            // Fallback: lexer produced individual tokens
            value_name = self.advance().value;

            // Check for index: each val, idx in ...
            if (self.check(.comma)) {
                _ = self.advance();
                if (self.check(.tag)) {
                    index_name = self.advance().value;
                }
            }

            // Expect 'in'
            if (self.check(.kw_in)) {
                _ = self.advance();
            }

            // Parse collection expression
            collection = try self.parseRestOfLine();
        } else {
            self.setDiagnostic(
                "Missing iterator variable in 'each' loop",
                "Use syntax: each item in collection",
            );
            return ParserError.MissingIterator;
        }

        self.skipNewlines();

        // Parse body
        var body = std.ArrayList(Node).empty;
        errdefer body.deinit(self.allocator);

        if (self.check(.indent)) {
            _ = self.advance();
            try self.parseChildren(&body);
        }

        // Check for else branch
        var else_children = std.ArrayList(Node).empty;
        errdefer else_children.deinit(self.allocator);

        if (self.check(.kw_else)) {
            _ = self.advance();
            self.skipNewlines();

            if (self.check(.indent)) {
                _ = self.advance();
                try self.parseChildren(&else_children);
            }
        }

        return .{ .each = .{
            .value_name = value_name,
            .index_name = index_name,
            .collection = collection,
            .children = try body.toOwnedSlice(self.allocator),
            .else_children = try else_children.toOwnedSlice(self.allocator),
        } };
    }

    /// Parses while loop.
    fn parseWhile(self: *Parser) Error!Node {
        _ = self.advance(); // skip 'while'

        const condition = try self.parseRestOfLine();

        self.skipNewlines();

        var body = std.ArrayList(Node).empty;
        errdefer body.deinit(self.allocator);

        if (self.check(.indent)) {
            _ = self.advance();
            try self.parseChildren(&body);
        }

        return .{ .@"while" = .{
            .condition = condition,
            .children = try body.toOwnedSlice(self.allocator),
        } };
    }

    /// Parses case/switch statement.
    fn parseCase(self: *Parser) Error!Node {
        _ = self.advance(); // skip 'case'

        const expression = try self.parseRestOfLine();

        self.skipNewlines();

        var whens = std.ArrayList(ast.Case.When).empty;
        errdefer whens.deinit(self.allocator);

        var default_children = std.ArrayList(Node).empty;
        errdefer default_children.deinit(self.allocator);

        // Parse indented when/default clauses
        if (self.check(.indent)) {
            _ = self.advance();

            while (!self.check(.dedent) and !self.isAtEnd()) {
                self.skipNewlines();

                if (self.check(.kw_when)) {
                    _ = self.advance(); // skip 'when'

                    // Parse the value (rest of line or until colon for block expansion)
                    var value: []const u8 = "";
                    if (self.check(.tag) or self.check(.text)) {
                        value = self.advance().value;
                    } else {
                        value = try self.parseRestOfLine();
                    }

                    var when_children = std.ArrayList(Node).empty;
                    errdefer when_children.deinit(self.allocator);
                    var has_break = false;

                    // Check for block expansion (: element)
                    if (self.check(.colon)) {
                        _ = self.advance();
                        self.skipWhitespace();
                        if (try self.parseNode()) |child| {
                            try when_children.append(self.allocator, child);
                        }
                    } else {
                        self.skipNewlines();

                        // Parse indented children
                        if (self.check(.indent)) {
                            _ = self.advance();

                            // Check for explicit break (- break)
                            if (self.check(.buffered_text)) {
                                const next_tok = self.peek();
                                if (next_tok.type == .text and std.mem.eql(u8, std.mem.trim(u8, next_tok.value, " \t"), "break")) {
                                    _ = self.advance(); // skip =
                                    _ = self.advance(); // skip break
                                    has_break = true;
                                }
                            }

                            if (!has_break) {
                                try self.parseChildren(&when_children);
                            } else {
                                // Skip remaining children after break
                                while (!self.check(.dedent) and !self.isAtEnd()) {
                                    _ = self.advance();
                                }
                            }

                            if (self.check(.dedent)) {
                                _ = self.advance();
                            }
                        }
                        // Empty body = fall-through (children stays empty)
                    }

                    try whens.append(self.allocator, .{
                        .value = value,
                        .children = try when_children.toOwnedSlice(self.allocator),
                        .has_break = has_break,
                    });
                } else if (self.check(.kw_default)) {
                    _ = self.advance(); // skip 'default'

                    // Check for block expansion (: element)
                    if (self.check(.colon)) {
                        _ = self.advance();
                        self.skipWhitespace();
                        if (try self.parseNode()) |child| {
                            try default_children.append(self.allocator, child);
                        }
                    } else {
                        self.skipNewlines();

                        if (self.check(.indent)) {
                            _ = self.advance();
                            try self.parseChildren(&default_children);
                            if (self.check(.dedent)) {
                                _ = self.advance();
                            }
                        }
                    }
                } else if (self.check(.dedent)) {
                    break;
                } else {
                    // Skip unknown tokens
                    _ = self.advance();
                }
            }

            if (self.check(.dedent)) {
                _ = self.advance();
            }
        }

        return .{ .case = .{
            .expression = expression,
            .whens = try whens.toOwnedSlice(self.allocator),
            .default_children = try default_children.toOwnedSlice(self.allocator),
        } };
    }

    /// Parses mixin definition.
    fn parseMixinDef(self: *Parser) Error!Node {
        _ = self.advance(); // skip 'mixin'

        // Parse mixin name
        var name: []const u8 = "";
        if (self.check(.tag)) {
            name = self.advance().value;
        } else {
            self.setDiagnostic(
                "Missing mixin name after 'mixin' keyword",
                "Use syntax: mixin name(params)",
            );
            return ParserError.MissingMixinName;
        }

        // Parse parameters if present
        var params = std.ArrayList([]const u8).empty;
        var defaults = std.ArrayList(?[]const u8).empty;
        errdefer params.deinit(self.allocator);
        errdefer defaults.deinit(self.allocator);

        var has_rest = false;

        if (self.check(.lparen)) {
            _ = self.advance();

            while (!self.check(.rparen) and !self.isAtEnd()) {
                if (self.check(.comma)) {
                    _ = self.advance();
                    continue;
                }

                if (self.check(.attr_name) or self.check(.tag)) {
                    const param_name = self.advance().value;

                    // Check for rest parameter
                    if (std.mem.startsWith(u8, param_name, "...")) {
                        try params.append(self.allocator, param_name[3..]);
                        try defaults.append(self.allocator, null);
                        has_rest = true;
                    } else {
                        try params.append(self.allocator, param_name);

                        // Check for default value
                        if (self.check(.attr_eq)) {
                            _ = self.advance();
                            if (self.check(.attr_value)) {
                                try defaults.append(self.allocator, self.advance().value);
                            } else {
                                try defaults.append(self.allocator, null);
                            }
                        } else {
                            try defaults.append(self.allocator, null);
                        }
                    }
                } else {
                    break;
                }
            }

            if (self.check(.rparen)) {
                _ = self.advance();
            }
        }

        self.skipNewlines();

        // Parse body
        var body = std.ArrayList(Node).empty;
        errdefer body.deinit(self.allocator);

        if (self.check(.indent)) {
            _ = self.advance();
            try self.parseChildren(&body);
        }

        return .{ .mixin_def = .{
            .name = name,
            .params = try params.toOwnedSlice(self.allocator),
            .defaults = try defaults.toOwnedSlice(self.allocator),
            .has_rest = has_rest,
            .children = try body.toOwnedSlice(self.allocator),
        } };
    }

    /// Parses mixin call.
    fn parseMixinCall(self: *Parser) Error!Node {
        const name = self.advance().value; // +name

        var args = std.ArrayList([]const u8).empty;
        var attributes = std.ArrayList(Attribute).empty;
        errdefer args.deinit(self.allocator);
        errdefer attributes.deinit(self.allocator);

        // Parse arguments
        if (self.check(.lparen)) {
            _ = self.advance();

            while (!self.check(.rparen) and !self.isAtEnd()) {
                if (self.check(.comma)) {
                    _ = self.advance();
                    continue;
                }

                if (self.check(.attr_value)) {
                    try args.append(self.allocator, self.advance().value);
                } else if (self.check(.attr_name)) {
                    // Could be named arg or regular arg
                    const val = self.advance().value;
                    try args.append(self.allocator, val);
                } else {
                    break;
                }
            }

            if (self.check(.rparen)) {
                _ = self.advance();
            }
        }

        // Parse attributes passed to mixin
        if (self.check(.lparen)) {
            _ = self.advance();
            try self.parseAttributes(&attributes);
            if (self.check(.rparen)) {
                _ = self.advance();
            }
        }

        self.skipNewlines();

        // Parse block content
        var block_children = std.ArrayList(Node).empty;
        errdefer block_children.deinit(self.allocator);

        if (self.check(.indent)) {
            _ = self.advance();
            try self.parseChildren(&block_children);
        }

        return .{ .mixin_call = .{
            .name = name,
            .args = try args.toOwnedSlice(self.allocator),
            .attributes = try attributes.toOwnedSlice(self.allocator),
            .block_children = try block_children.toOwnedSlice(self.allocator),
        } };
    }

    /// Parses include directive.
    fn parseInclude(self: *Parser) Error!Node {
        _ = self.advance(); // skip 'include'

        var filter: ?[]const u8 = null;

        // Check for filter :markdown
        if (self.check(.colon)) {
            _ = self.advance();
            if (self.check(.tag)) {
                filter = self.advance().value;
            }
        }

        // Parse path
        const path = try self.parseRestOfLine();

        return .{ .include = .{
            .path = path,
            .filter = filter,
        } };
    }

    /// Parses extends directive.
    fn parseExtends(self: *Parser) Error![]const u8 {
        _ = self.advance(); // skip 'extends'
        return try self.parseRestOfLine();
    }

    /// Parses block directive.
    fn parseBlock(self: *Parser) Error!Node {
        _ = self.advance(); // skip 'block'

        var mode: ast.Block.Mode = .replace;

        // Check for append/prepend (may be tokenized as tag or keyword)
        if (self.check(.tag)) {
            const modifier = self.peek().value;
            if (std.mem.eql(u8, modifier, "append")) {
                mode = .append;
                _ = self.advance();
            } else if (std.mem.eql(u8, modifier, "prepend")) {
                mode = .prepend;
                _ = self.advance();
            }
        } else if (self.check(.kw_append)) {
            mode = .append;
            _ = self.advance();
        } else if (self.check(.kw_prepend)) {
            mode = .prepend;
            _ = self.advance();
        }

        // Parse block name - if no name follows, this is a mixin block placeholder
        var name: []const u8 = "";
        if (self.check(.tag)) {
            name = self.advance().value;
        } else if (self.check(.text)) {
            name = std.mem.trim(u8, self.advance().value, " \t");
        } else if (self.check(.newline) or self.check(.eof) or self.check(.indent) or self.check(.dedent)) {
            // No name - this is a mixin block placeholder
            return .{ .mixin_block = {} };
        } else {
            self.setDiagnostic(
                "Missing block name after 'block' keyword",
                "Use syntax: block name",
            );
            return ParserError.MissingBlockName;
        }

        self.skipNewlines();

        // Parse body
        var body = std.ArrayList(Node).empty;
        errdefer body.deinit(self.allocator);

        if (self.check(.indent)) {
            _ = self.advance();
            try self.parseChildren(&body);
        }

        return .{ .block = .{
            .name = name,
            .mode = mode,
            .children = try body.toOwnedSlice(self.allocator),
        } };
    }

    /// Parses shorthand block syntax: `append name` or `prepend name`
    fn parseBlockShorthand(self: *Parser, mode: ast.Block.Mode) Error!Node {
        _ = self.advance(); // skip 'append' or 'prepend'

        // Parse block name
        var name: []const u8 = "";
        if (self.check(.tag)) {
            name = self.advance().value;
        } else if (self.check(.text)) {
            name = std.mem.trim(u8, self.advance().value, " \t");
        } else {
            self.setDiagnostic(
                "Missing block name after 'append' or 'prepend'",
                "Use syntax: append blockname or prepend blockname",
            );
            return ParserError.MissingBlockName;
        }

        self.skipNewlines();

        // Parse body
        var body = std.ArrayList(Node).empty;
        errdefer body.deinit(self.allocator);

        if (self.check(.indent)) {
            _ = self.advance();
            try self.parseChildren(&body);
        }

        return .{ .block = .{
            .name = name,
            .mode = mode,
            .children = try body.toOwnedSlice(self.allocator),
        } };
    }

    /// Parses pipe text.
    fn parsePipeText(self: *Parser) Error!Node {
        _ = self.advance(); // skip |

        const segments = try self.parseTextSegments();

        return .{ .text = .{ .segments = segments } };
    }

    /// Parses literal HTML (lines starting with <).
    fn parseLiteralHtml(self: *Parser) Error!Node {
        const html = self.advance().value;
        return .{ .raw_text = .{ .content = html } };
    }

    /// Parses comment.
    fn parseComment(self: *Parser) Error!Node {
        const rendered = self.check(.comment);
        const content = self.advance().value; // Preserve content exactly as captured (including leading space)

        self.skipNewlines();

        // Parse nested comment content ONLY if this is a block comment
        // Block comment: comment with no inline content, followed by indented block
        // e.g., "//" on its own line followed by indented content
        // vs inline comment: "// some text" which has no children
        var children = std.ArrayList(Node).empty;
        errdefer children.deinit(self.allocator);

        // Block comments can have indented content
        // This includes both empty comments (//) and comments with text (// block)
        // followed by indented content
        if (self.check(.indent)) {
            _ = self.advance();
            // Capture all content until dedent as raw text
            const raw_content = try self.parseBlockCommentContent();
            if (raw_content.len > 0) {
                try children.append(self.allocator, .{ .raw_text = .{ .content = raw_content } });
            }
        }

        return .{ .comment = .{
            .content = content,
            .rendered = rendered,
            .children = try children.toOwnedSlice(self.allocator),
        } };
    }

    /// Parses block comment content - collects raw text tokens until dedent
    fn parseBlockCommentContent(self: *Parser) Error![]const u8 {
        var lines = std.ArrayList(u8).empty;
        errdefer lines.deinit(self.allocator);

        while (!self.isAtEnd()) {
            const token = self.peek();

            switch (token.type) {
                .dedent => {
                    _ = self.advance();
                    break;
                },
                .newline => {
                    try lines.append(self.allocator, '\n');
                    _ = self.advance();
                },
                .text => {
                    // Raw text from comment block mode
                    try lines.appendSlice(self.allocator, token.value);
                    _ = self.advance();
                },
                .eof => break,
                else => {
                    // Skip any unexpected tokens
                    _ = self.advance();
                },
            }
        }

        return lines.toOwnedSlice(self.allocator);
    }

    /// Parses buffered code output (= or !=).
    fn parseBufferedCode(self: *Parser, escaped: bool) Error!Node {
        _ = self.advance(); // skip = or !=

        const expression = try self.parseRestOfLine();

        return .{ .code = .{
            .expression = expression,
            .escaped = escaped,
        } };
    }

    /// Parses plain text node.
    fn parseText(self: *Parser) Error!Node {
        const segments = try self.parseTextSegments();
        return .{ .text = .{ .segments = segments } };
    }

    /// Parses rest of line as text.
    fn parseRestOfLine(self: *Parser) Error![]const u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);

        while (!self.check(.newline) and !self.check(.indent) and !self.check(.dedent) and !self.isAtEnd()) {
            const token = self.advance();
            if (token.value.len > 0) {
                if (result.items.len > 0) {
                    try result.append(self.allocator, ' ');
                }
                try result.appendSlice(self.allocator, token.value);
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helper functions
    // ─────────────────────────────────────────────────────────────────────────

    /// Returns true if at end of tokens.
    fn isAtEnd(self: *const Parser) bool {
        return self.pos >= self.tokens.len or self.peek().type == .eof;
    }

    /// Returns current token without advancing.
    fn peek(self: *const Parser) Token {
        if (self.pos >= self.tokens.len) {
            return .{ .type = .eof, .value = "", .line = 0, .column = 0 };
        }
        return self.tokens[self.pos];
    }

    /// Returns true if current token matches the given type.
    fn check(self: *const Parser, token_type: TokenType) bool {
        if (self.isAtEnd()) return false;
        return self.peek().type == token_type;
    }

    /// Returns true if current token matches the given type and value.
    fn checkValue(self: *const Parser, token_type: TokenType, value: []const u8) bool {
        if (self.isAtEnd()) return false;
        const token = self.peek();
        return token.type == token_type and std.mem.eql(u8, token.value, value);
    }

    /// Advances and returns current token.
    fn advance(self: *Parser) Token {
        if (!self.isAtEnd()) {
            const token = self.tokens[self.pos];
            self.pos += 1;
            return token;
        }
        return .{ .type = .eof, .value = "", .line = 0, .column = 0 };
    }

    /// Skips newline tokens.
    fn skipNewlines(self: *Parser) void {
        while (self.check(.newline)) {
            _ = self.advance();
        }
    }

    /// Skips whitespace (spaces in tokens).
    fn skipWhitespace(self: *Parser) void {
        // Whitespace is mostly handled by lexer, but skip any stray newlines
        self.skipNewlines();
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "parse simple element" {
    const allocator = std.testing.allocator;

    var lex = lexer.Lexer.init(allocator, "div");
    defer lex.deinit();
    const tokens = try lex.tokenize();

    var parser = Parser.init(allocator, tokens);
    const doc = try parser.parse();

    try std.testing.expectEqual(@as(usize, 1), doc.nodes.len);
    try std.testing.expectEqualStrings("div", doc.nodes[0].element.tag);

    // Clean up
    allocator.free(doc.nodes[0].element.classes);
    allocator.free(doc.nodes[0].element.attributes);
    allocator.free(doc.nodes[0].element.children);
    allocator.free(doc.nodes);
}

test "parse element with class and id" {
    const allocator = std.testing.allocator;

    var lex = lexer.Lexer.init(allocator, "div#main.container.active");
    defer lex.deinit();
    const tokens = try lex.tokenize();

    var parser = Parser.init(allocator, tokens);
    const doc = try parser.parse();

    const elem = doc.nodes[0].element;
    try std.testing.expectEqualStrings("div", elem.tag);
    try std.testing.expectEqualStrings("main", elem.id.?);
    try std.testing.expectEqual(@as(usize, 2), elem.classes.len);
    try std.testing.expectEqualStrings("container", elem.classes[0]);
    try std.testing.expectEqualStrings("active", elem.classes[1]);

    // Clean up
    allocator.free(elem.classes);
    allocator.free(elem.attributes);
    allocator.free(elem.children);
    allocator.free(doc.nodes);
}

test "parse nested elements" {
    const allocator = std.testing.allocator;

    var lex = lexer.Lexer.init(allocator,
        \\div
        \\  p Hello
    );
    defer lex.deinit();
    const tokens = try lex.tokenize();

    var parser = Parser.init(allocator, tokens);
    const doc = try parser.parse();

    try std.testing.expectEqual(@as(usize, 1), doc.nodes.len);

    const div = doc.nodes[0].element;
    try std.testing.expectEqualStrings("div", div.tag);
    try std.testing.expectEqual(@as(usize, 1), div.children.len);

    const p = div.children[0].element;
    try std.testing.expectEqualStrings("p", p.tag);

    // Clean up nested structures
    if (p.inline_text) |text| allocator.free(text);
    allocator.free(p.classes);
    allocator.free(p.attributes);
    allocator.free(p.children);
    allocator.free(div.classes);
    allocator.free(div.attributes);
    allocator.free(div.children);
    allocator.free(doc.nodes);
}
