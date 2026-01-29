const std = @import("std");
const helpers = @import("helpers.zig");

pub const Data = struct {};

pub fn render(allocator: std.mem.Allocator, _: Data) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "<!DOCTYPE html><html><head><title>My Site</title></head><body><h1>Welcome</h1><p>This is a simple page</p></body></html>");

    return buf.toOwnedSlice(allocator);
}
