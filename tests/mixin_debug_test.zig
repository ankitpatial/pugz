// This test is imported by root.zig for testing
const std = @import("std");
const testing = std.testing;
const mixin = @import("../mixin.zig");

test "bindArguments - with default value in param" {
    const allocator = testing.allocator;

    var bindings = std.StringHashMapUnmanaged([]const u8){};
    defer bindings.deinit(allocator);

    // This is how it appears: params have default, args are the call args
    try mixin.bindArguments(allocator, "text, type=\"primary\"", "\"Click Me\", \"primary\"", &bindings);

    std.debug.print("\nBindings:\n", .{});
    var iter = bindings.iterator();
    while (iter.next()) |entry| {
        std.debug.print("  {s} = '{s}'\n", .{entry.key_ptr.*, entry.value_ptr.*});
    }

    try testing.expectEqualStrings("Click Me", bindings.get("text").?);
    try testing.expectEqualStrings("primary", bindings.get("type").?);
}
