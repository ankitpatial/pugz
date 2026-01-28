// Example: Using compiled templates
//
// This demonstrates how to use templates compiled with pug-compile.
//
// Steps to generate templates:
// 1. Build: zig build
// 2. Compile templates: ./zig-out/bin/pug-compile --dir views --out generated pages
// 3. Run this example: zig build example-compiled

const std = @import("std");
const tpls = @import("generated");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Memory leak detected!\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("=== Compiled Templates Example ===\n\n", .{});

    // Render home page
    if (@hasDecl(tpls, "home")) {
        const home_html = try tpls.home.render(allocator, .{
            .title = "My Site",
            .name = "Alice",
        });
        defer allocator.free(home_html);

        std.debug.print("=== Home Page ===\n{s}\n\n", .{home_html});
    }

    // Render conditional page
    if (@hasDecl(tpls, "conditional")) {
        // Test logged in
        {
            const html = try tpls.conditional.render(allocator, .{
                .isLoggedIn = "true",
                .username = "Bob",
            });
            defer allocator.free(html);
            std.debug.print("=== Conditional Page (Logged In) ===\n{s}\n\n", .{html});
        }

        // Test logged out
        {
            const html = try tpls.conditional.render(allocator, .{
                .isLoggedIn = "",
                .username = "",
            });
            defer allocator.free(html);
            std.debug.print("=== Conditional Page (Logged Out) ===\n{s}\n\n", .{html});
        }
    }

    std.debug.print("=== Example Complete ===\n", .{});
}
