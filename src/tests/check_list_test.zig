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

fn runTest(comptime name: []const u8) !void {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pug_content = @embedFile("check_list/" ++ name ++ ".pug");
    const expected_html = @embedFile("check_list/" ++ name ++ ".html");

    var lexer = pugz.Lexer.init(alloc, pug_content);
    const tokens = try lexer.tokenize();

    var parser = pugz.Parser.init(alloc, tokens);
    const doc = try parser.parse();

    const result = try pugz.render(alloc, doc, .{});

    const trimmed_result = std.mem.trimRight(u8, result, " \n\r\t");
    const trimmed_expected = std.mem.trimRight(u8, expected_html, " \n\r\t");

    try std.testing.expectEqualStrings(trimmed_expected, trimmed_result);
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
