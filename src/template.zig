// template.zig - Runtime template rendering with data binding
//
// This module provides runtime data binding for Pug templates.
// It allows passing a Zig struct and rendering dynamic content.
// Reuses utilities from runtime.zig for escaping and attribute rendering.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pug = @import("pug.zig");
const parser = @import("parser.zig");
const Node = parser.Node;
const runtime = @import("runtime.zig");
const mixin_mod = @import("mixin.zig");
pub const MixinRegistry = mixin_mod.MixinRegistry;

const log = std.log.scoped(.pugz);

pub const TemplateError = error{
    OutOfMemory,
    LexerError,
    ParserError,
};

/// Result of parsing - contains AST and the normalized source that AST slices point to
pub const ParseResult = struct {
    ast: *Node,
    /// Normalized source - AST strings are slices into this, must stay alive while AST is used
    normalized_source: []const u8,

    pub fn deinit(self: *ParseResult, allocator: Allocator) void {
        self.ast.deinit(allocator);
        allocator.destroy(self.ast);
        allocator.free(self.normalized_source);
    }
};

/// Render context tracks state like doctype mode and mixin registry
pub const RenderContext = struct {
    /// true = HTML5 terse mode (default), false = XHTML mode
    terse: bool = true,
    /// Mixin registry for expanding mixin calls (optional)
    mixins: ?*const MixinRegistry = null,
    /// Current mixin argument bindings (for substitution during mixin expansion)
    arg_bindings: ?*const std.StringHashMapUnmanaged([]const u8) = null,
    /// Block content passed to current mixin call (for `block` keyword)
    mixin_block: ?*Node = null,
    /// Enable pretty-printing with indentation and newlines
    pretty: bool = false,
    /// Current indentation level (for pretty printing)
    indent_level: u32 = 0,

    /// Create a child context with incremented indent level
    fn indented(self: RenderContext) RenderContext {
        var child = self;
        child.indent_level += 1;
        return child;
    }
};

/// Render a template with data
pub fn renderWithData(allocator: Allocator, source: []const u8, data: anytype) ![]const u8 {
    // Create arena for entire compilation pipeline - all temporary allocations freed at once
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    // Lex
    var lex = pug.lexer.Lexer.init(temp_allocator, source, .{}) catch return error.OutOfMemory;
    defer lex.deinit();

    const tokens = lex.getTokens() catch return error.LexerError;

    // Strip comments
    var stripped = pug.strip_comments.stripComments(temp_allocator, tokens, .{}) catch return error.OutOfMemory;
    defer stripped.deinit(temp_allocator);

    // Parse
    var pug_parser = pug.parser.Parser.init(temp_allocator, stripped.tokens.items, null, source);
    defer pug_parser.deinit();

    const ast = pug_parser.parse() catch {
        return error.ParserError;
    };
    defer {
        ast.deinit(temp_allocator);
        temp_allocator.destroy(ast);
    }

    // Render to temporary buffer
    const html = try renderAst(temp_allocator, ast, data);

    // Dupe final HTML to base allocator before arena cleanup
    return allocator.dupe(u8, html);
}

/// Render a pre-parsed AST with data. Use this for better performance when
/// rendering the same template multiple times - parse once, render many.
pub fn renderAst(allocator: Allocator, ast: *Node, data: anytype) ![]const u8 {
    var output = std.ArrayListUnmanaged(u8){};
    errdefer output.deinit(allocator);

    // Detect doctype to set terse mode
    var ctx = RenderContext{};
    detectDoctype(ast, &ctx);

    try renderNode(allocator, &output, ast, data, &ctx);

    return output.toOwnedSlice(allocator);
}

/// Render options for AST rendering
pub const RenderOptions = struct {
    pretty: bool = false,
};

/// Render a pre-parsed AST with data and mixin registry.
/// Use this when templates include mixin definitions from other files.
pub fn renderAstWithMixins(allocator: Allocator, ast: *Node, data: anytype, registry: *const MixinRegistry) ![]const u8 {
    return renderAstWithMixinsAndOptions(allocator, ast, data, registry, .{});
}

