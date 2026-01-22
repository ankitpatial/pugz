//! Pugz Benchmark - Compiled Templates vs Pug.js
//!
//! Both Pugz and Pug.js benchmarks read from the same files:
//!   src/benchmarks/templates/*.pug  (templates)
//!   src/benchmarks/templates/*.json (data)
//!
//! Run Pugz:   zig build bench-all-compiled
//! Run Pug.js: cd src/benchmarks/pugjs && npm install && npm run bench

const std = @import("std");
const tpls = @import("tpls");

const iterations: usize = 2000;
const templates_dir = "src/benchmarks/templates";

// ═══════════════════════════════════════════════════════════════════════════
// Data structures matching JSON files
// ═══════════════════════════════════════════════════════════════════════════

const SubFriend = struct {
    id: i64,
    name: []const u8,
};

const Friend = struct {
    name: []const u8,
    balance: []const u8,
    age: i64,
    address: []const u8,
    picture: []const u8,
    company: []const u8,
    email: []const u8,
    emailHref: []const u8,
    about: []const u8,
    tags: []const []const u8,
    friends: []const SubFriend,
};

const Account = struct {
    balance: i64,
    balanceFormatted: []const u8,
    status: []const u8,
    negative: bool,
};

const Project = struct {
    name: []const u8,
    url: []const u8,
    description: []const u8,
};

const SearchRecord = struct {
    imgUrl: []const u8,
    viewItemUrl: []const u8,
    title: []const u8,
    description: []const u8,
    featured: bool,
    sizes: ?[]const []const u8,
};

// ═══════════════════════════════════════════════════════════════════════════
// Main
// ═══════════════════════════════════════════════════════════════════════════

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔═══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║   Compiled Zig Templates Benchmark ({d} iterations)          ║\n", .{iterations});
    std.debug.print("║   Templates: {s}/*.pug                           ║\n", .{templates_dir});
    std.debug.print("╚═══════════════════════════════════════════════════════════════╝\n", .{});

    // ─────────────────────────────────────────────────────────────────────────
    // Load JSON data
    // ─────────────────────────────────────────────────────────────────────────
    std.debug.print("\nLoading JSON data...\n", .{});

    var data_arena = std.heap.ArenaAllocator.init(allocator);
    defer data_arena.deinit();
    const data_alloc = data_arena.allocator();

    // Load all JSON files
    const simple0 = try loadJson(struct { name: []const u8 }, data_alloc, "simple-0.json");
    const simple1 = try loadJson(struct {
        name: []const u8,
        messageCount: i64,
        colors: []const []const u8,
        primary: bool,
    }, data_alloc, "simple-1.json");
    const simple2 = try loadJson(struct {
        header: []const u8,
        header2: []const u8,
        header3: []const u8,
        header4: []const u8,
        header5: []const u8,
        header6: []const u8,
        list: []const []const u8,
    }, data_alloc, "simple-2.json");
    const if_expr = try loadJson(struct { accounts: []const Account }, data_alloc, "if-expression.json");
    const projects = try loadJson(struct {
        title: []const u8,
        text: []const u8,
        projects: []const Project,
    }, data_alloc, "projects-escaped.json");
    const search = try loadJson(struct { searchRecords: []const SearchRecord }, data_alloc, "search-results.json");
    const friends_data = try loadJson(struct { friends: []const Friend }, data_alloc, "friends.json");

    std.debug.print("Loaded. Starting benchmark...\n\n", .{});

    var total: f64 = 0;

    // ─────────────────────────────────────────────────────────────────────────
    // Benchmark each template
    // ─────────────────────────────────────────────────────────────────────────

    // simple-0
    total += try bench("simple-0", allocator, tpls.simple_0, simple0);

    // simple-1
    total += try bench("simple-1", allocator, tpls.simple_1, simple1);

    // simple-2
    total += try bench("simple-2", allocator, tpls.simple_2, simple2);

    // if-expression
    total += try bench("if-expression", allocator, tpls.if_expression, if_expr);

    // projects-escaped
    total += try bench("projects-escaped", allocator, tpls.projects_escaped, projects);

    // search-results
    total += try bench("search-results", allocator, tpls.search_results, search);

    // friends
    total += try bench("friends", allocator, tpls.friends, friends_data);

    // ─────────────────────────────────────────────────────────────────────────
    // Summary
    // ─────────────────────────────────────────────────────────────────────────
    std.debug.print("\n", .{});
    std.debug.print("  {s:<20} => {d:>7.1}ms\n", .{ "TOTAL", total });
    std.debug.print("\n", .{});
}

fn loadJson(comptime T: type, alloc: std.mem.Allocator, comptime filename: []const u8) !T {
    const path = templates_dir ++ "/" ++ filename;
    const content = try std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024);
    const parsed = try std.json.parseFromSlice(T, alloc, content, .{});
    return parsed.value;
}

fn bench(
    name: []const u8,
    allocator: std.mem.Allocator,
    comptime render_fn: anytype,
    data: anytype,
) !f64 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        _ = try render_fn(arena.allocator(), data);
    }
    const ms = @as(f64, @floatFromInt(timer.read())) / 1_000_000.0;
    std.debug.print("  {s:<20} => {d:>7.1}ms\n", .{ name, ms });
    return ms;
}
