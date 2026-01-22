//! ViewEngine - High-level template engine for web servers.
//!
//! Provides a simple API for rendering Pug templates with:
//! - Views directory configuration
//! - Lazy-loading mixins from a mixins subdirectory (on-demand)
//! - Relative path resolution for includes and extends
//! - **Compiled templates** for maximum performance (parse once, render many)
//!
//! Mixins are resolved in the following order:
//! 1. Mixins defined in the same template file
//! 2. Mixins from the mixins directory (lazy-loaded when first called)
//!
//! ## Basic Usage
//! ```zig
//! const engine = ViewEngine.init(.{
//!     .views_dir = "src/views",
//! });
//!
//! // Render from file
//! const html = try engine.render(allocator, "pages/home", .{ .title = "Home" });
//! defer allocator.free(html);
//!
//! // Render from template string (for embedded or cached templates)
//! const tpl = "h1 #{title}";
//! const out = try engine.renderTpl(allocator, tpl, .{ .title = "Hello" });
//! defer allocator.free(out);
//! ```
//!
//! ## Compiled Templates (High Performance)
//! For maximum performance, compile templates once and render many times:
//! ```zig
//! // At startup: compile template (keeps AST in memory)
//! var compiled = try CompiledTemplate.init(gpa, "h1 Hello, #{name}!");
//! defer compiled.deinit();
//!
//! // Per request: render with arena (fast, zero parsing overhead)
//! var arena = std.heap.ArenaAllocator.init(gpa);
//! defer arena.deinit();
//! const html = try compiled.render(arena.allocator(), .{ .name = "World" });
//! ```

const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const runtime = @import("runtime.zig");

const Runtime = runtime.Runtime;
const Context = runtime.Context;

/// Configuration options for the ViewEngine.
pub const Options = struct {
    /// Root directory containing view templates. Defaults to current directory.
    views_dir: []const u8 = ".",
    /// Subdirectory within views_dir containing mixin files.
    /// Defaults to "mixins". Mixins are lazy-loaded on first use.
    /// Set to null to disable mixin directory lookup.
    mixins_dir: ?[]const u8 = "mixins",
    /// File extension for templates. Defaults to ".pug".
    extension: []const u8 = ".pug",
    /// Enable pretty-printing with indentation.
    pretty: bool = true,
    /// Maximum template file size in bytes. Defaults to 5 MB.
    max_file_size: usize = 5 * 1024 * 1024,
};

/// Error types for ViewEngine operations.
pub const ViewEngineError = error{
    TemplateNotFound,
    ParseError,
    OutOfMemory,
    AccessDenied,
    InvalidPath,
};