/// Render a pre-parsed AST with data, mixin registry, and render options.
pub fn renderAstWithMixinsAndOptions(allocator: Allocator, ast: *Node, data: anytype, registry: *const MixinRegistry, options: RenderOptions) ![]const u8 {
    var output = std.ArrayListUnmanaged(u8){};
    errdefer output.deinit(allocator);

    // Detect doctype to set terse mode
    var ctx = RenderContext{
        .mixins = registry,
        .pretty = options.pretty,
    };
    detectDoctype(ast, &ctx);

    try renderNode(allocator, &output, ast, data, &ctx);

    return output.toOwnedSlice(allocator);
}

/// Parse template source into AST. Caller owns the returned AST and must call
/// ast.deinit(allocator) and allocator.destroy(ast) when done.
/// WARNING: The returned AST contains slices into a normalized copy of source.
/// This function frees that copy on return, so AST string values become invalid.
/// Use parseWithSource() instead if you need to access AST string values.
pub fn parse(allocator: Allocator, source: []const u8) !*Node {
    const result = try parseWithSource(allocator, source);
    // Free the normalized source - AST strings will be invalid after this!
    // This maintains backwards compatibility but is unsafe for include paths etc.
    allocator.free(result.normalized_source);
    return result.ast;
}

/// Parse template source into AST, returning both AST and the normalized source.
/// AST string values are slices into normalized_source, so it must stay alive.
/// Caller must call result.deinit(allocator) when done.
pub fn parseWithSource(allocator: Allocator, source: []const u8) !ParseResult {
    // Note: Cannot use ArenaAllocator here since returned AST must outlive function scope
    // Lex
    var lex = pug.lexer.Lexer.init(allocator, source, .{}) catch return error.OutOfMemory;
    errdefer lex.deinit();

    const tokens = lex.getTokens() catch {
        if (lex.last_error) |err| {
            log.err("{s} at line {d}, column {d}: {s}", .{ @tagName(err.code), err.line, err.column, err.message });
        }
        return error.LexerError;
    };

    // Strip comments
    var stripped = pug.strip_comments.stripComments(allocator, tokens, .{}) catch return error.OutOfMemory;
    defer stripped.deinit(allocator);

    // Parse
    var pug_parser = pug.parser.Parser.init(allocator, stripped.tokens.items, null, source);
    defer pug_parser.deinit();

    const ast = pug_parser.parse() catch {
        if (pug_parser.getError()) |err| {
            log.err("{s} at line {d}, column {d}: {s}", .{ @tagName(err.code), err.line, err.column, err.message });
        }
        return error.ParserError;
    };

    // Transfer ownership of normalized input from lexer to caller
    const normalized = lex.deinitKeepInput();

    return ParseResult{
        .ast = ast,
        .normalized_source = normalized,
    };
}

/// Scan AST for doctype and set terse mode accordingly
fn detectDoctype(node: *Node, ctx: *RenderContext) void {
    if (node.type == .Doctype) {
        if (node.val) |val| {
            // XHTML doctypes use non-terse mode
            if (std.mem.eql(u8, val, "xml") or
                std.mem.eql(u8, val, "strict") or
                std.mem.eql(u8, val, "transitional") or
                std.mem.eql(u8, val, "frameset") or
                std.mem.eql(u8, val, "1.1") or
                std.mem.eql(u8, val, "basic") or
                std.mem.eql(u8, val, "mobile"))
            {
                ctx.terse = false;
            }
        }
        return;
    }

    // Check children
    for (node.nodes.items) |child| {
        detectDoctype(child, ctx);
        if (!ctx.terse) return;
    }
}

// Tags where whitespace is significant - import from runtime (shared with codegen)
const whitespace_sensitive_tags = runtime.whitespace_sensitive_tags;

/// Write indentation (two spaces per level)
fn writeIndent(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), level: u32) Allocator.Error!void {
    var i: u32 = 0;
    while (i < level) : (i += 1) {
        try output.appendSlice(allocator, "  ");
    }
}

