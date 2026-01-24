// benchmark_examples.zig - Benchmark pug example files
//
// Tests the same example files as the JS benchmark

const std = @import("std");
const pug = @import("../pug.zig");

const Example = struct {
    name: []const u8,
    source: []const u8,
};

// Example templates (matching JS pug examples that don't use includes/extends)
const examples = [_]Example{
    .{
        .name = "attributes.pug",
        .source =
        \\div#id.left.container(class='user user-' + name)
        \\  h1.title= name
        \\  form
        \\    //- unbuffered comment :)
        \\    // An example of attributes.
        \\    input(type='text' name='user[name]' value=name)
        \\    input(checked, type='checkbox', name='user[blocked]')
        \\    input(type='submit', value='Update')
        ,
    },
    .{
        .name = "code.pug",
        .source =
        \\- var title = "Things"
        \\
        \\-
        \\  var subtitle = ["Really",  "long",
        \\                  "list", "of",
        \\                  "words"]
        \\h1= title
        \\h2= subtitle.join(" ")
        \\
        \\ul#users
        \\  each user, name in users
        \\    // expands to if (user.isA == 'ferret')
        \\    if user.isA == 'ferret'
        \\      li(class='user-' + name) #{name} is just a ferret
        \\    else
        \\      li(class='user-' + name) #{name} #{user.email}
        ,
    },
    .{
        .name = "dynamicscript.pug",
        .source =
        \\html
        \\  head
        \\    title Dynamic Inline JavaScript
        \\    script.
        \\      var users = !{JSON.stringify(users).replace(/<\//g, "<\\/")}
        ,
    },
    .{
        .name = "each.pug",
        .source =
        \\ul#users
        \\  each user, name in users
        \\    li(class='user-' + name) #{name} #{user.email}
        ,
    },
    .{
        .name = "extend-layout.pug",
        .source =
        \\html
        \\  head
        \\    h1 My Site - #{title}
        \\    block scripts
        \\      script(src='/jquery.js')
        \\  body
        \\    block content
        \\    block foot
        \\      #footer
        \\        p some footer content
        ,
    },
    .{
        .name = "form.pug",
        .source =
        \\form(method="post")
        \\  fieldset
        \\    legend General
        \\    p
        \\      label(for="user[name]") Username:
        \\        input(type="text", name="user[name]", value=user.name)
        \\    p
        \\      label(for="user[email]") Email:
        \\        input(type="text", name="user[email]", value=user.email)
        \\        .tip.
        \\          Enter a valid
        \\          email address
        \\          such as <em>tj@vision-media.ca</em>.
        \\  fieldset
        \\    legend Location
        \\    p
        \\      label(for="user[city]") City:
        \\        input(type="text", name="user[city]", value=user.city)
        \\    p
        \\      select(name="user[province]")
        \\        option(value="") -- Select Province --
        \\        option(value="AB") Alberta
        \\        option(value="BC") British Columbia
        \\        option(value="SK") Saskatchewan
        \\        option(value="MB") Manitoba
        \\        option(value="ON") Ontario
        \\        option(value="QC") Quebec
        \\  p.buttons
        \\    input(type="submit", value="Save")
        ,
    },
    .{
        .name = "layout.pug",
        .source =
        \\doctype html
        \\html(lang="en")
        \\  head
        \\    title Example
        \\    script.
        \\      if (foo) {
        \\        bar();
        \\      }
        \\  body
        \\    h1 Pug - node template engine
        \\    #container
        ,
    },
    .{
        .name = "pet.pug",
        .source =
        \\.pet
        \\  h2= pet.name
        \\  p #{pet.name} is <em>#{pet.age}</em> year(s) old.
        ,
    },
    .{
        .name = "rss.pug",
        .source =
        \\doctype xml
        \\rss(version='2.0')
        \\channel
        \\  title RSS Title
        \\  description Some description here
        \\  link http://google.com
        \\  lastBuildDate Mon, 06 Sep 2010 00:01:00 +0000
        \\  pubDate Mon, 06 Sep 2009 16:45:00 +0000
        \\
        \\  each item in items
        \\    item
        \\      title= item.title
        \\      description= item.description
        \\      link= item.link
        ,
    },
    .{
        .name = "text.pug",
        .source =
        \\| An example of an
        \\a(href='#') inline
        \\| link.
        \\
        \\form
        \\  label Username:
        \\    input(type='text', name='user[name]')
        \\    p
        \\      | Just an example of some text usage.
        \\      | You can have <em>inline</em> html,
        \\      | as well as
        \\      strong tags
        \\      | .
        \\
        \\      | Interpolation is also supported. The
        \\      | username is currently "#{name}".
        \\
        \\  label Email:
        \\    input(type='text', name='user[email]')
        \\    p
        \\      | Email is currently
        \\      em= email
        \\      | .
        ,
    },
    .{
        .name = "whitespace.pug",
        .source =
        \\- var js = '<script></script>'
        \\doctype html
        \\html
        \\
        \\  head
        \\    title= "Some " + "JavaScript"
        \\    != js
        \\
        \\
        \\
        \\  body
        ,
    },
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== Zig Pugz Example Benchmark ===\n\n", .{});

    var passed: usize = 0;
    var failed: usize = 0;
    var total_time_ns: u64 = 0;
    var html_outputs: [examples.len]?[]const u8 = undefined;
    for (&html_outputs) |*h| h.* = null;

    for (examples, 0..) |example, idx| {
        const iterations: usize = 100;
        var success = false;
        var time_ns: u64 = 0;

        // Warmup
        for (0..5) |_| {
            var result = pug.compile(allocator, example.source, .{}) catch continue;
            result.deinit(allocator);
        }

        // Benchmark
        var timer = try std.time.Timer.start();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            var result = pug.compile(allocator, example.source, .{}) catch break;
            if (i == iterations - 1) {
                // Keep last HTML for output
                html_outputs[idx] = result.html;
            } else {
                result.deinit(allocator);
            }
            success = true;
        }
        time_ns = timer.read();

        if (success and i == iterations) {
            const time_ms = @as(f64, @floatFromInt(time_ns)) / 1_000_000.0 / @as(f64, @floatFromInt(iterations));
            std.debug.print("{s}: OK ({d:.3} ms)\n", .{ example.name, time_ms });
            passed += 1;
            total_time_ns += time_ns;
        } else {
            std.debug.print("{s}: FAILED\n", .{example.name});
            failed += 1;
        }
    }

    std.debug.print("\n=== Summary ===\n", .{});
    std.debug.print("Passed: {d}/{d}\n", .{ passed, examples.len });
    std.debug.print("Failed: {d}/{d}\n", .{ failed, examples.len });

    if (passed > 0) {
        const total_ms = @as(f64, @floatFromInt(total_time_ns)) / 1_000_000.0 / 100.0;
        std.debug.print("Total time (successful): {d:.3} ms\n", .{total_ms});
        std.debug.print("Average time: {d:.3} ms\n", .{total_ms / @as(f64, @floatFromInt(passed))});
    }

    // Output HTML for comparison
    std.debug.print("\n=== HTML Output ===\n", .{});
    for (examples, 0..) |example, idx| {
        if (html_outputs[idx]) |html| {
            std.debug.print("\n--- {s} ---\n", .{example.name});
            const max_len = @min(html.len, 500);
            std.debug.print("{s}", .{html[0..max_len]});
            if (html.len > 500) std.debug.print("...", .{});
            std.debug.print("\n", .{});
        }
    }
}
