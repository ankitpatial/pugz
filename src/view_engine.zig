// ViewEngine - Template engine with include/mixin support for web servers
//
// Provides a high-level API for rendering Pug templates from a views directory.
// Handles include statements and mixin resolution automatically.
//
// Usage:
//   var engine = ViewEngine.init(.{ .views_dir = "views" });
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
const Node = parser.Node;
const MixinRegistry = mixin.MixinRegistry;

const log = std.log.scoped(.pugz);

pub const ViewEngineError = error{
    OutOfMemory,
    TemplateNotFound,
    ReadError,
    ParseError,
    ViewsDirNotFound,
    IncludeNotFound,
    PathEscapesRoot,
};

pub const Options = struct {
    /// Root directory containing view templates (all paths relative to this)
    views_dir: []const u8 = "views",
    /// File extension for templates
    extension: []const u8 = ".pug",
    /// Enable pretty-printing with indentation and newlines
    pretty: bool = false,
};

pub const ViewEngine = struct {
    options: Options,
    views_dir_logged: bool = false,

    pub fn init(options: Options) ViewEngine {
        return .{
            .options = options,
        };
    }

    pub fn deinit(self: *ViewEngine) void {
        _ = self;
    }

    /// Renders a template file with the given data context.
    /// Template path is relative to views_dir, extension added automatically.
    /// Processes includes and resolves mixin calls.
    pub fn render(self: *ViewEngine, allocator: std.mem.Allocator, template_path: []const u8, data: anytype) ![]const u8 {
        // Build mixin registry from all includes
        var registry = MixinRegistry.init(allocator);
        defer registry.deinit();

        // Parse the template (handles includes, extends, mixins)
        const ast = try self.parseTemplate(allocator, template_path, &registry);
        defer {
            ast.deinit(allocator);
            allocator.destroy(ast);
        }

        // Render the AST with mixin registry
        return template.renderAstWithMixinsAndOptions(allocator, ast, data, &registry, .{
            .pretty = self.options.pretty,
        });
    }

    /// Parse a template file and process all Pug features (includes, extends, mixins).
    /// template_path is relative to views_dir (e.g., "pages/home" for views/pages/home.pug)
    pub fn parseTemplate(self: *ViewEngine, allocator: std.mem.Allocator, template_path: []const u8, registry: *MixinRegistry) !*Node {
        return self.parseTemplateInternal(allocator, template_path, null, registry);
    }

    /// Internal parse function that tracks the current file's directory for resolving relative paths.
    /// current_dir: directory of the current file (relative to views_dir), or null for top-level
    fn parseTemplateInternal(self: *ViewEngine, allocator: std.mem.Allocator, template_path: []const u8, current_dir: ?[]const u8, registry: *MixinRegistry) !*Node {
        // Resolve the template path relative to current file's directory
        const resolved_template_path = try self.resolveRelativePath(allocator, template_path, current_dir);
        defer allocator.free(resolved_template_path);

        // Build full path (relative to views_dir)
        const full_path = self.resolvePath(allocator, resolved_template_path) catch |err| {
            log.err("❌ resolvePath: '{s}' — {}", .{ template_path, err });
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
            return switch (err) {
                error.PathEscapesRoot => ViewEngineError.PathEscapesRoot,
                else => ViewEngineError.ReadError,
            };
        };
        defer allocator.free(full_path);

        // Read template file
        const source = std.fs.cwd().readFileAlloc(allocator, full_path, 10 * 1024 * 1024) catch |err| {
            log.err("❌ readFile: '{s}' — {}", .{ full_path, err });
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
            return switch (err) {
                error.FileNotFound => ViewEngineError.TemplateNotFound,
                else => ViewEngineError.ReadError,
            };
        };
        defer allocator.free(source);

        // Parse template
        // Note: We intentionally leak parse_result.normalized_source here because:
        // 1. AST strings are slices into normalized_source
        // 2. The AST is returned and rendered later
        // 3. Both will be freed together when render() completes
        // This is acceptable since ViewEngine.render() is short-lived (single request)
        var parse_result = template.parseWithSource(allocator, source) catch |err| {
            log.err("❌ parse: '{s}' — {}", .{ full_path, err });
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
            return ViewEngineError.ParseError;
        };
        errdefer parse_result.deinit(allocator);

        // Get the directory of the current template (relative to views_dir) for resolving includes
        const template_dir = std.fs.path.dirname(resolved_template_path);

        // Process extends (template inheritance) - must be done before includes
        const final_ast = try self.processExtends(allocator, parse_result.ast, template_dir, registry);

        // Process includes in the AST
        try self.processIncludes(allocator, final_ast, template_dir, registry);

        // Collect mixins from this template
        mixin.collectMixins(allocator, final_ast, registry) catch {};

        // Don't free parse_result.normalized_source - it's needed while AST is alive
        // It will be freed when the caller uses ArenaAllocator (typical usage pattern)

        log.debug("✅ '{s}'", .{resolved_template_path});
        return final_ast;
    }

    /// Process all include statements in the AST
    /// current_dir: directory of the current template (relative to views_dir) for resolving relative paths
    pub fn processIncludes(self: *ViewEngine, allocator: std.mem.Allocator, node: *Node, current_dir: ?[]const u8, registry: *MixinRegistry) ViewEngineError!void {
        // Process Include nodes - load the file and inline its content
        if (node.type == .Include or node.type == .RawInclude) {
            // Skip if already processed (has children inlined)
            if (node.nodes.items.len > 0) {
                // Already processed, just recurse into children
                for (node.nodes.items) |child| {
                    try self.processIncludes(allocator, child, current_dir, registry);
                }
                return;
            }

            if (node.file) |file| {
                if (file.path) |include_path| {
                    // Parse the included file (path is resolved relative to current file's directory)
                    const included_ast = self.parseTemplateInternal(allocator, include_path, current_dir, registry) catch |err| {
                        // For includes, convert TemplateNotFound to IncludeNotFound
                        if (err == ViewEngineError.TemplateNotFound) {
                            return ViewEngineError.IncludeNotFound;
                        }
                        return err;
                    };

                    // For pug includes, inline the content into the node
                    if (node.type == .Include) {
                        // Transfer ownership of children from included AST to this node
                        for (included_ast.nodes.items) |child| {
                            node.nodes.append(allocator, child) catch {
                                return ViewEngineError.OutOfMemory;
                            };
                        }
                        // Clear children list so deinit doesn't free them (ownership transferred)
                        included_ast.nodes.clearRetainingCapacity();
                    }

                    // Now safe to free the included AST wrapper (children already transferred)
                    included_ast.deinit(allocator);
                    allocator.destroy(included_ast);
                }
            }
        }

        // Recurse into children
        for (node.nodes.items) |child| {
            try self.processIncludes(allocator, child, current_dir, registry);
        }
    }

    /// Process extends statement - loads parent template and merges blocks
    /// current_dir: directory of the current template (relative to views_dir) for resolving relative paths
    pub fn processExtends(self: *ViewEngine, allocator: std.mem.Allocator, ast: *Node, current_dir: ?[]const u8, registry: *MixinRegistry) ViewEngineError!*Node {
        if (ast.nodes.items.len == 0) return ast;

        // Check if first node is Extends
        const first_node = ast.nodes.items[0];
        if (first_node.type != .Extends) return ast;

        // Get parent template path
        const parent_path = if (first_node.file) |file| file.path else null;
        if (parent_path == null) return ast;

        // Process includes in child template BEFORE extracting blocks
        // This ensures mixin definitions from included files are available
        try self.processIncludes(allocator, ast, current_dir, registry);

        // Collect mixins from child template (including from processed includes)
        mixin.collectMixins(allocator, ast, registry) catch {};

        // Collect named blocks from child template (excluding the extends node)
        var child_blocks = std.StringHashMap(*Node).init(allocator);
        defer child_blocks.deinit();

        for (ast.nodes.items[1..]) |node| {
            self.collectNamedBlocks(node, &child_blocks);
        }

        // Parse parent template (path is resolved relative to current file's directory)
        const parent_ast = self.parseTemplateInternal(allocator, parent_path.?, current_dir, registry) catch |err| {
            if (err == ViewEngineError.TemplateNotFound) {
                return ViewEngineError.IncludeNotFound;
            }
            return err;
        };

        // Replace blocks in parent with child blocks
        self.replaceBlocks(allocator, parent_ast, &child_blocks);

        return parent_ast;
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
    fn replaceBlocks(self: *ViewEngine, allocator: std.mem.Allocator, node: *Node, child_blocks: *std.StringHashMap(*Node)) void {
        if (node.type == .NamedBlock) {
            if (node.name) |name| {
                if (child_blocks.get(name)) |child_block| {
                    // Get the block mode from child
                    const mode = child_block.mode orelse "replace";

                    if (std.mem.eql(u8, mode, "append")) {
                        // Append child content to parent block
                        for (child_block.nodes.items) |child_node| {
                            node.nodes.append(allocator, child_node) catch {};
                        }
                    } else if (std.mem.eql(u8, mode, "prepend")) {
                        // Prepend child content to parent block
                        var i: usize = 0;
                        for (child_block.nodes.items) |child_node| {
                            node.nodes.insert(allocator, i, child_node) catch {};
                            i += 1;
                        }
                    } else {
                        // Replace (default): clear parent and use child content
                        node.nodes.clearRetainingCapacity();
                        for (child_block.nodes.items) |child_node| {
                            node.nodes.append(allocator, child_node) catch {};
                        }
                    }
                }
            }
        }

        // Recurse into children
        for (node.nodes.items) |child| {
            self.replaceBlocks(allocator, child, child_blocks);
        }
    }

    /// Resolves a path relative to the current file's directory.
    /// - Paths starting with "/" are absolute from views_dir root
    /// - Other paths are relative to current file's directory (if provided)
    /// Returns a path relative to views_dir.
    fn resolveRelativePath(self: *const ViewEngine, allocator: std.mem.Allocator, path: []const u8, current_dir: ?[]const u8) ![]const u8 {
        _ = self;

        // If path starts with "/", treat as absolute from views_dir root
        if (path.len > 0 and path[0] == '/') {
            return allocator.dupe(u8, path[1..]);
        }

        // If no current directory (top-level call), path is already relative to views_dir
        const dir = current_dir orelse {
            return allocator.dupe(u8, path);
        };

        // Join current directory with path and normalize
        // e.g., current_dir="pages", path="../partials/header" -> "partials/header"
        const joined = try std.fs.path.join(allocator, &.{ dir, path });
        defer allocator.free(joined);

        // Normalize the path (resolve ".." and ".")
        // We need to handle this manually since std.fs.path.resolve needs absolute paths
        var components = std.ArrayList([]const u8){};
        defer components.deinit(allocator);

        var iter = std.mem.splitScalar(u8, joined, '/');
        while (iter.next()) |part| {
            if (std.mem.eql(u8, part, "..")) {
                // Go up one directory if possible
                if (components.items.len > 0) {
                    _ = components.pop();
                }
                // If no components left, we're at root - ".." is ignored (handled by security check later)
            } else if (std.mem.eql(u8, part, ".") or part.len == 0) {
                // Skip "." and empty parts
                continue;
            } else {
                try components.append(allocator, part);
            }
        }

        // Join components back together
        if (components.items.len == 0) {
            return allocator.dupe(u8, "");
        }

        return std.mem.join(allocator, "/", components.items);
    }

    /// Resolves a template path relative to views directory.
    /// Rejects paths that escape the views root (e.g., "../etc/passwd").
    fn resolvePath(self: *ViewEngine, allocator: std.mem.Allocator, template_path: []const u8) ![]const u8 {
        if (!self.views_dir_logged) {
            log.debug("views_dir='{s}'", .{self.options.views_dir});
            self.views_dir_logged = true;
        }

        // Add extension if not present
        const with_ext = if (std.mem.endsWith(u8, template_path, self.options.extension))
            try allocator.dupe(u8, template_path)
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ template_path, self.options.extension });
        defer allocator.free(with_ext);

        // Join with views_dir to get full path
        const full_path = try std.fs.path.join(allocator, &.{ self.options.views_dir, with_ext });
        defer allocator.free(full_path);

        // Get absolute paths for security check
        const abs_views_dir = std.fs.cwd().realpathAlloc(allocator, self.options.views_dir) catch {
            return ViewEngineError.ReadError;
        };
        defer allocator.free(abs_views_dir);

        // Resolve the full template path to absolute
        const abs_template_path = std.fs.cwd().realpathAlloc(allocator, full_path) catch {
            // File might not exist yet, or path may be invalid
            // In this case, manually construct the absolute path
            const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch {
                return ViewEngineError.ReadError;
            };
            defer allocator.free(cwd);

            const resolved = std.fs.path.resolve(allocator, &.{ cwd, full_path }) catch {
                return ViewEngineError.OutOfMemory;
            };

            // Check if resolved path is within views_dir
            log.debug("Security check: '{s}' vs '{s}'", .{ resolved, abs_views_dir });
            if (!std.mem.startsWith(u8, resolved, abs_views_dir)) {
                log.warn("Path '{s}' (from template '{s}') escapes views_dir '{s}'", .{ resolved, template_path, abs_views_dir });
                allocator.free(resolved);
                return ViewEngineError.PathEscapesRoot;
            }

            return resolved;
        };

        // File exists - check if it's within views_dir
        if (!std.mem.startsWith(u8, abs_template_path, abs_views_dir)) {
            allocator.free(abs_template_path);
            return ViewEngineError.PathEscapesRoot;
        }

        return abs_template_path;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ViewEngine - basic init and deinit" {
    var engine = ViewEngine.init(.{});
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

    var engine = ViewEngine.init(.{
        .views_dir = "tests/test_views",
    });
    defer engine.deinit();

    // Should reject paths that escape the views root
    const result = engine.render(allocator, "../etc/passwd", .{});
    try std.testing.expectError(ViewEngineError.PathEscapesRoot, result);

    // Absolute paths should also be rejected
    const result2 = engine.render(allocator, "/etc/passwd", .{});
    try std.testing.expectError(ViewEngineError.PathEscapesRoot, result2);
}

