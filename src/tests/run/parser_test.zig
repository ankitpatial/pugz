const std = @import("std");
const parser = @import("parser");
const Parser = parser.Parser;
const Token = parser.Token;
const TokenType = parser.TokenType;
const TokenValue = parser.TokenValue;
const Node = parser.Node;
const NodeType = parser.NodeType;
const fs = std.fs;
const json = std.json;
const mem = std.mem;

// ============================================================================
// JSON Token Parser - Parses tokens from JSON files
// ============================================================================

fn tokenTypeFromString(s: []const u8) ?TokenType {
    const mapping = .{
        .{ "tag", TokenType.tag },
        .{ "id", TokenType.id },
        .{ "class", TokenType.class },
        .{ "text", TokenType.text },
        .{ "text-html", TokenType.text_html },
        .{ "comment", TokenType.comment },
        .{ "doctype", TokenType.doctype },
        .{ "filter", TokenType.filter },
        .{ "extends", TokenType.extends },
        .{ "include", TokenType.include },
        .{ "path", TokenType.path },
        .{ "block", TokenType.block },
        .{ "mixin-block", TokenType.mixin_block },
        .{ "mixin", TokenType.mixin },
        .{ "call", TokenType.call },
        .{ "yield", TokenType.yield },
        .{ "code", TokenType.code },
        .{ "blockcode", TokenType.blockcode },
        .{ "interpolation", TokenType.interpolation },
        .{ "interpolated-code", TokenType.interpolated_code },
        .{ "if", TokenType.@"if" },
        .{ "else-if", TokenType.else_if },
        .{ "else", TokenType.@"else" },
        .{ "case", TokenType.case },
        .{ "when", TokenType.when },
        .{ "default", TokenType.default },
        .{ "each", TokenType.each },
        .{ "eachOf", TokenType.each_of },
        .{ "while", TokenType.@"while" },
        .{ "indent", TokenType.indent },
        .{ "outdent", TokenType.outdent },
        .{ "newline", TokenType.newline },
        .{ "eos", TokenType.eos },
        .{ "dot", TokenType.dot },
        .{ ":", TokenType.colon },
        .{ "slash", TokenType.slash },
        .{ "start-attributes", TokenType.start_attributes },
        .{ "end-attributes", TokenType.end_attributes },
        .{ "attribute", TokenType.attribute },
        .{ "&attributes", TokenType.@"&attributes" },
        .{ "start-pug-interpolation", TokenType.start_pug_interpolation },
        .{ "end-pug-interpolation", TokenType.end_pug_interpolation },
        .{ "start-pipeless-text", TokenType.start_pipeless_text },
        .{ "end-pipeless-text", TokenType.end_pipeless_text },
    };

    inline for (mapping) |pair| {
        if (mem.eql(u8, s, pair[0])) return pair[1];
    }
    return null;
}

fn jsonValueToTokenValue(val: ?json.Value) TokenValue {
    if (val) |v| {
        switch (v) {
            .string => |s| return .{ .string = s },
            .bool => |b| return .{ .boolean = b },
            .integer => |i| {
                // For integers, convert to string representation
                // This handles cases like indent values
                _ = i;
                return .none;
            },
            else => return .none,
        }
    }
    return .none;
}

// Result struct that holds tokens and their backing memory
const ParsedTokens = struct {
    tokens: []Token,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ParsedTokens, allocator: std.mem.Allocator) void {
        allocator.free(self.tokens);
        self.arena.deinit();
    }
};

