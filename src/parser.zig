const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

// Import token types from lexer
const lexer = @import("lexer.zig");
pub const TokenType = lexer.TokenType;
pub const TokenValue = lexer.TokenValue;
pub const Location = lexer.Location;
pub const TokenLoc = lexer.TokenLoc;
pub const Token = lexer.Token;

// ============================================================================
// Inline Tags (tags that are typically inline in HTML)
// ============================================================================

/// Comptime hash map for O(1) inline tag lookup instead of O(19) linear search
const inline_tags_map = std.StaticStringMap(void).initComptime(.{
    .{ "a", {} },
    .{ "abbr", {} },
    .{ "acronym", {} },
    .{ "b", {} },
    .{ "br", {} },
    .{ "code", {} },
    .{ "em", {} },
    .{ "font", {} },
    .{ "i", {} },
    .{ "img", {} },
    .{ "ins", {} },
    .{ "kbd", {} },
    .{ "map", {} },
    .{ "samp", {} },
    .{ "small", {} },
    .{ "span", {} },
    .{ "strong", {} },
    .{ "sub", {} },
    .{ "sup", {} },
});

inline fn isInlineTag(name: []const u8) bool {
    return inline_tags_map.has(name);
}

// ============================================================================
// AST Node Types
// ============================================================================

pub const NodeType = enum {
    Block,
    NamedBlock,
    Tag,
    InterpolatedTag,
    Text,
    Code,
    Comment,
    BlockComment,
    Doctype,
    Mixin,
    MixinBlock,
    Case,
    When,
    Conditional,
    While,
    Each,
    EachOf,
    Extends,
    Include,
    RawInclude,
    Filter,
    IncludeFilter,
    FileReference,
    YieldBlock,
    AttributeBlock,
    TypeHint, // Type annotation for compiled templates: //- @TypeOf(field): type
};

// ============================================================================
// AST Node - A tagged union representing all possible AST nodes
// ============================================================================

pub const Attribute = struct {
    name: []const u8,
    val: ?[]const u8,
    line: usize,
    column: usize,
    filename: ?[]const u8,
    must_escape: bool,
    val_owned: bool = false, // true if val was allocated and needs to be freed
    quoted: bool = false, // true if val was originally quoted (static string)
};

pub const AttributeBlock = struct {
    val: []const u8,
    line: usize,
    column: usize,
    filename: ?[]const u8,
};

pub const FileReference = struct {
    path: ?[]const u8,
    line: usize,
    column: usize,
    filename: ?[]const u8,
};

