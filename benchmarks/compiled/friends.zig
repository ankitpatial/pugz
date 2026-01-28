const std = @import("std");
const helpers = @import("helpers.zig");

pub const Data = struct {};

pub fn render(allocator: std.mem.Allocator, _: Data) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "<div class=\"'friend'\"><h3>friend_name</h3><p>friend_email</p><p>friend_about</p><span class=\"'tag'\">tag_value</span></div>");

    return buf.toOwnedSlice(allocator);
}
