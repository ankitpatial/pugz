const std = @import("std");
const pugz = @import("pugz");

test "debug mixin tokens" {
    const allocator = std.testing.allocator;
    
    const template = "+pet('cat')";
    
    var lexer = pugz.Lexer.init(allocator, template);
    defer lexer.deinit();
    
    const tokens = try lexer.tokenize();
    
    std.debug.print("\n=== Tokens for: {s} ===\n", .{template});
    for (tokens, 0..) |tok, i| {
        std.debug.print("{d}: {s} = '{s}'\n", .{i, @tagName(tok.type), tok.value});
    }
}
