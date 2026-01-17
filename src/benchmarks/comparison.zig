//! Pugz Benchmark - Comparison with template-engine-bench
//!
//! These benchmarks use the exact same templates from:
//! https://github.com/itsarnaud/template-engine-bench
//!
//! Run individual benchmarks:
//!   zig build test-bench -- simple-0
//!   zig build test-bench -- friends
//!
//! Run all benchmarks:
//!   zig build test-bench
//!
//! Pug.js reference (2000 iterations on MacBook Air M2):
//! - simple-0: pug => 2ms
//! - simple-1: pug => 9ms
//! - simple-2: pug => 9ms
//! - if-expression: pug => 12ms
//! - projects-escaped: pug => 86ms
//! - search-results: pug => 41ms
//! - friends: pug => 110ms

const std = @import("std");
const pugz = @import("pugz");

const iterations: usize = 2000;

// ═══════════════════════════════════════════════════════════════════════════
// simple-0
// ═══════════════════════════════════════════════════════════════════════════

const simple_0_tpl = "h1 Hello, #{name}";

test "bench: simple-0" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("leak!");

    const engine = pugz.ViewEngine.init(.{});
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    var total_ns: u64 = 0;
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        timer.reset();
        _ = try engine.renderTpl(arena.allocator(), simple_0_tpl, .{
            .name = "John",
        });
        total_ns += timer.read();
    }

    printResult("simple-0", total_ns, 2);
}

// ═══════════════════════════════════════════════════════════════════════════
// simple-1
// ═══════════════════════════════════════════════════════════════════════════

const simple_1_tpl =
    \\.simple-1(style="background-color: blue; border: 1px solid black")
    \\  .colors
    \\    span.hello Hello #{name}!
    \\      strong You have #{messageCount} messages!
    \\    if colors
    \\      ul
    \\        each color in colors
    \\          li.color= color
    \\    else
    \\      div No colors!
    \\  if primary
    \\    button(type="button" class="primary") Click me!
    \\  else
    \\    button(type="button" class="secondary") Click me!
;

test "bench: simple-1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const engine = pugz.ViewEngine.init(.{});

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    var total_ns: u64 = 0;
    var timer = try std.time.Timer.start();

    const data = .{
        .name = "George Washington",
        .messageCount = 999,
        .colors = &[_][]const u8{ "red", "green", "blue", "yellow", "orange", "pink", "black", "white", "beige", "brown", "cyan", "magenta" },
        .primary = true,
    };

    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        timer.reset();
        _ = try engine.renderTpl(arena.allocator(), simple_1_tpl, data);
        total_ns += timer.read();
    }

    printResult("simple-1", total_ns, 9);
}

// ═══════════════════════════════════════════════════════════════════════════
// simple-2
// ═══════════════════════════════════════════════════════════════════════════

const simple_2_tpl =
    \\div
    \\  h1.header #{header}
    \\  h2.header2 #{header2}
    \\  h3.header3 #{header3}
    \\  h4.header4 #{header4}
    \\  h5.header5 #{header5}
    \\  h6.header6 #{header6}
    \\  ul.list
    \\    each item in list
    \\      li.item #{item}
;

test "bench: simple-2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const engine = pugz.ViewEngine.init(.{});

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    var total_ns: u64 = 0;
    var timer = try std.time.Timer.start();
    const data = .{
        .header = "Header",
        .header2 = "Header2",
        .header3 = "Header3",
        .header4 = "Header4",
        .header5 = "Header5",
        .header6 = "Header6",
        .list = &[_][]const u8{ "1000000000", "2", "3", "4", "5", "6", "7", "8", "9", "10" },
    };

    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        timer.reset();
        _ = try engine.renderTpl(arena.allocator(), simple_2_tpl, data);
        total_ns += timer.read();
    }

    printResult("simple-2", total_ns, 9);
}

// ═══════════════════════════════════════════════════════════════════════════
// if-expression
// ═══════════════════════════════════════════════════════════════════════════

const if_expression_tpl =
    \\each account in accounts
    \\  div
    \\    if account.status == "closed"
    \\      div Your account has been closed!
    \\    if account.status == "suspended"
    \\      div Your account has been temporarily suspended
    \\    if account.status == "open"
    \\      div
    \\        | Bank balance:
    \\        if account.negative
    \\          span.negative= account.balanceFormatted
    \\        else
    \\          span.positive= account.balanceFormatted
;

const Account = struct {
    balance: i32,
    balanceFormatted: []const u8,
    status: []const u8,
    negative: bool,
};