fn renderNode(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), node: *Node, data: anytype, ctx: *const RenderContext) Allocator.Error!void {
    switch (node.type) {
        .Block, .NamedBlock => {
            for (node.nodes.items) |child| {
                try renderNode(allocator, output, child, data, ctx);
            }
        },
        .Tag, .InterpolatedTag => try renderTag(allocator, output, node, data, ctx),
        .Text => try renderText(allocator, output, node, data),
        .Code => try renderCode(allocator, output, node, data, ctx),
        .Comment => try renderComment(allocator, output, node),
        .BlockComment => try renderBlockComment(allocator, output, node, data, ctx),
        .Doctype => try renderDoctype(allocator, output, node),
        .Each => try renderEach(allocator, output, node, data, ctx),
        .Mixin => try renderMixin(allocator, output, node, data, ctx),
        .MixinBlock => {
            // Render the block content passed to the mixin
            if (ctx.mixin_block) |block| {
                for (block.nodes.items) |child| {
                    try renderNode(allocator, output, child, data, ctx);
                }
            }
        },
        else => {
            for (node.nodes.items) |child| {
                try renderNode(allocator, output, child, data, ctx);
            }
        },
    }
}

fn renderTag(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), tag: *Node, data: anytype, ctx: *const RenderContext) Allocator.Error!void {
    const name = tag.name orelse "div";
    const is_whitespace_sensitive = whitespace_sensitive_tags.has(name);

    // Check if children are only text/inline content (no block elements)
    const has_children = tag.nodes.items.len > 0;
    const has_block_children = has_children and hasBlockChildren(tag);

    // Pretty print: add newline and indent before opening tag (except for inline elements)
    if (ctx.pretty and !tag.is_inline) {
        // Only add newline if we're not at the start of output
        if (output.items.len > 0) {
            try output.append(allocator, '\n');
        }
        try writeIndent(allocator, output, ctx.indent_level);
    }

    try output.appendSlice(allocator, "<");
    try output.appendSlice(allocator, name);

    // Render attributes directly to output buffer (avoids intermediate allocations)
    for (tag.attrs.items) |attr| {
        // Substitute mixin arguments in attribute value if we're inside a mixin
        const final_val = if (ctx.arg_bindings) |bindings|
            substituteArgValue(attr.val, bindings)
        else
            attr.val;
        // Static/quoted values (e.g., from .class shorthand) should not be looked up in data
        const attr_val = if (attr.quoted)
            runtime.AttrValue{ .string = final_val orelse "" }
        else
            try evaluateAttrValue(allocator, final_val, data);

        try runtime.appendAttr(allocator, output, attr.name, attr_val, true, ctx.terse);
    }

    // Self-closing logic differs by mode:
    // - HTML5 terse: void elements are self-closing without />
    // - XHTML/XML: only explicit / makes tags self-closing
    const is_void = isSelfClosing(name);
    const is_self_closing = if (ctx.terse)
        tag.self_closing or is_void
    else
        tag.self_closing;

    if (is_self_closing and tag.nodes.items.len == 0 and tag.val == null) {
        if (ctx.terse and !tag.self_closing) {
            try output.appendSlice(allocator, ">");
        } else {
            try output.appendSlice(allocator, "/>");
        }
        return;
    }

    try output.appendSlice(allocator, ">");

    // Render text content (with mixin argument substitution if applicable)
    if (tag.val) |val| {
        const final_val = if (ctx.arg_bindings) |bindings|
            substituteArgValue(val, bindings) orelse val
        else
            val;
        try processInterpolation(allocator, output, final_val, false, data);
    }

    // Render children with increased indent (unless whitespace-sensitive)
    if (has_children) {
        const child_ctx = if (ctx.pretty and !is_whitespace_sensitive)
            ctx.indented()
        else
            ctx.*;
        for (tag.nodes.items) |child| {
            try renderNode(allocator, output, child, data, &child_ctx);
        }
    }

    // Close tag
    if (!is_self_closing) {
        // Pretty print: add newline and indent before closing tag
        // Only if we have block children (not just text/inline content)
        if (ctx.pretty and has_block_children and !tag.is_inline and !is_whitespace_sensitive) {
            try output.append(allocator, '\n');
            try writeIndent(allocator, output, ctx.indent_level);
        }
        try output.appendSlice(allocator, "</");
        try output.appendSlice(allocator, name);
        try output.appendSlice(allocator, ">");
    }
}

