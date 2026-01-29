// walk.zig - Zig port of pug-walk
//
// AST traversal utility with visitor pattern for Pug AST nodes.
// Provides before/after callbacks for each node with optional replacement.

const std = @import("std");
const Allocator = std.mem.Allocator;

// Import AST types from parser
const parser = @import("parser.zig");
pub const Node = parser.Node;
pub const NodeType = parser.NodeType;

// ============================================================================
// Walk Options
// ============================================================================

pub const WalkOptions = struct {
    /// Include dependencies (traverse into FileReference.ast if present)
    include_dependencies: bool = false,
    /// Parent node stack (managed internally during walk)
    parents: std.ArrayList(*Node) = .{},

    pub fn deinit(self: *WalkOptions, allocator: Allocator) void {
        self.parents.deinit(allocator);
    }

    /// Initialize with pre-allocated capacity for expected tree depth
    /// Reduces allocations during deep AST traversal
    pub fn initWithCapacity(allocator: Allocator, capacity: usize) !WalkOptions {
        var opts = WalkOptions{};
        try opts.parents.ensureTotalCapacity(allocator, capacity);
        return opts;
    }
};

// ============================================================================
// Replace Result
// ============================================================================

/// Result of a replace operation
pub const ReplaceResult = union(enum) {
    /// Keep the current node unchanged
    keep,
    /// Replace with a single node
    single: *Node,
    /// Replace with multiple nodes (only valid in Block/NamedBlock contexts)
    multiple: []*Node,
    /// Remove the node (replace with nothing)
    remove,
};

// ============================================================================
// Callback Types
// ============================================================================

/// Before callback - called before visiting children
/// Return false to skip traversing children, null to continue
/// Can use ReplaceResult to replace the current node
pub const BeforeCallback = *const fn (
    node: *Node,
    replace_allowed: bool,
    ctx: *WalkContext,
) WalkError!?ReplaceResult;

/// After callback - called after visiting children
pub const AfterCallback = *const fn (
    node: *Node,
    replace_allowed: bool,
    ctx: *WalkContext,
) WalkError!?ReplaceResult;

// ============================================================================
// Walk Context
// ============================================================================

pub const WalkContext = struct {
    allocator: Allocator,
    options: *WalkOptions,
    user_data: ?*anyopaque = null,

    /// Get parent at index (0 = immediate parent, 1 = grandparent, etc.)
    /// Uses reverse indexing since parents are stored with oldest first (stack-like append/pop)
    pub fn getParent(self: *WalkContext, index: usize) ?*Node {
        const len = self.options.parents.items.len;
        if (index >= len) return null;
        // Reverse index: 0 = last item (immediate parent), 1 = second-to-last, etc.
        return self.options.parents.items[len - 1 - index];
    }

    /// Get the immediate parent node
    pub fn parent(self: *WalkContext) ?*Node {
        const items = self.options.parents.items;
        if (items.len == 0) return null;
        return items[items.len - 1];
    }

    /// Get number of parents in the stack
    pub fn depth(self: *WalkContext) usize {
        return self.options.parents.items.len;
    }
};

// ============================================================================
// Walk Errors
// ============================================================================

pub const WalkError = error{
    OutOfMemory,
    ArrayReplaceNotAllowed,
    UnexpectedNodeType,
};

// ============================================================================
// Walk Implementation
// ============================================================================

/// Walk the AST tree, calling before/after callbacks for each node
pub fn walkAST(
    allocator: Allocator,
    ast: *Node,
    before: ?BeforeCallback,
    after: ?AfterCallback,
    options: *WalkOptions,
) WalkError!*Node {
    return walkASTWithUserData(allocator, ast, before, after, options, null);
}

