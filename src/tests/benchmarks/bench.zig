//! Pugz Benchmark - Template Rendering
//!
//! Three benchmark modes (best of 5 runs each):
//! 1. Cached AST: Parse once, render many times (matches Pug.js behavior)
//! 2. No Cache: Parse + render on every iteration
//! 3. Compiled: Pre-compiled templates to Zig code (zero parse overhead)
//!
//! Run: zig build bench

const std = @import("std");
const pugz = @import("pugz");
const compiled = @import("bench_compiled");

const iterations: usize = 2000;
const runs: usize = 5; // Best of 5
const templates_dir = "benchmarks/templates";

// Data structures matching JSON files
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load JSON data
    var data_arena = std.heap.ArenaAllocator.init(allocator);
    defer data_arena.deinit();
    const data_alloc = data_arena.allocator();

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

    // Load template sources
    const simple0_tpl = try loadTemplate(data_alloc, "simple-0.pug");
    const simple1_tpl = try loadTemplate(data_alloc, "simple-1.pug");
    const simple2_tpl = try loadTemplate(data_alloc, "simple-2.pug");
    const if_expr_tpl = try loadTemplate(data_alloc, "if-expression.pug");
    const projects_tpl = try loadTemplate(data_alloc, "projects-escaped.pug");
    const search_tpl = try loadTemplate(data_alloc, "search-results.pug");
    const friends_tpl = try loadTemplate(data_alloc, "friends.pug");

    // ═══════════════════════════════════════════════════════════════════════
    // Benchmark 1: Cached AST (parse once, render many)
    // ═══════════════════════════════════════════════════════════════════════
    std.debug.print("\n", .{});
    std.debug.print("╔═══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║   Pugz Benchmark - CACHED AST ({d} iterations, best of {d})      ║\n", .{ iterations, runs });
    std.debug.print("║   Mode: Parse once, render many (like Pug.js)                 ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════════╝\n", .{});

    std.debug.print("\nParsing templates...\n", .{});

    const simple0_ast = try pugz.template.parse(data_alloc, simple0_tpl);
    const simple1_ast = try pugz.template.parse(data_alloc, simple1_tpl);
    const simple2_ast = try pugz.template.parse(data_alloc, simple2_tpl);
    const if_expr_ast = try pugz.template.parse(data_alloc, if_expr_tpl);
    const projects_ast = try pugz.template.parse(data_alloc, projects_tpl);
    const search_ast = try pugz.template.parse(data_alloc, search_tpl);
    const friends_ast = try pugz.template.parse(data_alloc, friends_tpl);

    std.debug.print("Starting benchmark (render only)...\n\n", .{});

    var total_cached: f64 = 0;
    total_cached += try benchCached("simple-0", allocator, simple0_ast, simple0);
    total_cached += try benchCached("simple-1", allocator, simple1_ast, simple1);
    total_cached += try benchCached("simple-2", allocator, simple2_ast, simple2);
    total_cached += try benchCached("if-expression", allocator, if_expr_ast, if_expr);
    total_cached += try benchCached("projects-escaped", allocator, projects_ast, projects);
    total_cached += try benchCached("search-results", allocator, search_ast, search);
    total_cached += try benchCached("friends", allocator, friends_ast, friends_data);

    std.debug.print("\n", .{});
    std.debug.print("  {s:<20} => {d:>7.1}ms\n", .{ "TOTAL (cached)", total_cached });
    std.debug.print("\n", .{});

    // ═══════════════════════════════════════════════════════════════════════
    // Benchmark 2: No Cache (parse + render every time)
    // ═══════════════════════════════════════════════════════════════════════
    std.debug.print("\n", .{});
    std.debug.print("╔═══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║   Pugz Benchmark - NO CACHE ({d} iterations, best of {d})        ║\n", .{ iterations, runs });
    std.debug.print("║   Mode: Parse + render every iteration                        ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════════╝\n", .{});

    std.debug.print("\nStarting benchmark (parse + render)...\n\n", .{});

    var total_nocache: f64 = 0;
    total_nocache += try benchNoCache("simple-0", allocator, simple0_tpl, simple0);
    total_nocache += try benchNoCache("simple-1", allocator, simple1_tpl, simple1);
    total_nocache += try benchNoCache("simple-2", allocator, simple2_tpl, simple2);
    total_nocache += try benchNoCache("if-expression", allocator, if_expr_tpl, if_expr);
    total_nocache += try benchNoCache("projects-escaped", allocator, projects_tpl, projects);
    total_nocache += try benchNoCache("search-results", allocator, search_tpl, search);
    total_nocache += try benchNoCache("friends", allocator, friends_tpl, friends_data);

    std.debug.print("\n", .{});
    std.debug.print("  {s:<20} => {d:>7.1}ms\n", .{ "TOTAL (no cache)", total_nocache });
    std.debug.print("\n", .{});

    // ═══════════════════════════════════════════════════════════════════════
    // Benchmark 3: Compiled Templates (zero parse overhead)
    // ═══════════════════════════════════════════════════════════════════════
    std.debug.print("\n", .{});
    std.debug.print("╔═══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║   Pugz Benchmark - COMPILED ({d} iterations, best of {d})        ║\n", .{ iterations, runs });
    std.debug.print("║   Mode: Pre-compiled .pug → .zig (no parse overhead)          ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════════╝\n", .{});

    std.debug.print("\nStarting benchmark (compiled templates)...\n\n", .{});

    var total_compiled: f64 = 0;
    total_compiled += try benchCompiled("simple-0", allocator, compiled.simple_0);
    total_compiled += try benchCompiled("simple-1", allocator, compiled.simple_1);
    total_compiled += try benchCompiled("simple-2", allocator, compiled.simple_2);
    total_compiled += try benchCompiled("if-expression", allocator, compiled.if_expression);
    total_compiled += try benchCompiled("projects-escaped", allocator, compiled.projects_escaped);
    total_compiled += try benchCompiled("search-results", allocator, compiled.search_results);
    total_compiled += try benchCompiled("friends", allocator, compiled.friends);

    std.debug.print("\n", .{});
    std.debug.print("  {s:<20} => {d:>7.1}ms\n", .{ "TOTAL (compiled)", total_compiled });
    std.debug.print("\n", .{});

    // ═══════════════════════════════════════════════════════════════════════
    // Summary
    // ═══════════════════════════════════════════════════════════════════════
    std.debug.print("╔═══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║   SUMMARY                                                      ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("  Cached AST (render only):  {d:>7.1}ms\n", .{total_cached});
    std.debug.print("  No Cache (parse+render):   {d:>7.1}ms\n", .{total_nocache});
    if (total_compiled > 0) {
        std.debug.print("  Compiled (zero parse):     {d:>7.1}ms\n", .{total_compiled});
    }
    std.debug.print("\n", .{});
    std.debug.print("  Parse overhead:            {d:>7.1}ms ({d:.1}%)\n", .{
        total_nocache - total_cached,
        ((total_nocache - total_cached) / total_nocache) * 100.0,
    });
    if (total_compiled > 0) {
        std.debug.print("  Cached vs Compiled:        {d:>7.1}ms ({d:.1}x faster)\n", .{
            total_cached - total_compiled,
            total_cached / total_compiled,
        });
    }
    std.debug.print("\n", .{});
}

