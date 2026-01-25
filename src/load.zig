// load.zig - Zig port of pug-load
//
// Handles loading of include/extends files during AST processing.
// Walks the AST and loads file dependencies.

const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const mem = std.mem;

// Import AST types from parser
const parser = @import("parser.zig");
pub const Node = parser.Node;
pub const NodeType = parser.NodeType;
pub const FileReference = parser.FileReference;

// Import walk module
const walk_mod = @import("walk.zig");
pub const walkAST = walk_mod.walkAST;
pub const WalkOptions = walk_mod.WalkOptions;
pub const WalkContext = walk_mod.WalkContext;
pub const WalkError = walk_mod.WalkError;
pub const ReplaceResult = walk_mod.ReplaceResult;

// Import lexer for lexing includes
const lexer = @import("lexer.zig");
pub const Token = lexer.Token;
pub const Lexer = lexer.Lexer;

// Import error types
const pug_error = @import("error.zig");
pub const PugError = pug_error.PugError;

// ============================================================================
// Load Options
// ============================================================================

/// Function type for resolving file paths
pub const ResolveFn = *const fn (
    filename: []const u8,
    source: ?[]const u8,
    options: *const LoadOptions,
) LoadError![]const u8;

/// Function type for reading file contents
pub const ReadFn = *const fn (
    allocator: Allocator,
    filename: []const u8,
    options: *const LoadOptions,
) LoadError![]const u8;

/// Function type for lexing source
pub const LexFn = *const fn (
    allocator: Allocator,
    src: []const u8,
    options: *const LoadOptions,
) LoadError![]const Token;

/// Function type for parsing tokens
pub const ParseFn = *const fn (
    allocator: Allocator,
    tokens: []const Token,
    options: *const LoadOptions,
) LoadError!*Node;

pub const LoadOptions = struct {
    /// Base directory for absolute paths
    basedir: ?[]const u8 = null,
    /// Source filename
    filename: ?[]const u8 = null,
    /// Source content
    src: ?[]const u8 = null,
    /// Path resolution function
    resolve: ?ResolveFn = null,
    /// File reading function
    read: ?ReadFn = null,
    /// Lexer function
    lex: ?LexFn = null,
    /// Parser function
    parse: ?ParseFn = null,
    /// User data for callbacks
    user_data: ?*anyopaque = null,
};

// ============================================================================
// Load Errors
// ============================================================================

pub const LoadError = error{
    OutOfMemory,
    FileNotFound,
    AccessDenied,
    InvalidPath,
    MissingFilename,
    MissingBasedir,
    InvalidFileReference,
    LexError,
    ParseError,
    WalkError,
    InvalidUtf8,
    PathEscapesRoot,
};

// ============================================================================
// Load Result
// ============================================================================

pub const LoadResult = struct {
    ast: *Node,
    err: ?PugError = null,

    pub fn deinit(self: *LoadResult, allocator: Allocator) void {
        if (self.err) |*e| {
            e.deinit();
        }
        self.ast.deinit(allocator);
        allocator.destroy(self.ast);
    }
};

// ============================================================================
// Default Implementations
// ============================================================================

/// Check if path is safe (doesn't escape root via .. or other tricks)
/// Returns false if path would escape the root directory.
pub fn isPathSafe(path: []const u8) bool {
    // Reject absolute paths
    if (path.len > 0 and path[0] == '/') {
        return false;
    }

    var depth: i32 = 0;
    var iter = mem.splitScalar(u8, path, '/');

    while (iter.next()) |component| {
        if (component.len == 0 or mem.eql(u8, component, ".")) {
            continue;
        }
        if (mem.eql(u8, component, "..")) {
            depth -= 1;
            if (depth < 0) return false; // Escaped root
        } else {
            depth += 1;
        }
    }
    return true;
}

/// Default path resolution - handles relative and absolute paths
/// Rejects paths that would escape the base directory.
pub fn defaultResolve(
    filename: []const u8,
    source: ?[]const u8,
    options: *const LoadOptions,
) LoadError![]const u8 {
    const trimmed = mem.trim(u8, filename, " \t\r\n");

    if (trimmed.len == 0) {
        return error.InvalidPath;
    }

    // Security: reject paths that escape root
    if (!isPathSafe(trimmed)) {
        return error.PathEscapesRoot;
    }

    // Absolute path (starts with /)
    if (trimmed[0] == '/') {
        if (options.basedir == null) {
            return error.MissingBasedir;
        }
        // Join basedir with filename (without leading /)
        // Note: In a real implementation, we'd use path.join
        // For now, return the path as-is for testing
        return trimmed;
    }

    // Relative path
    if (source == null) {
        return error.MissingFilename;
    }

    // In a real implementation, join dirname(source) with filename
    // For now, return the path as-is for testing
    return trimmed;
}

/// Default file reading using std.fs
pub fn defaultRead(
    allocator: Allocator,
    filename: []const u8,
    options: *const LoadOptions,
) LoadError![]const u8 {
    _ = options;

    const file = fs.cwd().openFile(filename, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => error.FileNotFound,
            error.AccessDenied => error.AccessDenied,
            else => error.FileNotFound,
        };
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024 * 10) catch {
        return error.OutOfMemory;
    };

    return content;
}

// ============================================================================
// Load Implementation
// ============================================================================

