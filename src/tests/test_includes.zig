const std = @import("std");
const pugz = @import("pugz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = pugz.ViewEngine.init(allocator, .{
        .views_dir = "test_views",
    }) catch |err| {
        std.debug.print("Init Error: {}\n", .{err});
        return err;
    };
    defer engine.deinit();

    const html = engine.render(allocator, "home", .{}) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return err;
    };
    defer allocator.free(html);

    std.debug.print("=== Rendered HTML ===\n{s}\n=== End ===\n", .{html});
}