fn parseJsonTokens(allocator: std.mem.Allocator, json_content: []const u8) !ParsedTokens {
    var tokens = std.ArrayList(Token){};
    errdefer tokens.deinit(allocator);

    // Use an arena allocator to keep JSON string data alive
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    // Parse line by line (newline-delimited JSON)
    var lines = mem.splitSequence(u8, json_content, "\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const parsed = json.parseFromSlice(json.Value, arena.allocator(), line, .{}) catch |err| {
            std.debug.print("Failed to parse JSON line: {s}\nError: {}\n", .{ line, err });
            continue;
        };
        // Don't deinit - arena keeps the strings alive

        const obj = parsed.value.object;

        const type_str = obj.get("type").?.string;
        const token_type = tokenTypeFromString(type_str) orelse {
            std.debug.print("Unknown token type: {s}\n", .{type_str});
            continue;
        };

        const loc_obj = obj.get("loc").?.object;
        const start_obj = loc_obj.get("start").?.object;

        var token = Token{
            .type = token_type,
            .loc = .{
                .start = .{
                    .line = @intCast(start_obj.get("line").?.integer),
                    .column = @intCast(start_obj.get("column").?.integer),
                },
            },
        };

        // Parse val
        if (obj.get("val")) |val| {
            token.val = jsonValueToTokenValue(val);
        }

        // Parse name (for attribute tokens)
        if (obj.get("name")) |name| {
            token.name = jsonValueToTokenValue(name);
        }

        // Parse mustEscape
        if (obj.get("mustEscape")) |me| {
            token.must_escape = jsonValueToTokenValue(me);
        }

        // Parse buffer
        if (obj.get("buffer")) |buf| {
            token.buffer = jsonValueToTokenValue(buf);
        }

        // Parse mode
        if (obj.get("mode")) |mode| {
            token.mode = jsonValueToTokenValue(mode);
        }

        // Parse args
        if (obj.get("args")) |args| {
            token.args = jsonValueToTokenValue(args);
        }

        // Parse key
        if (obj.get("key")) |key| {
            token.key = jsonValueToTokenValue(key);
        }

        // Parse code
        if (obj.get("code")) |code| {
            token.code = jsonValueToTokenValue(code);
        }

        try tokens.append(allocator, token);
    }

    return .{
        .tokens = try tokens.toOwnedSlice(allocator),
        .arena = arena,
    };
}

// ============================================================================
// AST Printer - For debugging
// ============================================================================

fn printAst(node: *const Node, indent: usize) void {
    const spaces = "                                                            ";
    const prefix = spaces[0..@min(indent * 2, spaces.len)];

    std.debug.print("{s}{s}", .{ prefix, @tagName(node.type) });

    if (node.name) |n| {
        std.debug.print(" name=\"{s}\"", .{n});
    }
    if (node.val) |v| {
        std.debug.print(" val=\"{s}\"", .{v});
    }
    if (node.expr) |e| {
        std.debug.print(" expr=\"{s}\"", .{e});
    }
    if (node.test_expr) |t| {
        std.debug.print(" test=\"{s}\"", .{t});
    }

    std.debug.print(" line={d}", .{node.line});
    std.debug.print("\n", .{});

    // Print attributes
    for (node.attrs.items) |attr| {
        std.debug.print("{s}  @{s}={s}\n", .{ prefix, attr.name, attr.val orelse "null" });
    }

    // Print child nodes
    for (node.nodes.items) |child| {
        printAst(child, indent + 1);
    }

    // Print consequent/alternate for conditionals
    if (node.consequent) |c| {
        std.debug.print("{s}  consequent:\n", .{prefix});
        printAst(c, indent + 2);
    }
    if (node.alternate) |a| {
        std.debug.print("{s}  alternate:\n", .{prefix});
        printAst(a, indent + 2);
    }
}

fn countNodes(node: *const Node) usize {
    var count: usize = 1;
    for (node.nodes.items) |child| {
        count += countNodes(child);
    }
    if (node.consequent) |c| count += countNodes(c);
    if (node.alternate) |a| count += countNodes(a);
    return count;
}

// ============================================================================
// Test Case Loading
// ============================================================================

const TokenTestCase = struct {
    name: []const u8,
    content: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TokenTestCase) void {
        self.allocator.free(self.name);
        self.allocator.free(self.content);
    }
};

fn loadTokenTestCases(allocator: std.mem.Allocator, dir_path: []const u8) !std.ArrayList(TokenTestCase) {
    var cases = std.ArrayList(TokenTestCase){};
    errdefer {
        for (cases.items) |*c| c.deinit();
        cases.deinit(allocator);
    }

    var dir = fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Failed to open directory {s}: {}\n", .{ dir_path, err });
        return cases;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.name, ".tokens.json")) continue;

        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);

        const file = dir.openFile(entry.name, .{}) catch |err| {
            std.debug.print("Failed to open file {s}: {}\n", .{ entry.name, err });
            allocator.free(name);
            continue;
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
            std.debug.print("Failed to read file {s}: {}\n", .{ entry.name, err });
            allocator.free(name);
            continue;
        };

        try cases.append(allocator, .{
            .name = name,
            .content = content,
            .allocator = allocator,
        });
    }

    return cases;
}

