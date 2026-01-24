// mixin.zig - Mixin registry and expansion
//
// Handles mixin definitions and calls:
// - Collects mixin definitions from AST into a registry
// - Expands mixin calls by substituting arguments and block content
//
// Usage pattern in Pug:
//   mixin button(text, type)
//     button(class="btn btn-" + type)= text
//
//   +button("Click", "primary")
//
// Include pattern:
//   include mixins/_buttons.pug
//   +primary-button("Click")

const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;

const parser = @import("parser.zig");
pub const Node = parser.Node;
pub const NodeType = parser.NodeType;

// ============================================================================
// Mixin Registry
// ============================================================================

/// Registry for mixin definitions
pub const MixinRegistry = struct {
    allocator: Allocator,
    mixins: std.StringHashMapUnmanaged(*Node),

    pub fn init(allocator: Allocator) MixinRegistry {
        return .{
            .allocator = allocator,
            .mixins = .{},
        };
    }

    pub fn deinit(self: *MixinRegistry) void {
        self.mixins.deinit(self.allocator);
    }

    /// Register a mixin definition
    pub fn register(self: *MixinRegistry, name: []const u8, node: *Node) !void {
        try self.mixins.put(self.allocator, name, node);
    }

    /// Get a mixin definition by name
    pub fn get(self: *const MixinRegistry, name: []const u8) ?*Node {
        return self.mixins.get(name);
    }

    /// Check if a mixin exists
    pub fn contains(self: *const MixinRegistry, name: []const u8) bool {
        return self.mixins.contains(name);
    }
};

// ============================================================================
// Mixin Collector - Collect definitions from AST
// ============================================================================

/// Collect all mixin definitions from an AST into the registry
pub fn collectMixins(allocator: Allocator, ast: *Node, registry: *MixinRegistry) !void {
    try collectMixinsFromNode(allocator, ast, registry);
}

fn collectMixinsFromNode(allocator: Allocator, node: *Node, registry: *MixinRegistry) !void {
    // If this is a mixin definition (not a call), register it
    if (node.type == .Mixin and !node.call) {
        if (node.name) |name| {
            try registry.register(name, node);
        }
    }

    // Recurse into children
    for (node.nodes.items) |child| {
        try collectMixinsFromNode(allocator, child, registry);
    }
}

// ============================================================================
// Mixin Expander - Expand mixin calls in AST
// ============================================================================

/// Error types for mixin expansion
pub const MixinError = error{
    OutOfMemory,
    MixinNotFound,
    InvalidMixinCall,
};

/// Expand all mixin calls in an AST using the registry
/// Returns a new AST with mixin calls replaced by their expanded content
pub fn expandMixins(allocator: Allocator, ast: *Node, registry: *const MixinRegistry) MixinError!*Node {
    return expandNode(allocator, ast, registry, null);
}

fn expandNode(
    allocator: Allocator,
    node: *Node,
    registry: *const MixinRegistry,
    caller_block: ?*Node,
) MixinError!*Node {
    // Handle mixin call
    if (node.type == .Mixin and node.call) {
        return expandMixinCall(allocator, node, registry, caller_block);
    }

    // Handle MixinBlock - replace with caller's block content
    if (node.type == .MixinBlock) {
        if (caller_block) |block| {
            // Clone the caller's block
            return cloneNode(allocator, block);
        } else {
            // No block provided, return empty block
            const empty = allocator.create(Node) catch return error.OutOfMemory;
            empty.* = Node{
                .type = .Block,
                .line = node.line,
                .column = node.column,
            };
            return empty;
        }
    }

    // For other nodes, clone and recurse into children
    const new_node = allocator.create(Node) catch return error.OutOfMemory;
    new_node.* = node.*;
    new_node.nodes = .{};

    // Clone and expand children
    for (node.nodes.items) |child| {
        const expanded_child = try expandNode(allocator, child, registry, caller_block);
        new_node.nodes.append(allocator, expanded_child) catch return error.OutOfMemory;
    }

    return new_node;
}