/// Check if a tag has block-level children (not just text/inline content)
fn hasBlockChildren(tag: *Node) bool {
    for (tag.nodes.items) |child| {
        switch (child.type) {
            // Text and Code are inline
            .Text, .Code => continue,
            // Tags marked as inline are inline
            .Tag, .InterpolatedTag => {
                if (!child.is_inline) return true;
            },
            // Everything else is considered block
            else => return true,
        }
    }
    return false;
}

/// Substitute a single argument reference in a value (simple case - exact match)
fn substituteArgValue(val: ?[]const u8, bindings: *const std.StringHashMapUnmanaged([]const u8)) ?[]const u8 {
    const v = val orelse return null;
    // Check if the entire value is a parameter name
    if (bindings.get(v)) |replacement| {
        return replacement;
    }
    // For now, return as-is (complex substitution would need allocation)
    return v;
}

/// Evaluate attribute value from AST to runtime.AttrValue
fn evaluateAttrValue(allocator: Allocator, val: ?[]const u8, data: anytype) !runtime.AttrValue {
    _ = allocator;
    const v = val orelse return .{ .boolean = true }; // No value = boolean attribute

    // Handle boolean literals
    if (std.mem.eql(u8, v, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, v, "false")) return .{ .boolean = false };
    if (std.mem.eql(u8, v, "null") or std.mem.eql(u8, v, "undefined")) return .none;

    // Quoted string - extract inner value
    if (v.len >= 2 and (v[0] == '"' or v[0] == '\'')) {
        return .{ .string = v[1 .. v.len - 1] };
    }

    // Expression - try to look up in data
    if (getFieldValue(data, v)) |value| {
        return .{ .string = value };
    }

    // Unknown expression - return as string literal
    return .{ .string = v };
}

fn renderText(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), text: *Node, data: anytype) Allocator.Error!void {
    if (text.val) |val| {
        try processInterpolation(allocator, output, val, false, data);
    }
}

fn renderCode(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), code: *Node, data: anytype, ctx: *const RenderContext) Allocator.Error!void {
    if (code.buffer) {
        if (code.val) |val| {
            // Check if it's a string literal (quoted)
            if (val.len >= 2 and (val[0] == '"' or val[0] == '\'')) {
                const inner = val[1 .. val.len - 1];
                if (code.must_escape) {
                    try runtime.appendEscaped(allocator, output, inner);
                } else {
                    try output.appendSlice(allocator, inner);
                }
            } else if (ctx.arg_bindings) |bindings| {
                // Inside a mixin - check argument bindings first
                if (bindings.get(val)) |value| {
                    if (code.must_escape) {
                        try runtime.appendEscaped(allocator, output, value);
                    } else {
                        try output.appendSlice(allocator, value);
                    }
                } else if (getFieldValue(data, val)) |value| {
                    if (code.must_escape) {
                        try runtime.appendEscaped(allocator, output, value);
                    } else {
                        try output.appendSlice(allocator, value);
                    }
                }
            } else if (getFieldValue(data, val)) |value| {
                if (code.must_escape) {
                    try runtime.appendEscaped(allocator, output, value);
                } else {
                    try output.appendSlice(allocator, value);
                }
            }
        }
    }

    for (code.nodes.items) |child| {
        try renderNode(allocator, output, child, data, ctx);
    }
}