fn loadJson(comptime T: type, alloc: std.mem.Allocator, comptime filename: []const u8) !T {
    const path = templates_dir ++ "/" ++ filename;
    const content = try std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024);
    const parsed = try std.json.parseFromSlice(T, alloc, content, .{});
    return parsed.value;
}

fn loadTemplate(alloc: std.mem.Allocator, comptime filename: []const u8) ![]const u8 {
    const path = templates_dir ++ "/" ++ filename;
    return try std.fs.cwd().readFileAlloc(alloc, path, 1 * 1024 * 1024);
}

// Benchmark with cached AST (render only) - Best of 5 runs
fn benchCached(
    name: []const u8,
    allocator: std.mem.Allocator,
    ast: *pugz.parser.Node,
    data: anytype,
) !f64 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var best_ms: f64 = std.math.inf(f64);

    for (0..runs) |_| {
        _ = arena.reset(.retain_capacity);
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            _ = arena.reset(.retain_capacity);
            _ = pugz.template.renderAst(arena.allocator(), ast, data) catch |err| {
                std.debug.print("  {s:<20} => ERROR: {}\n", .{ name, err });
                return 0;
            };
        }
        const ms = @as(f64, @floatFromInt(timer.read())) / 1_000_000.0;
        if (ms < best_ms) best_ms = ms;
    }

    std.debug.print("  {s:<20} => {d:>7.1}ms\n", .{ name, best_ms });
    return best_ms;
}

// Benchmark without cache (parse + render every iteration) - Best of 5 runs
fn benchNoCache(
    name: []const u8,
    allocator: std.mem.Allocator,
    source: []const u8,
    data: anytype,
) !f64 {
    var best_ms: f64 = std.math.inf(f64);

    for (0..runs) |_| {
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            _ = pugz.template.renderWithData(arena.allocator(), source, data) catch |err| {
                std.debug.print("  {s:<20} => ERROR: {}\n", .{ name, err });
                return 0;
            };
        }
        const ms = @as(f64, @floatFromInt(timer.read())) / 1_000_000.0;
        if (ms < best_ms) best_ms = ms;
    }

    std.debug.print("  {s:<20} => {d:>7.1}ms\n", .{ name, best_ms });
    return best_ms;
}

// Benchmark compiled templates (zero parse overhead) - Best of 5 runs
fn benchCompiled(
    name: []const u8,
    allocator: std.mem.Allocator,
    comptime tpl: type,
) !f64 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var best_ms: f64 = std.math.inf(f64);

    for (0..runs) |_| {
        _ = arena.reset(.retain_capacity);
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            _ = arena.reset(.retain_capacity);
            _ = tpl.render(arena.allocator(), .{}) catch |err| {
                std.debug.print("  {s:<20} => ERROR: {}\n", .{ name, err });
                return 0;
            };
        }
        const ms = @as(f64, @floatFromInt(timer.read())) / 1_000_000.0;
        if (ms < best_ms) best_ms = ms;
    }

    std.debug.print("  {s:<20} => {d:>7.1}ms\n", .{ name, best_ms });
    return best_ms;
}