fn expandMixinCall(
    allocator: Allocator,
    call_node: *Node,
    registry: *const MixinRegistry,
    _: ?*Node,
) MixinError!*Node {
    const mixin_name = call_node.name orelse return error.InvalidMixinCall;

    // Look up mixin definition
    const mixin_def = registry.get(mixin_name) orelse {
        // Mixin not found - return a comment node indicating the error
        const error_node = allocator.create(Node) catch return error.OutOfMemory;
        error_node.* = Node{
            .type = .Comment,
            .val = mixin_name,
            .buffer = true,
            .line = call_node.line,
            .column = call_node.column,
        };
        return error_node;
    };

    // Get the block content from the call (if any)
    var call_block: ?*Node = null;
    if (call_node.nodes.items.len > 0) {
        // Create a block node containing the call's children
        const block = allocator.create(Node) catch return error.OutOfMemory;
        block.* = Node{
            .type = .Block,
            .line = call_node.line,
            .column = call_node.column,
        };
        for (call_node.nodes.items) |child| {
            const cloned = try cloneNode(allocator, child);
            block.nodes.append(allocator, cloned) catch return error.OutOfMemory;
        }
        call_block = block;
    }

    // Create argument bindings
    var arg_bindings = std.StringHashMapUnmanaged([]const u8){};
    defer arg_bindings.deinit(allocator);

    // Bind call arguments to mixin parameters
    if (mixin_def.args) |params| {
        if (call_node.args) |args| {
            try bindArguments(allocator, params, args, &arg_bindings);
        }
    }

    // Clone and expand the mixin body
    const result = allocator.create(Node) catch return error.OutOfMemory;
    result.* = Node{
        .type = .Block,
        .line = call_node.line,
        .column = call_node.column,
    };

    // Expand each node in the mixin definition's body
    for (mixin_def.nodes.items) |child| {
        const expanded = try expandNodeWithArgs(allocator, child, registry, call_block, &arg_bindings);
        result.nodes.append(allocator, expanded) catch return error.OutOfMemory;
    }

    return result;
}

fn expandNodeWithArgs(
    allocator: Allocator,
    node: *Node,
    registry: *const MixinRegistry,
    caller_block: ?*Node,
    arg_bindings: *const std.StringHashMapUnmanaged([]const u8),
) MixinError!*Node {
    // Handle mixin call (nested)
    if (node.type == .Mixin and node.call) {
        return expandMixinCall(allocator, node, registry, caller_block);
    }

    // Handle MixinBlock - replace with caller's block content
    if (node.type == .MixinBlock) {
        if (caller_block) |block| {
            return cloneNode(allocator, block);
        } else {
            const empty = allocator.create(Node) catch return error.OutOfMemory;
            empty.* = Node{
                .type = .Block,
                .line = node.line,
                .column = node.column,
            };
            return empty;
        }
    }

    // Clone the node
    const new_node = allocator.create(Node) catch return error.OutOfMemory;
    new_node.* = node.*;
    new_node.nodes = .{};
    new_node.attrs = .{};

    // Substitute argument references in text/val
    if (node.val) |val| {
        new_node.val = try substituteArgs(allocator, val, arg_bindings);
    }

    // Clone attributes with argument substitution
    for (node.attrs.items) |attr| {
        var new_attr = attr;
        if (attr.val) |val| {
            new_attr.val = try substituteArgs(allocator, val, arg_bindings);
        }
        new_node.attrs.append(allocator, new_attr) catch return error.OutOfMemory;
    }

    // Recurse into children
    for (node.nodes.items) |child| {
        const expanded = try expandNodeWithArgs(allocator, child, registry, caller_block, arg_bindings);
        new_node.nodes.append(allocator, expanded) catch return error.OutOfMemory;
    }

    return new_node;
}

/// Substitute argument references in a string and evaluate simple expressions
fn substituteArgs(
    allocator: Allocator,
    text: []const u8,
    bindings: *const std.StringHashMapUnmanaged([]const u8),
) MixinError![]const u8 {
    // Quick check - if no bindings or text doesn't contain any param names, return as-is
    if (bindings.count() == 0) {
        return text;
    }

    // Check if any substitution is needed
    var needs_substitution = false;
    var iter = bindings.iterator();
    while (iter.next()) |entry| {
        if (mem.indexOf(u8, text, entry.key_ptr.*) != null) {
            needs_substitution = true;
            break;
        }
    }

    if (!needs_substitution) {
        return text;
    }

    // Perform substitution
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        var found_match = false;

        // Check for parameter match at current position
        var iter2 = bindings.iterator();
        while (iter2.next()) |entry| {
            const param = entry.key_ptr.*;
            const value = entry.value_ptr.*;

            if (i + param.len <= text.len and mem.eql(u8, text[i .. i + param.len], param)) {
                // Check it's a word boundary (not part of a larger identifier)
                const before_ok = i == 0 or !isIdentChar(text[i - 1]);
                const after_ok = i + param.len >= text.len or !isIdentChar(text[i + param.len]);

                if (before_ok and after_ok) {
                    result.appendSlice(allocator, value) catch return error.OutOfMemory;
                    i += param.len;
                    found_match = true;
                    break;
                }
            }
        }

        if (!found_match) {
            result.append(allocator, text[i]) catch return error.OutOfMemory;
            i += 1;
        }
    }

    const substituted = result.toOwnedSlice(allocator) catch return error.OutOfMemory;

    // Evaluate string concatenation expressions like "btn btn-" + "primary"
    return evaluateStringConcat(allocator, substituted) catch return error.OutOfMemory;
}

