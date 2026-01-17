//! Doctype tests for Pugz engine

const helper = @import("helper.zig");
const expectOutput = helper.expectOutput;

// ─────────────────────────────────────────────────────────────────────────────
// Doctype tests
// ─────────────────────────────────────────────────────────────────────────────
test "Doctype default (html)" {
    try expectOutput("doctype", .{}, "<!DOCTYPE html>");
}

test "Doctype html explicit" {
    try expectOutput("doctype html", .{}, "<!DOCTYPE html>");
}

test "Doctype xml" {
    try expectOutput("doctype xml", .{}, "<?xml version=\"1.0\" encoding=\"utf-8\" ?>");
}

test "Doctype transitional" {
    try expectOutput(
        "doctype transitional",
        .{},
        "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Transitional//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd\">",
    );
}

test "Doctype strict" {
    try expectOutput(
        "doctype strict",
        .{},
        "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\">",
    );
}

test "Doctype frameset" {
    try expectOutput(
        "doctype frameset",
        .{},
        "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Frameset//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-frameset.dtd\">",
    );
}

test "Doctype 1.1" {
    try expectOutput(
        "doctype 1.1",
        .{},
        "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">",
    );
}

test "Doctype basic" {
    try expectOutput(
        "doctype basic",
        .{},
        "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML Basic 1.1//EN\" \"http://www.w3.org/TR/xhtml-basic/xhtml-basic11.dtd\">",
    );
}

test "Doctype mobile" {
    try expectOutput(
        "doctype mobile",
        .{},
        "<!DOCTYPE html PUBLIC \"-//WAPFORUM//DTD XHTML Mobile 1.2//EN\" \"http://www.openmobilealliance.org/tech/DTD/xhtml-mobile12.dtd\">",
    );
}

test "Doctype plist" {
    try expectOutput(
        "doctype plist",
        .{},
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">",
    );
}

test "Doctype custom" {
    try expectOutput(
        "doctype html PUBLIC \"-//W3C//DTD HTML 4.01//EN\"",
        .{},
        "<!DOCTYPE html PUBLIC \"-//W3C//DTD HTML 4.01//EN\">",
    );
}

test "Doctype with html content" {
    try expectOutput(
        \\doctype html
        \\html
        \\  head
        \\    title Hello
        \\  body
        \\    p World
    , .{},
        \\<!DOCTYPE html>
        \\<html>
        \\  <head>
        \\    <title>Hello</title>
        \\  </head>
        \\  <body>
        \\    <p>World</p>
        \\  </body>
        \\</html>
    );
}
