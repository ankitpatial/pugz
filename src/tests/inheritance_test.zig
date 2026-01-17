//! Template inheritance tests for Pugz engine

const std = @import("std");
const pugz = @import("pugz");

/// Mock file resolver for testing template inheritance.
/// Maps template paths to their content.
const MockFiles = struct {
    files: std.StringHashMap([]const u8),

    fn init(allocator: std.mem.Allocator) MockFiles {
        return .{ .files = std.StringHashMap([]const u8).init(allocator) };
    }

    fn deinit(self: *MockFiles) void {
        self.files.deinit();
    }

    fn put(self: *MockFiles, path: []const u8, content: []const u8) !void {
        try self.files.put(path, content);
    }

    fn get(self: *const MockFiles, path: []const u8) ?[]const u8 {
        return self.files.get(path);
    }
};

var test_files: ?*MockFiles = null;

fn mockFileResolver(_: std.mem.Allocator, path: []const u8) ?[]const u8 {
    if (test_files) |files| {
        return files.get(path);
    }
    return null;
}

fn renderWithFiles(
    allocator: std.mem.Allocator,
    template: []const u8,
    files: *MockFiles,
    data: anytype,
) ![]u8 {
    test_files = files;
    defer test_files = null;

    var lexer = pugz.Lexer.init(allocator, template);
    const tokens = try lexer.tokenize();

    var parser = pugz.Parser.init(allocator, tokens);
    const doc = try parser.parse();

    var ctx = pugz.runtime.Context.init(allocator);
    defer ctx.deinit();

    try ctx.pushScope();
    inline for (std.meta.fields(@TypeOf(data))) |field| {
        const value = @field(data, field.name);
        try ctx.set(field.name, pugz.runtime.toValue(allocator, value));
    }

    var runtime = pugz.runtime.Runtime.init(allocator, &ctx, .{
        .file_resolver = mockFileResolver,
    });
    defer runtime.deinit();

    return runtime.renderOwned(doc);
}

// ─────────────────────────────────────────────────────────────────────────────
// Block tests (without inheritance)
// ─────────────────────────────────────────────────────────────────────────────

test "Block with default content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const template =
        \\html
        \\  body
        \\    block content
        \\      p Default content
    ;

    var lexer = pugz.Lexer.init(allocator, template);
    const tokens = try lexer.tokenize();

    var parser = pugz.Parser.init(allocator, tokens);
    const doc = try parser.parse();

    var ctx = pugz.runtime.Context.init(allocator);
    defer ctx.deinit();

    var runtime = pugz.runtime.Runtime.init(allocator, &ctx, .{});
    defer runtime.deinit();

    const result = try runtime.renderOwned(doc);
    const trimmed = std.mem.trimRight(u8, result, "\n");

    try std.testing.expectEqualStrings(
        \\<html>
        \\  <body>
        \\    <p>Default content</p>
        \\  </body>
        \\</html>
    , trimmed);
}

// ─────────────────────────────────────────────────────────────────────────────
// Template inheritance tests
// ─────────────────────────────────────────────────────────────────────────────

test "Extends with block replace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var files = MockFiles.init(allocator);
    defer files.deinit();

    // Parent layout
    try files.put("layout.pug",
        \\html
        \\  head
        \\    title My Site
        \\  body
        \\    block content
        \\      p Default content
    );

    // Child template
    const child =
        \\extends layout.pug
        \\
        \\block content
        \\  h1 Hello World
        \\  p This is the child content
    ;

    const result = try renderWithFiles(allocator, child, &files, .{});
    const trimmed = std.mem.trimRight(u8, result, "\n");

    try std.testing.expectEqualStrings(
        \\<html>
        \\  <head>
        \\    <title>My Site</title>
        \\  </head>
        \\  <body>
        \\    <h1>Hello World</h1>
        \\    <p>This is the child content</p>
        \\  </body>
        \\</html>
    , trimmed);
}

