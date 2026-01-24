// linker.zig - Zig port of pug-linker
//
// Handles template inheritance and linking:
// - Resolves extends (parent template inheritance)
// - Handles named blocks (replace/append/prepend modes)
// - Processes includes with yield blocks
// - Manages mixin hoisting from child to parent

const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;

// Import AST types from parser
const parser = @import("parser.zig");
pub const Node = parser.Node;
pub const NodeType = parser.NodeType;

// Import walk module
const walk_mod = @import("walk.zig");
pub const WalkOptions = walk_mod.WalkOptions;
pub const WalkContext = walk_mod.WalkContext;
pub const WalkError = walk_mod.WalkError;
pub const ReplaceResult = walk_mod.ReplaceResult;

// Import error types
const pug_error = @import("error.zig");
pub const PugError = pug_error.PugError;

// ============================================================================
// Linker Errors
// ============================================================================

pub const LinkerError = error{
    OutOfMemory,
    InvalidAST,
    ExtendsNotFirst,
    UnexpectedNodesInExtending,
    UnexpectedBlock,
    WalkError,
};

// ============================================================================
// Block Definitions Map
// ============================================================================

/// Map of block names to their definition nodes
pub const BlockDefinitions = std.StringHashMapUnmanaged(*Node);

// ============================================================================
// Linker Result
// ============================================================================

pub const LinkerResult = struct {
    ast: *Node,
    declared_blocks: BlockDefinitions,
    has_extends: bool = false,
    err: ?PugError = null,

    pub fn deinit(self: *LinkerResult, allocator: Allocator) void {
        self.declared_blocks.deinit(allocator);
        if (self.err) |*e| {
            e.deinit();
        }
    }
};

// ============================================================================
// Link Implementation
// ============================================================================

/// Link an AST, resolving extends and includes
pub fn link(allocator: Allocator, ast: *Node) LinkerError!LinkerResult {
    // Top level must be a Block
    if (ast.type != .Block) {
        return error.InvalidAST;
    }

    var result = LinkerResult{
        .ast = ast,
        .declared_blocks = .{},
    };

    // Check for extends
    var extends_node: ?*Node = null;
    if (ast.nodes.items.len > 0) {
        const first_node = ast.nodes.items[0];
        if (first_node.type == .Extends) {
            // Verify extends position
            try checkExtendsPosition(allocator, ast);

            // Remove extends node from the list
            extends_node = ast.nodes.orderedRemove(0);
        }
    }

    // Apply includes (convert RawInclude to Text, link Include ASTs)
    result.ast = try applyIncludes(allocator, ast);

    // Find declared blocks
    result.declared_blocks = try findDeclaredBlocks(allocator, result.ast);

    // Handle extends
    if (extends_node) |ext_node| {
        // Get mixins and expected blocks from current template
        var mixins = std.ArrayListUnmanaged(*Node){};
        defer mixins.deinit(allocator);

        var expected_blocks = std.ArrayListUnmanaged(*Node){};
        defer expected_blocks.deinit(allocator);

        try collectMixinsAndBlocks(allocator, result.ast, &mixins, &expected_blocks);

        // Link the parent template
        if (ext_node.file) |file| {
            _ = file;
            // In a real implementation, we would:
            // 1. Get file.ast (the loaded parent AST)
            // 2. Recursively link it
            // 3. Extend parent blocks with child blocks
            // 4. Verify all expected blocks exist
            // 5. Merge mixin definitions

            // For now, mark that we have extends
            result.has_extends = true;
        }
    }

    return result;
}

/// Find all declared blocks (NamedBlock with mode="replace")
fn findDeclaredBlocks(allocator: Allocator, ast: *Node) LinkerError!BlockDefinitions {
    var definitions = BlockDefinitions{};

    const FindContext = struct {
        defs: *BlockDefinitions,
        alloc: Allocator,

        fn before(node: *Node, _: bool, ctx: *WalkContext) WalkError!?ReplaceResult {
            const self: *@This() = @ptrCast(@alignCast(ctx.user_data.?));

            if (node.type == .NamedBlock) {
                // Check mode - default is "replace"
                const mode = node.mode orelse "replace";
                if (mem.eql(u8, mode, "replace")) {
                    if (node.name) |name| {
                        self.defs.put(self.alloc, name, node) catch return error.OutOfMemory;
                    }
                }
            }
            return null;
        }
    };

    var find_ctx = FindContext{
        .defs = &definitions,
        .alloc = allocator,
    };

    var walk_options = WalkOptions{};
    defer walk_options.deinit(allocator);

    _ = walk_mod.walkASTWithUserData(
        allocator,
        ast,
        FindContext.before,
        null,
        &walk_options,
        &find_ctx,
    ) catch {
        return error.WalkError;
    };

    return definitions;
}