test "bench: if-expression" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const engine = pugz.ViewEngine.init(.{});

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    var total_ns: u64 = 0;
    var timer = try std.time.Timer.start();
    const data = .{
        .accounts = &[_]Account{
            .{ .balance = 0, .balanceFormatted = "$0.00", .status = "open", .negative = false },
            .{ .balance = 10, .balanceFormatted = "$10.00", .status = "closed", .negative = false },
            .{ .balance = -100, .balanceFormatted = "$-100.00", .status = "suspended", .negative = true },
            .{ .balance = 999, .balanceFormatted = "$999.00", .status = "open", .negative = false },
        },
    };

    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        timer.reset();
        _ = try engine.renderTpl(arena.allocator(), if_expression_tpl, data);
        total_ns += timer.read();
    }

    printResult("if-expression", total_ns, 12);
}

// ═══════════════════════════════════════════════════════════════════════════
// projects-escaped
// ═══════════════════════════════════════════════════════════════════════════

const projects_escaped_tpl =
    \\doctype html
    \\html
    \\  head
    \\    title #{title}
    \\  body
    \\    p #{text}
    \\    each project in projects
    \\      a(href=project.url) #{project.name}
    \\      p #{project.description}
    \\    else
    \\      p No projects
;

const Project = struct {
    name: []const u8,
    url: []const u8,
    description: []const u8,
};

test "bench: projects-escaped" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const engine = pugz.ViewEngine.init(.{});

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    var total_ns: u64 = 0;
    var timer = try std.time.Timer.start();
    const data = .{
        .title = "Projects",
        .text = "<p>Lorem ipsum dolor sit amet, consectetur adipiscing elit.</p>",
        .projects = &[_]Project{
            .{ .name = "<strong>Facebook</strong>", .url = "http://facebook.com", .description = "Social network" },
            .{ .name = "<strong>Google</strong>", .url = "http://google.com", .description = "Search engine" },
            .{ .name = "<strong>Twitter</strong>", .url = "http://twitter.com", .description = "Microblogging service" },
            .{ .name = "<strong>Amazon</strong>", .url = "http://amazon.com", .description = "Online retailer" },
            .{ .name = "<strong>eBay</strong>", .url = "http://ebay.com", .description = "Online auction" },
            .{ .name = "<strong>Wikipedia</strong>", .url = "http://wikipedia.org", .description = "A free encyclopedia" },
            .{ .name = "<strong>LiveJournal</strong>", .url = "http://livejournal.com", .description = "Blogging platform" },
        },
    };

    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        timer.reset();
        _ = try engine.renderTpl(arena.allocator(), projects_escaped_tpl, data);
        total_ns += timer.read();
    }

    printResult("projects-escaped", total_ns, 86);
}

// ═══════════════════════════════════════════════════════════════════════════
// search-results
// ═══════════════════════════════════════════════════════════════════════════

// Simplified to match original JS benchmark template exactly
const search_results_tpl =
    \\.search-results.view-gallery
    \\  each searchRecord in searchRecords
    \\    .search-item
    \\      .search-item-container.drop-shadow
    \\        .img-container
    \\          img(src=searchRecord.imgUrl)
    \\        h4.title
    \\          a(href=searchRecord.viewItemUrl)= searchRecord.title
    \\        | #{searchRecord.description}
    \\        if searchRecord.featured
    \\          div Featured!
    \\        if searchRecord.sizes
    \\          div
    \\            | Sizes available:
    \\            ul
    \\              each size in searchRecord.sizes
    \\                li= size
;

const SearchRecord = struct {
    imgUrl: []const u8,
    viewItemUrl: []const u8,
    title: []const u8,
    description: []const u8,
    featured: bool,
    sizes: ?[]const []const u8,
};

