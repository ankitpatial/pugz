//! Pugz Rendering Benchmark
//!
//! Measures template rendering performance with various template complexities.
//! Run with: zig build bench
//!
//! Metrics reported:
//! - Total time for N iterations
//! - Average time per render
//! - Renders per second
//! - Memory usage per render

const std = @import("std");
const pugz = @import("pugz");

const Allocator = std.mem.Allocator;

/// Benchmark configuration
const Config = struct {
    warmup_iterations: usize = 200,
    benchmark_iterations: usize = 20_000,
    show_output: bool = false,
};

/// Benchmark result
const Result = struct {
    name: []const u8,
    iterations: usize,
    total_ns: u64,
    min_ns: u64,
    max_ns: u64,
    avg_ns: u64,
    ops_per_sec: f64,
    bytes_per_render: usize,
    arena_peak_bytes: usize,

    pub fn print(self: Result) void {
        std.debug.print("\n{s}\n", .{self.name});
        std.debug.print("  Iterations:     {d:>10}\n", .{self.iterations});
        std.debug.print("  Total time:     {d:>10.2} ms\n", .{@as(f64, @floatFromInt(self.total_ns)) / 1_000_000.0});
        std.debug.print("  Avg per render: {d:>10.2} us\n", .{@as(f64, @floatFromInt(self.avg_ns)) / 1_000.0});
        std.debug.print("  Min:            {d:>10.2} us\n", .{@as(f64, @floatFromInt(self.min_ns)) / 1_000.0});
        std.debug.print("  Max:            {d:>10.2} us\n", .{@as(f64, @floatFromInt(self.max_ns)) / 1_000.0});
        std.debug.print("  Renders/sec:    {d:>10.0}\n", .{self.ops_per_sec});
        std.debug.print("  Output size:    {d:>10} bytes\n", .{self.bytes_per_render});
        std.debug.print("  Memory/render:  {d:>10} bytes\n", .{self.arena_peak_bytes});
    }
};

/// Run a benchmark for a template
fn runBenchmark(
    allocator: Allocator,
    comptime name: []const u8,
    template: []const u8,
    data: anytype,
    config: Config,
) !Result {
    // Warmup phase
    for (0..config.warmup_iterations) |_| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        _ = try pugz.renderTemplate(arena.allocator(), template, data);
    }

    // Benchmark phase
    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var output_size: usize = 0;
    var peak_memory: usize = 0;

    var timer = try std.time.Timer.start();

    for (0..config.benchmark_iterations) |i| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        timer.reset();
        const result = try pugz.renderTemplate(arena.allocator(), template, data);
        const elapsed = timer.read();

        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);

        if (i == 0) {
            output_size = result.len;
            // Measure memory used by arena (query state before deinit)
            const state = arena.queryCapacity();
            peak_memory = state;
            if (config.show_output) {
                std.debug.print("\n--- {s} output ---\n{s}\n", .{ name, result });
            }
        }
    }

    const avg_ns = total_ns / config.benchmark_iterations;
    const ops_per_sec = @as(f64, @floatFromInt(config.benchmark_iterations)) / (@as(f64, @floatFromInt(total_ns)) / 1_000_000_000.0);

    return .{
        .name = name,
        .iterations = config.benchmark_iterations,
        .total_ns = total_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
        .avg_ns = avg_ns,
        .ops_per_sec = ops_per_sec,
        .bytes_per_render = output_size,
        .arena_peak_bytes = peak_memory,
    };
}

/// Simple template - just a few elements
const simple_template =
    \\doctype html
    \\html
    \\  head
    \\    title= title
    \\  body
    \\    h1 Hello, #{name}!
    \\    p Welcome to our site.
;