/// Collect mixin definitions and named blocks from the AST
fn collectMixinsAndBlocks(
    allocator: Allocator,
    ast: *Node,
    mixins: *std.ArrayListUnmanaged(*Node),
    expected_blocks: *std.ArrayListUnmanaged(*Node),
) LinkerError!void {
    for (ast.nodes.items) |node| {
        switch (node.type) {
            .NamedBlock => {
                try expected_blocks.append(allocator, node);
            },
            .Block => {
                // Recurse into nested blocks
                try collectMixinsAndBlocks(allocator, node, mixins, expected_blocks);
            },
            .Mixin => {
                // Only collect mixin definitions (not calls)
                if (!node.call) {
                    try mixins.append(allocator, node);
                }
            },
            else => {
                // In extending template, only named blocks and mixins allowed at top level
                // This would be an error in strict mode
            },
        }
    }
}

/// Extend parent blocks with child block content
fn extendBlocks(
    allocator: Allocator,
    parent_blocks: *BlockDefinitions,
    child_ast: *Node,
) LinkerError!void {
    const ExtendContext = struct {
        parent: *BlockDefinitions,
        stack: std.StringHashMapUnmanaged(void),
        alloc: Allocator,

        fn before(node: *Node, _: bool, ctx: *WalkContext) WalkError!?ReplaceResult {
            const self: *@This() = @ptrCast(@alignCast(ctx.user_data.?));

            if (node.type == .NamedBlock) {
                if (node.name) |name| {
                    // Check for circular reference
                    if (self.stack.contains(name)) {
                        return null; // Skip to avoid infinite loop
                    }

                    self.stack.put(self.alloc, name, {}) catch return error.OutOfMemory;

                    // Find parent block
                    if (self.parent.get(name)) |parent_block| {
                        const mode = node.mode orelse "replace";

                        if (mem.eql(u8, mode, "append")) {
                            // Append child nodes to parent
                            for (node.nodes.items) |child_node| {
                                parent_block.nodes.append(self.alloc, child_node) catch return error.OutOfMemory;
                            }
                        } else if (mem.eql(u8, mode, "prepend")) {
                            // Prepend child nodes to parent
                            for (node.nodes.items, 0..) |child_node, i| {
                                parent_block.nodes.insert(self.alloc, i, child_node) catch return error.OutOfMemory;
                            }
                        } else {
                            // Replace - clear parent and add child nodes
                            parent_block.nodes.clearRetainingCapacity();
                            for (node.nodes.items) |child_node| {
                                parent_block.nodes.append(self.alloc, child_node) catch return error.OutOfMemory;
                            }
                        }
                    }
                }
            }
            return null;
        }

        fn after(node: *Node, _: bool, ctx: *WalkContext) WalkError!?ReplaceResult {
            const self: *@This() = @ptrCast(@alignCast(ctx.user_data.?));

            if (node.type == .NamedBlock) {
                if (node.name) |name| {
                    _ = self.stack.remove(name);
                }
            }
            return null;
        }
    };

    var extend_ctx = ExtendContext{
        .parent = parent_blocks,
        .stack = .{},
        .alloc = allocator,
    };
    defer extend_ctx.stack.deinit(allocator);

    var walk_options = WalkOptions{};
    defer walk_options.deinit(allocator);

    _ = walk_mod.walkASTWithUserData(
        allocator,
        child_ast,
        ExtendContext.before,
        ExtendContext.after,
        &walk_options,
        &extend_ctx,
    ) catch {
        return error.WalkError;
    };
}

