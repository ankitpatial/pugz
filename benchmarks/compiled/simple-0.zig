const std = @import("std");
const helpers = @import("helpers.zig");

pub const Data = struct {};

pub fn render(allocator: std.mem.Allocator, _: Data) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "<p>Hello World</p>");

    return buf.toOwnedSlice(allocator);
}