test "bench: search-results" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const engine = pugz.ViewEngine.init(.{});

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const sizes = &[_][]const u8{ "S", "M", "L", "XL", "XXL" };

    // Long descriptions matching original benchmark (Lorem ipsum paragraphs)
    const desc1 = "Duis laborum nostrud consectetur exercitation minim ad laborum velit adipisicing. Dolore adipisicing pariatur in fugiat nulla voluptate aliquip esse laboris quis exercitation aliqua labore.";
    const desc2 = "Incididunt ea mollit commodo velit officia. Enim officia occaecat nulla aute. Esse sunt laborum excepteur sint elit sit esse ad.";
    const desc3 = "Aliquip Lorem consequat sunt ipsum dolor amet amet cupidatat deserunt eiusmod qui anim cillum sint. Dolor exercitation tempor aliquip sunt nisi ipsum ullamco adipisicing.";
    const desc4 = "Est ad amet irure veniam dolore velit amet irure fugiat ut elit. Tempor fugiat dolor tempor aute enim. Ad sint mollit laboris id sint ullamco eu do irure nostrud magna sunt voluptate.";
    const desc5 = "Sunt ex magna culpa cillum esse irure consequat Lorem aliquip enim sit reprehenderit sunt. Exercitation esse irure magna proident ex ut elit magna mollit aliqua amet.";

    var total_ns: u64 = 0;
    var timer = try std.time.Timer.start();
    const data = .{
        .searchRecords = &[_]SearchRecord{
            .{ .imgUrl = "img1.jpg", .viewItemUrl = "http://foo/1", .title = "Namebox", .description = desc1, .featured = true, .sizes = sizes },
            .{ .imgUrl = "img2.jpg", .viewItemUrl = "http://foo/2", .title = "Arctiq", .description = desc2, .featured = false, .sizes = sizes },
            .{ .imgUrl = "img3.jpg", .viewItemUrl = "http://foo/3", .title = "Niquent", .description = desc3, .featured = true, .sizes = sizes },
            .{ .imgUrl = "img4.jpg", .viewItemUrl = "http://foo/4", .title = "Remotion", .description = desc4, .featured = true, .sizes = sizes },
            .{ .imgUrl = "img5.jpg", .viewItemUrl = "http://foo/5", .title = "Octocore", .description = desc5, .featured = true, .sizes = sizes },
            .{ .imgUrl = "img6.jpg", .viewItemUrl = "http://foo/6", .title = "Spherix", .description = desc1, .featured = true, .sizes = sizes },
            .{ .imgUrl = "img7.jpg", .viewItemUrl = "http://foo/7", .title = "Quarex", .description = desc2, .featured = true, .sizes = sizes },
            .{ .imgUrl = "img8.jpg", .viewItemUrl = "http://foo/8", .title = "Supremia", .description = desc3, .featured = false, .sizes = sizes },
            .{ .imgUrl = "img9.jpg", .viewItemUrl = "http://foo/9", .title = "Amtap", .description = desc4, .featured = false, .sizes = sizes },
            .{ .imgUrl = "img10.jpg", .viewItemUrl = "http://foo/10", .title = "Qiao", .description = desc5, .featured = false, .sizes = sizes },
            .{ .imgUrl = "img11.jpg", .viewItemUrl = "http://foo/11", .title = "Pushcart", .description = desc1, .featured = true, .sizes = sizes },
            .{ .imgUrl = "img12.jpg", .viewItemUrl = "http://foo/12", .title = "Eweville", .description = desc2, .featured = false, .sizes = sizes },
            .{ .imgUrl = "img13.jpg", .viewItemUrl = "http://foo/13", .title = "Senmei", .description = desc3, .featured = true, .sizes = sizes },
            .{ .imgUrl = "img14.jpg", .viewItemUrl = "http://foo/14", .title = "Maximind", .description = desc4, .featured = true, .sizes = sizes },
            .{ .imgUrl = "img15.jpg", .viewItemUrl = "http://foo/15", .title = "Blurrybus", .description = desc5, .featured = true, .sizes = sizes },
            .{ .imgUrl = "img16.jpg", .viewItemUrl = "http://foo/16", .title = "Virva", .description = desc1, .featured = true, .sizes = sizes },
            .{ .imgUrl = "img17.jpg", .viewItemUrl = "http://foo/17", .title = "Centregy", .description = desc2, .featured = true, .sizes = sizes },
            .{ .imgUrl = "img18.jpg", .viewItemUrl = "http://foo/18", .title = "Dancerity", .description = desc3, .featured = true, .sizes = sizes },
            .{ .imgUrl = "img19.jpg", .viewItemUrl = "http://foo/19", .title = "Oceanica", .description = desc4, .featured = true, .sizes = sizes },
            .{ .imgUrl = "img20.jpg", .viewItemUrl = "http://foo/20", .title = "Synkgen", .description = desc5, .featured = false, .sizes = null },
        },
    };

    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        timer.reset();
        _ = try engine.renderTpl(arena.allocator(), search_results_tpl, data);
        total_ns += timer.read();
    }

    printResult("search-results", total_ns, 41);
}

// ═══════════════════════════════════════════════════════════════════════════
// friends
// ═══════════════════════════════════════════════════════════════════════════

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

const SubFriend = struct {
    id: i32,
    name: []const u8,
};

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

test "bench: friends" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("leadk");

    const engine = pugz.ViewEngine.init(.{});

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

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

    var total_ns: u64 = 0;
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        timer.reset();
        _ = try engine.renderTpl(arena.allocator(), friends_tpl, .{
            .friends = &friends_data,
        });
        total_ns += timer.read();
    }

    printResult("friends", total_ns, 110);
}

// ═══════════════════════════════════════════════════════════════════════════
// Helper
// ═══════════════════════════════════════════════════════════════════════════

fn printResult(name: []const u8, total_ns: u64, pug_ref_ms: f64) void {
    const total_ms = @as(f64, @floatFromInt(total_ns)) / 1_000_000.0;
    const avg_us = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iterations)) / 1_000.0;
    const speedup = pug_ref_ms / total_ms;

    std.debug.print("\n{s:<20} => {d:>6.1}ms ({d:.2}us/render) | Pug.js: {d:.0}ms | {d:.1}x\n", .{
        name,
        total_ms,
        avg_us,
        pug_ref_ms,
        speedup,
    });
}
