// benchmark.zig - Benchmark for pugz (Zig Pug implementation)
//
// This benchmark matches the JavaScript pug benchmark for comparison
// Uses exact same templates as packages/pug/support/benchmark.js

const std = @import("std");
const pug = @import("../pug.zig");

const MIN_ITERATIONS: usize = 200;
const MIN_TIME_NS: u64 = 200_000_000; // 200ms minimum

fn benchmark(comptime name: []const u8, template: []const u8, iterations: *usize, elapsed_ns: *u64) !void {
    const allocator = std.heap.page_allocator;

    // Warmup
    for (0..10) |_| {
        var result = try pug.compile(allocator, template, .{});
        result.deinit(allocator);
    }

    var timer = try std.time.Timer.start();

    var count: usize = 0;
    while (count < MIN_ITERATIONS or timer.read() < MIN_TIME_NS) {
        var result = try pug.compile(allocator, template, .{});
        result.deinit(allocator);
        count += 1;
    }

    const elapsed = timer.read();
    iterations.* = count;
    elapsed_ns.* = elapsed;

    const ops_per_sec = @as(f64, @floatFromInt(count)) * 1_000_000_000.0 / @as(f64, @floatFromInt(elapsed));
    std.debug.print("{s}: {d:.0}\n", .{ name, ops_per_sec });
}

pub fn main() !void {
    var iterations: usize = 0;
    var elapsed_ns: u64 = 0;

    // Tiny template - exact match to JS: 'html\n  body\n    h1 Title'
    const tiny = "html\n  body\n    h1 Title";
    try benchmark("tiny", tiny, &iterations, &elapsed_ns);

    // Small template - exact match to JS (note trailing \n on each line)
    const small =
        "html\n" ++
        "  body\n" ++
        "    h1 Title\n" ++
        "    ul#menu\n" ++
        "      li: a(href=\"#\") Home\n" ++
        "      li: a(href=\"#\") About Us\n" ++
        "      li: a(href=\"#\") Store\n" ++
        "      li: a(href=\"#\") FAQ\n" ++
        "      li: a(href=\"#\") Contact\n";
    try benchmark("small", small, &iterations, &elapsed_ns);

    // Medium template - Array(30).join(str) creates 29 copies in JS
    const medium = small ** 29;
    try benchmark("medium", medium, &iterations, &elapsed_ns);

    // Large template - Array(100).join(str) creates 99 copies in JS
    const large = small ** 99;
    try benchmark("large", large, &iterations, &elapsed_ns);
}