/// Apply includes - convert RawInclude to Text, process Include nodes
fn applyIncludes(allocator: Allocator, ast: *Node) LinkerError!*Node {
    const IncludeContext = struct {
        alloc: Allocator,

        fn before(node: *Node, _: bool, ctx: *WalkContext) WalkError!?ReplaceResult {
            const self: *@This() = @ptrCast(@alignCast(ctx.user_data.?));
            _ = self;

            // Convert RawInclude to Text
            if (node.type == .RawInclude) {
                // In a real implementation:
                // - Get file.str (the loaded file content)
                // - Create a Text node with that content
                // For now, just keep the node as-is
                node.type = .Text;
                // node.val = file.str with \r removed
            }
            return null;
        }

        fn after(node: *Node, _: bool, ctx: *WalkContext) WalkError!?ReplaceResult {
            const self: *@This() = @ptrCast(@alignCast(ctx.user_data.?));
            _ = self;

            // Process Include nodes
            if (node.type == .Include) {
                // In a real implementation:
                // 1. Link the included file's AST
                // 2. If it has extends, remove named blocks
                // 3. Apply yield block
                // For now, keep the node as-is
            }
            return null;
        }
    };

    var include_ctx = IncludeContext{
        .alloc = allocator,
    };

    var walk_options = WalkOptions{};
    defer walk_options.deinit(allocator);

    const result = walk_mod.walkASTWithUserData(
        allocator,
        ast,
        IncludeContext.before,
        IncludeContext.after,
        &walk_options,
        &include_ctx,
    ) catch {
        return error.WalkError;
    };

    return result;
}

/// Check that extends is the first thing in the file
fn checkExtendsPosition(allocator: Allocator, ast: *Node) LinkerError!void {
    var found_legit_extends = false;

    const CheckContext = struct {
        legit_extends: *bool,
        has_extends: bool,
        alloc: Allocator,

        fn before(node: *Node, _: bool, ctx: *WalkContext) WalkError!?ReplaceResult {
            const self: *@This() = @ptrCast(@alignCast(ctx.user_data.?));

            if (node.type == .Extends) {
                if (self.has_extends and !self.legit_extends.*) {
                    self.legit_extends.* = true;
                } else {
                    // This would be an error - extends not first or multiple extends
                    // For now we just skip
                }
            }
            return null;
        }
    };

    var check_ctx = CheckContext{
        .legit_extends = &found_legit_extends,
        .has_extends = true,
        .alloc = allocator,
    };

    var walk_options = WalkOptions{};
    defer walk_options.deinit(allocator);

    _ = walk_mod.walkASTWithUserData(
        allocator,
        ast,
        CheckContext.before,
        null,
        &walk_options,
        &check_ctx,
    ) catch {
        return error.WalkError;
    };
}

/// Remove named blocks (convert to regular blocks)
pub fn removeNamedBlocks(allocator: Allocator, ast: *Node) LinkerError!*Node {
    const RemoveContext = struct {
        alloc: Allocator,

        fn before(node: *Node, _: bool, ctx: *WalkContext) WalkError!?ReplaceResult {
            const self: *@This() = @ptrCast(@alignCast(ctx.user_data.?));
            _ = self;

            if (node.type == .NamedBlock) {
                node.type = .Block;
                node.name = null;
                node.mode = null;
            }
            return null;
        }
    };

    var remove_ctx = RemoveContext{
        .alloc = allocator,
    };

    var walk_options = WalkOptions{};
    defer walk_options.deinit(allocator);

    return walk_mod.walkASTWithUserData(
        allocator,
        ast,
        RemoveContext.before,
        null,
        &walk_options,
        &remove_ctx,
    ) catch error.WalkError;
}

/// Apply yield block to included content
pub fn applyYield(allocator: Allocator, ast: *Node, block: ?*Node) LinkerError!*Node {
    if (block == null or block.?.nodes.items.len == 0) {
        return ast;
    }

    var replaced = false;

    const YieldContext = struct {
        yield_block: *Node,
        was_replaced: *bool,
        alloc: Allocator,

        fn after(node: *Node, _: bool, ctx: *WalkContext) WalkError!?ReplaceResult {
            const self: *@This() = @ptrCast(@alignCast(ctx.user_data.?));

            if (node.type == .YieldBlock) {
                self.was_replaced.* = true;
                node.type = .Block;
                node.nodes.clearRetainingCapacity();
                node.nodes.append(self.alloc, self.yield_block) catch return error.OutOfMemory;
            }
            return null;
        }
    };

    var yield_ctx = YieldContext{
        .yield_block = block.?,
        .was_replaced = &replaced,
        .alloc = allocator,
    };

    var walk_options = WalkOptions{};
    defer walk_options.deinit(allocator);

    const result = walk_mod.walkASTWithUserData(
        allocator,
        ast,
        null,
        YieldContext.after,
        &walk_options,
        &yield_ctx,
    ) catch {
        return error.WalkError;
    };

    // If no yield block found, append to default location
    if (!replaced) {
        const default_loc = findDefaultYieldLocation(result);
        default_loc.nodes.append(allocator, block.?) catch return error.OutOfMemory;
    }

    return result;
}