// ============================================================================
// Test Runner
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load test cases from pug-parser test directory
    const test_dir = "./test-data/pug-parser/cases";
    var test_cases = try loadTokenTestCases(allocator, test_dir);
    defer {
        for (test_cases.items) |*c| c.deinit();
        test_cases.deinit(allocator);
    }

    std.debug.print("Loaded {d} test cases\n\n", .{test_cases.items.len});

    var success_count: usize = 0;
    var fail_count: usize = 0;
    const total_count = test_cases.items.len;

    for (test_cases.items) |test_case| {
        std.debug.print("Testing {s}...\n", .{test_case.name});

        var parsed_tokens = parseJsonTokens(allocator, test_case.content) catch |err| {
            std.debug.print("Failed to parse tokens from {s}: {}\n", .{ test_case.name, err });
            fail_count += 1;
            continue;
        };
        defer parsed_tokens.deinit(allocator);

        if (parsed_tokens.tokens.len == 0) {
            std.debug.print("SKIP {s}: no tokens\n", .{test_case.name});
            continue;
        }

        var p = Parser.init(allocator, parsed_tokens.tokens, test_case.name, null);
        defer p.deinit();

        const ast = p.parse() catch |err| {
            std.debug.print("FAIL {s}: parse error: {}\n", .{ test_case.name, err });
            if (p.getError()) |parse_err| {
                std.debug.print("     Error: {s} at line {d}, column {d}\n", .{
                    parse_err.message,
                    parse_err.line,
                    parse_err.column,
                });
            }
            fail_count += 1;
            continue;
        };
        defer {
            ast.deinit(allocator);
            allocator.destroy(ast);
        }

        const node_count = countNodes(ast);
        std.debug.print("PASS {s}: {d} nodes\n", .{ test_case.name, node_count });
        success_count += 1;
    }

    std.debug.print("\n=== Summary ===\n", .{});
    std.debug.print("Passed: {d}/{d}\n", .{ success_count, total_count });
    std.debug.print("Failed: {d}\n", .{fail_count});
}

// ============================================================================
// Unit Tests
// ============================================================================

test "parse basic tag structure" {
    const allocator = std.testing.allocator;

    var tokens = [_]Token{
        .{ .type = .tag, .val = .{ .string = "html" }, .loc = .{ .start = .{ .line = 1, .column = 1 } } },
        .{ .type = .indent, .loc = .{ .start = .{ .line = 2, .column = 1 } } },
        .{ .type = .tag, .val = .{ .string = "body" }, .loc = .{ .start = .{ .line = 2, .column = 3 } } },
        .{ .type = .indent, .loc = .{ .start = .{ .line = 3, .column = 1 } } },
        .{ .type = .tag, .val = .{ .string = "h1" }, .loc = .{ .start = .{ .line = 3, .column = 5 } } },
        .{ .type = .text, .val = .{ .string = "Title" }, .loc = .{ .start = .{ .line = 3, .column = 8 } } },
        .{ .type = .outdent, .loc = .{ .start = .{ .line = 3, .column = 13 } } },
        .{ .type = .outdent, .loc = .{ .start = .{ .line = 3, .column = 13 } } },
        .{ .type = .eos, .loc = .{ .start = .{ .line = 3, .column = 13 } } },
    };

    var p = Parser.init(allocator, &tokens, "test.pug", null);
    defer p.deinit();

    const ast = try p.parse();
    defer {
        ast.deinit(allocator);
        allocator.destroy(ast);
    }

    try std.testing.expectEqual(NodeType.Block, ast.type);
    try std.testing.expectEqual(@as(usize, 1), ast.nodes.items.len);

    const html = ast.nodes.items[0];
    try std.testing.expectEqual(NodeType.Tag, html.type);
    try std.testing.expectEqualStrings("html", html.name.?);
    try std.testing.expectEqual(@as(usize, 1), html.nodes.items.len);

    const body = html.nodes.items[0];
    try std.testing.expectEqual(NodeType.Tag, body.type);
    try std.testing.expectEqualStrings("body", body.name.?);
    try std.testing.expectEqual(@as(usize, 1), body.nodes.items.len);

    const h1 = body.nodes.items[0];
    try std.testing.expectEqual(NodeType.Tag, h1.type);
    try std.testing.expectEqualStrings("h1", h1.name.?);
    try std.testing.expectEqual(@as(usize, 1), h1.nodes.items.len);

    const text = h1.nodes.items[0];
    try std.testing.expectEqual(NodeType.Text, text.type);
    try std.testing.expectEqualStrings("Title", text.val.?);
}