/// Evaluate simple string concatenation expressions
/// Handles: "btn btn-" + primary -> "btn btn-primary"
/// Also handles: "btn btn-" + "primary" -> "btn btn-primary"
fn evaluateStringConcat(allocator: Allocator, expr: []const u8) ![]const u8 {
    // Check if there's a + operator (string concat)
    _ = mem.indexOf(u8, expr, " + ") orelse return expr;

    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    var remaining = expr;
    var is_first_part = true;

    while (remaining.len > 0) {
        const next_plus = mem.indexOf(u8, remaining, " + ");
        const part = if (next_plus) |pos| remaining[0..pos] else remaining;

        // Extract string value (strip quotes and whitespace)
        const stripped = mem.trim(u8, part, " \t");
        const unquoted = stripQuotes(stripped);

        // For the first part, we might want to keep it quoted in the final output
        // For subsequent parts, just append the value
        if (is_first_part) {
            // If the first part is a quoted string, we'll build an unquoted result
            result.appendSlice(allocator, unquoted) catch return error.OutOfMemory;
            is_first_part = false;
        } else {
            result.appendSlice(allocator, unquoted) catch return error.OutOfMemory;
        }

        if (next_plus) |pos| {
            remaining = remaining[pos + 3 ..]; // Skip " + "
        } else {
            break;
        }
    }

    // Free original and return concatenated result
    allocator.free(expr);
    return result.toOwnedSlice(allocator);
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_' or c == '-';
}

/// Bind call arguments to mixin parameters
fn bindArguments(
    allocator: Allocator,
    params: []const u8,
    args: []const u8,
    bindings: *std.StringHashMapUnmanaged([]const u8),
) MixinError!void {
    // Parse parameter names from definition: "text, type" or "text, type='primary'"
    var param_names = std.ArrayListUnmanaged([]const u8){};
    defer param_names.deinit(allocator);

    var param_iter = mem.splitSequence(u8, params, ",");
    while (param_iter.next()) |param_part| {
        const trimmed = mem.trim(u8, param_part, " \t");
        if (trimmed.len == 0) continue;

        // Handle default values: "type='primary'" -> just get "type"
        var param_name = trimmed;
        if (mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            param_name = mem.trim(u8, trimmed[0..eq_pos], " \t");
        }

        // Handle rest args: "...items" -> "items"
        if (mem.startsWith(u8, param_name, "...")) {
            param_name = param_name[3..];
        }

        param_names.append(allocator, param_name) catch return error.OutOfMemory;
    }

    // Parse argument values from call: "'Click', 'primary'" or "text='Click'"
    var arg_values = std.ArrayListUnmanaged([]const u8){};
    defer arg_values.deinit(allocator);

    // Simple argument parsing - split by comma but respect quotes
    var in_string = false;
    var string_char: u8 = 0;
    var paren_depth: usize = 0;
    var start: usize = 0;

    for (args, 0..) |c, idx| {
        if (!in_string) {
            if (c == '"' or c == '\'') {
                in_string = true;
                string_char = c;
            } else if (c == '(') {
                paren_depth += 1;
            } else if (c == ')') {
                if (paren_depth > 0) paren_depth -= 1;
            } else if (c == ',' and paren_depth == 0) {
                const arg_val = mem.trim(u8, args[start..idx], " \t");
                arg_values.append(allocator, stripQuotes(arg_val)) catch return error.OutOfMemory;
                start = idx + 1;
            }
        } else {
            if (c == string_char) {
                in_string = false;
            }
        }
    }

    // Add last argument
    if (start < args.len) {
        const arg_val = mem.trim(u8, args[start..], " \t");
        if (arg_val.len > 0) {
            arg_values.append(allocator, stripQuotes(arg_val)) catch return error.OutOfMemory;
        }
    }

    // Bind positional arguments
    const min_len = @min(param_names.items.len, arg_values.items.len);
    for (0..min_len) |i| {
        bindings.put(allocator, param_names.items[i], arg_values.items[i]) catch return error.OutOfMemory;
    }
}