/// Render mixin definition or call
fn renderMixin(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), node: *Node, data: anytype, ctx: *const RenderContext) Allocator.Error!void {
    // Mixin definitions are skipped (only mixin calls render)
    if (!node.call) return;

    const mixin_name = node.name orelse return;

    // Look up mixin definition in registry
    const mixin_def = if (ctx.mixins) |registry| registry.get(mixin_name) else null;

    if (mixin_def) |def| {
        // Build argument bindings
        var bindings = std.StringHashMapUnmanaged([]const u8){};
        defer bindings.deinit(allocator);

        if (def.args) |params| {
            if (node.args) |args| {
                bindMixinArguments(allocator, params, args, &bindings) catch {};
            }
        }

        // Create block node from call's children (if any) for `block` keyword
        var call_block: ?*Node = null;
        if (node.nodes.items.len > 0) {
            call_block = node;
        }

        // Render the mixin body with argument bindings
        var mixin_ctx = RenderContext{
            .terse = ctx.terse,
            .mixins = ctx.mixins,
            .arg_bindings = &bindings,
            .mixin_block = call_block,
        };

        for (def.nodes.items) |child| {
            try renderNode(allocator, output, child, data, &mixin_ctx);
        }
    } else {
        // Mixin not found - render children directly (fallback behavior)
        for (node.nodes.items) |child| {
            try renderNode(allocator, output, child, data, ctx);
        }
    }
}

/// Bind mixin call arguments to parameter names
fn bindMixinArguments(
    allocator: Allocator,
    params: []const u8,
    args: []const u8,
    bindings: *std.StringHashMapUnmanaged([]const u8),
) !void {
    // Parse parameter names from definition: "text, type" or "text, type='primary'"
    var param_names = std.ArrayListUnmanaged([]const u8){};
    defer param_names.deinit(allocator);

    var param_iter = std.mem.splitSequence(u8, params, ",");
    while (param_iter.next()) |param_part| {
        const trimmed = std.mem.trim(u8, param_part, " \t");
        if (trimmed.len == 0) continue;

        // Handle default values: "type='primary'" -> just get "type"
        var param_name = trimmed;
        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            param_name = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
        }

        // Handle rest args: "...items" -> "items"
        if (std.mem.startsWith(u8, param_name, "...")) {
            param_name = param_name[3..];
        }

        try param_names.append(allocator, param_name);
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
                const arg_val = std.mem.trim(u8, args[start..idx], " \t");
                try arg_values.append(allocator, stripQuotes(arg_val));
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
        const arg_val = std.mem.trim(u8, args[start..], " \t");
        if (arg_val.len > 0) {
            try arg_values.append(allocator, stripQuotes(arg_val));
        }
    }

    // Bind positional arguments
    const min_len = @min(param_names.items.len, arg_values.items.len);
    for (0..min_len) |i| {
        try bindings.put(allocator, param_names.items[i], arg_values.items[i]);
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

fn renderEach(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), each: *Node, data: anytype, ctx: *const RenderContext) Allocator.Error!void {
    const collection_name = each.obj orelse return;
    const item_name = each.val orelse "item";
    _ = item_name;

    const T = @TypeOf(data);
    const info = @typeInfo(T);

    if (info != .@"struct") return;

    inline for (info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, collection_name)) {
            const collection = @field(data, field.name);
            const CollType = @TypeOf(collection);
            const coll_info = @typeInfo(CollType);

            // Handle both slices ([]T) and pointers to arrays (*[N]T)
            const is_slice = coll_info == .pointer and coll_info.pointer.size == .slice;
            const is_array_ptr = coll_info == .pointer and coll_info.pointer.size == .one and
                @typeInfo(coll_info.pointer.child) == .array;

            if (is_slice or is_array_ptr) {
                for (collection) |item| {
                    const ItemType = @TypeOf(item);
                    if (ItemType == []const u8) {
                        // Simple string item - use renderNodeWithItem
                        for (each.nodes.items) |child| {
                            try renderNodeWithItem(allocator, output, child, data, item, ctx);
                        }
                    } else if (@typeInfo(ItemType) == .@"struct") {
                        // Struct item - render with item as the data context
                        for (each.nodes.items) |child| {
                            try renderNode(allocator, output, child, item, ctx);
                        }
                    } else {
                        // Other types - skip
                        for (each.nodes.items) |child| {
                            try renderNode(allocator, output, child, data, ctx);
                        }
                    }
                }
                return;
            }
        }
    }

    if (each.alternate) |alt| {
        try renderNode(allocator, output, alt, data, ctx);
    }
}

