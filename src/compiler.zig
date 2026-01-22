//! Pugz Compiler - Compiles Pug templates to efficient Zig functions.
//!
//! Generates Zig source code that can be @import'd and called directly,
//! avoiding AST interpretation overhead entirely.

const std = @import("std");
const ast = @import("ast.zig");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;

/// Compiles a Pug source string to a Zig function.
pub fn compileSource(allocator: std.mem.Allocator, name: []const u8, source: []const u8) ![]u8 {
    var lexer = Lexer.init(allocator, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(allocator, tokens);
    const doc = try parser.parse();

    return compileDoc(allocator, name, doc);
}

/// Compiles an AST Document to a Zig function.
pub fn compileDoc(allocator: std.mem.Allocator, name: []const u8, doc: ast.Document) ![]u8 {
    var c = Compiler.init(allocator);
    defer c.deinit();
    return c.compile(name, doc);
}

const Compiler = struct {
    alloc: std.mem.Allocator,
    out: std.ArrayListUnmanaged(u8),
    depth: u8,

    fn init(allocator: std.mem.Allocator) Compiler {
        return .{
            .alloc = allocator,
            .out = .{},
            .depth = 0,
        };
    }

    fn deinit(self: *Compiler) void {
        self.out.deinit(self.alloc);
    }

    fn compile(self: *Compiler, name: []const u8, doc: ast.Document) ![]u8 {
        // Header
        try self.w(
            \\const std = @import("std");
            \\
            \\/// HTML escape lookup table
            \\const esc_table = blk: {
            \\    var t: [256]?[]const u8 = .{null} ** 256;
            \\    t['&'] = "&amp;";
            \\    t['<'] = "&lt;";
            \\    t['>'] = "&gt;";
            \\    t['"'] = "&quot;";
            \\    t['\''] = "&#x27;";
            \\    break :blk t;
            \\};
            \\
            \\fn esc(out: *std.ArrayList(u8), s: []const u8) !void {
            \\    var i: usize = 0;
            \\    for (s, 0..) |c, j| {
            \\        if (esc_table[c]) |e| {
            \\            if (j > i) try out.appendSlice(s[i..j]);
            \\            try out.appendSlice(e);
            \\            i = j + 1;
            \\        }
            \\    }
            \\    if (i < s.len) try out.appendSlice(s[i..]);
            \\}
            \\
            \\fn toStr(v: anytype) []const u8 {
            \\    const T = @TypeOf(v);
            \\    if (T == []const u8) return v;
            \\    if (@typeInfo(T) == .optional) {
            \\        if (v) |inner| return toStr(inner);
            \\        return "";
            \\    }
            \\    return "";
            \\}
            \\
            \\
        );

        // Function signature
        try self.w("pub fn ");
        try self.w(name);
        try self.w("(out: *std.ArrayList(u8), data: anytype) !void {\n");
        self.depth = 1;

        // Body
        for (doc.nodes) |n| {
            try self.node(n);
        }

        try self.w("}\n");
        return try self.alloc.dupe(u8, self.out.items);
    }

    fn node(self: *Compiler, n: ast.Node) anyerror!void {
        switch (n) {
            .doctype => |d| try self.doctype(d),
            .element => |e| try self.element(e),
            .text => |t| try self.text(t.segments),
            .conditional => |c| try self.conditional(c),
            .each => |e| try self.each(e),
            .raw_text => |r| try self.raw(r.content),
            .comment => |c| if (c.rendered) try self.comment(c),
            .code => |c| try self.code(c),
            .document => |d| for (d.nodes) |child| try self.node(child),
            .mixin_def, .mixin_call, .mixin_block, .@"while", .case, .block, .include, .extends => {},
        }
    }

    fn doctype(self: *Compiler, d: ast.Doctype) !void {
        try self.indent();
        if (std.mem.eql(u8, d.value, "html")) {
            try self.w("try out.appendSlice(\"<!DOCTYPE html>\");\n");
        } else {
            try self.w("try out.appendSlice(\"<!DOCTYPE ");
            try self.wEsc(d.value);
            try self.w(">\");\n");
        }
    }

    fn element(self: *Compiler, e: ast.Element) anyerror!void {
        const is_void = isVoid(e.tag) or e.self_closing;

        // Open tag
        try self.indent();
        try self.w("try out.appendSlice(\"<");
        try self.w(e.tag);

        // ID
        if (e.id) |id| {
            try self.w(" id=\\\"");
            try self.wEsc(id);
            try self.w("\\\"");
        }

        // Classes
        if (e.classes.len > 0) {
            try self.w(" class=\\\"");
            for (e.classes, 0..) |cls, i| {
                if (i > 0) try self.w(" ");
                try self.wEsc(cls);
            }
            try self.w("\\\"");
        }

        // Static attributes (close the appendSlice, handle dynamic separately)
        var has_dynamic = false;
        for (e.attributes) |attr| {
            if (attr.value) |v| {
                if (isDynamic(v)) {
                    has_dynamic = true;
                    continue;
                }
                try self.w(" ");
                try self.w(attr.name);
                try self.w("=\\\"");
                try self.wEsc(stripQuotes(v));
                try self.w("\\\"");
            } else {
                try self.w(" ");
                try self.w(attr.name);
                try self.w("=\\\"");
                try self.w(attr.name);
                try self.w("\\\"");
            }
        }

        if (is_void and !has_dynamic) {
            try self.w(" />\");\n");
            return;
        }
        if (!has_dynamic and e.inline_text == null and e.buffered_code == null) {
            try self.w(">\");\n");
        } else {
            try self.w("\");\n");
        }

        // Dynamic attributes
        for (e.attributes) |attr| {
            if (attr.value) |v| {
                if (isDynamic(v)) {
                    try self.indent();
                    try self.w("try out.appendSlice(\" ");
                    try self.w(attr.name);
                    try self.w("=\\\"\");\n");
                    try self.indent();
                    try self.expr(v, attr.escaped);
                    try self.indent();
                    try self.w("try out.appendSlice(\"\\\"\");\n");
                }
            }
        }

        if (has_dynamic or e.inline_text != null or e.buffered_code != null) {
            try self.indent();
            if (is_void) {
                try self.w("try out.appendSlice(\" />\");\n");
                return;
            }
            try self.w("try out.appendSlice(\">\");\n");
        }

        // Inline text
        if (e.inline_text) |segs| {
            try self.text(segs);
        }

        // Buffered code (p= expr)
        if (e.buffered_code) |bc| {
            try self.indent();
            try self.expr(bc.expression, bc.escaped);
        }

        // Children
        self.depth += 1;
        for (e.children) |child| {
            try self.node(child);
        }
        self.depth -= 1;

        // Close tag
        try self.indent();
        try self.w("try out.appendSlice(\"</");
        try self.w(e.tag);
        try self.w(">\");\n");
    }

    fn text(self: *Compiler, segs: []const ast.TextSegment) anyerror!void {
        for (segs) |seg| {
            switch (seg) {
                .literal => |lit| {
                    try self.indent();
                    try self.w("try out.appendSlice(\"");
                    try self.wEsc(lit);
                    try self.w("\");\n");
                },
                .interp_escaped => |e| {
                    try self.indent();
                    try self.expr(e, true);
                },
                .interp_unescaped => |e| {
                    try self.indent();
                    try self.expr(e, false);
                },
                .interp_tag => |t| try self.inlineTag(t),
            }
        }
    }

    fn inlineTag(self: *Compiler, t: ast.InlineTag) anyerror!void {
        try self.indent();
        try self.w("try out.appendSlice(\"<");
        try self.w(t.tag);
        if (t.id) |id| {
            try self.w(" id=\\\"");
            try self.wEsc(id);
            try self.w("\\\"");
        }
        if (t.classes.len > 0) {
            try self.w(" class=\\\"");
            for (t.classes, 0..) |cls, i| {
                if (i > 0) try self.w(" ");
                try self.wEsc(cls);
            }
            try self.w("\\\"");
        }
        try self.w(">\");\n");
        try self.text(t.text_segments);
        try self.indent();
        try self.w("try out.appendSlice(\"</");
        try self.w(t.tag);
        try self.w(">\");\n");
    }

    fn conditional(self: *Compiler, c: ast.Conditional) anyerror!void {
        for (c.branches, 0..) |br, i| {
            try self.indent();
            if (i == 0) {
                if (br.is_unless) {
                    try self.w("if (!");
                } else {
                    try self.w("if (");
                }
                try self.cond(br.condition orelse "true");
                try self.w(") {\n");
            } else if (br.condition) |cnd| {
                try self.w("} else if (");
                try self.cond(cnd);
                try self.w(") {\n");
            } else {
                try self.w("} else {\n");
            }
            self.depth += 1;
            for (br.children) |child| try self.node(child);
            self.depth -= 1;
        }
        try self.indent();
        try self.w("}\n");
    }

    fn cond(self: *Compiler, c: []const u8) !void {
        // Check for field access: convert "field" to "@hasField(...) and data.field"
        // and "obj.field" to "obj.field" (assuming obj is a loop var)
        if (std.mem.indexOfScalar(u8, c, '.')) |_| {
            try self.w(c);
        } else {
            try self.w("@hasField(@TypeOf(data), \"");
            try self.w(c);
            try self.w("\") and @field(data, \"");
            try self.w(c);
            try self.w("\") != null");
        }
    }

    fn each(self: *Compiler, e: ast.Each) anyerror!void {
        // Parse collection - could be "items" or "obj.items"
        const col = e.collection;

        try self.indent();
        if (std.mem.indexOfScalar(u8, col, '.')) |dot| {
            // Nested: for (parent.field) |item|
            try self.w("for (");
            try self.w(col[0..dot]);
            try self.w(".");
            try self.w(col[dot + 1 ..]);
            try self.w(") |");
        } else {
            // Top-level: for (data.field) |item|
            try self.w("if (@hasField(@TypeOf(data), \"");
            try self.w(col);
            try self.w("\")) {\n");
            self.depth += 1;
            try self.indent();
            try self.w("for (@field(data, \"");
            try self.w(col);
            try self.w("\")) |");
        }

        try self.w(e.value_name);
        if (e.index_name) |idx| {
            try self.w(", ");
            try self.w(idx);
        }
        try self.w("| {\n");

        self.depth += 1;
        for (e.children) |child| try self.node(child);
        self.depth -= 1;

        try self.indent();
        try self.w("}\n");

        // Close the hasField block for top-level
        if (std.mem.indexOfScalar(u8, col, '.') == null) {
            self.depth -= 1;
            try self.indent();
            try self.w("}\n");
        }
    }

    fn code(self: *Compiler, c: ast.Code) !void {
        try self.indent();
        try self.expr(c.expression, c.escaped);
    }

    fn expr(self: *Compiler, e: []const u8, escaped: bool) !void {
        // Parse: "name" (data field), "item.name" (loop var field)
        if (std.mem.indexOfScalar(u8, e, '.')) |dot| {
            const base = e[0..dot];
            const field = e[dot + 1 ..];
            if (escaped) {
                try self.w("try esc(out, toStr(");
                try self.w(base);
                try self.w(".");
                try self.w(field);
                try self.w("));\n");
            } else {
                try self.w("try out.appendSlice(toStr(");
                try self.w(base);
                try self.w(".");
                try self.w(field);
                try self.w("));\n");
            }
        } else {
            if (escaped) {
                try self.w("try esc(out, toStr(@field(data, \"");
                try self.w(e);
                try self.w("\")));\n");
            } else {
                try self.w("try out.appendSlice(toStr(@field(data, \"");
                try self.w(e);
                try self.w("\")));\n");
            }
        }
    }

    fn raw(self: *Compiler, content: []const u8) !void {
        try self.indent();
        try self.w("try out.appendSlice(\"");
        try self.wEsc(content);
        try self.w("\");\n");
    }

    fn comment(self: *Compiler, c: ast.Comment) !void {
        try self.indent();
        try self.w("try out.appendSlice(\"<!-- ");
        try self.wEsc(c.content);
        try self.w(" -->\");\n");
    }

    // Helpers
    fn indent(self: *Compiler) !void {
        for (0..self.depth) |_| try self.out.appendSlice(self.alloc, "    ");
    }

    fn w(self: *Compiler, s: []const u8) !void {
        try self.out.appendSlice(self.alloc, s);
    }

    fn wEsc(self: *Compiler, s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '\\' => try self.out.appendSlice(self.alloc, "\\\\"),
                '"' => try self.out.appendSlice(self.alloc, "\\\""),
                '\n' => try self.out.appendSlice(self.alloc, "\\n"),
                '\r' => try self.out.appendSlice(self.alloc, "\\r"),
                '\t' => try self.out.appendSlice(self.alloc, "\\t"),
                else => try self.out.append(self.alloc, c),
            }
        }
    }
};

fn isDynamic(v: []const u8) bool {
    if (v.len < 2) return true;
    return v[0] != '"' and v[0] != '\'';
}

fn stripQuotes(v: []const u8) []const u8 {
    if (v.len >= 2 and (v[0] == '"' or v[0] == '\'')) {
        return v[1 .. v.len - 1];
    }
    return v;
}

fn isVoid(tag: []const u8) bool {
    const voids = std.StaticStringMap(void).initComptime(.{
        .{ "area", {} },  .{ "base", {} }, .{ "br", {} },    .{ "col", {} },
        .{ "embed", {} }, .{ "hr", {} },   .{ "img", {} },   .{ "input", {} },
        .{ "link", {} },  .{ "meta", {} }, .{ "param", {} }, .{ "source", {} },
        .{ "track", {} }, .{ "wbr", {} },
    });
    return voids.has(tag);
}

test "compile simple template" {
    const allocator = std.testing.allocator;
    const source = "p Hello";

    const code = try compileSource(allocator, "simple", source);
    defer allocator.free(code);

    std.debug.print("\n{s}\n", .{code});
}