pub const Node = struct {
    type: NodeType,
    line: usize = 0,
    column: usize = 0,
    filename: ?[]const u8 = null,

    // Block fields
    nodes: std.ArrayListUnmanaged(*Node) = .{},

    // NamedBlock additional fields
    name: ?[]const u8 = null, // Also used for Tag, Mixin, Filter
    mode: ?[]const u8 = null, // "prepend", "append", "replace"

    // Tag fields
    self_closing: bool = false,
    attrs: std.ArrayListUnmanaged(Attribute) = .{},
    attribute_blocks: std.ArrayListUnmanaged(AttributeBlock) = .{},
    is_inline: bool = false,
    text_only: bool = false,
    self_closing_allowed: bool = false,

    // Text fields
    val: ?[]const u8 = null, // Also used for Code, Comment, Doctype, Case expr, When expr, Conditional test, While test
    is_html: bool = false,

    // Code fields
    buffer: bool = false,
    must_escape: bool = true,
    is_inline_code: bool = false,

    // Mixin fields
    args: ?[]const u8 = null,
    call: bool = false,

    // Each fields
    obj: ?[]const u8 = null,
    key: ?[]const u8 = null,

    // Conditional fields
    test_expr: ?[]const u8 = null, // "test" in JS
    consequent: ?*Node = null,
    alternate: ?*Node = null,

    // Extends/Include fields
    file: ?FileReference = null,

    // Include fields
    filters: std.ArrayListUnmanaged(*Node) = .{},

    // InterpolatedTag fields
    expr: ?[]const u8 = null,

    // When/Conditional debug field
    debug: bool = true,

    // TypeHint fields (for //- @TypeOf(field): type annotations)
    type_hint_field: ?[]const u8 = null, // Field name (e.g., "cartItems")
    type_hint_type: ?[]const u8 = null, // Type spec (e.g., "[]{name: []const u8}")

    // Memory ownership flags
    val_owned: bool = false, // true if val was allocated and needs to be freed

    pub fn deinit(self: *Node, allocator: Allocator) void {
        // Free owned val string
        if (self.val_owned) {
            if (self.val) |v| {
                allocator.free(v);
            }
        }

        // Free child nodes recursively
        for (self.nodes.items) |child| {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self.nodes.deinit(allocator);

        // Free attrs (including owned val strings)
        for (self.attrs.items) |attr| {
            if (attr.val_owned) {
                if (attr.val) |v| {
                    allocator.free(v);
                }
            }
        }
        self.attrs.deinit(allocator);

        // Free attribute_blocks
        self.attribute_blocks.deinit(allocator);

        // Free filters
        for (self.filters.items) |filter| {
            filter.deinit(allocator);
            allocator.destroy(filter);
        }
        self.filters.deinit(allocator);

        // Free consequent and alternate
        if (self.consequent) |c| {
            c.deinit(allocator);
            allocator.destroy(c);
        }
        if (self.alternate) |a| {
            a.deinit(allocator);
            allocator.destroy(a);
        }
    }

    pub fn addNode(self: *Node, allocator: Allocator, node: *Node) !void {
        try self.nodes.append(allocator, node);
    }
};

// ============================================================================
// Parser Error
// ============================================================================

pub const ParserErrorCode = enum {
    INVALID_TOKEN,
    BLOCK_IN_BUFFERED_CODE,
    BLOCK_OUTISDE_MIXIN,
    MIXIN_WITHOUT_BODY,
    RAW_INCLUDE_BLOCK,
    DUPLICATE_ID,
    DUPLICATE_ATTRIBUTE,
    UNEXPECTED_END,
};

pub const ParserError = struct {
    code: ParserErrorCode,
    message: []const u8,
    line: usize,
    column: usize,
    filename: ?[]const u8,
};

// ============================================================================
// Parser
// ============================================================================

pub const Parser = struct {
    allocator: Allocator,
    tokens: []const Token,
    pos: usize = 0,
    deferred: std.ArrayListUnmanaged(Token) = .{},
    filename: ?[]const u8 = null,
    src: ?[]const u8 = null,
    in_mixin: usize = 0,
    err: ?ParserError = null,

    pub fn init(allocator: Allocator, tokens: []const Token, filename: ?[]const u8, src: ?[]const u8) Parser {
        return .{
            .allocator = allocator,
            .tokens = tokens,
            .filename = filename,
            .src = src,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.deferred.deinit(self.allocator);
    }

    // ========================================================================
    // Token Stream Methods
    // ========================================================================

    /// Return the next token without consuming it
    pub fn peek(self: *Parser) Token {
        if (self.deferred.items.len > 0) {
            return self.deferred.items[0];
        }
        if (self.pos < self.tokens.len) {
            return self.tokens[self.pos];
        }
        // Return EOS token if past end
        return .{
            .type = .eos,
            .loc = .{ .start = .{ .line = 0, .column = 0 } },
        };
    }

    /// Return the token at offset n from current position (0 = current)
    pub fn lookahead(self: *Parser, n: usize) Token {
        const deferred_len = self.deferred.items.len;
        if (n < deferred_len) {
            return self.deferred.items[n];
        }
        const index = self.pos + (n - deferred_len);
        if (index < self.tokens.len) {
            return self.tokens[index];
        }
        return .{
            .type = .eos,
            .loc = .{ .start = .{ .line = 0, .column = 0 } },
        };
    }

    /// Consume and return the next token
    pub fn advance(self: *Parser) Token {
        if (self.deferred.items.len > 0) {
            return self.deferred.orderedRemove(0);
        }
        if (self.pos < self.tokens.len) {
            const tok = self.tokens[self.pos];
            self.pos += 1;
            return tok;
        }
        return .{
            .type = .eos,
            .loc = .{ .start = .{ .line = 0, .column = 0 } },
        };
    }

    /// Push a token to the front of the stream
    pub fn defer_token(self: *Parser, token: Token) !void {
        try self.deferred.insert(self.allocator, 0, token);
    }

    /// Expect a specific token type, return error if not found
    pub fn expect(self: *Parser, token_type: TokenType) !Token {
        const tok = self.peek();
        if (tok.type == token_type) {
            return self.advance();
        }
        self.setError(.INVALID_TOKEN, "expected different token type", tok);
        return error.InvalidToken;
    }

    /// Accept a token if it matches, otherwise return null
    pub fn accept(self: *Parser, token_type: TokenType) ?Token {
        if (self.peek().type == token_type) {
            return self.advance();
        }
        return null;
    }

    // ========================================================================
    // Error Handling
    // ========================================================================

    fn setError(self: *Parser, code: ParserErrorCode, message: []const u8, token: Token) void {
        self.err = .{
            .code = code,
            .message = message,
            .line = token.loc.start.line,
            .column = token.loc.start.column,
            .filename = self.filename,
        };
    }

    pub fn getError(self: *const Parser) ?ParserError {
        return self.err;
    }

    // ========================================================================
    // Block Helpers
    // ========================================================================

    fn initBlock(self: *Parser, line: usize) !*Node {
        const node = try self.allocator.create(Node);
        node.* = .{
            .type = .Block,
            .line = line,
            .filename = self.filename,
        };
        return node;
    }

    fn emptyBlock(self: *Parser, line: usize) !*Node {
        return self.initBlock(line);
    }

    // ========================================================================
    // Main Parse Entry Point
    // ========================================================================

    pub fn parse(self: *Parser) !*Node {
        var block = try self.emptyBlock(0);

        while (self.peek().type != .eos) {
            if (self.peek().type == .newline) {
                _ = self.advance();
            } else if (self.peek().type == .text_html) {
                var html_nodes = try self.parseTextHtml();
                for (html_nodes.items) |node| {
                    try block.addNode(self.allocator, node);
                }
                html_nodes.deinit(self.allocator);
            } else {
                const expr = try self.parseExpr();
                if (expr.type == .Block) {
                    // Flatten block nodes into parent
                    for (expr.nodes.items) |node| {
                        try block.addNode(self.allocator, node);
                    }
                    // Clear the expr's nodes list (already moved)
                    expr.nodes.clearAndFree(self.allocator);
                    self.allocator.destroy(expr);
                } else {
                    try block.addNode(self.allocator, expr);
                }
            }
        }

        return block;
    }

    // ========================================================================
    // Expression Parsing
    // ========================================================================

    fn parseExpr(self: *Parser) anyerror!*Node {
        const tok = self.peek();
        return switch (tok.type) {
            .tag => self.parseTag(),
            .mixin => self.parseMixin(),
            .block => self.parseBlock(),
            .mixin_block => self.parseMixinBlock(),
            .case => self.parseCase(),
            .extends => self.parseExtends(),
            .include => self.parseInclude(),
            .doctype => self.parseDoctype(),
            .filter => self.parseFilter(),
            .comment => self.parseComment(),
            .text, .interpolated_code, .start_pug_interpolation => self.parseText(true),
            .text_html => blk: {
                var html_nodes = try self.parseTextHtml();
                const block = try self.initBlock(tok.loc.start.line);
                for (html_nodes.items) |node| {
                    try block.addNode(self.allocator, node);
                }
                html_nodes.deinit(self.allocator);
                break :blk block;
            },
            .dot => self.parseDot(),
            .each => self.parseEach(),
            .each_of => self.parseEachOf(),
            .code => self.parseCode(false),
            .blockcode => self.parseBlockCode(),
            .@"if" => self.parseConditional(),
            .@"while" => self.parseWhile(),
            .call => self.parseCall(),
            .interpolation => self.parseInterpolation(),
            .yield => self.parseYield(),
            .id, .class => blk: {
                // Implicit div tag for #id or .class
                try self.defer_token(.{
                    .type = .tag,
                    .val = .{ .string = "div" },
                    .loc = tok.loc,
                });
                break :blk self.parseExpr();
            },
            else => {
                self.setError(.INVALID_TOKEN, "unexpected token", tok);
                return error.InvalidToken;
            },
        };
    }

    fn parseDot(self: *Parser) !*Node {
        _ = self.advance();
        return self.parseTextBlock() orelse try self.emptyBlock(self.peek().loc.start.line);
    }

    // ========================================================================
    // Text Parsing
    // ========================================================================

    fn parseText(self: *Parser, allow_block: bool) !*Node {
        const lineno = self.peek().loc.start.line;
        var tags = std.ArrayListUnmanaged(*Node){};
        defer tags.deinit(self.allocator);

        while (true) {
            const next_tok = self.peek();
            switch (next_tok.type) {
                .text => {
                    const tok = self.advance();
                    const text_node = try self.allocator.create(Node);
                    text_node.* = .{
                        .type = .Text,
                        .val = tok.val.getString(),
                        .line = tok.loc.start.line,
                        .column = tok.loc.start.column,
                        .filename = self.filename,
                    };
                    try tags.append(self.allocator, text_node);
                },
                .interpolated_code => {
                    const tok = self.advance();
                    const code_node = try self.allocator.create(Node);
                    code_node.* = .{
                        .type = .Code,
                        .val = tok.val.getString(),
                        .buffer = tok.isBuffered(),
                        .must_escape = tok.shouldEscape(),
                        .is_inline_code = true,
                        .line = tok.loc.start.line,
                        .column = tok.loc.start.column,
                        .filename = self.filename,
                    };
                    try tags.append(self.allocator, code_node);
                },
                .newline => {
                    if (!allow_block) break;
                    const tok = self.advance();
                    const next_type = self.peek().type;
                    if (next_type == .text or next_type == .interpolated_code) {
                        const nl_node = try self.allocator.create(Node);
                        nl_node.* = .{
                            .type = .Text,
                            .val = "\n",
                            .line = tok.loc.start.line,
                            .column = tok.loc.start.column,
                            .filename = self.filename,
                        };
                        try tags.append(self.allocator, nl_node);
                    }
                },
                .start_pug_interpolation => {
                    _ = self.advance();
                    const expr = try self.parseExpr();
                    try tags.append(self.allocator, expr);
                    _ = try self.expect(.end_pug_interpolation);
                },
                else => break,
            }
        }

        if (tags.items.len == 1) {
            const result = tags.items[0];
            tags.clearAndFree(self.allocator);
            return result;
        } else {
            const block = try self.initBlock(lineno);
            for (tags.items) |node| {
                try block.addNode(self.allocator, node);
            }
            tags.clearAndFree(self.allocator);
            return block;
        }
    }

    fn parseTextHtml(self: *Parser) !std.ArrayListUnmanaged(*Node) {
        var nodes = std.ArrayListUnmanaged(*Node){};
        var current_node: ?*Node = null;

        while (true) {
            switch (self.peek().type) {
                .text_html => {
                    const text = self.advance();
                    if (current_node == null) {
                        current_node = try self.allocator.create(Node);
                        current_node.?.* = .{
                            .type = .Text,
                            .val = text.val.getString(),
                            .filename = self.filename,
                            .line = text.loc.start.line,
                            .column = text.loc.start.column,
                            .is_html = true,
                        };
                        try nodes.append(self.allocator, current_node.?);
                    } else {
                        // Concatenate with newline - need to allocate new string
                        // For now, create a new text node (simplified)
                        const new_node = try self.allocator.create(Node);
                        new_node.* = .{
                            .type = .Text,
                            .val = text.val.getString(),
                            .filename = self.filename,
                            .line = text.loc.start.line,
                            .column = text.loc.start.column,
                            .is_html = true,
                        };
                        try nodes.append(self.allocator, new_node);
                    }
                },
                .indent => {
                    const block_nodes = try self.block_();
                    for (block_nodes.nodes.items) |node| {
                        if (node.is_html) {
                            if (current_node == null) {
                                current_node = node;
                                try nodes.append(self.allocator, current_node.?);
                            } else {
                                try nodes.append(self.allocator, node);
                            }
                        } else {
                            current_node = null;
                            try nodes.append(self.allocator, node);
                        }
                    }
                    block_nodes.nodes.deinit(self.allocator);
                    self.allocator.destroy(block_nodes);
                },
                .code => {
                    current_node = null;
                    const code_node = try self.parseCode(true);
                    try nodes.append(self.allocator, code_node);
                },
                .newline => {
                    _ = self.advance();
                },
                else => break,
            }
        }

        return nodes;
    }

    fn parseTextBlock(self: *Parser) ?*Node {
        const tok = self.accept(.start_pipeless_text) orelse return null;
        var block = self.emptyBlock(tok.loc.start.line) catch return null;

        while (self.peek().type != .end_pipeless_text) {
            const cur_tok = self.advance();
            switch (cur_tok.type) {
                .text => {
                    const text_node = self.allocator.create(Node) catch return null;
                    text_node.* = .{
                        .type = .Text,
                        .val = cur_tok.val.getString(),
                        .line = cur_tok.loc.start.line,
                        .column = cur_tok.loc.start.column,
                        .filename = self.filename,
                    };
                    block.addNode(self.allocator, text_node) catch return null;
                },
                .newline => {
                    const nl_node = self.allocator.create(Node) catch return null;
                    nl_node.* = .{
                        .type = .Text,
                        .val = "\n",
                        .line = cur_tok.loc.start.line,
                        .column = cur_tok.loc.start.column,
                        .filename = self.filename,
                    };
                    block.addNode(self.allocator, nl_node) catch return null;
                },
                .start_pug_interpolation => {
                    const expr = self.parseExpr() catch return null;
                    block.addNode(self.allocator, expr) catch return null;
                    _ = self.expect(.end_pug_interpolation) catch return null;
                },
                .interpolated_code => {
                    const code_node = self.allocator.create(Node) catch return null;
                    code_node.* = .{
                        .type = .Code,
                        .val = cur_tok.val.getString(),
                        .buffer = cur_tok.isBuffered(),
                        .must_escape = cur_tok.shouldEscape(),
                        .is_inline_code = true,
                        .line = cur_tok.loc.start.line,
                        .column = cur_tok.loc.start.column,
                        .filename = self.filename,
                    };
                    block.addNode(self.allocator, code_node) catch return null;
                },
                else => {
                    self.setError(.INVALID_TOKEN, "Unexpected token in text block", cur_tok);
                    return null;
                },
            }
        }
        _ = self.advance(); // consume end_pipeless_text
        return block;
    }

    // ========================================================================
    // Block Expansion
    // ========================================================================

    fn parseBlockExpansion(self: *Parser) !*Node {
        if (self.accept(.colon)) |tok| {
            const expr = try self.parseExpr();
            if (expr.type == .Block) {
                return expr;
            }
            const block = try self.initBlock(tok.loc.start.line);
            try block.addNode(self.allocator, expr);
            return block;
        }
        return self.block_();
    }

    // ========================================================================
    // Case/When/Default
    // ========================================================================

    fn parseCase(self: *Parser) !*Node {
        const tok = try self.expect(.case);
        const node = try self.allocator.create(Node);
        node.* = .{
            .type = .Case,
            .expr = tok.val.getString(),
            .line = tok.loc.start.line,
            .column = tok.loc.start.column,
            .filename = self.filename,
        };

        var block = try self.emptyBlock(tok.loc.start.line + 1);
        _ = try self.expect(.indent);

        while (self.peek().type != .outdent) {
            switch (self.peek().type) {
                .comment, .newline => {
                    _ = self.advance();
                },
                .when => {
                    const when_node = try self.parseWhen();
                    try block.addNode(self.allocator, when_node);
                },
                .default => {
                    const default_node = try self.parseDefault();
                    try block.addNode(self.allocator, default_node);
                },
                else => {
                    self.setError(.INVALID_TOKEN, "Expected 'when', 'default' or 'newline'", self.peek());
                    return error.InvalidToken;
                },
            }
        }
        _ = try self.expect(.outdent);

        // Move block nodes to case node
        for (block.nodes.items) |n| {
            try node.addNode(self.allocator, n);
        }
        block.nodes.deinit(self.allocator);
        self.allocator.destroy(block);

        return node;
    }

    fn parseWhen(self: *Parser) !*Node {
        const tok = try self.expect(.when);
        const node = try self.allocator.create(Node);

        if (self.peek().type != .newline) {
            node.* = .{
                .type = .When,
                .expr = tok.val.getString(),
                .debug = false,
                .line = tok.loc.start.line,
                .column = tok.loc.start.column,
                .filename = self.filename,
            };
            const block = try self.parseBlockExpansion();
            for (block.nodes.items) |n| {
                try node.addNode(self.allocator, n);
            }
            block.nodes.deinit(self.allocator);
            self.allocator.destroy(block);
        } else {
            node.* = .{
                .type = .When,
                .expr = tok.val.getString(),
                .debug = false,
                .line = tok.loc.start.line,
                .column = tok.loc.start.column,
                .filename = self.filename,
            };
        }

        return node;
    }

    fn parseDefault(self: *Parser) !*Node {
        const tok = try self.expect(.default);
        const node = try self.allocator.create(Node);
        node.* = .{
            .type = .When,
            .expr = "default",
            .debug = false,
            .line = tok.loc.start.line,
            .column = tok.loc.start.column,
            .filename = self.filename,
        };
        const block = try self.parseBlockExpansion();
        for (block.nodes.items) |n| {
            try node.addNode(self.allocator, n);
        }
        block.nodes.deinit(self.allocator);
        self.allocator.destroy(block);
        return node;
    }

    // ========================================================================
    // Code Parsing
    // ========================================================================

    fn parseCode(self: *Parser, no_block: bool) !*Node {
        const tok = try self.expect(.code);
        const node = try self.allocator.create(Node);
        node.* = .{
            .type = .Code,
            .val = tok.val.getString(),
            .buffer = tok.isBuffered(),
            .must_escape = tok.shouldEscape(),
            .is_inline_code = no_block,
            .line = tok.loc.start.line,
            .column = tok.loc.start.column,
            .filename = self.filename,
        };

        // Check for "else" pattern - disable debug
        if (node.val) |v| {
            if (mem.indexOf(u8, v, "else") != null) {
                node.debug = false;
            }
        }

        if (no_block) return node;

        // Handle block
        if (self.peek().type == .indent) {
            if (tok.isBuffered()) {
                self.setError(.BLOCK_IN_BUFFERED_CODE, "Buffered code cannot have a block attached", self.peek());
                return error.BlockInBufferedCode;
            }
            const block = try self.block_();
            for (block.nodes.items) |n| {
                try node.addNode(self.allocator, n);
            }
            block.nodes.deinit(self.allocator);
            self.allocator.destroy(block);
        }

        return node;
    }

    fn parseConditional(self: *Parser) !*Node {
        const tok = try self.expect(.@"if");
        const node = try self.allocator.create(Node);
        node.* = .{
            .type = .Conditional,
            .test_expr = tok.val.getString(),
            .line = tok.loc.start.line,
            .column = tok.loc.start.column,
            .filename = self.filename,
        };
        node.consequent = try self.emptyBlock(tok.loc.start.line);

        // Handle block
        if (self.peek().type == .indent) {
            const block = try self.block_();
            // Replace empty consequent with actual block
            self.allocator.destroy(node.consequent.?);
            node.consequent = block;
        }

        var current_node = node;
        while (true) {
            if (self.peek().type == .newline) {
                _ = try self.expect(.newline);
            } else if (self.peek().type == .else_if) {
                const else_if_tok = try self.expect(.else_if);
                const else_if_node = try self.allocator.create(Node);
                else_if_node.* = .{
                    .type = .Conditional,
                    .test_expr = else_if_tok.val.getString(),
                    .line = else_if_tok.loc.start.line,
                    .column = else_if_tok.loc.start.column,
                    .filename = self.filename,
                };
                else_if_node.consequent = try self.emptyBlock(else_if_tok.loc.start.line);
                current_node.alternate = else_if_node;
                current_node = else_if_node;

                if (self.peek().type == .indent) {
                    const block = try self.block_();
                    self.allocator.destroy(current_node.consequent.?);
                    current_node.consequent = block;
                }
            } else if (self.peek().type == .@"else") {
                _ = try self.expect(.@"else");
                if (self.peek().type == .indent) {
                    current_node.alternate = try self.block_();
                }
                break;
            } else {
                break;
            }
        }

        return node;
    }

    fn parseWhile(self: *Parser) !*Node {
        const tok = try self.expect(.@"while");
        const node = try self.allocator.create(Node);
        node.* = .{
            .type = .While,
            .test_expr = tok.val.getString(),
            .line = tok.loc.start.line,
            .column = tok.loc.start.column,
            .filename = self.filename,
        };

        // Handle block
        if (self.peek().type == .indent) {
            const block = try self.block_();
            for (block.nodes.items) |n| {
                try node.addNode(self.allocator, n);
            }
            block.nodes.deinit(self.allocator);
            self.allocator.destroy(block);
        }

        return node;
    }

    fn parseBlockCode(self: *Parser) !*Node {
        const tok = try self.expect(.blockcode);
        const line = tok.loc.start.line;
        const column = tok.loc.start.column;

        var text = std.ArrayListUnmanaged(u8){};
        defer text.deinit(self.allocator);

        if (self.peek().type == .start_pipeless_text) {
            _ = self.advance();
            while (self.peek().type != .end_pipeless_text) {
                const inner_tok = self.advance();
                switch (inner_tok.type) {
                    .text => {
                        if (inner_tok.val.getString()) |s| {
                            try text.appendSlice(self.allocator, s);
                        }
                    },
                    .newline => {
                        try text.append(self.allocator, '\n');
                    },
                    else => {
                        self.setError(.INVALID_TOKEN, "Unexpected token in block code", inner_tok);
                        return error.InvalidToken;
                    },
                }
            }
            _ = self.advance();
        }

        const node = try self.allocator.create(Node);
        // Need to dupe the text to persist it
        const text_slice = try self.allocator.dupe(u8, text.items);
        node.* = .{
            .type = .Code,
            .val = text_slice,
            .val_owned = true, // We allocated this string
            .buffer = false,
            .must_escape = false,
            .is_inline_code = false,
            .line = line,
            .column = column,
            .filename = self.filename,
        };
        return node;
    }

    // ========================================================================
    // Comment Parsing
    // ========================================================================

    fn parseComment(self: *Parser) !*Node {
        const tok = try self.expect(.comment);

        // Check for type hint in unbuffered comment: //- @TypeOf(field): type
        if (!tok.isBuffered()) {
            if (tok.val.getString()) |text| {
                const trimmed = mem.trim(u8, text, " \t");
                if (mem.startsWith(u8, trimmed, "@TypeOf(")) {
                    return self.parseTypeHint(tok, trimmed);
                }
            }
        }

        if (self.parseTextBlock()) |block| {
            const node = try self.allocator.create(Node);
            node.* = .{
                .type = .BlockComment,
                .val = tok.val.getString(),
                .buffer = tok.isBuffered(),
                .line = tok.loc.start.line,
                .column = tok.loc.start.column,
                .filename = self.filename,
            };
            // Move block nodes to comment
            for (block.nodes.items) |n| {
                try node.addNode(self.allocator, n);
            }
            block.nodes.deinit(self.allocator);
            self.allocator.destroy(block);
            return node;
        } else {
            const node = try self.allocator.create(Node);
            node.* = .{
                .type = .Comment,
                .val = tok.val.getString(),
                .buffer = tok.isBuffered(),
                .line = tok.loc.start.line,
                .column = tok.loc.start.column,
                .filename = self.filename,
            };
            return node;
        }
    }

    // ========================================================================
    // TypeHint Parsing (for compiled templates)
    // ========================================================================

    /// Parse a type hint annotation: @TypeOf(fieldName): typeSpec
    fn parseTypeHint(self: *Parser, tok: Token, text: []const u8) !*Node {
        // Find closing paren: @TypeOf(fieldName)
        const paren_start = "@TypeOf(".len;
        var paren_end: usize = paren_start;
        while (paren_end < text.len and text[paren_end] != ')') : (paren_end += 1) {}

        if (paren_end >= text.len) {
            // Malformed type hint - treat as regular comment
            const node = try self.allocator.create(Node);
            node.* = .{
                .type = .Comment,
                .val = tok.val.getString(),
                .buffer = false,
                .line = tok.loc.start.line,
                .column = tok.loc.start.column,
                .filename = self.filename,
            };
            return node;
        }

        const field_name = text[paren_start..paren_end];

        // Find colon separator
        var colon_pos = paren_end + 1;
        while (colon_pos < text.len and (text[colon_pos] == ' ' or text[colon_pos] == '\t')) : (colon_pos += 1) {}

        if (colon_pos >= text.len or text[colon_pos] != ':') {
            // No colon found - treat as regular comment
            const node = try self.allocator.create(Node);
            node.* = .{
                .type = .Comment,
                .val = tok.val.getString(),
                .buffer = false,
                .line = tok.loc.start.line,
                .column = tok.loc.start.column,
                .filename = self.filename,
            };
            return node;
        }

        // Get type spec after colon
        const type_spec = mem.trim(u8, text[colon_pos + 1 ..], " \t");

        const node = try self.allocator.create(Node);
        node.* = .{
            .type = .TypeHint,
            .type_hint_field = field_name,
            .type_hint_type = type_spec,
            .line = tok.loc.start.line,
            .column = tok.loc.start.column,
            .filename = self.filename,
        };
        return node;
    }

    // ========================================================================
    // Doctype Parsing
    // ========================================================================

    fn parseDoctype(self: *Parser) !*Node {
        const tok = try self.expect(.doctype);
        const node = try self.allocator.create(Node);
        node.* = .{
            .type = .Doctype,
            .val = tok.val.getString(),
            .line = tok.loc.start.line,
            .column = tok.loc.start.column,
            .filename = self.filename,
        };
        return node;
    }

    // ========================================================================
    // Filter Parsing
    // ========================================================================

    fn parseIncludeFilter(self: *Parser) !*Node {
        const tok = try self.expect(.filter);
        var filter_attrs = std.ArrayListUnmanaged(Attribute){};

        if (self.peek().type == .start_attributes) {
            filter_attrs = try self.attrs(null);
        }

        const node = try self.allocator.create(Node);
        node.* = .{
            .type = .IncludeFilter,
            .name = tok.val.getString(),
            .attrs = filter_attrs,
            .line = tok.loc.start.line,
            .column = tok.loc.start.column,
            .filename = self.filename,
        };
        return node;
    }

    fn parseFilter(self: *Parser) !*Node {
        const tok = try self.expect(.filter);
        var filter_attrs = std.ArrayListUnmanaged(Attribute){};

        if (self.peek().type == .start_attributes) {
            filter_attrs = try self.attrs(null);
        }

        var block: *Node = undefined;
        if (self.peek().type == .text) {
            const text_token = self.advance();
            block = try self.initBlock(text_token.loc.start.line);
            const text_node = try self.allocator.create(Node);
            text_node.* = .{
                .type = .Text,
                .val = text_token.val.getString(),
                .line = text_token.loc.start.line,
                .column = text_token.loc.start.column,
                .filename = self.filename,
            };
            try block.addNode(self.allocator, text_node);
        } else if (self.peek().type == .filter) {
            block = try self.initBlock(tok.loc.start.line);
            const nested_filter = try self.parseFilter();
            try block.addNode(self.allocator, nested_filter);
        } else {
            block = self.parseTextBlock() orelse try self.emptyBlock(tok.loc.start.line);
        }

        const node = try self.allocator.create(Node);
        node.* = .{
            .type = .Filter,
            .name = tok.val.getString(),
            .attrs = filter_attrs,
            .line = tok.loc.start.line,
            .column = tok.loc.start.column,
            .filename = self.filename,
        };
        for (block.nodes.items) |n| {
            try node.addNode(self.allocator, n);
        }
        block.nodes.deinit(self.allocator);
        self.allocator.destroy(block);
        return node;
    }

    // ========================================================================
    // Each Parsing
    // ========================================================================

    fn parseEach(self: *Parser) !*Node {
        const tok = try self.expect(.each);
        const node = try self.allocator.create(Node);
        node.* = .{
            .type = .Each,
            .obj = tok.code.getString(),
            .val = tok.val.getString(),
            .key = tok.key.getString(),
            .line = tok.loc.start.line,
            .column = tok.loc.start.column,
            .filename = self.filename,
        };

        const block = try self.block_();
        for (block.nodes.items) |n| {
            try node.addNode(self.allocator, n);
        }
        block.nodes.deinit(self.allocator);
        self.allocator.destroy(block);

        if (self.peek().type == .@"else") {
            _ = self.advance();
            node.alternate = try self.block_();
        }

        return node;
    }

    fn parseEachOf(self: *Parser) !*Node {
        const tok = try self.expect(.each_of);
        const node = try self.allocator.create(Node);
        node.* = .{
            .type = .EachOf,
            .obj = tok.code.getString(),
            .val = tok.val.getString(),
            .line = tok.loc.start.line,
            .column = tok.loc.start.column,
            .filename = self.filename,
        };

        const block = try self.block_();
        for (block.nodes.items) |n| {
            try node.addNode(self.allocator, n);
        }
        block.nodes.deinit(self.allocator);
        self.allocator.destroy(block);

        return node;
    }

    // ========================================================================
    // Extends Parsing
    // ========================================================================

    fn parseExtends(self: *Parser) !*Node {
        const tok = try self.expect(.extends);
        const path_tok = try self.expect(.path);

        const path_val = if (path_tok.val.getString()) |s| mem.trim(u8, s, " \t") else null;

        const node = try self.allocator.create(Node);
        node.* = .{
            .type = .Extends,
            .file = .{
                .path = path_val,
                .line = path_tok.loc.start.line,
                .column = path_tok.loc.start.column,
                .filename = self.filename,
            },
            .line = tok.loc.start.line,
            .column = tok.loc.start.column,
            .filename = self.filename,
        };
        return node;
    }

    // ========================================================================
    // Block Parsing
    // ========================================================================

    fn parseBlock(self: *Parser) !*Node {
        const tok = try self.expect(.block);

        var node: *Node = undefined;
        if (self.peek().type == .indent) {
            node = try self.block_();
        } else {
            node = try self.emptyBlock(tok.loc.start.line);
        }

        node.type = .NamedBlock;
        node.name = if (tok.val.getString()) |s| mem.trim(u8, s, " \t") else null;
        node.mode = tok.mode.getString();
        node.line = tok.loc.start.line;
        node.column = tok.loc.start.column;

        return node;
    }

    fn parseMixinBlock(self: *Parser) !*Node {
        const tok = try self.expect(.mixin_block);
        if (self.in_mixin == 0) {
            self.setError(.BLOCK_OUTISDE_MIXIN, "Anonymous blocks are not allowed unless they are part of a mixin.", tok);
            return error.BlockOutsideMixin;
        }
        const node = try self.allocator.create(Node);
        node.* = .{
            .type = .MixinBlock,
            .line = tok.loc.start.line,
            .column = tok.loc.start.column,
            .filename = self.filename,
        };
        return node;
    }

    fn parseYield(self: *Parser) !*Node {
        const tok = try self.expect(.yield);
        const node = try self.allocator.create(Node);
        node.* = .{
            .type = .YieldBlock,
            .line = tok.loc.start.line,
            .column = tok.loc.start.column,
            .filename = self.filename,
        };
        return node;
    }

    // ========================================================================
    // Include Parsing
    // ========================================================================

    fn parseInclude(self: *Parser) !*Node {
        const tok = try self.expect(.include);
        const node = try self.allocator.create(Node);
        node.* = .{
            .type = .Include,
            .file = .{
                .path = null,
                .line = 0,
                .column = 0,
                .filename = self.filename,
            },
            .line = tok.loc.start.line,
            .column = tok.loc.start.column,
            .filename = self.filename,
        };

        // Parse filters
        while (self.peek().type == .filter) {
            const filter_node = try self.parseIncludeFilter();
            try node.filters.append(self.allocator, filter_node);
        }

        const path_tok = try self.expect(.path);
        const path_val = if (path_tok.val.getString()) |s| mem.trim(u8, s, " \t") else null;

        node.file = .{
            .path = path_val,
            .line = path_tok.loc.start.line,
            .column = path_tok.loc.start.column,
            .filename = self.filename,
        };

        const has_filters = node.filters.items.len > 0;
        const is_pug_file = if (path_val) |p| (mem.endsWith(u8, p, ".jade") or mem.endsWith(u8, p, ".pug")) else false;

        if (is_pug_file and !has_filters) {
            // Pug include with block
            if (self.peek().type == .indent) {
                const block = try self.block_();
                for (block.nodes.items) |n| {
                    try node.addNode(self.allocator, n);
                }
                block.nodes.deinit(self.allocator);
                self.allocator.destroy(block);
            }
        } else {
            // Raw include
            node.type = .RawInclude;
            if (self.peek().type == .indent) {
                self.setError(.RAW_INCLUDE_BLOCK, "Raw inclusion cannot contain a block", self.peek());
                return error.RawIncludeBlock;
            }
        }

        return node;
    }

    // ========================================================================
    // Mixin/Call Parsing
    // ========================================================================

    fn parseCall(self: *Parser) !*Node {
        const tok = try self.expect(.call);
        const node = try self.allocator.create(Node);
        node.* = .{
            .type = .Mixin,
            .name = tok.val.getString(),
            .args = tok.args.getString(),
            .call = true,
            .line = tok.loc.start.line,
            .column = tok.loc.start.column,
            .filename = self.filename,
        };

        try self.tag_(node, true);

        // If code was added, move it to block
        // (simplified - the JS version has special handling for mixin.code)

        // If block is empty, set to null (matching JS behavior)
        if (node.nodes.items.len == 0) {
            // Keep empty block as is - JS sets block to null but we don't have optional block
        }

        return node;
    }

    fn parseMixin(self: *Parser) !*Node {
        const tok = try self.expect(.mixin);

        if (self.peek().type == .indent) {
            self.in_mixin += 1;
            const node = try self.allocator.create(Node);
            node.* = .{
                .type = .Mixin,
                .name = tok.val.getString(),
                .args = tok.args.getString(),
                .call = false,
                .line = tok.loc.start.line,
                .column = tok.loc.start.column,
                .filename = self.filename,
            };
            const block = try self.block_();
            for (block.nodes.items) |n| {
                try node.addNode(self.allocator, n);
            }
            block.nodes.deinit(self.allocator);
            self.allocator.destroy(block);
            self.in_mixin -= 1;
            return node;
        } else {
            self.setError(.MIXIN_WITHOUT_BODY, "Mixin declared without body", tok);
            return error.MixinWithoutBody;
        }
    }

    // ========================================================================
    // Block (indent/outdent)
    // ========================================================================

    fn block_(self: *Parser) anyerror!*Node {
        const tok = try self.expect(.indent);
        var block = try self.emptyBlock(tok.loc.start.line);

        while (self.peek().type != .outdent) {
            if (self.peek().type == .newline) {
                _ = self.advance();
            } else if (self.peek().type == .text_html) {
                var html_nodes = try self.parseTextHtml();
                for (html_nodes.items) |node| {
                    try block.addNode(self.allocator, node);
                }
                html_nodes.deinit(self.allocator);
            } else {
                const expr = try self.parseExpr();
                if (expr.type == .Block) {
                    for (expr.nodes.items) |node| {
                        try block.addNode(self.allocator, node);
                    }
                    expr.nodes.clearAndFree(self.allocator);
                    self.allocator.destroy(expr);
                } else {
                    try block.addNode(self.allocator, expr);
                }
            }
        }
        _ = try self.expect(.outdent);
        return block;
    }

    // ========================================================================
    // Interpolation/Tag Parsing
    // ========================================================================

    fn parseInterpolation(self: *Parser) !*Node {
        const tok = self.advance();
        const node = try self.allocator.create(Node);
        node.* = .{
            .type = .InterpolatedTag,
            .expr = tok.val.getString(),
            .self_closing = false,
            .is_inline = false,
            .line = tok.loc.start.line,
            .column = tok.loc.start.column,
            .filename = self.filename,
        };
        try self.tag_(node, true);
        return node;
    }

    fn parseTag(self: *Parser) !*Node {
        const tok = self.advance();
        const tag_name = tok.val.getString() orelse "div";
        const node = try self.allocator.create(Node);
        node.* = .{
            .type = .Tag,
            .name = tag_name,
            .self_closing = false,
            .is_inline = isInlineTag(tag_name),
            .line = tok.loc.start.line,
            .column = tok.loc.start.column,
            .filename = self.filename,
        };
        try self.tag_(node, true);
        return node;
    }

    fn tag_(self: *Parser, tag: *Node, self_closing_allowed: bool) !void {
        var seen_attrs = false;
        var attribute_names = std.ArrayListUnmanaged([]const u8){};
        defer attribute_names.deinit(self.allocator);

        // (attrs | class | id)*
        outer: while (true) {
            switch (self.peek().type) {
                .id, .class => {
                    const tok = self.advance();
                    if (tok.type == .id) {
                        // Check for duplicate id
                        for (attribute_names.items) |name| {
                            if (mem.eql(u8, name, "id")) {
                                self.setError(.DUPLICATE_ID, "Duplicate attribute \"id\" is not allowed.", tok);
                                return error.DuplicateId;
                            }
                        }
                        try attribute_names.append(self.allocator, "id");
                    }
                    // Class/id values from shorthand are always static strings
                    const val_str = tok.val.getString() orelse "";
                    const final_val = try self.allocator.dupe(u8, val_str);

                    try tag.attrs.append(self.allocator, .{
                        .name = if (tok.type == .id) "id" else "class",
                        .val = final_val,
                        .line = tok.loc.start.line,
                        .column = tok.loc.start.column,
                        .filename = self.filename,
                        .must_escape = false,
                        .val_owned = true, // We allocated this string
                        .quoted = true, // Shorthand class/id are always static
                    });
                },
                .start_attributes => {
                    if (seen_attrs) {
                        // Warning: multiple attributes - but continue
                    }
                    seen_attrs = true;
                    var new_attrs = try self.attrs(&attribute_names);
                    for (new_attrs.items) |attr| {
                        try tag.attrs.append(self.allocator, attr);
                    }
                    new_attrs.deinit(self.allocator);
                },
                .@"&attributes" => {
                    const tok = self.advance();
                    try tag.attribute_blocks.append(self.allocator, .{
                        .val = tok.val.getString() orelse "",
                        .line = tok.loc.start.line,
                        .column = tok.loc.start.column,
                        .filename = self.filename,
                    });
                },
                else => break :outer,
            }
        }

        // Check for textOnly (.)
        if (self.peek().type == .dot) {
            tag.text_only = true;
            _ = self.advance();
        }

        // (text | code | ':')?
        switch (self.peek().type) {
            .text, .interpolated_code => {
                const text = try self.parseText(false);
                if (text.type == .Block) {
                    for (text.nodes.items) |node| {
                        try tag.addNode(self.allocator, node);
                    }
                    text.nodes.deinit(self.allocator);
                    self.allocator.destroy(text);
                } else {
                    try tag.addNode(self.allocator, text);
                }
            },
            .code => {
                const code_node = try self.parseCode(true);
                try tag.addNode(self.allocator, code_node);
            },
            .colon => {
                _ = self.advance();
                const expr = try self.parseExpr();
                if (expr.type == .Block) {
                    for (expr.nodes.items) |node| {
                        try tag.addNode(self.allocator, node);
                    }
                    expr.nodes.deinit(self.allocator);
                    self.allocator.destroy(expr);
                } else {
                    try tag.addNode(self.allocator, expr);
                }
            },
            .newline, .indent, .outdent, .eos, .start_pipeless_text, .end_pug_interpolation => {},
            .slash => {
                if (self_closing_allowed) {
                    _ = self.advance();
                    tag.self_closing = true;
                } else {
                    self.setError(.INVALID_TOKEN, "Unexpected token", self.peek());
                    return error.InvalidToken;
                }
            },
            else => {
                // Accept other tokens without error for now
            },
        }

        // newline*
        while (self.peek().type == .newline) {
            _ = self.advance();
        }

        // block?
        if (tag.text_only) {
            if (self.parseTextBlock()) |block| {
                for (block.nodes.items) |node| {
                    try tag.addNode(self.allocator, node);
                }
                block.nodes.deinit(self.allocator);
                self.allocator.destroy(block);
            }
        } else if (self.peek().type == .indent) {
            const block = try self.block_();
            for (block.nodes.items) |node| {
                try tag.addNode(self.allocator, node);
            }
            block.nodes.deinit(self.allocator);
            self.allocator.destroy(block);
        }
    }

    fn attrs(self: *Parser, attribute_names: ?*std.ArrayListUnmanaged([]const u8)) !std.ArrayListUnmanaged(Attribute) {
        _ = try self.expect(.start_attributes);

        var result = std.ArrayListUnmanaged(Attribute){};
        var tok = self.advance();

        while (tok.type == .attribute) {
            const attr_name = tok.name.getString() orelse "";

            // Check for duplicates (except class)
            if (!mem.eql(u8, attr_name, "class")) {
                if (attribute_names) |names| {
                    for (names.items) |name| {
                        if (mem.eql(u8, name, attr_name)) {
                            self.setError(.DUPLICATE_ATTRIBUTE, "Duplicate attribute is not allowed.", tok);
                            return error.DuplicateAttribute;
                        }
                    }
                    try names.append(self.allocator, attr_name);
                }
            }

            try result.append(self.allocator, .{
                .name = attr_name,
                .val = tok.val.getString(),
                .line = tok.loc.start.line,
                .column = tok.loc.start.column,
                .filename = self.filename,
                .must_escape = tok.shouldEscape(),
                .quoted = tok.isQuoted(),
            });
            tok = self.advance();
        }

        try self.defer_token(tok);
        _ = try self.expect(.end_attributes);

        return result;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "parser basic" {
    const allocator = std.testing.allocator;

    // Simulate tokens for: html\n  body\n    h1 Title
    var tokens = [_]Token{
        .{ .type = .tag, .val = .{ .string = "html" }, .loc = .{ .start = .{ .line = 1, .column = 1 } } },
        .{ .type = .indent, .val = .{ .string = "2" }, .loc = .{ .start = .{ .line = 2, .column = 1 } } },
        .{ .type = .tag, .val = .{ .string = "body" }, .loc = .{ .start = .{ .line = 2, .column = 3 } } },
        .{ .type = .indent, .val = .{ .string = "4" }, .loc = .{ .start = .{ .line = 3, .column = 1 } } },
        .{ .type = .tag, .val = .{ .string = "h1" }, .loc = .{ .start = .{ .line = 3, .column = 5 } } },
        .{ .type = .text, .val = .{ .string = "Title" }, .loc = .{ .start = .{ .line = 3, .column = 8 } } },
        .{ .type = .outdent, .loc = .{ .start = .{ .line = 3, .column = 13 } } },
        .{ .type = .outdent, .loc = .{ .start = .{ .line = 3, .column = 13 } } },
        .{ .type = .eos, .loc = .{ .start = .{ .line = 3, .column = 13 } } },
    };

    var parser = Parser.init(allocator, &tokens, "test.pug", null);
    defer parser.deinit();

    const ast = try parser.parse();
    defer {
        ast.deinit(allocator);
        allocator.destroy(ast);
    }

    try std.testing.expectEqual(NodeType.Block, ast.type);
    try std.testing.expectEqual(@as(usize, 1), ast.nodes.items.len);

    const html_tag = ast.nodes.items[0];
    try std.testing.expectEqual(NodeType.Tag, html_tag.type);
    try std.testing.expectEqualStrings("html", html_tag.name.?);
}

test "parser doctype" {
    const allocator = std.testing.allocator;

    var tokens = [_]Token{
        .{ .type = .doctype, .val = .{ .string = "html" }, .loc = .{ .start = .{ .line = 1, .column = 1 } } },
        .{ .type = .eos, .loc = .{ .start = .{ .line = 1, .column = 13 } } },
    };

    var parser = Parser.init(allocator, &tokens, "test.pug", null);
    defer parser.deinit();

    const ast = try parser.parse();
    defer {
        ast.deinit(allocator);
        allocator.destroy(ast);
    }

    try std.testing.expectEqual(@as(usize, 1), ast.nodes.items.len);
    try std.testing.expectEqual(NodeType.Doctype, ast.nodes.items[0].type);
    try std.testing.expectEqualStrings("html", ast.nodes.items[0].val.?);
}