/// Walk the AST tree with user-provided context data
pub fn walkASTWithUserData(
    allocator: Allocator,
    ast: *Node,
    before: ?BeforeCallback,
    after: ?AfterCallback,
    options: *WalkOptions,
    user_data: ?*anyopaque,
) WalkError!*Node {
    var current = ast;

    // Check if array replacement is allowed based on parent context
    const replace_allowed = isArrayReplaceAllowed(options, current);

    var ctx = WalkContext{
        .allocator = allocator,
        .options = options,
        .user_data = user_data,
    };

    // Call before callback
    if (before) |before_fn| {
        if (try before_fn(current, replace_allowed, &ctx)) |result| {
            switch (result) {
                .keep => {},
                .single => |replacement| {
                    current = replacement;
                },
                .multiple => {
                    // Array replacement - return the original node as marker
                    // The caller (walkAndMergeNodes) will handle expansion
                    return current;
                },
                .remove => {
                    // Return null marker - handled by caller
                    return current;
                },
            }
        }
    }

    // Push current node to parents stack (O(1) append instead of O(n) insert at 0)
    try options.parents.append(allocator, current);
    defer _ = options.parents.pop();

    // Visit children based on node type
    try visitChildren(allocator, current, before, after, options, user_data);

    // Call after callback
    if (after) |after_fn| {
        if (try after_fn(current, replace_allowed, &ctx)) |result| {
            switch (result) {
                .keep => {},
                .single => |replacement| {
                    current = replacement;
                },
                .multiple, .remove => {
                    // Handled by caller
                },
            }
        }
    }

    return current;
}

/// Check if array replacement is allowed for the current context
fn isArrayReplaceAllowed(options: *WalkOptions, node: *Node) bool {
    const items = options.parents.items;
    if (items.len == 0) return false;

    // Get immediate parent (last item in stack)
    const parent_node = items[items.len - 1];

    // Array replacement allowed in Block/NamedBlock
    if (parent_node.type == .Block or parent_node.type == .NamedBlock) {
        return true;
    }

    // Also allowed for IncludeFilter in RawInclude
    if (parent_node.type == .RawInclude and node.type == .IncludeFilter) {
        return true;
    }

    return false;
}

/// Visit children of a node based on its type
fn visitChildren(
    allocator: Allocator,
    node: *Node,
    before: ?BeforeCallback,
    after: ?AfterCallback,
    options: *WalkOptions,
    user_data: ?*anyopaque,
) WalkError!void {
    switch (node.type) {
        .NamedBlock, .Block => {
            // Walk and merge nodes
            try walkAndMergeNodes(allocator, &node.nodes, before, after, options, user_data);
        },

        .Case, .Filter, .Mixin, .Tag, .InterpolatedTag, .When, .Code, .While => {
            // Walk block if present (represented by non-empty nodes)
            if (node.nodes.items.len > 0) {
                // Find the block node (first child that is a Block)
                for (node.nodes.items, 0..) |child, i| {
                    if (child.type == .Block or child.type == .NamedBlock) {
                        node.nodes.items[i] = try walkASTWithUserData(
                            allocator,
                            child,
                            before,
                            after,
                            options,
                            user_data,
                        );
                    }
                }
            }
        },

        .Each => {
            // Walk block
            if (node.nodes.items.len > 0) {
                for (node.nodes.items, 0..) |child, i| {
                    if (child.type == .Block or child.type == .NamedBlock) {
                        node.nodes.items[i] = try walkASTWithUserData(
                            allocator,
                            child,
                            before,
                            after,
                            options,
                            user_data,
                        );
                    }
                }
            }
            // Walk alternate
            if (node.alternate) |alt| {
                node.alternate = try walkASTWithUserData(
                    allocator,
                    alt,
                    before,
                    after,
                    options,
                    user_data,
                );
            }
        },

        .EachOf => {
            // Walk block only
            if (node.nodes.items.len > 0) {
                for (node.nodes.items, 0..) |child, i| {
                    if (child.type == .Block or child.type == .NamedBlock) {
                        node.nodes.items[i] = try walkASTWithUserData(
                            allocator,
                            child,
                            before,
                            after,
                            options,
                            user_data,
                        );
                    }
                }
            }
        },

        .Conditional => {
            // Walk consequent
            if (node.consequent) |cons| {
                node.consequent = try walkASTWithUserData(
                    allocator,
                    cons,
                    before,
                    after,
                    options,
                    user_data,
                );
            }
            // Walk alternate
            if (node.alternate) |alt| {
                node.alternate = try walkASTWithUserData(
                    allocator,
                    alt,
                    before,
                    after,
                    options,
                    user_data,
                );
            }
        },

        .Include => {
            // Walk block (represented as child nodes)
            try walkAndMergeNodes(allocator, &node.nodes, before, after, options, user_data);
            // Note: file is a FileReference struct, not a Node, so we don't walk it
        },

        .Extends => {
            // Note: file is a FileReference struct, not a Node
        },

        .RawInclude => {
            // Walk filters
            try walkAndMergeNodes(allocator, &node.filters, before, after, options, user_data);
            // Note: file is a FileReference struct
        },

        .FileReference => {
            // Walk into ast if includeDependencies is set
            // Note: In our implementation, FileReference doesn't hold a nested AST directly
            // This would need to be handled by the loader
            _ = options.include_dependencies;
        },

        // Leaf nodes - no children to visit
        .AttributeBlock,
        .BlockComment,
        .Comment,
        .Doctype,
        .IncludeFilter,
        .MixinBlock,
        .YieldBlock,
        .Text,
        .TypeHint,
        => {},
    }
}

