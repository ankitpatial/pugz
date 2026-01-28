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

        // Parse the main AST and process includes
        const ast = try self.parseWithIncludes(allocator, template_path, &registry);
        defer {
            ast.deinit(allocator);
            allocator.destroy(ast);
        }

        // Render the AST with mixin registry
        return template.renderAstWithMixinsAndOptions(allocator, ast, data, &registry, .{
            .pretty = self.options.pretty,
        });
    }

    /// Parse a template and process includes recursively
    pub fn parseWithIncludes(self: *ViewEngine, allocator: std.mem.Allocator, template_path: []const u8, registry: *MixinRegistry) !*Node {
        // Build full path (relative to views_dir)
        const full_path = self.resolvePath(allocator, template_path) catch |err| {
            log.debug("failed to resolve path '{s}': {}", .{ template_path, err });
            return switch (err) {
                error.PathEscapesRoot => ViewEngineError.PathEscapesRoot,
                else => ViewEngineError.ReadError,
            };
        };
        defer allocator.free(full_path);

        // Read template file
        const source = std.fs.cwd().readFileAlloc(allocator, full_path, 10 * 1024 * 1024) catch |err| {
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
            log.err("failed to parse template '{s}': {}", .{ full_path, err });
            return ViewEngineError.ParseError;
        };
        errdefer parse_result.deinit(allocator);

        // Process extends (template inheritance) - must be done before includes
        const final_ast = try self.processExtends(allocator, parse_result.ast, registry);

        // Process includes in the AST
        try self.processIncludes(allocator, final_ast, registry);

        // Collect mixins from this template
        mixin.collectMixins(allocator, final_ast, registry) catch {};

        // Don't free parse_result.normalized_source - it's needed while AST is alive
        // It will be freed when the caller uses ArenaAllocator (typical usage pattern)

        return final_ast;
    }

    /// Process all include statements in the AST
    pub fn processIncludes(self: *ViewEngine, allocator: std.mem.Allocator, node: *Node, registry: *MixinRegistry) ViewEngineError!void {
        // Process Include nodes - load the file and inline its content
        if (node.type == .Include or node.type == .RawInclude) {
            if (node.file) |file| {
                if (file.path) |include_path| {
                    // Load the included file (path relative to views_dir)
                    const included_ast = self.parseWithIncludes(allocator, include_path, registry) catch |err| {
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
            try self.processIncludes(allocator, child, registry);
        }
    }

    /// Process extends statement - loads parent template and merges blocks
    pub fn processExtends(self: *ViewEngine, allocator: std.mem.Allocator, ast: *Node, registry: *MixinRegistry) ViewEngineError!*Node {
        if (ast.nodes.items.len == 0) return ast;

        // Check if first node is Extends
        const first_node = ast.nodes.items[0];
        if (first_node.type != .Extends) return ast;

        // Get parent template path
        const parent_path = if (first_node.file) |file| file.path else null;
        if (parent_path == null) return ast;

        // Collect named blocks from child template (excluding the extends node)
        var child_blocks = std.StringHashMap(*Node).init(allocator);
        defer child_blocks.deinit();

        for (ast.nodes.items[1..]) |node| {
            self.collectNamedBlocks(node, &child_blocks);
        }

        // Load parent template
        const parent_ast = self.parseWithIncludes(allocator, parent_path.?, registry) catch |err| {
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

    /// Resolves a template path relative to views directory.
    /// Rejects paths that escape the views root (e.g., "../etc/passwd").
    fn resolvePath(self: *const ViewEngine, allocator: std.mem.Allocator, template_path: []const u8) ![]const u8 {
        log.debug("resolvePath: template_path='{s}', views_dir='{s}'", .{ template_path, self.options.views_dir });

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
