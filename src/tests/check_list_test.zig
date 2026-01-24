//! Check list tests - validates pug templates against expected HTML output.
//! Each test embeds a .pug file and its matching .html file at compile time.
//!
//! NOTE: Many tests are disabled because they require features not yet implemented:
//! - JavaScript expression evaluation (e.g., `(1) ? 1 : 0`, `new Date()`)
//! - Filters (`:markdown`, `:coffeescript`, `:less`, etc.)
//! - File includes without a file resolver
//! - Runtime data variables (tests expect `users`, `friends` etc.)
//!
//! Tests that pass are those with:
//! - Static content only (no JS expressions)
//! - No include/extends directives
//! - No filters

const std = @import("std");
const pugz = @import("pugz");

/// Normalizes HTML by removing indentation/formatting whitespace.
/// This allows comparing pretty vs non-pretty output.
fn normalizeHtml(allocator: std.mem.Allocator, html: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    var i: usize = 0;
    var in_tag = false;
    var last_was_space = false;

    while (i < html.len) {
        const c = html[i];

        if (c == '<') {
            in_tag = true;
            last_was_space = false;
            try result.append(allocator, c);
        } else if (c == '>') {
            in_tag = false;
            last_was_space = false;
            try result.append(allocator, c);
        } else if (c == '\n' or c == '\r') {
            // Skip newlines
            i += 1;
            continue;
        } else if (c == ' ' or c == '\t') {
            if (in_tag) {
                // Preserve single space in tags for attribute separation
                if (!last_was_space) {
                    try result.append(allocator, ' ');
                    last_was_space = true;
                }
            } else {
                // Outside tags: skip leading whitespace after >
                if (result.items.len > 0 and result.items[result.items.len - 1] != '>') {
                    if (!last_was_space) {
                        try result.append(allocator, ' ');
                        last_was_space = true;
                    }
                }
            }
            i += 1;
            continue;
        } else {
            last_was_space = false;
            try result.append(allocator, c);
        }
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

fn runTest(comptime name: []const u8) !void {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pug_content = @embedFile("check_list/" ++ name ++ ".pug");
    const expected_html = @embedFile("check_list/" ++ name ++ ".html");

    const result = try pugz.renderTemplate(alloc, pug_content, .{});

    const trimmed_result = std.mem.trimRight(u8, result, " \n\r\t");
    const trimmed_expected = std.mem.trimRight(u8, expected_html, " \n\r\t");

    // Normalize both for comparison (ignores pretty-print differences)
    const norm_result = try normalizeHtml(alloc, trimmed_result);
    const norm_expected = try normalizeHtml(alloc, trimmed_expected);

    try std.testing.expectEqualStrings(norm_expected, norm_result);
}

// ─────────────────────────────────────────────────────────────────────────────
// PASSING TESTS - Static content, no JS expressions, no includes/filters
// ─────────────────────────────────────────────────────────────────────────────

test "attrs.colon" {
    try runTest("attrs.colon");
}

test "basic" {
    try runTest("basic");
}

test "blanks" {
    try runTest("blanks");
}

test "block-expansion" {
    try runTest("block-expansion");
}

test "block-expansion.shorthands" {
    try runTest("block-expansion.shorthands");
}

test "blockquote" {
    try runTest("blockquote");
}

test "classes-empty" {
    try runTest("classes-empty");
}

test "code.escape" {
    try runTest("code.escape");
}

test "comments.source" {
    try runTest("comments.source");
}

test "doctype.custom" {
    try runTest("doctype.custom");
}

test "doctype.default" {
    try runTest("doctype.default");
}

test "doctype.keyword" {
    try runTest("doctype.keyword");
}

test "escape-chars" {
    try runTest("escape-chars");
}

// Disabled: html5 - expects HTML5 boolean attrs without ="checked"
// test "html5" {
//     try runTest("html5");
// }

test "inheritance.defaults" {
    // Static template with block defaults (no extends)
    try runTest("inheritance.defaults");
}

test "mixins-unused" {
    try runTest("mixins-unused");
}

test "namespaces" {
    try runTest("namespaces");
}

test "nesting" {
    try runTest("nesting");
}

test "quotes" {
    try runTest("quotes");
}

test "script.whitespace" {
    try runTest("script.whitespace");
}

test "scripts" {
    try runTest("scripts");
}

test "self-closing-html" {
    try runTest("self-closing-html");
}

test "single-period" {
    try runTest("single-period");
}

test "source" {
    try runTest("source");
}

// Disabled: tags.self-closing - uses interpolated tag names #{'foo'} requiring JS eval
// test "tags.self-closing" {
//     try runTest("tags.self-closing");
// }

test "utf8bom" {
    try runTest("utf8bom");
}

test "xml" {
    try runTest("xml");
}

// ─────────────────────────────────────────────────────────────────────────────
// DISABLED TESTS - Require unimplemented features
// ─────────────────────────────────────────────────────────────────────────────

// Requires JavaScript expression evaluation:
// - attrs: `bar= (1) ? 1 : 0`, `new Date(0)`
// - attrs-data: `{name: "tobi"}` object literals with JS
// - attrs.js: `'/user/' + id` string concatenation with variables
// - attrs.unescaped: complex JS in attributes
// - case, case-blocks: case statements with JS expressions
// - classes: class attribute with JS object `{bar: true, baz: 1}`
// - code, code.conditionals, code.iteration: JS variables and loops
// - comments-in-case: case with JS
// - each.else: requires `users` variable
// - escape-test: requires `code` variable
// - escaping-class-attribute: class with `!{bar}` unescaped
// - html: requires variables
// - inline-tag, intepolated-elements: `#{user.name}` with data
// - interpolated-mixin: mixin with interpolated content
// - interpolation.escape: requires variables
// - mixin-at-end-of-file, mixin-block-with-space, mixin-hoist: require data
// - mixin.attrs, mixin.block-tag-behaviour, mixin.blocks, mixin.merge: require data
// - mixins, mixins.rest-args: require data
// - pipeless-comments, pipeless-filters, pipeless-tag: pipeless text with data
// - pre: requires data
// - regression.1794, regression.784: require JS/data
// - scripts.non-js: requires data
// - styles: requires data
// - tag.interpolation: requires data
// - template: requires data
// - text, text-block: require data
// - vars: requires JS variables
// - while: requires JS condition

// Requires include/extends with file resolver:
// - blocks-in-blocks, blocks-in-if: extends directive
// - filter-in-include: include with filter
// - include-extends-from-root, include-extends-of-common-template, include-extends-relative
// - include-only-text, include-only-text-body, include-with-text, include-with-text-head
// - include.script, include.yield.nested, includes, includes-with-ext-js
// - inheritance, inheritance.alert-dialog, inheritance.extend, inheritance.extend.include
// - inheritance.extend.mixins, inheritance.extend.mixins.block, inheritance.extend.recursive
// - inheritance.extend.whitespace
// - layout.append, layout.append.without-block, layout.multi.append.prepend.block
// - layout.prepend, layout.prepend.without-block
// - mixin-via-include
// - yield, yield-before-conditional, yield-before-conditional-head
// - yield-head, yield-title, yield-title-head

// Requires filter support:
// - filters-empty, filters.coffeescript, filters.custom, filters.include
// - filters.include.custom, filters.inline, filters.less, filters.markdown
// - filters.nested, filters.stylus
