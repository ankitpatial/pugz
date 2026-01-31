//! Tag interpolation tests for Pugz engine

const std = @import("std");
const helper = @import("helper.zig");
const expectOutput = helper.expectOutput;

test "Tag interpolation with buffered code - string literal" {
    try expectOutput(
        "p Dear #[strong= \"asdasd\"]",
        .{},
        "<p>Dear <strong>asdasd</strong></p>",
    );
}

test "Simple tag interpolation" {
    try expectOutput(
        "p This is #[em emphasized] text.",
        .{},
        "<p>This is <em>emphasized</em> text.</p>",
    );
}

test "Tag interpolation with strong" {
    try expectOutput(
        "p This is #[strong important] text.",
        .{},
        "<p>This is <strong>important</strong> text.</p>",
    );
}

test "Tag interpolation with link" {
    try expectOutput(
        "p Click #[a(href='/') here] to continue.",
        .{},
        "<p>Click <a href=\"/\">here</a> to continue.</p>",
    );
}

test "Tag interpolation with class" {
    try expectOutput(
        "p This is #[span.highlight highlighted] text.",
        .{},
        "<p>This is <span class=\"highlight\">highlighted</span> text.</p>",
    );
}

test "Tag interpolation with id" {
    try expectOutput(
        "p See #[span#note this note] for details.",
        .{},
        "<p>See <span id=\"note\">this note</span> for details.</p>",
    );
}

test "Multiple tag interpolations" {
    try expectOutput(
        "p This has #[em emphasis] and #[strong strength].",
        .{},
        "<p>This has <em>emphasis</em> and <strong>strength</strong>.</p>",
    );
}

test "Tag interpolation with multiple classes" {
    try expectOutput(
        "p Text with #[span.red.bold styled content] here.",
        .{},
        "<p>Text with <span class=\"red bold\">styled content</span> here.</p>",
    );
}