test "parse tag with attributes" {
    const allocator = std.testing.allocator;

    var tokens = [_]Token{
        .{ .type = .tag, .val = .{ .string = "a" }, .loc = .{ .start = .{ .line = 1, .column = 1 } } },
        .{ .type = .start_attributes, .loc = .{ .start = .{ .line = 1, .column = 2 } } },
        .{ .type = .attribute, .name = .{ .string = "href" }, .val = .{ .string = "'/contact'" }, .must_escape = .{ .boolean = true }, .loc = .{ .start = .{ .line = 1, .column = 3 } } },
        .{ .type = .end_attributes, .loc = .{ .start = .{ .line = 1, .column = 18 } } },
        .{ .type = .text, .val = .{ .string = "contact" }, .loc = .{ .start = .{ .line = 1, .column = 20 } } },
        .{ .type = .eos, .loc = .{ .start = .{ .line = 1, .column = 27 } } },
    };

    var p = Parser.init(allocator, &tokens, "test.pug", null);
    defer p.deinit();

    const ast = try p.parse();
    defer {
        ast.deinit(allocator);
        allocator.destroy(ast);
    }

    try std.testing.expectEqual(@as(usize, 1), ast.nodes.items.len);

    const a_tag = ast.nodes.items[0];
    try std.testing.expectEqual(NodeType.Tag, a_tag.type);
    try std.testing.expectEqualStrings("a", a_tag.name.?);
    try std.testing.expectEqual(@as(usize, 1), a_tag.attrs.items.len);

    const href_attr = a_tag.attrs.items[0];
    try std.testing.expectEqualStrings("href", href_attr.name);
    try std.testing.expectEqualStrings("'/contact'", href_attr.val.?);
    try std.testing.expect(href_attr.must_escape);
}

test "parse conditional" {
    const allocator = std.testing.allocator;

    var tokens = [_]Token{
        .{ .type = .@"if", .val = .{ .string = "condition" }, .loc = .{ .start = .{ .line = 1, .column = 1 } } },
        .{ .type = .indent, .loc = .{ .start = .{ .line = 2, .column = 1 } } },
        .{ .type = .tag, .val = .{ .string = "p" }, .loc = .{ .start = .{ .line = 2, .column = 3 } } },
        .{ .type = .text, .val = .{ .string = "true" }, .loc = .{ .start = .{ .line = 2, .column = 5 } } },
        .{ .type = .outdent, .loc = .{ .start = .{ .line = 3, .column = 1 } } },
        .{ .type = .@"else", .loc = .{ .start = .{ .line = 3, .column = 1 } } },
        .{ .type = .indent, .loc = .{ .start = .{ .line = 4, .column = 1 } } },
        .{ .type = .tag, .val = .{ .string = "p" }, .loc = .{ .start = .{ .line = 4, .column = 3 } } },
        .{ .type = .text, .val = .{ .string = "false" }, .loc = .{ .start = .{ .line = 4, .column = 5 } } },
        .{ .type = .outdent, .loc = .{ .start = .{ .line = 5, .column = 1 } } },
        .{ .type = .eos, .loc = .{ .start = .{ .line = 5, .column = 1 } } },
    };

    var p = Parser.init(allocator, &tokens, "test.pug", null);
    defer p.deinit();

    const ast = try p.parse();
    defer {
        ast.deinit(allocator);
        allocator.destroy(ast);
    }

    try std.testing.expectEqual(@as(usize, 1), ast.nodes.items.len);

    const cond = ast.nodes.items[0];
    try std.testing.expectEqual(NodeType.Conditional, cond.type);
    try std.testing.expectEqualStrings("condition", cond.test_expr.?);
    try std.testing.expect(cond.consequent != null);
    try std.testing.expect(cond.alternate != null);
}
