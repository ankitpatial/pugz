// ViewEngine - Template engine with include/mixin support for web servers
//
// Provides a high-level API for rendering Pug templates from a views directory.
// Templates are parsed once and cached in memory for fast subsequent renders.
// Handles include statements and mixin resolution automatically.
//
// Usage:
//   var engine = try ViewEngine.init(allocator, .{ .views_dir = "views" });
//   defer engine.deinit();
//
//   const html = try engine.render(request_allocator, "pages/home", .{ .title = "Home" });
//
// Include/Mixin pattern:
//   // views/pages/home.pug
//   include mixins/_buttons.pug
//   include mixins/_cards.pug
//
//   doctype html
//   html
//     body
//       +primary-button("Click me")
//       +card("Title", "content")

const std = @import("std");
const template = @import("template.zig");
const parser = @import("parser.zig");
const mixin = @import("mixin.zig");
const load = @import("load.zig");
const cache = @import("cache");
const Node = parser.Node;
const MixinRegistry = mixin.MixinRegistry;

pub const ViewEngineError = error{
    OutOfMemory,
    TemplateNotFound,
    ReadError,
    ParseError,
    ViewsDirNotFound,
    IncludeNotFound,
    PathEscapesRoot,
    CacheInitError,
};

pub const Options = struct {
    /// Root directory containing view templates (all paths relative to this)
    views_dir: []const u8 = "views",
    /// File extension for templates
    extension: []const u8 = ".pug",
    /// Enable pretty-printing with indentation and newlines
    pretty: bool = false,
    /// Enable AST caching (disable for development hot-reload)
    cache_enabled: bool = true,
    /// Maximum number of templates to keep in cache (0 = unlimited). When set, uses LRU eviction.
    max_cached_templates: u32 = 0,
    /// Cache TTL in seconds (0 = never expires). For development, set to e.g. 5.
    /// Only works when max_cached_templates > 0 (LRU cache mode).
    cache_ttl_seconds: u32 = 0,
};

/// Cached template entry - stores AST and normalized source (AST contains slices into it)
const CachedTemplate = struct {
    ast: *Node,
    /// Normalized source from lexer - AST strings are slices into this
    normalized_source: []const u8,
    /// Key stored for cleanup when using LRU cache
    key: []const u8,

    fn deinit(self: *CachedTemplate, allocator: std.mem.Allocator) void {
        self.ast.deinit(allocator);
        allocator.destroy(self.ast);
        allocator.free(self.normalized_source);
        if (self.key.len > 0) {
            allocator.free(self.key);
        }
    }
};

/// LRU cache type for templates
const LruCache = cache.Cache(*CachedTemplate);