fn renderNodeWithItem(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), node: *Node, data: anytype, item: []const u8, ctx: *const RenderContext) Allocator.Error!void {
    switch (node.type) {
        .Block, .NamedBlock => {
            for (node.nodes.items) |child| {
                try renderNodeWithItem(allocator, output, child, data, item, ctx);
            }
        },
        .Tag, .InterpolatedTag => try renderTagWithItem(allocator, output, node, data, item, ctx),
        .Text => try renderTextWithItem(allocator, output, node, item),
        .Code => {
            if (node.buffer) {
                if (node.must_escape) {
                    try runtime.appendEscaped(allocator, output, item);
                } else {
                    try output.appendSlice(allocator, item);
                }
            }
        },
        else => {
            for (node.nodes.items) |child| {
                try renderNodeWithItem(allocator, output, child, data, item, ctx);
            }
        },
    }
}

fn renderTagWithItem(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), tag: *Node, data: anytype, item: []const u8, ctx: *const RenderContext) Allocator.Error!void {
    const name = tag.name orelse "div";

    try output.appendSlice(allocator, "<");
    try output.appendSlice(allocator, name);

    // Render attributes directly to output buffer (avoids intermediate allocations)
    for (tag.attrs.items) |attr| {
        // Static/quoted values (e.g., from .class shorthand) should not be looked up in data
        const attr_val = if (attr.quoted)
            runtime.AttrValue{ .string = attr.val orelse "" }
        else
            try evaluateAttrValue(allocator, attr.val, data);

        try runtime.appendAttr(allocator, output, attr.name, attr_val, true, ctx.terse);
    }

    const is_void = isSelfClosing(name);
    const is_self_closing = if (ctx.terse)
        tag.self_closing or is_void
    else
        tag.self_closing;

    if (is_self_closing and tag.nodes.items.len == 0 and tag.val == null) {
        if (ctx.terse and !tag.self_closing) {
            try output.appendSlice(allocator, ">");
        } else {
            try output.appendSlice(allocator, "/>");
        }
        return;
    }

    try output.appendSlice(allocator, ">");

    if (tag.val) |val| {
        try processInterpolationWithItem(allocator, output, val, true, data, item);
    }

    for (tag.nodes.items) |child| {
        try renderNodeWithItem(allocator, output, child, data, item, ctx);
    }

    if (!is_self_closing) {
        try output.appendSlice(allocator, "</");
        try output.appendSlice(allocator, name);
        try output.appendSlice(allocator, ">");
    }
}

fn renderTextWithItem(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), text: *Node, item: []const u8) Allocator.Error!void {
    if (text.val) |val| {
        try runtime.appendEscaped(allocator, output, val);
        _ = item;
    }
}

fn processInterpolationWithItem(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), text: []const u8, escape: bool, data: anytype, item: []const u8) Allocator.Error!void {
    _ = data;
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '#' and text[i + 1] == '{') {
            var j = i + 2;
            var brace_count: usize = 1;
            while (j < text.len and brace_count > 0) {
                if (text[j] == '{') brace_count += 1;
                if (text[j] == '}') brace_count -= 1;
                j += 1;
            }
            if (brace_count == 0) {
                if (escape) {
                    try runtime.appendEscaped(allocator, output, item);
                } else {
                    try output.appendSlice(allocator, item);
                }
                i = j;
                continue;
            }
        }
        if (escape) {
            if (runtime.escapeChar(text[i])) |esc| {
                try output.appendSlice(allocator, esc);
            } else {
                try output.append(allocator, text[i]);
            }
        } else {
            try output.append(allocator, text[i]);
        }
        i += 1;
    }
}

fn renderComment(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), comment: *Node) Allocator.Error!void {
    if (!comment.buffer) return;
    try output.appendSlice(allocator, "<!--");
    if (comment.val) |val| {
        try output.appendSlice(allocator, val);
    }
    try output.appendSlice(allocator, "-->");
}

fn renderBlockComment(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), comment: *Node, data: anytype, ctx: *const RenderContext) Allocator.Error!void {
    if (!comment.buffer) return;
    try output.appendSlice(allocator, "<!--");
    if (comment.val) |val| {
        try output.appendSlice(allocator, val);
    }
    for (comment.nodes.items) |child| {
        try renderNode(allocator, output, child, data, ctx);
    }
    try output.appendSlice(allocator, "-->");
}

