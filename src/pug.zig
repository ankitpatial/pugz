// pug.zig - Main entry point for Pug template engine in Zig
//
// This is the main module that ties together all the Pug compilation stages:
// 1. Lexer - tokenizes the source
// 2. Parser - builds the AST
// 3. Strip Comments - removes comment tokens
// 4. Load - loads includes and extends
// 5. Linker - resolves template inheritance
// 6. Codegen - generates HTML output

const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;

// ============================================================================
// Module Exports
// ============================================================================

pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const runtime = @import("runtime.zig");
pub const pug_error = @import("error.zig");
pub const walk = @import("walk.zig");
pub const strip_comments = @import("strip_comments.zig");
pub const load = @import("load.zig");
pub const linker = @import("linker.zig");
pub const codegen = @import("codegen.zig");

// Re-export commonly used types
pub const Token = lexer.Token;
pub const TokenType = lexer.TokenType;
pub const Lexer = lexer.Lexer;
pub const Parser = parser.Parser;
pub const Node = parser.Node;
pub const NodeType = parser.NodeType;
pub const PugError = pug_error.PugError;
pub const Compiler = codegen.Compiler;

// ============================================================================
// Compile Options
// ============================================================================

pub const CompileOptions = struct {
    /// Source filename for error messages
    filename: ?[]const u8 = null,
    /// Base directory for absolute includes
    basedir: ?[]const u8 = null,
    /// Pretty print output with indentation
    pretty: bool = false,
    /// Strip unbuffered comments
    strip_unbuffered_comments: bool = true,
    /// Strip buffered comments
    strip_buffered_comments: bool = false,
    /// Include debug information
    debug: bool = false,
    /// Doctype to use
    doctype: ?[]const u8 = null,
};

// ============================================================================
// Compile Result
// ============================================================================

pub const CompileResult = struct {
    html: []const u8,
    err: ?PugError = null,

    pub fn deinit(self: *CompileResult, allocator: Allocator) void {
        allocator.free(self.html);
        if (self.err) |*e| {
            e.deinit();
        }
    }
};

// ============================================================================
// Compilation Errors
// ============================================================================

pub const CompileError = error{
    OutOfMemory,
    LexerError,
    ParserError,
    LoadError,
    LinkerError,
    CodegenError,
    FileNotFound,
    AccessDenied,
    InvalidUtf8,
};

// ============================================================================
// Main Compilation Functions
// ============================================================================

/// Compile a Pug template string to HTML
pub fn compile(
    allocator: Allocator,
    source: []const u8,
    options: CompileOptions,
) CompileError!CompileResult {
    // Create arena for entire compilation pipeline - all temporary allocations freed at once
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    var result = CompileResult{
        .html = &[_]u8{},
    };

    // Stage 1: Lex the source
    var lex_inst = Lexer.init(temp_allocator, source, .{
        .filename = options.filename,
    }) catch {
        return error.LexerError;
    };
    defer lex_inst.deinit();

    const tokens = lex_inst.getTokens() catch {
        if (lex_inst.last_error) |err| {
            // Try to create detailed error, fall back to basic error if allocation fails
            result.err = pug_error.makeError(
                allocator,
                "PUG:LEXER_ERROR",
                err.message,
                .{
                    .line = err.line,
                    .column = err.column,
                    .filename = options.filename,
                    .src = source,
                },
            ) catch blk: {
                // If error creation fails, create minimal error without source context
                break :blk pug_error.makeError(allocator, "PUG:LEXER_ERROR", err.message, .{
                    .line = err.line,
                    .column = err.column,
                    .filename = options.filename,
                    .src = null, // Skip source to reduce allocation
                }) catch null;
            };
        }
        return error.LexerError;
    };

    // Stage 2: Strip comments
    var stripped = strip_comments.stripComments(
        temp_allocator,
        tokens,
        .{
            .strip_unbuffered = options.strip_unbuffered_comments,
            .strip_buffered = options.strip_buffered_comments,
            .filename = options.filename,
        },
    ) catch {
        return error.LexerError;
    };
    defer stripped.deinit(temp_allocator);

    // Stage 3: Parse tokens to AST
    var parse = Parser.init(temp_allocator, stripped.tokens.items, options.filename, source);
    defer parse.deinit();

    const ast = parse.parse() catch {
        if (parse.err) |err| {
            // Try to create detailed error, fall back to basic error if allocation fails
            result.err = pug_error.makeError(
                allocator,
                "PUG:PARSER_ERROR",
                err.message,
                .{
                    .line = err.line,
                    .column = err.column,
                    .filename = options.filename,
                    .src = source,
                },
            ) catch blk: {
                // If error creation fails, create minimal error without source context
                break :blk pug_error.makeError(allocator, "PUG:PARSER_ERROR", err.message, .{
                    .line = err.line,
                    .column = err.column,
                    .filename = options.filename,
                    .src = null,
                }) catch null;
            };
        }
        return error.ParserError;
    };
    defer {
        ast.deinit(temp_allocator);
        temp_allocator.destroy(ast);
    }

    // Stage 4: Link (resolve extends/blocks)
    var link_result = linker.link(temp_allocator, ast) catch {
        return error.LinkerError;
    };
    defer link_result.deinit(temp_allocator);

    // Stage 5: Generate HTML
    var compiler = Compiler.init(temp_allocator, .{
        .pretty = options.pretty,
        .doctype = options.doctype,
        .debug = options.debug,
    });
    defer compiler.deinit();

    const html = compiler.compile(link_result.ast) catch {
        return error.CodegenError;
    };

    // Dupe final HTML to base allocator before arena cleanup
    result.html = try allocator.dupe(u8, html);
    return result;
}

