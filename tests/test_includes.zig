const std = @import("std");
const pugz = @import("pugz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test: Simple include from test_views
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

    // Verify output contains included content
    if (std.mem.indexOf(u8, html, "Included Partial") != null and
        std.mem.indexOf(u8, html, "info-box") != null)
    {
        std.debug.print("\nSUCCESS: Include directive works correctly!\n", .{});
    } else {
        std.debug.print("\nFAILURE: Include content not found!\n", .{});
        return error.TestFailed;
    }
}
