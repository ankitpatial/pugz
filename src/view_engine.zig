//! ViewEngine - High-level template engine for web servers.
//!
//! Provides a simple API for rendering Pug templates with:
//! - Views directory configuration
//! - Lazy-loading mixins from a mixins subdirectory (on-demand)
//! - Relative path resolution for includes and extends
//!
//! Mixins are resolved in the following order:
//! 1. Mixins defined in the same template file
//! 2. Mixins from the mixins directory (lazy-loaded when first called)
//!
//! Example:
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
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "ViewEngine resolves paths correctly" {
    // This test requires a views directory - skip in unit tests
    // Full integration tests are in src/tests/
}
