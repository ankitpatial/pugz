const std = @import("std");
const helpers = @import("helpers.zig");

pub const Data = struct {};

pub fn render(allocator: std.mem.Allocator, _: Data) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "<div><h3>result_title</h3><span>$result_price</span></div>");

    return buf.toOwnedSlice(allocator);
}