test "resolveRelativePath - relative paths from subdirectory" {
    const allocator = std.testing.allocator;
    const engine = ViewEngine.init(.{});

    // From pages/, include ../partials/header -> partials/header
    const result1 = try engine.resolveRelativePath(allocator, "../partials/header", "pages");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("partials/header", result1);

    // From pages/admin/, include ../../partials/header -> partials/header
    const result2 = try engine.resolveRelativePath(allocator, "../../partials/header", "pages/admin");
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("partials/header", result2);

    // From pages/, include ./utils -> pages/utils (explicit relative)
    const result3 = try engine.resolveRelativePath(allocator, "./utils", "pages");
    defer allocator.free(result3);
    try std.testing.expectEqualStrings("pages/utils", result3);

    // From pages/, include header (no ./) -> pages/header (relative to current dir)
    const result4 = try engine.resolveRelativePath(allocator, "header", "pages");
    defer allocator.free(result4);
    try std.testing.expectEqualStrings("pages/header", result4);

    // From pages/, include includes/partial -> pages/includes/partial (relative to current dir)
    const result5 = try engine.resolveRelativePath(allocator, "includes/partial", "pages");
    defer allocator.free(result5);
    try std.testing.expectEqualStrings("pages/includes/partial", result5);
}

test "resolveRelativePath - absolute paths from views root" {
    const allocator = std.testing.allocator;
    const engine = ViewEngine.init(.{});

    // /partials/header from any directory -> partials/header
    const result1 = try engine.resolveRelativePath(allocator, "/partials/header", "pages/admin");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("partials/header", result1);

    // /layouts/base from pages/ -> layouts/base
    const result2 = try engine.resolveRelativePath(allocator, "/layouts/base", "pages");
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("layouts/base", result2);
}

test "resolveRelativePath - no current directory (top-level)" {
    const allocator = std.testing.allocator;
    const engine = ViewEngine.init(.{});

    // When current_dir is null, path is returned as-is
    const result1 = try engine.resolveRelativePath(allocator, "pages/home", null);
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("pages/home", result1);

    const result2 = try engine.resolveRelativePath(allocator, "partials/header", null);
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("partials/header", result2);
}
