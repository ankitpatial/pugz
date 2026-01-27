const std = @import("std");
const pugz = @import("pugz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Use ArenaAllocator for ViewEngine (recommended pattern)
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Test: Simple include from test_views
    var engine = pugz.ViewEngine.init(.{
        .views_dir = "tests/sample/01",
    });
    defer engine.deinit();

    const html = engine.render(arena_alloc, "home", .{}) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return err;
    };

    std.debug.print("=== Rendered HTML ===\n{s}\n=== End ===\n", .{html});

    // Verify output contains mixin-generated content
    if (std.mem.indexOf(u8, html, "card") != null and
        std.mem.indexOf(u8, html, "Title") != null and
        std.mem.indexOf(u8, html, "content here") != null)
    {
        std.debug.print("\nSUCCESS: Include and mixin directives work correctly!\n", .{});
    } else {
        std.debug.print("\nFAILURE: Expected content not found!\n", .{});
        return error.TestFailed;
    }
}
