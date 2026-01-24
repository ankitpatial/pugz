// Zig Pugz - Process all .pug files in playground/examples folder

const std = @import("std");
const pug = @import("../pug.zig");
const fs = std.fs;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Zig Pugz Playground ===\n\n", .{});

    // Open the examples directory relative to cwd
    var dir = fs.cwd().openDir("playground/examples", .{ .iterate = true }) catch |err| {
        // Try from playground directory
        dir = fs.cwd().openDir("examples", .{ .iterate = true }) catch {
            std.debug.print("Error opening examples directory: {}\n", .{err});
            return;
        };
    };
    defer dir.close();

    // Collect .pug files
    var files = std.ArrayList([]const u8).init(allocator);
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit();
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pug")) {
            const name = try allocator.dupe(u8, entry.name);
            try files.append(name);
        }
    }

    // Sort files
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    std.debug.print("Found {d} .pug files\n\n", .{files.items.len});

    var passed: usize = 0;
    var failed: usize = 0;
    var total_time_ns: u64 = 0;

    for (files.items) |filename| {
        // Read file
        const file = dir.openFile(filename, .{}) catch {
            std.debug.print("✗ {s}\n  → Could not open file\n\n", .{filename});
            failed += 1;
            continue;
        };
        defer file.close();

        const source = file.readToEndAlloc(allocator, 1024 * 1024) catch {
            std.debug.print("✗ {s}\n  → Could not read file\n\n", .{filename});
            failed += 1;
            continue;
        };
        defer allocator.free(source);

        // Benchmark
        const iterations: usize = 100;
        var success = false;
        var last_html: ?[]const u8 = null;

        // Warmup
        for (0..5) |_| {
            var result = pug.compile(allocator, source, .{}) catch continue;
            result.deinit(allocator);
        }

        var timer = try std.time.Timer.start();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            var result = pug.compile(allocator, source, .{}) catch break;
            if (i == iterations - 1) {
                last_html = result.html;
            } else {
                result.deinit(allocator);
            }
            success = true;
        }
        const elapsed_ns = timer.read();

        if (success and i == iterations) {
            const time_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0 / @as(f64, @floatFromInt(iterations));
            std.debug.print("✓ {s} ({d:.3} ms)\n", .{ filename, time_ms });

            // Show preview
            if (last_html) |html| {
                const max_len = @min(html.len, 200);
                std.debug.print("  → {s}{s}\n\n", .{ html[0..max_len], if (html.len > 200) "..." else "" });
                allocator.free(html);
            }

            passed += 1;
            total_time_ns += elapsed_ns;
        } else {
            std.debug.print("✗ {s}\n  → Compilation failed\n\n", .{filename});
            failed += 1;
        }
    }

    std.debug.print("=== Summary ===\n", .{});
    std.debug.print("Passed: {d}/{d}\n", .{ passed, files.items.len });
    std.debug.print("Failed: {d}/{d}\n", .{ failed, files.items.len });

    if (passed > 0) {
        const total_ms = @as(f64, @floatFromInt(total_time_ns)) / 1_000_000.0 / 100.0;
        std.debug.print("Total time: {d:.3} ms\n", .{total_ms});
        std.debug.print("Average: {d:.3} ms per file\n", .{total_ms / @as(f64, @floatFromInt(passed))});
    }
}