/// Compile a Pug file to HTML
pub fn compileFile(
    allocator: Allocator,
    filename: []const u8,
    options: CompileOptions,
) CompileError!CompileResult {
    // Read the file
    const file = std.fs.cwd().openFile(filename, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => error.FileNotFound,
            error.AccessDenied => error.AccessDenied,
            else => error.FileNotFound,
        };
    };
    defer file.close();

    const source = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        return error.OutOfMemory;
    };
    defer allocator.free(source);

    // Compile with filename set
    var file_options = options;
    file_options.filename = filename;

    return compile(allocator, source, file_options);
}

/// Render a Pug template string to HTML (convenience function)
pub fn render(
    allocator: Allocator,
    source: []const u8,
) CompileError![]const u8 {
    var result = try compile(allocator, source, .{});
    if (result.err) |*e| {
        e.deinit();
    }
    return result.html;
}

/// Render a Pug template string to pretty-printed HTML
pub fn renderPretty(
    allocator: Allocator,
    source: []const u8,
) CompileError![]const u8 {
    var result = try compile(allocator, source, .{ .pretty = true });
    if (result.err) |*e| {
        e.deinit();
    }
    return result.html;
}

/// Render a Pug file to HTML
pub fn renderFile(
    allocator: Allocator,
    filename: []const u8,
) CompileError![]const u8 {
    var result = try compileFile(allocator, filename, .{});
    if (result.err) |*e| {
        e.deinit();
    }
    return result.html;
}

// ============================================================================
// Tests
// ============================================================================

test "compile - simple text" {
    const allocator = std.testing.allocator;

    var result = try compile(allocator, "| Hello, World!", .{});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("Hello, World!", result.html);
}

test "compile - simple tag" {
    const allocator = std.testing.allocator;

    var result = try compile(allocator, "div", .{});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("<div></div>", result.html);
}

test "compile - tag with text" {
    const allocator = std.testing.allocator;

    var result = try compile(allocator, "p Hello", .{});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("<p>Hello</p>", result.html);
}

test "compile - tag with class shorthand" {
    const allocator = std.testing.allocator;

    var result = try compile(allocator, "div.container", .{});
    defer result.deinit(allocator);

    // Parser stores class values with quotes, verify class attribute is present
    try std.testing.expect(mem.indexOf(u8, result.html, "class=") != null);
    try std.testing.expect(mem.indexOf(u8, result.html, "container") != null);
}

test "compile - tag with id shorthand" {
    const allocator = std.testing.allocator;

    var result = try compile(allocator, "div#main", .{});
    defer result.deinit(allocator);

    // Parser stores id values with quotes, verify id attribute is present
    try std.testing.expect(mem.indexOf(u8, result.html, "id=") != null);
    try std.testing.expect(mem.indexOf(u8, result.html, "main") != null);
}