/// Walk a list of nodes and merge results (handling array replacements)
fn walkAndMergeNodes(
    allocator: Allocator,
    nodes: *std.ArrayList(*Node),
    before: ?BeforeCallback,
    after: ?AfterCallback,
    options: *WalkOptions,
    user_data: ?*anyopaque,
) WalkError!void {
    var i: usize = 0;
    while (i < nodes.items.len) {
        const result = try walkASTWithUserData(
            allocator,
            nodes.items[i],
            before,
            after,
            options,
            user_data,
        );

        // Update the node in place
        nodes.items[i] = result;
        i += 1;
    }
}

// ============================================================================
// Convenience Functions
// ============================================================================

/// Simple walk that just calls a callback for each node (no replacement)
pub fn walk(
    allocator: Allocator,
    ast: *Node,
    callback: *const fn (node: *Node, ctx: *WalkContext) WalkError!void,
) WalkError!void {
    const Wrapper = struct {
        fn before(node: *Node, _: bool, ctx: *WalkContext) WalkError!?ReplaceResult {
            const cb: *const fn (*Node, *WalkContext) WalkError!void = @ptrCast(@alignCast(ctx.user_data.?));
            try cb(node, ctx);
            return null;
        }
    };

    var options = WalkOptions{};
    defer options.deinit(allocator);

    _ = try walkASTWithUserData(
        allocator,
        ast,
        Wrapper.before,
        null,
        &options,
        @ptrCast(@constCast(callback)),
    );
}

/// Count nodes of a specific type
pub fn countNodes(allocator: Allocator, ast: *Node, node_type: NodeType) WalkError!usize {
    const Counter = struct {
        count: usize = 0,
        target_type: NodeType,

        fn before(node: *Node, _: bool, ctx: *WalkContext) WalkError!?ReplaceResult {
            const self: *@This() = @ptrCast(@alignCast(ctx.user_data.?));
            if (node.type == self.target_type) {
                self.count += 1;
            }
            return null;
        }
    };

    var counter = Counter{ .target_type = node_type };
    var options = WalkOptions{};
    defer options.deinit(allocator);

    _ = try walkASTWithUserData(
        allocator,
        ast,
        Counter.before,
        null,
        &options,
        &counter,
    );

    return counter.count;
}

/// Find the first node matching a predicate
pub fn findNode(
    allocator: Allocator,
    ast: *Node,
    predicate: *const fn (node: *Node) bool,
) WalkError!?*Node {
    const Finder = struct {
        found: ?*Node = null,
        pred: *const fn (*Node) bool,

        fn before(node: *Node, _: bool, ctx: *WalkContext) WalkError!?ReplaceResult {
            const self: *@This() = @ptrCast(@alignCast(ctx.user_data.?));
            if (self.found == null and self.pred(node)) {
                self.found = node;
            }
            return null;
        }
    };

    var finder = Finder{ .pred = predicate };
    var options = WalkOptions{};
    defer options.deinit(allocator);

    _ = try walkASTWithUserData(
        allocator,
        ast,
        Finder.before,
        null,
        &options,
        &finder,
    );

    return finder.found;
}