pub const ViewEngine = struct {
    options: Options,
    /// Allocator for cached ASTs (long-lived, typically GPA)
    cache_allocator: std.mem.Allocator,
    /// Simple hashmap cache (unlimited size, when max_cached_templates = 0)
    simple_cache: ?std.StringHashMap(CachedTemplate),
    /// LRU cache (limited size, when max_cached_templates > 0)
    lru_cache: ?LruCache,

    pub fn init(allocator: std.mem.Allocator, options: Options) ViewEngineError!ViewEngine {
        if (options.max_cached_templates > 0) {
            // Use LRU cache with size limit
            const lru = LruCache.init(allocator, .{
                .max_size = options.max_cached_templates,
            }) catch return ViewEngineError.CacheInitError;
            return .{
                .options = options,
                .cache_allocator = allocator,
                .simple_cache = null,
                .lru_cache = lru,
            };
        } else {
            // Use simple unlimited hashmap
            return .{
                .options = options,
                .cache_allocator = allocator,
                .simple_cache = std.StringHashMap(CachedTemplate).init(allocator),
                .lru_cache = null,
            };
        }
    }

    pub fn deinit(self: *ViewEngine) void {
        if (self.simple_cache) |*sc| {
            var it = sc.iterator();
            while (it.next()) |entry| {
                self.cache_allocator.free(entry.key_ptr.*);
                entry.value_ptr.ast.deinit(self.cache_allocator);
                self.cache_allocator.destroy(entry.value_ptr.ast);
                self.cache_allocator.free(entry.value_ptr.normalized_source);
            }
            sc.deinit();
        }
        if (self.lru_cache) |*lru| {
            lru.deinit();
        }
    }

    /// Renders a template file with the given data context.
    /// Template path is relative to views_dir, extension added automatically.
    /// Processes includes and resolves mixin calls.
    pub fn render(self: *ViewEngine, allocator: std.mem.Allocator, template_path: []const u8, data: anytype) ![]const u8 {
        // Build mixin registry from all includes
        var registry = MixinRegistry.init(allocator);
        defer registry.deinit();

        // Get or parse the main AST and process includes
        const ast = try self.getOrParseWithIncludes(template_path, &registry);

        // Render the AST with mixin registry - mixins are expanded inline during rendering
        return template.renderAstWithMixinsAndOptions(allocator, ast, data, &registry, .{
            .pretty = self.options.pretty,
        });
    }

    /// Get cached AST or parse it, processing includes recursively
    fn getOrParseWithIncludes(self: *ViewEngine, template_path: []const u8, registry: *MixinRegistry) !*Node {
        // Check cache first (only if caching is enabled for read)
        if (self.options.cache_enabled) {
            if (self.lru_cache) |*lru| {
                if (lru.get(template_path)) |entry| {
                    defer entry.release();
                    const cached = entry.value;
                    mixin.collectMixins(self.cache_allocator, cached.ast, registry) catch {};
                    return cached.ast;
                }
            } else if (self.simple_cache) |*sc| {
                if (sc.get(template_path)) |cached| {
                    mixin.collectMixins(self.cache_allocator, cached.ast, registry) catch {};
                    return cached.ast;
                }
            }
        }

        // Build full path (relative to views_dir)
        const full_path = try self.resolvePath(self.cache_allocator, template_path);
        defer self.cache_allocator.free(full_path);

        // Read template file
        const source = std.fs.cwd().readFileAlloc(self.cache_allocator, full_path, 10 * 1024 * 1024) catch |err| {
            return switch (err) {
                error.FileNotFound => ViewEngineError.TemplateNotFound,
                else => ViewEngineError.ReadError,
            };
        };
        defer self.cache_allocator.free(source);

        // Parse template - returns AST and normalized source that AST strings point to
        var parse_result = template.parseWithSource(self.cache_allocator, source) catch {
            return ViewEngineError.ParseError;
        };
        errdefer parse_result.deinit(self.cache_allocator);

        // Process extends (template inheritance) - must be done before includes
        const final_ast = try self.processExtends(parse_result.ast, registry);

        // Process includes in the AST
        try self.processIncludes(final_ast, registry);

        // Collect mixins from this template
        mixin.collectMixins(self.cache_allocator, final_ast, registry) catch {};

        // Update parse_result.ast to point to final_ast for caching
        parse_result.ast = final_ast;

        // Cache the AST
        if (self.lru_cache) |*lru| {
            // For LRU cache, we need to allocate the CachedTemplate struct
            const cached_ptr = self.cache_allocator.create(CachedTemplate) catch {
                parse_result.deinit(self.cache_allocator);
                return ViewEngineError.OutOfMemory;
            };
            const cache_key = self.cache_allocator.dupe(u8, template_path) catch {
                self.cache_allocator.destroy(cached_ptr);
                parse_result.deinit(self.cache_allocator);
                return ViewEngineError.OutOfMemory;
            };
            cached_ptr.* = .{
                .ast = parse_result.ast,
                .normalized_source = parse_result.normalized_source,
                .key = cache_key,
            };
            // TTL: 0 means never expires, otherwise use configured seconds
            const ttl = if (self.options.cache_ttl_seconds == 0)
                std.math.maxInt(u32)
            else
                self.options.cache_ttl_seconds;
            lru.put(cache_key, cached_ptr, .{ .ttl = ttl }) catch {
                cached_ptr.deinit(self.cache_allocator);
                self.cache_allocator.destroy(cached_ptr);
                return ViewEngineError.OutOfMemory;
            };
            return parse_result.ast;
        } else if (self.simple_cache) |*sc| {
            const cache_key = self.cache_allocator.dupe(u8, template_path) catch {
                parse_result.deinit(self.cache_allocator);
                return ViewEngineError.OutOfMemory;
            };
            sc.put(cache_key, .{
                .ast = parse_result.ast,
                .normalized_source = parse_result.normalized_source,
                .key = &.{},
            }) catch {
                self.cache_allocator.free(cache_key);
                parse_result.deinit(self.cache_allocator);
                return ViewEngineError.OutOfMemory;
            };
            return parse_result.ast;
        }

        return parse_result.ast;
    }

    /// Process all include statements in the AST
    fn processIncludes(self: *ViewEngine, node: *Node, registry: *MixinRegistry) ViewEngineError!void {
        // Process Include nodes - load the file and inline its content
        if (node.type == .Include or node.type == .RawInclude) {
            if (node.file) |file| {
                if (file.path) |include_path| {
                    // Load the included file (path relative to views_dir)
                    const included_ast = self.getOrParseWithIncludes(include_path, registry) catch |err| {
                        // For includes, convert TemplateNotFound to IncludeNotFound
                        if (err == ViewEngineError.TemplateNotFound) {
                            return ViewEngineError.IncludeNotFound;
                        }
                        return err;
                    };

                    // For pug includes, inline the content into the node
                    if (node.type == .Include) {
                        // Copy children from included AST to this node
                        for (included_ast.nodes.items) |child| {
                            node.nodes.append(self.cache_allocator, child) catch {
                                return ViewEngineError.OutOfMemory;
                            };
                        }
                    }
                }
            }
        }

        // Recurse into children
        for (node.nodes.items) |child| {
            try self.processIncludes(child, registry);
        }
    }

    /// Process extends statement - loads parent template and merges blocks
    fn processExtends(self: *ViewEngine, ast: *Node, registry: *MixinRegistry) ViewEngineError!*Node {
        if (ast.nodes.items.len == 0) return ast;

        // Check if first node is Extends
        const first_node = ast.nodes.items[0];
        if (first_node.type != .Extends) return ast;

        // Get parent template path
        const parent_path = if (first_node.file) |file| file.path else null;
        if (parent_path == null) return ast;

        // Collect named blocks from child template (excluding the extends node)
        var child_blocks = std.StringHashMap(*Node).init(self.cache_allocator);
        defer child_blocks.deinit();

        for (ast.nodes.items[1..]) |node| {
            self.collectNamedBlocks(node, &child_blocks);
        }

        // Load parent template WITHOUT caching (each child gets its own copy)
        const parent_ast = self.parseTemplateNoCache(parent_path.?, registry) catch |err| {
            if (err == ViewEngineError.TemplateNotFound) {
                return ViewEngineError.IncludeNotFound;
            }
            return err;
        };

        // Replace blocks in parent with child blocks
        self.replaceBlocks(parent_ast, &child_blocks);

        return parent_ast;
    }

    /// Parse a template without caching - used for parent layouts in extends
    fn parseTemplateNoCache(self: *ViewEngine, template_path: []const u8, registry: *MixinRegistry) ViewEngineError!*Node {
        const full_path = try self.resolvePath(self.cache_allocator, template_path);
        defer self.cache_allocator.free(full_path);

        const source = std.fs.cwd().readFileAlloc(self.cache_allocator, full_path, 10 * 1024 * 1024) catch |err| {
            return switch (err) {
                error.FileNotFound => ViewEngineError.TemplateNotFound,
                else => ViewEngineError.ReadError,
            };
        };
        defer self.cache_allocator.free(source);

        const parse_result = template.parseWithSource(self.cache_allocator, source) catch {
            return ViewEngineError.ParseError;
        };

        // Process nested extends if parent also extends another layout
        const final_ast = try self.processExtends(parse_result.ast, registry);

        // Process includes
        try self.processIncludes(final_ast, registry);

        // Collect mixins
        mixin.collectMixins(self.cache_allocator, final_ast, registry) catch {};

        return final_ast;
    }

    /// Collect all named blocks from a node tree
    fn collectNamedBlocks(self: *ViewEngine, node: *Node, blocks: *std.StringHashMap(*Node)) void {
        if (node.type == .NamedBlock) {
            if (node.name) |name| {
                blocks.put(name, node) catch {};
            }
        }
        for (node.nodes.items) |child| {
            self.collectNamedBlocks(child, blocks);
        }
    }

    /// Replace named blocks in parent with child block content
    fn replaceBlocks(self: *ViewEngine, node: *Node, child_blocks: *std.StringHashMap(*Node)) void {
        if (node.type == .NamedBlock) {
            if (node.name) |name| {
                if (child_blocks.get(name)) |child_block| {
                    // Get the block mode from child
                    const mode = child_block.mode orelse "replace";

                    if (std.mem.eql(u8, mode, "append")) {
                        // Append child content to parent block
                        for (child_block.nodes.items) |child_node| {
                            node.nodes.append(self.cache_allocator, child_node) catch {};
                        }
                    } else if (std.mem.eql(u8, mode, "prepend")) {
                        // Prepend child content to parent block
                        var i: usize = 0;
                        for (child_block.nodes.items) |child_node| {
                            node.nodes.insert(self.cache_allocator, i, child_node) catch {};
                            i += 1;
                        }
                    } else {
                        // Replace (default): clear parent and use child content
                        node.nodes.clearRetainingCapacity();
                        for (child_block.nodes.items) |child_node| {
                            node.nodes.append(self.cache_allocator, child_node) catch {};
                        }
                    }
                }
            }
        }

        // Recurse into children
        for (node.nodes.items) |child| {
            self.replaceBlocks(child, child_blocks);
        }
    }

    /// Pre-load and cache all templates from views directory
    pub fn preload(self: *ViewEngine) !usize {
        var count: usize = 0;
        var dir = std.fs.cwd().openDir(self.options.views_dir, .{ .iterate = true }) catch {
            return ViewEngineError.ViewsDirNotFound;
        };
        defer dir.close();

        var walker = dir.walk(self.cache_allocator) catch return ViewEngineError.OutOfMemory;
        defer walker.deinit();

        while (walker.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, self.options.extension)) continue;

            const name_len = entry.path.len - self.options.extension.len;
            const template_name = entry.path[0..name_len];

            var registry = MixinRegistry.init(self.cache_allocator);
            defer registry.deinit();
            _ = self.getOrParseWithIncludes(template_name, &registry) catch continue;
            count += 1;
        }

        return count;
    }

    /// Clear all cached templates
    pub fn clearCache(self: *ViewEngine) void {
        if (self.simple_cache) |*sc| {
            var it = sc.iterator();
            while (it.next()) |entry| {
                self.cache_allocator.free(entry.key_ptr.*);
                entry.value_ptr.ast.deinit(self.cache_allocator);
                self.cache_allocator.destroy(entry.value_ptr.ast);
                self.cache_allocator.free(entry.value_ptr.normalized_source);
            }
            sc.clearRetainingCapacity();
        }
        // Note: LRU cache doesn't have a clear method, would need to recreate
    }

    /// Returns the number of cached templates
    pub fn cacheCount(self: *const ViewEngine) usize {
        if (self.simple_cache) |sc| {
            return sc.count();
        }
        // LRU cache doesn't expose count easily
        return 0;
    }

    /// Resolves a template path relative to views directory.
    /// Rejects paths that escape the views root (e.g., "../etc/passwd").
    fn resolvePath(self: *const ViewEngine, allocator: std.mem.Allocator, template_path: []const u8) ![]const u8 {
        // Security: reject paths that escape root
        if (!load.isPathSafe(template_path)) {
            return ViewEngineError.PathEscapesRoot;
        }

        const with_ext = if (std.mem.endsWith(u8, template_path, self.options.extension))
            try allocator.dupe(u8, template_path)
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ template_path, self.options.extension });
        defer allocator.free(with_ext);

        return std.fs.path.join(allocator, &.{ self.options.views_dir, with_ext });
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ViewEngine - basic init and deinit" {
    const allocator = std.testing.allocator;
    var engine = try ViewEngine.init(allocator, .{});
    defer engine.deinit();
}