// Doctype mappings
// Import doctypes from runtime (shared with codegen)
const doctypes = runtime.doctypes;

fn renderDoctype(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), doctype: *Node) Allocator.Error!void {
    if (doctype.val) |val| {
        if (doctypes.get(val)) |dt| {
            try output.appendSlice(allocator, dt);
        } else {
            try output.appendSlice(allocator, "<!DOCTYPE ");
            try output.appendSlice(allocator, val);
            try output.appendSlice(allocator, ">");
        }
    } else {
        try output.appendSlice(allocator, "<!DOCTYPE html>");
    }
}

/// Process interpolation #{expr} in text
/// escape_quotes: true for attribute values (escape "), false for text content
fn processInterpolation(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), text: []const u8, escape_quotes: bool, data: anytype) Allocator.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '#' and text[i + 1] == '{') {
            var j = i + 2;
            var brace_count: usize = 1;
            while (j < text.len and brace_count > 0) {
                if (text[j] == '{') brace_count += 1;
                if (text[j] == '}') brace_count -= 1;
                j += 1;
            }
            if (brace_count == 0) {
                const expr = std.mem.trim(u8, text[i + 2 .. j - 1], " \t");
                if (getFieldValue(data, expr)) |value| {
                    if (escape_quotes) {
                        try runtime.appendEscaped(allocator, output, value);
                    } else {
                        // Text content: escape < > & but not quotes
                        try appendTextEscaped(allocator, output, value);
                    }
                }
                i = j;
                continue;
            }
        }
        // Regular character - use appropriate escaping
        const c = text[i];
        if (escape_quotes) {
            if (runtime.escapeChar(c)) |esc| {
                try output.appendSlice(allocator, esc);
            } else {
                try output.append(allocator, c);
            }
        } else {
            // Text content: escape < > & but not quotes, preserve HTML entities
            switch (c) {
                '<' => try output.appendSlice(allocator, "&lt;"),
                '>' => try output.appendSlice(allocator, "&gt;"),
                '&' => {
                    if (isHtmlEntity(text[i..])) {
                        try output.append(allocator, c);
                    } else {
                        try output.appendSlice(allocator, "&amp;");
                    }
                },
                else => try output.append(allocator, c),
            }
        }
        i += 1;
    }
}

/// Get a field value from the data struct by name
fn getFieldValue(data: anytype, name: []const u8) ?[]const u8 {
    const T = @TypeOf(data);
    const info = @typeInfo(T);

    if (info != .@"struct") return null;

    inline for (info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            const value = @field(data, field.name);
            const ValueType = @TypeOf(value);

            if (ValueType == []const u8) {
                return value;
            }

            const value_info = @typeInfo(ValueType);
            if (value_info == .pointer) {
                const ptr = value_info.pointer;
                if (ptr.size == .one) {
                    const child_info = @typeInfo(ptr.child);
                    if (child_info == .array and child_info.array.child == u8) {
                        return value;
                    }
                }
            }
        }
    }
    return null;
}

/// Escape for text content - escapes < > & (NOT quotes)
/// Preserves existing HTML entities like &#8217;
fn appendTextEscaped(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), str: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < str.len) {
        const c = str[i];
        switch (c) {
            '<' => try output.appendSlice(allocator, "&lt;"),
            '>' => try output.appendSlice(allocator, "&gt;"),
            '&' => {
                if (isHtmlEntity(str[i..])) {
                    try output.append(allocator, c);
                } else {
                    try output.appendSlice(allocator, "&amp;");
                }
            },
            else => try output.append(allocator, c),
        }
        i += 1;
    }
}