/// Medium template - with conditionals and loops
const medium_template =
    \\doctype html
    \\html
    \\  head
    \\    title= title
    \\    meta(charset="utf-8")
    \\    meta(name="viewport" content="width=device-width, initial-scale=1")
    \\  body
    \\    header
    \\      nav.navbar
    \\        a.brand(href="/") Brand
    \\        ul.nav-links
    \\          each link in navLinks
    \\            li
    \\              a(href=link.href)= link.text
    \\    main.container
    \\      h1= title
    \\      if showIntro
    \\        p.intro Welcome, #{userName}!
    \\      section.content
    \\        each item in items
    \\          .card
    \\            h3= item.title
    \\            p= item.description
    \\    footer
    \\      p Copyright 2024
;

/// Complex template - with mixins, nested loops, conditionals
const complex_template =
    \\mixin card(title, description)
    \\  .card
    \\    .card-header
    \\      h3= title
    \\    .card-body
    \\      p= description
    \\      block
    \\
    \\mixin button(text, type="primary")
    \\  button(class="btn btn-" + type)= text
    \\
    \\mixin navItem(href, text)
    \\  li
    \\    a(href=href)= text
    \\
    \\doctype html
    \\html
    \\  head
    \\    title= title
    \\    meta(charset="utf-8")
    \\    meta(name="viewport" content="width=device-width, initial-scale=1")
    \\    link(rel="stylesheet" href="/css/style.css")
    \\  body
    \\    header.site-header
    \\      .container
    \\        a.logo(href="/")
    \\          img(src="/img/logo.png" alt="Logo")
    \\        nav.main-nav
    \\          ul
    \\            each link in navLinks
    \\              +navItem(link.href, link.text)
    \\        .user-menu
    \\          if user
    \\            span.greeting Hello, #{user.name}!
    \\            +button("Logout", "secondary")
    \\          else
    \\            +button("Login")
    \\            +button("Sign Up", "success")
    \\    main.site-content
    \\      .container
    \\        .page-header
    \\          h1= pageTitle
    \\          if subtitle
    \\            p.subtitle= subtitle
    \\        .content-grid
    \\          each category in categories
    \\            section.category
    \\              h2= category.name
    \\              .cards
    \\                each item in category.items
    \\                  +card(item.title, item.description)
    \\                    .card-footer
    \\                      +button("View Details")
    \\        aside.sidebar
    \\          .widget
    \\            h4 Recent Posts
    \\            ul.post-list
    \\              each post in recentPosts
    \\                li
    \\                  a(href=post.url)= post.title
    \\          .widget
    \\            h4 Tags
    \\            .tag-cloud
    \\              each tag in allTags
    \\                span.tag= tag
    \\    footer.site-footer
    \\      .container
    \\        .footer-grid
    \\          .footer-col
    \\            h4 About
    \\            p Some description text here.
    \\          .footer-col
    \\            h4 Links
    \\            ul
    \\              each link in footerLinks
    \\                li
    \\                  a(href=link.href)= link.text
    \\          .footer-col
    \\            h4 Contact
    \\            p Email: contact@example.com
    \\        .copyright
    \\          p Copyright #{year} Example Inc.
;