test "ViewEngine - init with LRU cache" {
    const allocator = std.testing.allocator;
    var engine = try ViewEngine.init(allocator, .{
        .max_cached_templates = 100,
    });
    defer engine.deinit();
}

test "isPathSafe - safe paths" {
    try std.testing.expect(load.isPathSafe("home"));
    try std.testing.expect(load.isPathSafe("pages/home"));
    try std.testing.expect(load.isPathSafe("mixins/_buttons"));
    try std.testing.expect(load.isPathSafe("a/b/c/d"));
    try std.testing.expect(load.isPathSafe("a/b/../b/c")); // Goes up then back down, still safe
}

test "isPathSafe - unsafe paths" {
    try std.testing.expect(!load.isPathSafe("../etc/passwd"));
    try std.testing.expect(!load.isPathSafe(".."));
    try std.testing.expect(!load.isPathSafe("a/../../b"));
    try std.testing.expect(!load.isPathSafe("a/b/c/../../../.."));
    try std.testing.expect(!load.isPathSafe("/etc/passwd")); // Absolute paths
}

test "ViewEngine - path escape protection" {
    const allocator = std.testing.allocator;

    var engine = try ViewEngine.init(allocator, .{
        .views_dir = "src/tests/test_views",
    });
    defer engine.deinit();

    // Should reject paths that escape the views root
    const result = engine.render(allocator, "../etc/passwd", .{});
    try std.testing.expectError(ViewEngineError.PathEscapesRoot, result);

    // Absolute paths should also be rejected
    const result2 = engine.render(allocator, "/etc/passwd", .{});
    try std.testing.expectError(ViewEngineError.PathEscapesRoot, result2);
}