test "Extends with block append" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var files = MockFiles.init(allocator);
    defer files.deinit();

    // Parent layout with scripts
    try files.put("layout.pug",
        \\html
        \\  head
        \\    block scripts
        \\      script(src='/jquery.js')
    );

    // Child appends more scripts
    const child =
        \\extends layout.pug
        \\
        \\block append scripts
        \\  script(src='/app.js')
    ;

    const result = try renderWithFiles(allocator, child, &files, .{});
    const trimmed = std.mem.trimRight(u8, result, "\n");

    try std.testing.expectEqualStrings(
        \\<html>
        \\  <head>
        \\    <script src="/jquery.js"></script>
        \\    <script src="/app.js"></script>
        \\  </head>
        \\</html>
    , trimmed);
}

test "Extends with block prepend" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var files = MockFiles.init(allocator);
    defer files.deinit();

    // Parent layout
    try files.put("layout.pug",
        \\html
        \\  head
        \\    block styles
        \\      link(rel='stylesheet' href='/main.css')
    );

    // Child prepends reset styles
    const child =
        \\extends layout.pug
        \\
        \\block prepend styles
        \\  link(rel='stylesheet' href='/reset.css')
    ;

    const result = try renderWithFiles(allocator, child, &files, .{});
    const trimmed = std.mem.trimRight(u8, result, "\n");

    try std.testing.expectEqualStrings(
        \\<html>
        \\  <head>
        \\    <link rel="stylesheet" href="/reset.css" />
        \\    <link rel="stylesheet" href="/main.css" />
        \\  </head>
        \\</html>
    , trimmed);
}

test "Extends with shorthand append syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var files = MockFiles.init(allocator);
    defer files.deinit();

    try files.put("layout.pug",
        \\html
        \\  head
        \\    block head
        \\      script(src='/vendor.js')
    );

    // Using shorthand: `append head` instead of `block append head`
    const child =
        \\extends layout.pug
        \\
        \\append head
        \\  script(src='/app.js')
    ;

    const result = try renderWithFiles(allocator, child, &files, .{});
    const trimmed = std.mem.trimRight(u8, result, "\n");

    try std.testing.expectEqualStrings(
        \\<html>
        \\  <head>
        \\    <script src="/vendor.js"></script>
        \\    <script src="/app.js"></script>
        \\  </head>
        \\</html>
    , trimmed);
}

test "Extends without .pug extension" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var files = MockFiles.init(allocator);
    defer files.deinit();

    try files.put("layout.pug",
        \\html
        \\  body
        \\    block content
    );

    // Reference without .pug extension
    const child =
        \\extends layout
        \\
        \\block content
        \\  p Hello
    ;

    const result = try renderWithFiles(allocator, child, &files, .{});
    const trimmed = std.mem.trimRight(u8, result, "\n");

    try std.testing.expectEqualStrings(
        \\<html>
        \\  <body>
        \\    <p>Hello</p>
        \\  </body>
        \\</html>
    , trimmed);
}

test "Extends with unused block keeps default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var files = MockFiles.init(allocator);
    defer files.deinit();

    try files.put("layout.pug",
        \\html
        \\  body
        \\    block content
        \\      p Default
        \\    block footer
        \\      p Footer
    );

    // Only override content, footer keeps default
    const child =
        \\extends layout.pug
        \\
        \\block content
        \\  p Overridden
    ;

    const result = try renderWithFiles(allocator, child, &files, .{});
    const trimmed = std.mem.trimRight(u8, result, "\n");

    try std.testing.expectEqualStrings(
        \\<html>
        \\  <body>
        \\    <p>Overridden</p>
        \\    <p>Footer</p>
        \\  </body>
        \\</html>
    , trimmed);
}

// ─────────────────────────────────────────────────────────────────────────────
// Include tests
// ─────────────────────────────────────────────────────────────────────────────

test "Include another template" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var files = MockFiles.init(allocator);
    defer files.deinit();

    try files.put("header.pug",
        \\header
        \\  h1 Site Header
    );

    const template =
        \\html
        \\  body
        \\    include header.pug
        \\    main
        \\      p Content
    ;

    const result = try renderWithFiles(allocator, template, &files, .{});
    const trimmed = std.mem.trimRight(u8, result, "\n");

    try std.testing.expectEqualStrings(
        \\<html>
        \\  <body>
        \\    <header>
        \\      <h1>Site Header</h1>
        \\    </header>
        \\    <main>
        \\      <p>Content</p>
        \\    </main>
        \\  </body>
        \\</html>
    , trimmed);
}