/// Collect all nodes of a specific type
pub fn collectNodes(
    allocator: Allocator,
    ast: *Node,
    node_type: NodeType,
) WalkError!std.ArrayList(*Node) {
    const Collector = struct {
        collected: std.ArrayList(*Node) = .{},
        alloc: Allocator,
        target_type: NodeType,

        fn before(node: *Node, _: bool, ctx: *WalkContext) WalkError!?ReplaceResult {
            const self: *@This() = @ptrCast(@alignCast(ctx.user_data.?));
            if (node.type == self.target_type) {
                self.collected.append(self.alloc, node) catch return error.OutOfMemory;
            }
            return null;
        }
    };

    var collector = Collector{
        .alloc = allocator,
        .target_type = node_type,
    };
    var options = WalkOptions{};
    defer options.deinit(allocator);

    _ = try walkASTWithUserData(
        allocator,
        ast,
        Collector.before,
        null,
        &options,
        &collector,
    );

    return collector.collected;
}

// ============================================================================
// Tests
// ============================================================================

test "walkAST - basic traversal" {
    const allocator = std.testing.allocator;

    // Create a simple AST: Block -> Tag -> Text
    const text_node = try allocator.create(Node);
    text_node.* = Node{
        .type = .Text,
        .val = "Hello",
        .line = 1,
        .column = 1,
    };

    var tag_block = try allocator.create(Node);
    tag_block.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try tag_block.nodes.append(allocator, text_node);

    var tag_node = try allocator.create(Node);
    tag_node.* = Node{
        .type = .Tag,
        .name = "div",
        .line = 1,
        .column = 1,
    };
    try tag_node.nodes.append(allocator, tag_block);

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, tag_node);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    // Count nodes
    const count = try countNodes(allocator, root, .Tag);
    try std.testing.expectEqual(@as(usize, 1), count);

    const block_count = try countNodes(allocator, root, .Block);
    try std.testing.expectEqual(@as(usize, 2), block_count);

    const text_count = try countNodes(allocator, root, .Text);
    try std.testing.expectEqual(@as(usize, 1), text_count);
}

test "walkAST - conditional traversal" {
    const allocator = std.testing.allocator;

    // Create AST with conditional: if (test) then else
    const then_block = try allocator.create(Node);
    then_block.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };

    const else_block = try allocator.create(Node);
    else_block.* = Node{
        .type = .Block,
        .line = 2,
        .column = 1,
    };

    const cond_node = try allocator.create(Node);
    cond_node.* = Node{
        .type = .Conditional,
        .test_expr = "true",
        .consequent = then_block,
        .alternate = else_block,
        .line = 1,
        .column = 1,
    };

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, cond_node);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    // Count all blocks (root + then + else = 3)
    const block_count = try countNodes(allocator, root, .Block);
    try std.testing.expectEqual(@as(usize, 3), block_count);

    // Count conditionals
    const cond_count = try countNodes(allocator, root, .Conditional);
    try std.testing.expectEqual(@as(usize, 1), cond_count);
}

test "walkAST - each with alternate" {
    const allocator = std.testing.allocator;

    // Create Each node with block and alternate
    const loop_block = try allocator.create(Node);
    loop_block.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };

    const alt_block = try allocator.create(Node);
    alt_block.* = Node{
        .type = .Block,
        .line = 2,
        .column = 1,
    };

    var each_node = try allocator.create(Node);
    each_node.* = Node{
        .type = .Each,
        .val = "item",
        .obj = "items",
        .alternate = alt_block,
        .line = 1,
        .column = 1,
    };
    try each_node.nodes.append(allocator, loop_block);

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, each_node);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    // Count blocks (root + loop_block + alt_block = 3)
    const block_count = try countNodes(allocator, root, .Block);
    try std.testing.expectEqual(@as(usize, 3), block_count);

    // Count each nodes
    const each_count = try countNodes(allocator, root, .Each);
    try std.testing.expectEqual(@as(usize, 1), each_count);
}