test "compile - tag with attributes" {
    const allocator = std.testing.allocator;

    var result = try compile(allocator, "a(href=\"/home\") Home", .{});
    defer result.deinit(allocator);

    // Parser stores attribute values with quotes, verify attribute is present
    try std.testing.expect(mem.indexOf(u8, result.html, "href=") != null);
    try std.testing.expect(mem.indexOf(u8, result.html, "/home") != null);
    try std.testing.expect(mem.indexOf(u8, result.html, "Home") != null);
}

test "compile - nested tags" {
    const allocator = std.testing.allocator;

    var result = try compile(allocator, "div\n  span Hello", .{});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("<div><span>Hello</span></div>", result.html);
}

test "compile - self-closing tag" {
    const allocator = std.testing.allocator;

    var result = try compile(allocator, "br", .{});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("<br>", result.html);
}

test "compile - doctype" {
    const allocator = std.testing.allocator;

    var result = try compile(allocator, "doctype html\nhtml", .{});
    defer result.deinit(allocator);

    try std.testing.expect(mem.startsWith(u8, result.html, "<!DOCTYPE html>"));
}

test "compile - unbuffered comment stripped" {
    const allocator = std.testing.allocator;

    // Unbuffered comments (//-) are stripped by default
    var result = try compile(allocator, "//- This is stripped\ndiv", .{});
    defer result.deinit(allocator);

    // The comment text should not appear
    try std.testing.expect(mem.indexOf(u8, result.html, "stripped") == null);
    // But the div should
    try std.testing.expect(mem.indexOf(u8, result.html, "<div>") != null);
}

test "compile - buffered comment visible" {
    const allocator = std.testing.allocator;

    // Buffered comments (//) are kept by default
    var result = try compile(allocator, "// This is visible", .{});
    defer result.deinit(allocator);

    // Buffered comments should be in output
    try std.testing.expect(mem.indexOf(u8, result.html, "<!--") != null);
    try std.testing.expect(mem.indexOf(u8, result.html, "visible") != null);
}

test "render - convenience function" {
    const allocator = std.testing.allocator;

    const html = try render(allocator, "p test");
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<p>test</p>", html);
}

test "compile - multiple tags" {
    const allocator = std.testing.allocator;

    var result = try compile(allocator, "p First\np Second", .{});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("<p>First</p><p>Second</p>", result.html);
}

test "compile - interpolation text" {
    const allocator = std.testing.allocator;

    var result = try compile(allocator, "p Hello, World!", .{});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("<p>Hello, World!</p>", result.html);
}

test "compile - multiple classes" {
    const allocator = std.testing.allocator;

    var result = try compile(allocator, "div.foo.bar", .{});
    defer result.deinit(allocator);

    try std.testing.expect(mem.indexOf(u8, result.html, "class=\"") != null);
}

test "compile - class and id" {
    const allocator = std.testing.allocator;

    var result = try compile(allocator, "div#main.container", .{});
    defer result.deinit(allocator);

    // Parser stores values with quotes, check that both id and class are present
    try std.testing.expect(mem.indexOf(u8, result.html, "id=") != null);
    try std.testing.expect(mem.indexOf(u8, result.html, "main") != null);
    try std.testing.expect(mem.indexOf(u8, result.html, "class=") != null);
    try std.testing.expect(mem.indexOf(u8, result.html, "container") != null);
}

test "compile - deeply nested" {
    const allocator = std.testing.allocator;

    var result = try compile(allocator,
        \\html
        \\  head
        \\    title Test
        \\  body
        \\    div Hello
    , .{});
    defer result.deinit(allocator);

    try std.testing.expect(mem.indexOf(u8, result.html, "<html>") != null);
    try std.testing.expect(mem.indexOf(u8, result.html, "<head>") != null);
    try std.testing.expect(mem.indexOf(u8, result.html, "<title>Test</title>") != null);
    try std.testing.expect(mem.indexOf(u8, result.html, "<body>") != null);
    try std.testing.expect(mem.indexOf(u8, result.html, "<div>Hello</div>") != null);
}
