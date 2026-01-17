const std = @import("std");
const pugz = @import("pugz");

const friends_tpl =
    \\doctype html
    \\html(lang="en")
    \\  head
    \\    meta(charset="UTF-8")
    \\    title Friends
    \\  body
    \\    div.friends
    \\      each friend in friends
    \\        div.friend
    \\          ul
    \\            li Name: #{friend.name}
    \\            li Balance: #{friend.balance}
    \\            li Age: #{friend.age}
    \\            li Address: #{friend.address}
    \\            li Image:
    \\              img(src=friend.picture)
    \\            li Company: #{friend.company}
    \\            li Email:
    \\              a(href=friend.emailHref) #{friend.email}
    \\            li About: #{friend.about}
    \\            if friend.tags
    \\              li Tags:
    \\                ul
    \\                  each tag in friend.tags
    \\                    li #{tag}
    \\            if friend.friends
    \\              li Friends:
    \\                ul
    \\                  each subFriend in friend.friends
    \\                    li #{subFriend.name} (#{subFriend.id})
;

const SubFriend = struct { id: i32, name: []const u8 };
const Friend = struct {
    name: []const u8,
    balance: []const u8,
    age: i32,
    address: []const u8,
    picture: []const u8,
    company: []const u8,
    email: []const u8,
    emailHref: []const u8,
    about: []const u8,
    tags: ?[]const []const u8,
    friends: ?[]const SubFriend,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const engine = pugz.ViewEngine.init(.{});

    const friend_tags = &[_][]const u8{ "id", "amet", "non", "ut", "dolore", "commodo", "consequat" };
    const sub_friends = &[_]SubFriend{
        .{ .id = 0, .name = "Gates Lewis" },
        .{ .id = 1, .name = "Britt Stokes" },
        .{ .id = 2, .name = "Reed Wade" },
    };

    var friends_data: [100]Friend = undefined;
    for (&friends_data, 0..) |*f, i| {
        f.* = .{
            .name = "Gardner Alvarez",
            .balance = "$1,509.00",
            .age = 30 + @as(i32, @intCast(i % 20)),
            .address = "282 Lancaster Avenue, Bowden, Kansas, 666",
            .picture = "http://placehold.it/32x32",
            .company = "Dentrex",
            .email = "gardneralvarez@dentrex.com",
            .emailHref = "mailto:gardneralvarez@dentrex.com",
            .about = "Minim elit tempor enim voluptate labore do non nisi sint nulla deserunt officia proident excepteur.",
            .tags = friend_tags,
            .friends = sub_friends,
        };
    }

    const data = .{ .friends = &friends_data };

    // Warmup
    for (0..10) |_| {
        _ = arena.reset(.retain_capacity);
        _ = try engine.renderTpl(arena.allocator(), friends_tpl, data);
    }

    // Get output size
    _ = arena.reset(.retain_capacity);
    const output = try engine.renderTpl(arena.allocator(), friends_tpl, data);
    const output_size = output.len;

    // Profile render
    const iterations: usize = 500;
    var total_render: u64 = 0;
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        timer.reset();
        _ = try engine.renderTpl(arena.allocator(), friends_tpl, data);
        total_render += timer.read();
    }

    const avg_render_us = @as(f64, @floatFromInt(total_render)) / @as(f64, @floatFromInt(iterations)) / 1000.0;
    const total_ms = @as(f64, @floatFromInt(total_render)) / 1_000_000.0;

    // Header
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           FRIENDS TEMPLATE CPU PROFILE                       ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║ Iterations: {d:<6}  Output size: {d:<6} bytes               ║\n", .{ iterations, output_size });
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n\n", .{});

    // Results
    std.debug.print("┌────────────────────────────────────┬─────────────────────────┐\n", .{});
    std.debug.print("│ Metric                             │ Value                   │\n", .{});
    std.debug.print("├────────────────────────────────────┼─────────────────────────┤\n", .{});
    std.debug.print("│ Total time                         │ {d:>10.1} ms           │\n", .{total_ms});
    std.debug.print("│ Avg per render                     │ {d:>10.1} µs           │\n", .{avg_render_us});
    std.debug.print("│ Renders/sec                        │ {d:>10.0}              │\n", .{1_000_000.0 / avg_render_us});
    std.debug.print("└────────────────────────────────────┴─────────────────────────┘\n", .{});

    // Template complexity breakdown
    std.debug.print("\n📋 Template Complexity:\n", .{});
    std.debug.print("   • 100 friends (outer loop)\n", .{});
    std.debug.print("   • 7 tags per friend (nested loop) = 700 tag iterations\n", .{});
    std.debug.print("   • 3 sub-friends per friend (nested loop) = 300 sub-friend iterations\n", .{});
    std.debug.print("   • Total loop iterations: 100 + 700 + 300 = 1,100\n", .{});
    std.debug.print("   • ~10 interpolations per friend = 1,000+ variable lookups\n", .{});
    std.debug.print("   • 2 conditionals per friend = 200 conditional evaluations\n", .{});

    // Cost breakdown estimate
    const loop_iterations: f64 = 1100;
    const var_lookups: f64 = 1500; // approximate

    std.debug.print("\n💡 Estimated Cost Breakdown (per render):\n", .{});
    std.debug.print("   Total: {d:.1} µs\n", .{avg_render_us});
    std.debug.print("   Per loop iteration: ~{d:.2} µs ({d:.0} iterations)\n", .{ avg_render_us / loop_iterations, loop_iterations });
    std.debug.print("   Per variable lookup: ~{d:.3} µs ({d:.0} lookups)\n", .{ avg_render_us / var_lookups, var_lookups });

    // Comparison
    std.debug.print("\n📊 Comparison with Pug.js:\n", .{});
    const pugjs_us: f64 = 55.0; // From benchmark: 110ms / 2000 = 55µs
    std.debug.print("   Pug.js:  {d:.1} µs/render\n", .{pugjs_us});
    std.debug.print("   Pugz:    {d:.1} µs/render\n", .{avg_render_us});
    const ratio = avg_render_us / pugjs_us;
    if (ratio > 1.0) {
        std.debug.print("   Status:  Pugz is {d:.1}x SLOWER\n", .{ratio});
    } else {
        std.debug.print("   Status:  Pugz is {d:.1}x FASTER\n", .{1.0 / ratio});
    }

    std.debug.print("\nKey Bottlenecks (likely):\n", .{});
    std.debug.print("   1. Data conversion: Zig struct -> pugz.Value (comptime reflection)\n", .{});
    std.debug.print("   2. Variable lookup: HashMap get() for each interpolation\n", .{});
    std.debug.print("   3. AST traversal: Walking tree nodes vs Pug.js compiled JS functions\n", .{});
    std.debug.print("   4. Loop scope: Creating/clearing scope per loop iteration\n", .{});

    std.debug.print("\nAlready optimized:\n", .{});
    std.debug.print("   - Scope pooling (reuse hashmap capacity)\n", .{});
    std.debug.print("   - Batched HTML escaping\n", .{});
    std.debug.print("   - Arena allocator with retain_capacity\n", .{});
}