/// Check if string starts with a valid HTML entity
fn isHtmlEntity(str: []const u8) bool {
    if (str.len < 3 or str[0] != '&') return false;

    var i: usize = 1;

    // Numeric entity: &#digits; or &#xhex;
    if (str[i] == '#') {
        i += 1;
        if (i >= str.len) return false;

        if (str[i] == 'x' or str[i] == 'X') {
            i += 1;
            if (i >= str.len) return false;
            var has_hex = false;
            while (i < str.len and i < 10) : (i += 1) {
                const ch = str[i];
                if (ch == ';') return has_hex;
                if ((ch >= '0' and ch <= '9') or
                    (ch >= 'a' and ch <= 'f') or
                    (ch >= 'A' and ch <= 'F'))
                {
                    has_hex = true;
                } else {
                    return false;
                }
            }
            return false;
        }

        var has_digit = false;
        while (i < str.len and i < 10) : (i += 1) {
            const ch = str[i];
            if (ch == ';') return has_digit;
            if (ch >= '0' and ch <= '9') {
                has_digit = true;
            } else {
                return false;
            }
        }
        return false;
    }

    // Named entity: &name;
    var has_alpha = false;
    while (i < str.len and i < 32) : (i += 1) {
        const ch = str[i];
        if (ch == ';') return has_alpha;
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9')) {
            has_alpha = true;
        } else {
            return false;
        }
    }
    return false;
}

fn isSelfClosing(name: []const u8) bool {
    const self_closing_tags = [_][]const u8{
        "area", "base", "br",    "col",    "embed", "hr",  "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    };
    for (self_closing_tags) |tag| {
        if (std.mem.eql(u8, name, tag)) return true;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "simple interpolation" {
    const allocator = std.testing.allocator;

    const html = try renderWithData(allocator, "p Hello, #{name}!", .{ .name = "World" });
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<p>Hello, World!</p>", html);
}

test "multiple interpolations" {
    const allocator = std.testing.allocator;

    const html = try renderWithData(allocator, "p #{greeting}, #{name}!", .{
        .greeting = "Hello",
        .name = "World",
    });
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<p>Hello, World!</p>", html);
}

test "attribute with data" {
    const allocator = std.testing.allocator;

    const html = try renderWithData(allocator, "a(href=url) Click", .{ .url = "/home" });
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<a href=\"/home\">Click</a>", html);
}

test "buffered code" {
    const allocator = std.testing.allocator;

    const html = try renderWithData(allocator, "p= message", .{ .message = "Hello" });
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<p>Hello</p>", html);
}

test "escape html" {
    const allocator = std.testing.allocator;

    const html = try renderWithData(allocator, "p #{content}", .{ .content = "<b>bold</b>" });
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<p>&lt;b&gt;bold&lt;/b&gt;</p>", html);
}

test "no data - static template" {
    const allocator = std.testing.allocator;

    const html = try renderWithData(allocator, "p Hello, World!", .{});
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<p>Hello, World!</p>", html);
}

test "nested tags with data" {
    const allocator = std.testing.allocator;

    const html = try renderWithData(allocator,
        \\div
        \\  h1 #{title}
        \\  p #{body}
    , .{
        .title = "Welcome",
        .body = "Hello there!",
    });
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<div><h1>Welcome</h1><p>Hello there!</p></div>", html);
}

test "pretty print - nested tags" {
    const allocator = std.testing.allocator;

    var result = try parseWithSource(allocator,
        \\div
        \\  h1 Title
        \\  p Content
    );
    defer result.deinit(allocator);

    var registry = MixinRegistry.init(allocator);
    defer registry.deinit();

    const html = try renderAstWithMixinsAndOptions(allocator, result.ast, .{}, &registry, .{ .pretty = true });
    defer allocator.free(html);

    const expected =
        \\<div>
        \\  <h1>Title</h1>
        \\  <p>Content</p>
        \\</div>
    ;
    try std.testing.expectEqualStrings(expected, html);
}

test "pretty print - deeply nested" {
    const allocator = std.testing.allocator;

    var result = try parseWithSource(allocator,
        \\html
        \\  body
        \\    div
        \\      p Hello
    );
    defer result.deinit(allocator);

    var registry = MixinRegistry.init(allocator);
    defer registry.deinit();

    const html = try renderAstWithMixinsAndOptions(allocator, result.ast, .{}, &registry, .{ .pretty = true });
    defer allocator.free(html);

    const expected =
        \\<html>
        \\  <body>
        \\    <div>
        \\      <p>Hello</p>
        \\    </div>
        \\  </body>
        \\</html>
    ;
    try std.testing.expectEqualStrings(expected, html);
}
