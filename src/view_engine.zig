//! ViewEngine - High-level template engine for web servers.
//!
//! Provides a simple API for rendering Pug templates with:
//! - Views directory configuration
//! - Auto-loading mixins from a mixins subdirectory
//! - Relative path resolution for includes and extends
//!
//! Example:
//! ```zig
//! var engine = try ViewEngine.init(allocator, .{
//!     .views_dir = "src/views",
//! });
//! defer engine.deinit();
//!
//! const html = try engine.render(arena.allocator(), "pages/home", .{
//!     .title = "Home",
//! });
//! ```

const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const runtime = @import("runtime.zig");
const ast = @import("ast.zig");

const Runtime = runtime.Runtime;
const Context = runtime.Context;
const Value = runtime.Value;

/// Configuration options for the ViewEngine.
pub const Options = struct {
    /// Root directory containing view templates.
    views_dir: []const u8,
    /// Subdirectory within views_dir containing mixin files.
    /// Defaults to "mixins". Set to null to disable auto-loading.
    mixins_dir: ?[]const u8 = "mixins",
    /// File extension for templates. Defaults to ".pug".
    extension: []const u8 = ".pug",
    /// Enable pretty-printing with indentation.
    pretty: bool = true,
};

/// Error types for ViewEngine operations.
pub const ViewEngineError = error{
    TemplateNotFound,
    ParseError,
    OutOfMemory,
    AccessDenied,
    InvalidPath,
};

/// A pre-parsed mixin definition.
const MixinEntry = struct {
    name: []const u8,
    def: ast.MixinDef,
};

/// ViewEngine manages template rendering with a configured views directory.
pub const ViewEngine = struct {
    allocator: std.mem.Allocator,
    options: Options,
    /// Absolute path to views directory.
    views_path: []const u8,
    /// Pre-loaded mixin definitions.
    mixins: std.ArrayListUnmanaged(MixinEntry),
    /// Cached mixin source files (to keep slices valid).
    mixin_sources: std.ArrayListUnmanaged([]const u8),

    /// Initializes the ViewEngine with the given options.
    /// Loads all mixins from the mixins directory if configured.
    pub fn init(allocator: std.mem.Allocator, options: Options) !ViewEngine {
        // Resolve views directory to absolute path
        const views_path = try std.fs.cwd().realpathAlloc(allocator, options.views_dir);
        errdefer allocator.free(views_path);

        var engine = ViewEngine{
            .allocator = allocator,
            .options = options,
            .views_path = views_path,
            .mixins = .empty,
            .mixin_sources = .empty,
        };

        // Auto-load mixins if configured
        if (options.mixins_dir) |mixins_subdir| {
            try engine.loadMixins(mixins_subdir);
        }

        return engine;
    }

    /// Releases all resources held by the ViewEngine.
    pub fn deinit(self: *ViewEngine) void {
        self.allocator.free(self.views_path);
        self.mixins.deinit(self.allocator);
        for (self.mixin_sources.items) |source| {
            self.allocator.free(source);
        }
        self.mixin_sources.deinit(self.allocator);
    }

    /// Loads all mixin files from the specified subdirectory.
    fn loadMixins(self: *ViewEngine, mixins_subdir: []const u8) !void {
        const mixins_path = try std.fs.path.join(self.allocator, &.{ self.views_path, mixins_subdir });
        defer self.allocator.free(mixins_path);

        var dir = std.fs.openDirAbsolute(mixins_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                // Mixins directory doesn't exist - that's OK
                return;
            }
            return err;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;

            // Check for .pug extension
            if (!std.mem.endsWith(u8, entry.name, self.options.extension)) continue;

            // Read and parse the mixin file
            try self.loadMixinFile(dir, entry.name);
        }
    }

    /// Loads a single mixin file and extracts its mixin definitions.
    fn loadMixinFile(self: *ViewEngine, dir: std.fs.Dir, filename: []const u8) !void {
        const source = try dir.readFileAlloc(self.allocator, filename, 1024 * 1024);
        errdefer self.allocator.free(source);

        // Keep source alive for string slices
        try self.mixin_sources.append(self.allocator, source);

        // Parse the file
        var lexer = Lexer.init(self.allocator, source);
        defer lexer.deinit();

        const tokens = lexer.tokenize() catch return;

        var parser = Parser.init(self.allocator, tokens);
        const doc = parser.parse() catch return;

        // Extract mixin definitions
        for (doc.nodes) |node| {
            if (node == .mixin_def) {
                try self.mixins.append(self.allocator, .{
                    .name = node.mixin_def.name,
                    .def = node.mixin_def,
                });
            }
        }
    }

    /// Renders a template with the given data context.
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
    pub fn render(self: *ViewEngine, allocator: std.mem.Allocator, template_path: []const u8, data: anytype) ![]u8 {
        // Build full path
        const full_path = try self.resolvePath(allocator, template_path);
        defer allocator.free(full_path);

        // Read template file
        const source = std.fs.cwd().readFileAlloc(allocator, full_path, 1024 * 1024) catch {
            return ViewEngineError.TemplateNotFound;
        };
        defer allocator.free(source);

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

        // Register pre-loaded mixins
        for (self.mixins.items) |mixin_entry| {
            try ctx.defineMixin(mixin_entry.def);
        }

        // Populate context from data struct
        try ctx.pushScope();
        inline for (std.meta.fields(@TypeOf(data))) |field| {
            const value = @field(data, field.name);
            try ctx.set(field.name, runtime.toValue(allocator, value));
        }

        // Create runtime with file resolver for includes/extends
        var rt = Runtime.init(allocator, &ctx, .{
            .pretty = self.options.pretty,
            .base_dir = self.views_path,
            .file_resolver = createFileResolver(),
        });
        defer rt.deinit();

        return rt.renderOwned(doc);
    }

    /// Resolves a template path relative to views directory.
    fn resolvePath(self: *ViewEngine, allocator: std.mem.Allocator, template_path: []const u8) ![]const u8 {
        // Add extension if not present
        const with_ext = if (std.mem.endsWith(u8, template_path, self.options.extension))
            try allocator.dupe(u8, template_path)
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ template_path, self.options.extension });
        defer allocator.free(with_ext);

        return std.fs.path.join(allocator, &.{ self.views_path, with_ext });
    }

    /// Creates a file resolver function for the runtime.
    fn createFileResolver() runtime.FileResolver {
        return struct {
            fn resolve(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
                return std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch null;
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
