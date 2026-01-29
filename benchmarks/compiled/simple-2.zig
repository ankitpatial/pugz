const std = @import("std");
const helpers = @import("helpers.zig");

pub const Data = struct {};

pub fn render(allocator: std.mem.Allocator, _: Data) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "<h1>Header</h1><h2>Header2</h2><h3>Header3</h3><h4>Header4</h4><h5>Header5</h5><h6>Header6</h6><ul><li>item1</li><li>item2</li><li>item3</li></ul>");

    return buf.toOwnedSlice(allocator);
}