fn stripQuotes(val: []const u8) []const u8 {
    if (val.len < 2) return val;
    const first = val[0];
    const last = val[val.len - 1];
    if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
        return val[1 .. val.len - 1];
    }
    return val;
}

/// Clone a node and all its children
fn cloneNode(allocator: Allocator, node: *Node) MixinError!*Node {
    const new_node = allocator.create(Node) catch return error.OutOfMemory;
    new_node.* = node.*;
    new_node.nodes = .{};
    new_node.attrs = .{};

    // Clone attributes
    for (node.attrs.items) |attr| {
        new_node.attrs.append(allocator, attr) catch return error.OutOfMemory;
    }

    // Clone children recursively
    for (node.nodes.items) |child| {
        const cloned_child = try cloneNode(allocator, child);
        new_node.nodes.append(allocator, cloned_child) catch return error.OutOfMemory;
    }

    return new_node;
}

// ============================================================================
// Tests
// ============================================================================

test "MixinRegistry - basic operations" {
    const allocator = std.testing.allocator;

    var registry = MixinRegistry.init(allocator);
    defer registry.deinit();

    // Create a mock mixin node
    var mixin_node = Node{
        .type = .Mixin,
        .name = "button",
        .line = 1,
        .column = 1,
    };

    try registry.register("button", &mixin_node);

    try std.testing.expect(registry.contains("button"));
    try std.testing.expect(!registry.contains("nonexistent"));

    const retrieved = registry.get("button");
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqualStrings("button", retrieved.?.name.?);
}

test "bindArguments - simple positional" {
    const allocator = std.testing.allocator;

    var bindings = std.StringHashMapUnmanaged([]const u8){};
    defer bindings.deinit(allocator);

    try bindArguments(allocator, "text, type", "'Click', 'primary'", &bindings);

    try std.testing.expectEqualStrings("Click", bindings.get("text").?);
    try std.testing.expectEqualStrings("primary", bindings.get("type").?);
}

test "substituteArgs - basic substitution" {
    const allocator = std.testing.allocator;

    var bindings = std.StringHashMapUnmanaged([]const u8){};
    defer bindings.deinit(allocator);

    bindings.put(allocator, "title", "Hello") catch unreachable;
    bindings.put(allocator, "name", "World") catch unreachable;

    const result = try substituteArgs(allocator, "title is title and name is name", &bindings);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello is Hello and World is World", result);
}

test "stripQuotes" {
    try std.testing.expectEqualStrings("hello", stripQuotes("'hello'"));
    try std.testing.expectEqualStrings("hello", stripQuotes("\"hello\""));
    try std.testing.expectEqualStrings("hello", stripQuotes("hello"));
    try std.testing.expectEqualStrings("", stripQuotes("''"));
}

test "substituteArgs - string concatenation expression" {
    const allocator = std.testing.allocator;

    var bindings = std.StringHashMapUnmanaged([]const u8){};
    defer bindings.deinit(allocator);

    try bindings.put(allocator, "type", "primary");

    // Test the exact format that comes from the parser
    const input = "\"btn btn-\" + type";
    const result = try substituteArgs(allocator, input, &bindings);
    defer allocator.free(result);

    // After substitution and concatenation evaluation, should be: btn btn-primary
    try std.testing.expectEqualStrings("btn btn-primary", result);
}

test "evaluateStringConcat - basic" {
    const allocator = std.testing.allocator;

    // Test with quoted + unquoted
    const input1 = try allocator.dupe(u8, "\"btn btn-\" + primary");
    const result1 = try evaluateStringConcat(allocator, input1);
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("btn btn-primary", result1);

    // Test with both quoted
    const input2 = try allocator.dupe(u8, "\"btn btn-\" + \"primary\"");
    const result2 = try evaluateStringConcat(allocator, input2);
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("btn btn-primary", result2);
}