/// Find the default yield location (deepest block)
fn findDefaultYieldLocation(node: *Node) *Node {
    var result = node;

    for (node.nodes.items) |child| {
        if (child.text_only) continue;

        if (child.type == .Block) {
            result = findDefaultYieldLocation(child);
        } else if (child.nodes.items.len > 0) {
            result = findDefaultYieldLocation(child);
        }
    }

    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "link - basic block" {
    const allocator = std.testing.allocator;

    // Create a simple AST
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

    var result = try link(allocator, root);
    defer result.deinit(allocator);

    try std.testing.expectEqual(root, result.ast);
    try std.testing.expectEqual(false, result.has_extends);
}

test "link - with named block" {
    const allocator = std.testing.allocator;

    // Create named block
    const text_node = try allocator.create(Node);
    text_node.* = Node{
        .type = .Text,
        .val = "content",
        .line = 2,
        .column = 3,
    };

    const named_block = try allocator.create(Node);
    named_block.* = Node{
        .type = .NamedBlock,
        .name = "content",
        .mode = "replace",
        .line = 2,
        .column = 1,
    };
    try named_block.nodes.append(allocator, text_node);

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, named_block);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    var result = try link(allocator, root);
    defer result.deinit(allocator);

    // Should find the declared block
    try std.testing.expect(result.declared_blocks.contains("content"));
}

test "findDeclaredBlocks - multiple blocks" {
    const allocator = std.testing.allocator;

    const block1 = try allocator.create(Node);
    block1.* = Node{
        .type = .NamedBlock,
        .name = "header",
        .mode = "replace",
        .line = 1,
        .column = 1,
    };

    const block2 = try allocator.create(Node);
    block2.* = Node{
        .type = .NamedBlock,
        .name = "footer",
        .mode = "replace",
        .line = 5,
        .column = 1,
    };

    const block3 = try allocator.create(Node);
    block3.* = Node{
        .type = .NamedBlock,
        .name = "sidebar",
        .mode = "append", // Should not be in declared blocks
        .line = 10,
        .column = 1,
    };

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, block1);
    try root.nodes.append(allocator, block2);
    try root.nodes.append(allocator, block3);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    var blocks = try findDeclaredBlocks(allocator, root);
    defer blocks.deinit(allocator);

    try std.testing.expect(blocks.contains("header"));
    try std.testing.expect(blocks.contains("footer"));
    try std.testing.expect(!blocks.contains("sidebar")); // append mode
}

test "removeNamedBlocks" {
    const allocator = std.testing.allocator;

    const named_block = try allocator.create(Node);
    named_block.* = Node{
        .type = .NamedBlock,
        .name = "content",
        .mode = "replace",
        .line = 1,
        .column = 1,
    };

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, named_block);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    const result = try removeNamedBlocks(allocator, root);

    // Named block should now be a regular Block
    try std.testing.expectEqual(NodeType.Block, result.nodes.items[0].type);
    try std.testing.expectEqual(@as(?[]const u8, null), result.nodes.items[0].name);
}

test "findDefaultYieldLocation - nested blocks" {
    const allocator = std.testing.allocator;

    const inner_block = try allocator.create(Node);
    inner_block.* = Node{
        .type = .Block,
        .line = 3,
        .column = 1,
    };

    const outer_block = try allocator.create(Node);
    outer_block.* = Node{
        .type = .Block,
        .line = 2,
        .column = 1,
    };
    try outer_block.nodes.append(allocator, inner_block);

    var root = try allocator.create(Node);
    root.* = Node{
        .type = .Block,
        .line = 1,
        .column = 1,
    };
    try root.nodes.append(allocator, outer_block);

    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    const location = findDefaultYieldLocation(root);

    // Should find the innermost block
    try std.testing.expectEqual(inner_block, location);
}