/// ViewEngine manages template rendering with a configured views directory.
/// Mixins are lazy-loaded from the mixins directory when first called.
pub const ViewEngine = struct {
    options: Options,
    /// Cached file resolver (avoid creating new closure each render).
    file_resolver: runtime.FileResolver,

    /// Initializes the ViewEngine with the given options.
    pub fn init(options: Options) ViewEngine {
        return ViewEngine{
            .options = options,
            .file_resolver = createFileResolver(),
        };
    }

    /// Renders a template file with the given data context.
    ///
    /// The template path is relative to the views directory.
    /// The .pug extension is added automatically if not present.
    ///
    /// Example:
    /// ```zig
    /// const html = try engine.render(allocator, "pages/home", .{
    ///     .title = "Home Page",
    /// });
    /// ```
    pub fn render(self: *const ViewEngine, allocator: std.mem.Allocator, template_path: []const u8, data: anytype) ![]u8 {
        // Build full path
        const full_path = try self.resolvePath(allocator, template_path);
        defer allocator.free(full_path);

        // Read template file
        const source = std.fs.cwd().readFileAlloc(allocator, full_path, self.options.max_file_size) catch {
            return ViewEngineError.TemplateNotFound;
        };
        defer allocator.free(source);

        return self.renderTpl(allocator, source, data);
    }

    /// Renders a template string directly without file I/O.
    ///
    /// Use this when you have the template source in memory (e.g., from a cache
    /// or embedded at compile time). This avoids file system overhead.
    ///
    /// For high-performance loops, pass an arena allocator that resets between iterations.
    ///
    /// Example:
    /// ```zig
    /// const tpl = "h1 Hello, #{name}";
    /// const html = try engine.renderTpl(allocator, tpl, .{ .name = "World" });
    /// ```
    pub fn renderTpl(self: *const ViewEngine, allocator: std.mem.Allocator, source: []const u8, data: anytype) ![]u8 {
        // Resolve mixins path
        const mixins_path = if (self.options.mixins_dir) |mixins_subdir|
            try std.fs.path.join(allocator, &.{ self.options.views_dir, mixins_subdir })
        else
            "";
        defer if (mixins_path.len > 0) allocator.free(mixins_path);

        // Tokenize
        var lexer = Lexer.init(allocator, source);
        defer lexer.deinit();
        const tokens = lexer.tokenize() catch return ViewEngineError.ParseError;

        // Parse
        var parser = Parser.init(allocator, tokens);
        const doc = parser.parse() catch return ViewEngineError.ParseError;

        // Create context with data
        var ctx = Context.init(allocator);
        defer ctx.deinit();

        // Populate context from data struct
        try ctx.pushScope();
        inline for (std.meta.fields(@TypeOf(data))) |field| {
            const value = @field(data, field.name);
            try ctx.set(field.name, runtime.toValue(allocator, value));
        }

        // Create runtime with cached file resolver
        var rt = Runtime.init(allocator, &ctx, .{
            .pretty = self.options.pretty,
            .base_dir = self.options.views_dir,
            .mixins_dir = mixins_path,
            .file_resolver = self.file_resolver,
        });
        defer rt.deinit();

        return rt.renderOwned(doc);
    }

    /// Resolves a template path relative to views directory, adding extension if needed.
    fn resolvePath(self: *const ViewEngine, allocator: std.mem.Allocator, template_path: []const u8) ![]const u8 {
        // Add extension if not present
        const with_ext = if (std.mem.endsWith(u8, template_path, self.options.extension))
            try allocator.dupe(u8, template_path)
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ template_path, self.options.extension });
        defer allocator.free(with_ext);

        return std.fs.path.join(allocator, &.{ self.options.views_dir, with_ext });
    }

    /// Creates a file resolver function for the runtime.
    fn createFileResolver() runtime.FileResolver {
        return struct {
            fn resolve(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
                return std.fs.cwd().readFileAlloc(allocator, path, 5 * 1024 * 1024) catch null;
            }
        }.resolve;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// CompiledTemplate - Parse once, render many times
// ─────────────────────────────────────────────────────────────────────────────

const ast = @import("ast.zig");

/// A pre-compiled template that can be rendered multiple times with different data.
/// This is the fastest way to render templates - parsing happens once at startup,
/// and each render only needs to evaluate the AST with new data.
///
/// Memory layout:
/// - The CompiledTemplate owns an arena that holds all AST nodes and source strings
/// - Call render() with a per-request arena allocator for output
/// - Call deinit() when the template is no longer needed
///
/// Example:
/// ```zig
/// // Compile once at startup
/// var tpl = try CompiledTemplate.init(gpa, "h1 Hello, #{name}!");
/// defer tpl.deinit();
///
/// // Render many times with different data
/// for (requests) |req| {
///     var arena = std.heap.ArenaAllocator.init(gpa);
///     defer arena.deinit();
///     const html = try tpl.render(arena.allocator(), .{ .name = req.name });
///     // send html...
/// }
/// ```
pub const CompiledTemplate = struct {
    /// Arena holding all compiled template data (AST, source slices)
    arena: std.heap.ArenaAllocator,
    /// The parsed document AST
    doc: ast.Document,
    /// Runtime options
    options: RenderOptions,

    pub const RenderOptions = struct {
        pretty: bool = true,
        base_dir: []const u8 = ".",
        mixins_dir: []const u8 = "",
    };

    /// Compiles a template string into a reusable CompiledTemplate.
    /// The backing_allocator is used for the internal arena that holds the AST.
    pub fn init(backing_allocator: std.mem.Allocator, source: []const u8) !CompiledTemplate {
        return initWithOptions(backing_allocator, source, .{});
    }

    /// Compiles a template with custom options.
    pub fn initWithOptions(backing_allocator: std.mem.Allocator, source: []const u8, options: RenderOptions) !CompiledTemplate {
        var arena = std.heap.ArenaAllocator.init(backing_allocator);
        errdefer arena.deinit();

        const alloc = arena.allocator();

        // Copy source into arena (AST slices point into it)
        const owned_source = try alloc.dupe(u8, source);

        // Tokenize
        var lexer = Lexer.init(alloc, owned_source);
        // Don't deinit lexer - arena owns all memory
        const tokens = lexer.tokenize() catch return ViewEngineError.ParseError;

        // Parse
        var parser = Parser.init(alloc, tokens);
        const doc = parser.parse() catch return ViewEngineError.ParseError;

        return .{
            .arena = arena,
            .doc = doc,
            .options = options,
        };
    }

    /// Compiles a template from a file.
    pub fn initFromFile(backing_allocator: std.mem.Allocator, path: []const u8, options: RenderOptions) !CompiledTemplate {
        const source = std.fs.cwd().readFileAlloc(backing_allocator, path, 5 * 1024 * 1024) catch {
            return ViewEngineError.TemplateNotFound;
        };
        defer backing_allocator.free(source);

        return initWithOptions(backing_allocator, source, options);
    }

    /// Releases all memory used by the compiled template.
    pub fn deinit(self: *CompiledTemplate) void {
        self.arena.deinit();
    }

    /// Renders the compiled template with the given data.
    /// Use a per-request arena allocator for best performance.
    pub fn render(self: *const CompiledTemplate, allocator: std.mem.Allocator, data: anytype) ![]u8 {
        // Create context with data
        var ctx = Context.init(allocator);
        defer ctx.deinit();

        // Populate context from data struct
        try ctx.pushScope();
        inline for (std.meta.fields(@TypeOf(data))) |field| {
            const value = @field(data, field.name);
            try ctx.set(field.name, runtime.toValue(allocator, value));
        }

        // Create runtime
        var rt = Runtime.init(allocator, &ctx, .{
            .pretty = self.options.pretty,
            .base_dir = self.options.base_dir,
            .mixins_dir = self.options.mixins_dir,
            .file_resolver = null,
        });
        defer rt.deinit();

        return rt.renderOwned(self.doc);
    }

    /// Renders with a pre-converted Value context (avoids toValue overhead).
    pub fn renderWithValue(self: *const CompiledTemplate, allocator: std.mem.Allocator, data: runtime.Value) ![]u8 {
        var ctx = Context.init(allocator);
        defer ctx.deinit();

        // Populate context from Value object
        try ctx.pushScope();
        switch (data) {
            .object => |obj| {
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    try ctx.set(entry.key_ptr.*, entry.value_ptr.*);
                }
            },
            else => {},
        }

        var rt = Runtime.init(allocator, &ctx, .{
            .pretty = self.options.pretty,
            .base_dir = self.options.base_dir,
            .mixins_dir = self.options.mixins_dir,
            .file_resolver = null,
        });
        defer rt.deinit();

        return rt.renderOwned(self.doc);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "ViewEngine resolves paths correctly" {
    // This test requires a views directory - skip in unit tests
    // Full integration tests are in src/tests/
}

test "CompiledTemplate basic usage" {
    const allocator = std.testing.allocator;

    var tpl = try CompiledTemplate.init(allocator, "h1 Hello, #{name}!");
    defer tpl.deinit();

    // Render multiple times
    for (0..3) |_| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const html = try tpl.render(arena.allocator(), .{ .name = "World" });
        try std.testing.expectEqualStrings("<h1>Hello, World!</h1>\n", html);
    }
}

test "CompiledTemplate with loop" {
    const allocator = std.testing.allocator;

    var tpl = try CompiledTemplate.init(allocator,
        \\ul
        \\  each item in items
        \\    li= item
    );
    defer tpl.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const html = try tpl.render(arena.allocator(), .{
        .items = &[_][]const u8{ "a", "b", "c" },
    });

    try std.testing.expect(std.mem.indexOf(u8, html, "<li>a</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<li>b</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<li>c</li>") != null);
}