pub fn main() !void {
    // Use GPA with leak detection enabled
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = 10,
        .safety = true,
    }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("\n⚠️  MEMORY LEAK DETECTED!\n", .{});
        } else {
            std.debug.print("\n✓ No memory leaks detected.\n", .{});
        }
    }
    const allocator = gpa.allocator();

    const config = Config{
        .warmup_iterations = 200,
        .benchmark_iterations = 20_000,
        .show_output = false,
    };

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║              Pugz Template Rendering Benchmark               ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Warmup iterations:    {d:>6}                                ║\n", .{config.warmup_iterations});
    std.debug.print("║  Benchmark iterations: {d:>6}                                ║\n", .{config.benchmark_iterations});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});

    // Simple template benchmark
    const simple_result = try runBenchmark(
        allocator,
        "Simple Template (basic elements, interpolation)",
        simple_template,
        .{
            .title = "Welcome",
            .name = "World",
        },
        config,
    );
    simple_result.print();

    // Medium template benchmark
    const NavLink = struct { href: []const u8, text: []const u8 };
    const Item = struct { title: []const u8, description: []const u8 };

    const medium_result = try runBenchmark(
        allocator,
        "Medium Template (loops, conditionals, nested elements)",
        medium_template,
        .{
            .title = "Dashboard",
            .userName = "Alice",
            .showIntro = true,
            .navLinks = &[_]NavLink{
                .{ .href = "/", .text = "Home" },
                .{ .href = "/about", .text = "About" },
                .{ .href = "/contact", .text = "Contact" },
            },
            .items = &[_]Item{
                .{ .title = "Item 1", .description = "Description for item 1" },
                .{ .title = "Item 2", .description = "Description for item 2" },
                .{ .title = "Item 3", .description = "Description for item 3" },
                .{ .title = "Item 4", .description = "Description for item 4" },
            },
        },
        config,
    );
    medium_result.print();

    // Complex template benchmark
    const User = struct { name: []const u8 };
    const SimpleItem = struct { title: []const u8, description: []const u8 };
    const Category = struct { name: []const u8, items: []const SimpleItem };
    const Post = struct { url: []const u8, title: []const u8 };
    const FooterLink = struct { href: []const u8, text: []const u8 };

    const complex_result = try runBenchmark(
        allocator,
        "Complex Template (mixins, nested loops, conditionals)",
        complex_template,
        .{
            .title = "Example Site",
            .pageTitle = "Welcome to Our Site",
            .subtitle = "The best place on the web",
            .year = "2024",
            .user = User{ .name = "Alice" },
            .navLinks = &[_]NavLink{
                .{ .href = "/", .text = "Home" },
                .{ .href = "/products", .text = "Products" },
                .{ .href = "/about", .text = "About" },
                .{ .href = "/contact", .text = "Contact" },
            },
            .categories = &[_]Category{
                .{
                    .name = "Featured",
                    .items = &[_]SimpleItem{
                        .{ .title = "Product A", .description = "Amazing product A" },
                        .{ .title = "Product B", .description = "Wonderful product B" },
                    },
                },
                .{
                    .name = "Popular",
                    .items = &[_]SimpleItem{
                        .{ .title = "Product C", .description = "Popular product C" },
                        .{ .title = "Product D", .description = "Trending product D" },
                    },
                },
            },
            .recentPosts = &[_]Post{
                .{ .url = "/blog/post-1", .title = "First Blog Post" },
                .{ .url = "/blog/post-2", .title = "Second Blog Post" },
                .{ .url = "/blog/post-3", .title = "Third Blog Post" },
            },
            .allTags = &[_][]const u8{ "tech", "news", "tutorial", "review", "guide" },
            .footerLinks = &[_]FooterLink{
                .{ .href = "/privacy", .text = "Privacy Policy" },
                .{ .href = "/terms", .text = "Terms of Service" },
                .{ .href = "/sitemap", .text = "Sitemap" },
            },
        },
        config,
    );
    complex_result.print();

    // Summary
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                         Summary                              ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Template        │ Avg (us) │ Renders/sec │ Output (bytes)  ║\n", .{});
    std.debug.print("╠──────────────────┼──────────┼─────────────┼─────────────────╣\n", .{});
    std.debug.print("║  Simple          │ {d:>8.2} │ {d:>11.0} │ {d:>15} ║\n", .{
        @as(f64, @floatFromInt(simple_result.avg_ns)) / 1_000.0,
        simple_result.ops_per_sec,
        simple_result.bytes_per_render,
    });
    std.debug.print("║  Medium          │ {d:>8.2} │ {d:>11.0} │ {d:>15} ║\n", .{
        @as(f64, @floatFromInt(medium_result.avg_ns)) / 1_000.0,
        medium_result.ops_per_sec,
        medium_result.bytes_per_render,
    });
    std.debug.print("║  Complex         │ {d:>8.2} │ {d:>11.0} │ {d:>15} ║\n", .{
        @as(f64, @floatFromInt(complex_result.avg_ns)) / 1_000.0,
        complex_result.ops_per_sec,
        complex_result.bytes_per_render,
    });
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
}
