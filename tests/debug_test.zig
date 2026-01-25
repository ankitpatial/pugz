const std = @import("std");
const lexer_mod = @import("../lexer.zig");
const parser_mod = @import("../parser.zig");
const ast = @import("../ast.zig");

test "debug block expansion" {
    const alloc = std.testing.allocator;
    
    const pug = 
        \\ul
        \\  li.list-item: .foo: #bar baz
    ;
    
    var lexer = lexer_mod.Lexer.init(alloc, pug);
    const tokens = try lexer.tokenize();
    
    var parser = parser_mod.Parser.init(alloc, tokens);
    const doc = try parser.parse();
    
    // Print structure
    std.debug.print("\n", .{});
    for (doc.nodes) |node| {
        printNode(node, 0);
    }
}

fn printNode(node: ast.Node, depth: usize) void {
    var i: usize = 0;
    while (i < depth * 2) : (i += 1) {
        std.debug.print(" ", .{});
    }
    switch (node) {
        .element => |elem| {
            std.debug.print("element: {s} is_inline={} children={d}", .{elem.tag, elem.is_inline, elem.children.len});
            if (elem.inline_text != null) {
                std.debug.print(" (has inline_text)", .{});
            }
            std.debug.print("\n", .{});
            for (elem.children) |child| {
                printNode(child, depth + 1);
            }
        },
        .text => |_| std.debug.print("text\n", .{}),
        else => std.debug.print("other\n", .{}),
    }
}