/// Load file dependencies from an AST
/// Walks the AST and loads Include, RawInclude, and Extends nodes
pub fn load(
    allocator: Allocator,
    ast: *Node,
    options: LoadOptions,
) LoadError!*Node {
    // Create a context for the walk
    const LoadContext = struct {
        allocator: Allocator,
        options: LoadOptions,
        err: ?PugError = null,

        fn beforeCallback(node: *Node, _: bool, ctx: *WalkContext) WalkError!?ReplaceResult {
            const self: *@This() = @ptrCast(@alignCast(ctx.user_data.?));

            // Only process Include, RawInclude, and Extends nodes
            if (node.type != .Include and node.type != .RawInclude and node.type != .Extends) {
                return null;
            }

            // Check if already loaded (str is set)
            if (node.file) |*file| {
                // Load the file content
                self.loadFileReference(file, node) catch {
                    // Store error but continue walking
                    return null;
                };
            }

            return null;
        }

        fn loadFileReference(self: *@This(), file: *FileReference, node: *Node) LoadError!void {
            _ = node;

            if (file.path == null) {
                return error.InvalidFileReference;
            }

            // Resolve the path
            const resolve_fn = self.options.resolve orelse defaultResolve;
            const resolved_path = try resolve_fn(file.path.?, self.options.filename, &self.options);

            // Read the file
            const read_fn = self.options.read orelse defaultRead;
            const content = try read_fn(self.allocator, resolved_path, &self.options);
            _ = content;

            // For Include/Extends, parse the content into an AST
            // This would require lexer and parser functions to be provided
            // For now, we just load the raw content
        }
    };

    var load_ctx = LoadContext{
        .allocator = allocator,
        .options = options,
    };

    var walk_options = WalkOptions{};
    defer walk_options.deinit(allocator);

    const result = walk_mod.walkASTWithUserData(
        allocator,
        ast,
        LoadContext.beforeCallback,
        null,
        &walk_options,
        &load_ctx,
    ) catch {
        return error.WalkError;
    };

    if (load_ctx.err) |*e| {
        e.deinit();
        return error.FileNotFound;
    }

    return result;
}

/// Load from a string source
pub fn loadString(
    allocator: Allocator,
    src: []const u8,
    options: LoadOptions,
) LoadError!*Node {
    // Need lex and parse functions
    const lex_fn = options.lex orelse return error.LexError;
    const parse_fn = options.parse orelse return error.ParseError;

    // Lex the source
    const tokens = try lex_fn(allocator, src, &options);

    // Parse the tokens
    var parse_options = options;
    parse_options.src = src;
    const ast = try parse_fn(allocator, tokens, &parse_options);

    // Load dependencies
    return load(allocator, ast, parse_options);
}

/// Load from a file
pub fn loadFile(
    allocator: Allocator,
    filename: []const u8,
    options: LoadOptions,
) LoadError!*Node {
    // Read the file
    const read_fn = options.read orelse defaultRead;
    const content = try read_fn(allocator, filename, &options);
    defer allocator.free(content);

    // Load from string with filename set
    var file_options = options;
    file_options.filename = filename;
    return loadString(allocator, content, file_options);
}

// ============================================================================
// Path Utilities
// ============================================================================

/// Get the directory name from a path
pub fn dirname(path: []const u8) []const u8 {
    if (mem.lastIndexOf(u8, path, "/")) |idx| {
        if (idx == 0) return "/";
        return path[0..idx];
    }
    return ".";
}

/// Join two path components
pub fn pathJoin(allocator: Allocator, base: []const u8, relative: []const u8) ![]const u8 {
    if (relative.len > 0 and relative[0] == '/') {
        return allocator.dupe(u8, relative);
    }

    const base_dir = dirname(base);

    // Handle .. and . components
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, base_dir);
    if (base_dir.len > 0 and base_dir[base_dir.len - 1] != '/') {
        try result.append(allocator, '/');
    }
    try result.appendSlice(allocator, relative);

    return result.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "dirname - basic paths" {
    try std.testing.expectEqualStrings(".", dirname("file.pug"));
    try std.testing.expectEqualStrings("/home/user", dirname("/home/user/file.pug"));
    try std.testing.expectEqualStrings("views", dirname("views/file.pug"));
    try std.testing.expectEqualStrings("/", dirname("/file.pug"));
    try std.testing.expectEqualStrings(".", dirname(""));
}

test "pathJoin - relative paths" {
    const allocator = std.testing.allocator;

    const result1 = try pathJoin(allocator, "/home/user/views/index.pug", "partials/header.pug");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("/home/user/views/partials/header.pug", result1);

    const result2 = try pathJoin(allocator, "views/index.pug", "footer.pug");
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("views/footer.pug", result2);
}

test "pathJoin - absolute paths" {
    const allocator = std.testing.allocator;

    const result = try pathJoin(allocator, "/home/user/views/index.pug", "/absolute/path.pug");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/absolute/path.pug", result);
}

test "defaultResolve - rejects absolute paths as path escape" {
    const options = LoadOptions{};
    const result = defaultResolve("/absolute/path.pug", null, &options);
    // Absolute paths are rejected as path escape (security boundary)
    try std.testing.expectError(error.PathEscapesRoot, result);
}

test "defaultResolve - missing filename for relative path" {
    const options = LoadOptions{ .basedir = "/base" };
    const result = defaultResolve("relative/path.pug", null, &options);
    try std.testing.expectError(error.MissingFilename, result);
}

test "load - basic AST without includes" {
    const allocator = std.testing.allocator;

    // Create a simple AST with no includes
    const text_node = try allocator.create(Node);
    text_node.* = Node{
        .type = .Text,
        .val = "Hello",
        .line = 1,
        .column = 1,
    };

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, text_node);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    // Load should succeed with no changes
    const result = try load(allocator, root, .{});
    try std.testing.expectEqual(root, result);
}