test "walkAST - findNode" {
    const allocator = std.testing.allocator;

    // Create a simple AST with multiple tags
    const tag1 = try allocator.create(Node);
    tag1.* = Node{
        .type = .Tag,
        .name = "div",
        .line = 1,
        .column = 1,
    };

    const tag2 = try allocator.create(Node);
    tag2.* = Node{
        .type = .Tag,
        .name = "span",
        .line = 2,
        .column = 1,
    };

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, tag1);
    try root.nodes.append(allocator, tag2);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    // Find span tag
    const isSpan = struct {
        fn check(node: *Node) bool {
            return node.type == .Tag and
                node.name != null and
                std.mem.eql(u8, node.name.?, "span");
        }
    }.check;

    const found = try findNode(allocator, root, isSpan);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("span", found.?.name.?);
}

test "walkAST - collectNodes" {
    const allocator = std.testing.allocator;

    // Create AST with multiple text nodes
    const text1 = try allocator.create(Node);
    text1.* = Node{
        .type = .Text,
        .val = "Hello",
        .line = 1,
        .column = 1,
    };

    const text2 = try allocator.create(Node);
    text2.* = Node{
        .type = .Text,
        .val = "World",
        .line = 2,
        .column = 1,
    };

    const tag = try allocator.create(Node);
    tag.* = Node{
        .type = .Tag,
        .name = "div",
        .line = 1,
        .column = 1,
    };

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, text1);
    try root.nodes.append(allocator, tag);
    try root.nodes.append(allocator, text2);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    // Collect all text nodes
    var collected = try collectNodes(allocator, root, .Text);
    defer collected.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), collected.items.len);
    try std.testing.expectEqualStrings("Hello", collected.items[0].val.?);
    try std.testing.expectEqualStrings("World", collected.items[1].val.?);
}

test "walkAST - parent tracking" {
    const allocator = std.testing.allocator;

    // Create nested structure
    const inner_text = try allocator.create(Node);
    inner_text.* = Node{
        .type = .Text,
        .val = "nested",
        .line = 1,
        .column = 1,
    };

    var inner_block = try allocator.create(Node);
    inner_block.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try inner_block.nodes.append(allocator, inner_text);

    var tag = try allocator.create(Node);
    tag.* = Node{
        .type = .Tag,
        .name = "div",
        .line = 1,
        .column = 1,
    };
    try tag.nodes.append(allocator, inner_block);

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, tag);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    // Track parent depths for text node
    const ParentTracker = struct {
        text_depth: usize = 0,
        text_parent_type: ?NodeType = null,

        fn before(node: *Node, _: bool, ctx: *WalkContext) WalkError!?ReplaceResult {
            const self: *@This() = @ptrCast(@alignCast(ctx.user_data.?));
            if (node.type == .Text) {
                self.text_depth = ctx.depth();
                if (ctx.parent()) |p| {
                    self.text_parent_type = p.type;
                }
            }
            return null;
        }
    };

    var tracker = ParentTracker{};
    var options = WalkOptions{};
    defer options.deinit(allocator);

    _ = try walkASTWithUserData(
        allocator,
        root,
        ParentTracker.before,
        null,
        &options,
        &tracker,
    );

    // Text node should have depth 3 (root Block -> Tag -> inner Block -> Text)
    // Parent should be the inner Block
    try std.testing.expectEqual(@as(usize, 3), tracker.text_depth);
    try std.testing.expectEqual(NodeType.Block, tracker.text_parent_type.?);
}

test "walkAST - RawInclude with filters" {
    const allocator = std.testing.allocator;

    // Create RawInclude with filters
    const filter1 = try allocator.create(Node);
    filter1.* = Node{
        .type = .IncludeFilter,
        .name = "markdown",
        .line = 1,
        .column = 1,
    };

    const filter2 = try allocator.create(Node);
    filter2.* = Node{
        .type = .IncludeFilter,
        .name = "escape",
        .line = 1,
        .column = 1,
    };

    var raw_include = try allocator.create(Node);
    raw_include.* = Node{
        .type = .RawInclude,
        .line = 1,
        .column = 1,
    };
    try raw_include.filters.append(allocator, filter1);
    try raw_include.filters.append(allocator, filter2);

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, raw_include);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    // Count IncludeFilter nodes
    const filter_count = try countNodes(allocator, root, .IncludeFilter);
    try std.testing.expectEqual(@as(usize, 2), filter_count);
}
