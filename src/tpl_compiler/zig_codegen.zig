// Generate Zig template functions from Pug AST
//
// Strategy: Generate Zig code that directly appends HTML strings to a buffer,
// reusing runtime.zig utilities for escaping. This avoids duplicating logic
// from template.zig and codegen.zig.
//
// Generated code pattern:
//   pub fn render(allocator: Allocator, data: Data) ![]const u8 {
//       var buf: std.ArrayList(u8) = .{};
//       defer buf.deinit(allocator);
//       try buf.appendSlice(allocator, "<html><body>");
//       try runtime.appendEscaped(&buf, allocator, data.field);
//       try buf.appendSlice(allocator, "</body></html>");
//       return buf.toOwnedSlice(allocator);
//   }

const std = @import("std");
const parser = @import("../parser.zig");
const runtime = @import("../runtime.zig");
const codegen = @import("../codegen.zig");
const template = @import("../template.zig");
const Allocator = std.mem.Allocator;
const Node = parser.Node;
const NodeType = parser.NodeType;

pub const ZigCodegenError = error{
    OutOfMemory,
    InvalidNode,
    UnsupportedFeature,
};

/// Type information parsed from @TypeOf annotations
pub const TypeInfo = struct {
    is_array: bool = false,
    is_optional: bool = false,
    struct_fields: ?std.StringHashMap([]const u8) = null,
    primitive_type: ?[]const u8 = null,
    import_type: ?[]const u8 = null,

    pub fn deinit(self: *TypeInfo, allocator: Allocator) void {
        if (self.struct_fields) |*fields| {
            fields.deinit();
        }
        _ = allocator;
    }
};

pub const Codegen = struct {
    allocator: Allocator,
    output: std.ArrayList(u8),
    indent_level: usize,
    terse: bool, // HTML5 mode vs XHTML
    // Buffer for combining consecutive static strings
    static_buffer: std.ArrayList(u8),
    // Type hints from @TypeOf annotations
    type_hints: std.StringHashMap(TypeInfo),
    // Current loop variable for field resolution inside each blocks
    current_loop_var: ?[]const u8 = null,

    pub fn init(allocator: Allocator) Codegen {
        return .{
            .allocator = allocator,
            .output = .{},
            .indent_level = 0,
            .terse = true, // Default to HTML5
            .static_buffer = .{},
            .type_hints = std.StringHashMap(TypeInfo).init(allocator),
            .current_loop_var = null,
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.output.deinit(self.allocator);
        self.static_buffer.deinit(self.allocator);
        // Clean up type hints
        var iter = self.type_hints.valueIterator();
        while (iter.next()) |info| {
            if (info.struct_fields) |*fields| {
                fields.deinit();
            }
        }
        self.type_hints.deinit();
    }

    /// Generate Zig code for a template
    /// helpers_path: relative path to helpers.zig from the output file (e.g., "../helpers.zig" for nested dirs)
    pub fn generate(self: *Codegen, ast: *Node, function_name: []const u8, fields: []const []const u8, helpers_path: ?[]const u8) ![]const u8 {
        // Reset state
        self.output.clearRetainingCapacity();
        self.static_buffer.clearRetainingCapacity();
        self.indent_level = 0;
        self.terse = true;
        self.current_loop_var = null;

        // Clean up any existing type hints
        var hint_iter = self.type_hints.valueIterator();
        while (hint_iter.next()) |info| {
            if (info.struct_fields) |*sf| {
                sf.deinit();
            }
        }
        self.type_hints.clearRetainingCapacity();

        // Collect type hints from AST
        try collectTypeHints(self.allocator, ast, &self.type_hints);

        // Detect doctype to set terse mode
        self.detectDoctype(ast);

        // Generate imports
        try self.writeLine("const std = @import(\"std\");");
        try self.write("const helpers = @import(\"");
        try self.write(helpers_path orelse "helpers.zig");
        try self.writeLine("\");");
        try self.writeLine("");

        // Generate Data struct with typed fields
        try self.writeIndent();
        try self.writeLine("pub const Data = struct {");
        self.indent_level += 1;

        for (fields) |field| {
            try self.writeIndent();
            try self.write(field);

            // Check if we have a type hint for this field
            if (self.type_hints.get(field)) |type_info| {
                try self.write(": ");
                try self.writeTypeInfo(type_info);
            } else {
                try self.write(": []const u8 = \"\"");
            }
            try self.writeLine(",");
        }
        self.indent_level -= 1;
        try self.writeIndent();
        try self.writeLine("};");
        try self.writeLine("");

        // Generate render function
        try self.writeIndent();
        try self.write("pub fn ");
        try self.write(function_name);
        try self.writeLine("(allocator: std.mem.Allocator, data: Data) ![]const u8 {");
        self.indent_level += 1;

        // Initialize buffer
        try self.writeIndent();
        try self.writeLine("var buf: std.ArrayList(u8) = .{};");
        try self.writeIndent();
        try self.writeLine("defer buf.deinit(allocator);");

        // Suppress unused parameter warning if no fields
        if (fields.len == 0) {
            try self.writeIndent();
            try self.writeLine("_ = data;");
        }

        try self.writeLine("");

        // Generate code for AST
        try self.generateNode(ast);

        // Flush any remaining static content
        try self.flushStaticBuffer();

        // Return
        try self.writeLine("");
        try self.writeIndent();
        try self.writeLine("return buf.toOwnedSlice(allocator);");

        self.indent_level -= 1;
        try self.writeIndent();
        try self.writeLine("}");

        return self.output.toOwnedSlice(self.allocator);
    }

    // ========================================================================
    // AST Walking
    // ========================================================================

    fn generateNode(self: *Codegen, node: *Node) ZigCodegenError!void {
        switch (node.type) {
            .Block, .NamedBlock => try self.generateBlock(node),
            .Tag, .InterpolatedTag => try self.generateTag(node),
            .Text => try self.generateText(node),
            .Code => try self.generateCode(node),
            .Comment => try self.generateComment(node),
            .BlockComment => try self.generateBlockComment(node),
            .Doctype => try self.generateDoctype(node),
            .Conditional => try self.generateConditional(node),
            .Each, .EachOf => try self.generateEach(node),
            .TypeHint => {}, // Skip - processed during field extraction
            .Mixin => {
                // Skip mixin definitions (call=false), only process mixin calls (call=true)
                // Mixin calls should already be expanded by mixin.expandMixins()
                if (!node.call) return;
                // If somehow a mixin call wasn't expanded, process its children
                for (node.nodes.items) |child| {
                    try self.generateNode(child);
                }
            },
            .Include => {
                // Process included content (children were inlined by processIncludes)
                for (node.nodes.items) |child| {
                    try self.generateNode(child);
                }
            },
            else => {
                // Unsupported nodes: skip or process children
                for (node.nodes.items) |child| {
                    try self.generateNode(child);
                }
            },
        }
    }

    fn generateBlock(self: *Codegen, block: *Node) !void {
        for (block.nodes.items) |child| {
            try self.generateNode(child);
        }
    }

    fn generateTag(self: *Codegen, tag: *Node) !void {
        const name = tag.name orelse "div";
        const is_void = codegen.void_elements.has(name);

        // Opening tag
        try self.addStatic("<");
        try self.addStatic(name);

        // Attributes - handle both static and dynamic
        var has_dynamic_attrs = false;
        for (tag.attrs.items) |attr| {
            if (attr.val) |val| {
                // Quoted values are always static strings, unquoted can be field references
                if (!attr.quoted and self.isDataFieldReference(val)) {
                    has_dynamic_attrs = true;
                    break;
                }
            }
        }

        if (!has_dynamic_attrs) {
            // All static attributes - include in buffer
            for (tag.attrs.items) |attr| {
                try self.addStatic(" ");
                try self.addStatic(attr.name);
                if (attr.val) |val| {
                    try self.addStatic("=\"");
                    try self.addStatic(val);
                    try self.addStatic("\"");
                } else {
                    // Boolean attribute
                    if (!self.terse) {
                        try self.addStatic("=\"");
                        try self.addStatic(attr.name);
                        try self.addStatic("\"");
                    }
                }
            }
            try self.addStatic(">");
        } else {
            // Flush static content before dynamic attributes (this closes any open string)
            try self.flushStaticBuffer();

            for (tag.attrs.items) |attr| {
                if (attr.val) |val| {
                    // Quoted values are always static, unquoted can be field references
                    if (!attr.quoted and self.isDataFieldReference(val)) {
                        // Dynamic attribute value (unquoted field reference)
                        try self.writeIndent();
                        try self.write("try buf.appendSlice(allocator, \" ");
                        try self.write(attr.name);
                        try self.writeLine("=\\\"\");");

                        // Check if this is a loop variable reference or typed field
                        const is_loop_var = self.isLoopVariableReference(val);
                        const needs_value_helper = is_loop_var or self.hasNonStringTypeHint(val);

                        try self.writeIndent();
                        if (needs_value_helper) {
                            // Use appendValue for typed fields (handles any type)
                            try self.write("try helpers.appendValue(&buf, allocator, ");
                            if (is_loop_var) {
                                try self.writeFieldReference(val);
                            } else {
                                try self.write("data.");
                                try self.writeSanitizedFieldName(val);
                            }
                        } else if (attr.must_escape) {
                            try self.write("try helpers.appendEscaped(&buf, allocator, data.");
                            try self.writeSanitizedFieldName(val);
                        } else {
                            try self.write("try buf.appendSlice(allocator, data.");
                            try self.writeSanitizedFieldName(val);
                        }
                        try self.writeLine(");");

                        try self.writeIndent();
                        try self.writeLine("try buf.appendSlice(allocator, \"\\\"\");");
                    } else {
                        // Static attribute value (quoted or non-identifier)
                        try self.writeIndent();
                        try self.write("try buf.appendSlice(allocator, \" ");
                        try self.write(attr.name);
                        try self.write("=\\\"");
                        try self.writeEscaped(val);
                        try self.writeLine("\\\"\");");
                    }
                } else {
                    // Boolean attribute
                    try self.writeIndent();
                    try self.write("try buf.appendSlice(allocator, \" ");
                    try self.write(attr.name);
                    if (!self.terse) {
                        try self.write("=\\\"");
                        try self.write(attr.name);
                        try self.write("\\\"");
                    }
                    try self.writeLine("\");");
                }
            }

            try self.writeIndent();
            try self.writeLine("try buf.appendSlice(allocator, \">\");");
        }

        // Handle tag content and children
        const has_children = tag.nodes.items.len > 0;

        if (has_children) {
            for (tag.nodes.items) |child| {
                try self.generateNode(child);
            }
        }

        // Closing tag (void elements don't need closing tags)
        if (!is_void) {
            try self.addStatic("</");
            try self.addStatic(name);
            try self.addStatic(">");
        }
    }

    fn generateText(self: *Codegen, text_node: *Node) !void {
        const val = text_node.val orelse return;

        // Parse for interpolations: #{field}
        var i: usize = 0;
        var last_pos: usize = 0;

        while (i < val.len) {
            if (i + 2 < val.len and val[i] == '#' and val[i + 1] == '{') {
                // Found interpolation
                const start = i + 2;
                var end = start;
                while (end < val.len and val[end] != '}') : (end += 1) {}

                if (end < val.len) {
                    // Output static text before interpolation
                    if (last_pos < i) {
                        try self.addStatic(val[last_pos..i]);
                    }

                    // Flush static buffer before dynamic content
                    try self.flushStaticBuffer();

                    // Output interpolated field
                    const field_name = val[start..end];
                    try self.writeIndent();

                    // Check if this is a loop variable reference (e.g., item.name)
                    const is_loop_var = self.isLoopVariableReference(field_name);
                    // Check if the field has a non-string type hint
                    const needs_value_helper = is_loop_var or self.hasNonStringTypeHint(field_name);

                    if (text_node.buffer) {
                        // Escaped (default)
                        if (needs_value_helper) {
                            // Use appendValue for typed fields (handles any type)
                            try self.write("try helpers.appendValue(&buf, allocator, ");
                            if (is_loop_var) {
                                try self.writeFieldReference(field_name);
                            } else {
                                try self.write("data.");
                                try self.writeSanitizedFieldName(field_name);
                            }
                        } else {
                            try self.write("try helpers.appendEscaped(&buf, allocator, data.");
                            try self.writeSanitizedFieldName(field_name);
                        }
                    } else {
                        // Unescaped (unsafe)
                        if (needs_value_helper) {
                            // Use appendValue for typed fields (handles any type)
                            try self.write("try helpers.appendValue(&buf, allocator, ");
                            if (is_loop_var) {
                                try self.writeFieldReference(field_name);
                            } else {
                                try self.write("data.");
                                try self.writeSanitizedFieldName(field_name);
                            }
                        } else {
                            try self.write("try buf.appendSlice(allocator, data.");
                            try self.writeSanitizedFieldName(field_name);
                        }
                    }
                    try self.writeLine(");");

                    i = end + 1;
                    last_pos = i;
                    continue;
                }
            }
            i += 1;
        }

        // Output remaining static text
        if (last_pos < val.len) {
            try self.addStatic(val[last_pos..]);
        }
    }

    fn generateCode(self: *Codegen, code_node: *Node) !void {
        const val = code_node.val orelse return;

        // Buffered code outputs a field
        if (code_node.buffer) {
            // Flush static buffer before dynamic content
            try self.flushStaticBuffer();

            // Check if this is a loop variable reference
            const is_loop_var = self.isLoopVariableReference(val);
            const needs_value_helper = is_loop_var or self.hasNonStringTypeHint(val);

            try self.writeIndent();
            if (needs_value_helper) {
                // Use appendValue for typed fields (handles any type)
                try self.write("try helpers.appendValue(&buf, allocator, ");
                if (is_loop_var) {
                    try self.writeFieldReference(val);
                } else {
                    try self.write("data.");
                    try self.writeSanitizedFieldName(val);
                }
            } else if (code_node.must_escape) {
                try self.write("try helpers.appendEscaped(&buf, allocator, data.");
                try self.writeSanitizedFieldName(val);
            } else {
                try self.write("try buf.appendSlice(allocator, data.");
                try self.writeSanitizedFieldName(val);
            }
            try self.writeLine(");");
        }
        // Unbuffered code is not supported in static compilation
    }

    fn generateComment(self: *Codegen, comment_node: *Node) !void {
        if (!comment_node.buffer) return; // Silent comment

        const val = comment_node.val orelse return;
        try self.addStatic("<!--");
        try self.addStatic(val);
        try self.addStatic("-->");
    }

    fn generateBlockComment(self: *Codegen, comment_node: *Node) !void {
        if (!comment_node.buffer) return; // Silent comment

        try self.addStatic("<!--");

        for (comment_node.nodes.items) |child| {
            try self.generateNode(child);
        }

        try self.addStatic("-->");
    }

    fn generateDoctype(self: *Codegen, doctype_node: *Node) !void {
        const val = doctype_node.val orelse "html";

        if (runtime.doctypes.get(val)) |doctype_str| {
            try self.addStatic(doctype_str);
        } else {
            // Custom doctype
            try self.addStatic("<!DOCTYPE ");
            try self.addStatic(val);
            try self.addStatic(">");
        }
    }

    fn generateEach(self: *Codegen, node: *Node) !void {
        const collection = node.obj orelse return;
        const item_var = node.val orelse "item";

        // Flush static content before loop
        try self.flushStaticBuffer();

        // Generate: for (data.collection) |item| {
        try self.writeIndent();
        try self.write("for (data.");
        try self.writeSanitizedFieldName(collection);
        try self.write(") |");
        try self.write(item_var);
        try self.writeLine("| {");
        self.indent_level += 1;

        // Track loop variable for field resolution
        const prev_loop_var = self.current_loop_var;
        self.current_loop_var = item_var;

        // Generate loop body
        for (node.nodes.items) |child| {
            try self.generateNode(child);
        }

        // Flush any remaining static content
        try self.flushStaticBuffer();

        self.current_loop_var = prev_loop_var;
        self.indent_level -= 1;
        try self.writeIndent();
        try self.writeLine("}");
    }

    fn generateConditional(self: *Codegen, cond: *Node) !void {
        // For compiled templates, generate Zig if/else statements
        // Only support simple field references like "isLoggedIn" or "count > 0"
        const test_expr = cond.test_expr orelse return error.InvalidNode;

        // Flush any static content before conditional
        try self.flushStaticBuffer();

        // Extract field name (simple case: just a field name)
        const field_name = std.mem.trim(u8, test_expr, " \t");

        // Generate if statement
        try self.writeIndent();
        try self.write("if (helpers.isTruthy(data.");
        try self.writeSanitizedFieldName(field_name);
        try self.writeLine(")) {");
        self.indent_level += 1;

        // Generate consequent
        if (cond.consequent) |cons| {
            try self.generateNode(cons);
        }

        // Flush static buffer before closing the if block
        try self.flushStaticBuffer();

        self.indent_level -= 1;

        // Generate alternate (else/else if)
        if (cond.alternate) |alt| {
            try self.writeIndent();
            if (alt.type == .Conditional) {
                // else if
                try self.write("} else if (helpers.isTruthy(data.");
                const alt_test = alt.test_expr orelse return error.InvalidNode;
                const alt_field = std.mem.trim(u8, alt_test, " \t");
                try self.write(alt_field);
                try self.writeLine(")) {");
                self.indent_level += 1;

                if (alt.consequent) |alt_cons| {
                    try self.generateNode(alt_cons);
                }

                // Flush static buffer before closing the else-if block
                try self.flushStaticBuffer();

                self.indent_level -= 1;

                // Handle nested alternates
                if (alt.alternate) |nested_alt| {
                    try self.writeIndent();
                    try self.writeLine("} else {");
                    self.indent_level += 1;
                    try self.generateNode(nested_alt);
                    // Flush static buffer before closing the else block
                    try self.flushStaticBuffer();
                    self.indent_level -= 1;
                }

                try self.writeIndent();
                try self.writeLine("}");
            } else {
                // else
                try self.writeLine("} else {");
                self.indent_level += 1;
                try self.generateNode(alt);
                // Flush static buffer before closing the else block
                try self.flushStaticBuffer();
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            }
        } else {
            try self.writeIndent();
            try self.writeLine("}");
        }
    }

    // ========================================================================
    // Static String Buffer Management
    // ========================================================================

    /// Add static HTML to the buffer (will be combined with adjacent static strings)
    fn addStatic(self: *Codegen, str: []const u8) !void {
        try self.static_buffer.appendSlice(self.allocator, str);
    }

    /// Flush accumulated static strings as a single appendSlice call
    fn flushStaticBuffer(self: *Codegen) !void {
        if (self.static_buffer.items.len == 0) return;

        try self.writeIndent();
        try self.write("try buf.appendSlice(allocator, \"");
        try self.writeEscaped(self.static_buffer.items);
        try self.writeLine("\");");

        self.static_buffer.clearRetainingCapacity();
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    fn detectDoctype(self: *Codegen, node: *Node) void {
        if (node.type == .Doctype) {
            if (node.val) |val| {
                // XHTML doctypes use non-terse mode
                // Uses shared isXhtmlDoctype from runtime.zig
                if (runtime.isXhtmlDoctype(val)) {
                    self.terse = false;
                }
            }
            return;
        }

        for (node.nodes.items) |child| {
            self.detectDoctype(child);
            if (!self.terse) return;
        }
    }

    fn writeIndent(self: *Codegen) !void {
        for (0..self.indent_level) |_| {
            try self.output.appendSlice(self.allocator, "    ");
        }
    }

    fn write(self: *Codegen, str: []const u8) !void {
        try self.output.appendSlice(self.allocator, str);
    }

    fn writeLine(self: *Codegen, str: []const u8) !void {
        try self.output.appendSlice(self.allocator, str);
        try self.output.append(self.allocator, '\n');
    }

    /// Escape string for Zig string literal (handles ", \, newlines)
    fn writeEscaped(self: *Codegen, str: []const u8) !void {
        for (str) |c| {
            switch (c) {
                '"' => try self.write("\\\""),
                '\\' => try self.write("\\\\"),
                '\n' => try self.write("\\n"),
                '\r' => try self.write("\\r"),
                '\t' => try self.write("\\t"),
                else => try self.output.append(self.allocator, c),
            }
        }
    }

    /// Write a field name with sanitization (replace dots with underscores).
    /// For @import-typed fields, preserves dots as real Zig field access and
    /// inserts `.?` after the base if the type is optional (e.g., user.name -> user.?.name).
    fn writeSanitizedFieldName(self: *Codegen, field_name: []const u8) !void {
        if (std.mem.indexOf(u8, field_name, ".")) |dot_idx| {
            const base = field_name[0..dot_idx];
            if (self.type_hints.get(base)) |info| {
                if (info.import_type != null) {
                    // Preserve dots as real Zig field access
                    try self.write(base);
                    if (info.is_optional) {
                        try self.write(".?");
                    }
                    try self.write(field_name[dot_idx..]);
                    return;
                }
            }
        }
        // Default: replace dots with underscores
        for (field_name) |c| {
            try self.output.append(self.allocator, if (c == '.') '_' else c);
        }
    }

    /// Check if field_name is a loop variable reference (e.g., "item" or "item.name" when current_loop_var is "item")
    fn isLoopVariableReference(self: *Codegen, field_name: []const u8) bool {
        const loop_var = self.current_loop_var orelse return false;
        // Exact match (e.g., "item" when loop var is "item")
        if (std.mem.eql(u8, field_name, loop_var)) return true;
        // Field access (e.g., "item.name" when loop var is "item")
        if (field_name.len > loop_var.len and
            std.mem.startsWith(u8, field_name, loop_var) and
            field_name[loop_var.len] == '.')
        {
            return true;
        }
        return false;
    }

    /// Check if a field has a non-string type hint (requires helpers.appendValue)
    fn hasNonStringTypeHint(self: *Codegen, field_name: []const u8) bool {
        // Direct lookup first, then try base name for dotted fields (e.g., "user.name" -> "user")
        const type_info = self.type_hints.get(field_name) orelse blk: {
            if (std.mem.indexOf(u8, field_name, ".")) |dot_idx| {
                break :blk self.type_hints.get(field_name[0..dot_idx]);
            }
            break :blk null;
        } orelse return false;

        // Import types always need appendValue (field access returns non-string types)
        if (type_info.import_type != null) return true;

        // Arrays always need appendValue
        if (type_info.is_array) return true;

        // Structs need appendValue
        if (type_info.struct_fields != null) return true;

        // Check primitive type
        if (type_info.primitive_type) |prim| {
            // String types don't need appendValue
            if (std.mem.eql(u8, prim, "[]const u8")) return false;
            // All other primitives (f32, i32, bool, etc.) need appendValue
            return true;
        }

        return false;
    }

    /// Write a field reference, handling loop variables (item.name -> item.name) vs data fields (field -> data.field)
    fn writeFieldReference(self: *Codegen, field_name: []const u8) !void {
        // For loop variable references, write directly (e.g., "item.name")
        try self.write(field_name);
    }

    /// Write type information to output (generates Zig type syntax with default value)
    fn writeTypeInfo(self: *Codegen, type_info: TypeInfo) !void {
        // Handle @import(...) type expressions (verbatim Zig types)
        if (type_info.import_type) |import_expr| {
            if (type_info.is_array) {
                try self.write("[]const ");
            }
            if (type_info.is_optional) {
                try self.write("?");
            }
            try self.write(import_expr);
            if (type_info.is_optional) {
                try self.write(" = null");
            } else if (type_info.is_array) {
                try self.write(" = &.{}");
            }
            return;
        }

        if (type_info.is_array) {
            // Array type: []const struct { ... } = &.{}
            if (type_info.struct_fields) |struct_fields| {
                try self.write("[]const struct { ");
                var iter = struct_fields.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (!first) {
                        try self.write(", ");
                    }
                    first = false;
                    try self.write(entry.key_ptr.*);
                    try self.write(": ");
                    try self.write(entry.value_ptr.*);
                }
                try self.write(" } = &.{}");
            } else if (type_info.primitive_type) |prim| {
                // Array of primitives: []const u8, []i32, etc.
                try self.write("[]const ");
                try self.write(prim);
                try self.write(" = &.{}");
            } else {
                // Fallback: array of strings
                try self.write("[]const []const u8 = &.{}");
            }
        } else {
            // Non-array type
            if (type_info.struct_fields) |struct_fields| {
                // Anonymous struct
                try self.write("struct { ");
                var iter = struct_fields.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (!first) {
                        try self.write(", ");
                    }
                    first = false;
                    try self.write(entry.key_ptr.*);
                    try self.write(": ");
                    try self.write(entry.value_ptr.*);
                }
                try self.write(" } = .{}");
            } else if (type_info.primitive_type) |prim| {
                // Primitive type with appropriate default
                try self.write(prim);
                if (std.mem.eql(u8, prim, "[]const u8")) {
                    try self.write(" = \"\"");
                } else if (std.mem.eql(u8, prim, "bool")) {
                    try self.write(" = false");
                } else if (std.mem.startsWith(u8, prim, "i") or std.mem.startsWith(u8, prim, "u")) {
                    try self.write(" = 0");
                } else if (std.mem.startsWith(u8, prim, "f")) {
                    try self.write(" = 0.0");
                } else {
                    // Unknown type, no default
                }
            } else {
                // Fallback: string
                try self.write("[]const u8 = \"\"");
            }
        }
    }

    /// Check if value is a data field reference (simple identifier, may contain dots)
    fn isDataFieldReference(self: *Codegen, val: []const u8) bool {
        _ = self;
        if (val.len == 0) return false;

        // Check for quotes (static string)
        if (val[0] == '"' or val[0] == '\'') return false;

        // Check if it's a valid identifier (allow dots for nested access)
        for (val, 0..) |c, idx| {
            if (idx == 0) {
                if (!std.ascii.isAlphabetic(c) and c != '_') return false;
            } else {
                if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.') return false;
            }
        }

        return true;
    }
};

// ============================================================================
// Field Name Extraction
// ============================================================================

/// Extract all data field names referenced in an AST
/// Sanitizes field names to be valid Zig identifiers (replaces '.' with '_'),
/// except for fields whose base has an @import type hint (those collapse to the base name).
pub fn extractFieldNames(allocator: Allocator, ast: *Node) ![][]const u8 {
    var fields = std.StringHashMap(void).init(allocator);
    defer fields.deinit();

    var loop_vars = std.StringHashMap(void).init(allocator);
    defer loop_vars.deinit();

    try extractFieldNamesRecursive(ast, &fields, &loop_vars);

    // Collect type hints to identify @import-typed fields
    var type_hints = std.StringHashMap(TypeInfo).init(allocator);
    defer type_hints.deinit();
    try collectTypeHints(allocator, ast, &type_hints);

    // Convert to sorted slice, collapsing dotted fields whose base has an @import type
    var result: std.ArrayList([]const u8) = .{};
    errdefer {
        for (result.items) |item| allocator.free(item);
        result.deinit(allocator);
    }

    // Track which base names we've already added (to avoid duplicates after collapsing)
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var iter = fields.keyIterator();
    while (iter.next()) |key| {
        // For dotted fields (e.g., "user.name"), check if base has an @import type
        if (std.mem.indexOf(u8, key.*, ".")) |dot_idx| {
            const base = key.*[0..dot_idx];
            if (type_hints.get(base)) |info| {
                if (info.import_type != null) {
                    // Collapse to base name — skip if already added
                    if (seen.contains(base)) continue;
                    try seen.put(base, {});
                    const duped = try allocator.dupe(u8, base);
                    try result.append(allocator, duped);
                    continue;
                }
            }
        }

        // Default: sanitize dots to underscores for valid Zig identifiers
        const sanitized = try allocator.alloc(u8, key.*.len);
        errdefer allocator.free(sanitized);

        for (key.*, 0..) |c, i| {
            sanitized[i] = if (c == '.') '_' else c;
        }

        // Deduplicate (base name from TypeHint node may already exist)
        if (seen.contains(sanitized)) {
            allocator.free(sanitized);
            continue;
        }
        try seen.put(sanitized, {});
        try result.append(allocator, sanitized);
    }

    // Sort for consistent output
    const slice = try result.toOwnedSlice(allocator);
    std.mem.sort([]const u8, slice, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    return slice;
}

fn extractFieldNamesRecursive(node: *Node, fields: *std.StringHashMap(void), loop_vars: *std.StringHashMap(void)) !void {
    // Skip mixin DEFINITIONS - they contain parameter references that shouldn't
    // be extracted as data fields. Only expanded mixin CALLS should be processed.
    if (node.type == .Mixin and !node.call) {
        return;
    }

    // Handle TypeHint nodes - just add the field name, type info is handled separately
    if (node.type == .TypeHint) {
        if (node.type_hint_field) |field| {
            try fields.put(field, {});
        }
        return;
    }

    // Handle Each/EachOf nodes - extract collection field and track loop variable
    if (node.type == .Each or node.type == .EachOf) {
        if (node.obj) |collection| {
            const trimmed = std.mem.trim(u8, collection, " \t");
            if (trimmed.len > 0) {
                try fields.put(trimmed, {});
            }
        }

        // Track the loop variable (e.g., "item" in "each item in items")
        const loop_var = node.val orelse "item";
        try loop_vars.put(loop_var, {});

        // Recurse into loop body
        for (node.nodes.items) |child| {
            try extractFieldNamesRecursive(child, fields, loop_vars);
        }

        // Remove loop variable after processing (for nested loops with same var name)
        _ = loop_vars.remove(loop_var);
        return;
    }

    // Extract from text interpolations: #{field}
    if (node.type == .Text or node.type == .Code) {
        if (node.val) |val| {
            // Parse #{field} interpolations
            var i: usize = 0;
            while (i < val.len) {
                if (i + 2 < val.len and val[i] == '#' and val[i + 1] == '{') {
                    const start = i + 2;
                    var end = start;
                    while (end < val.len and val[end] != '}') : (end += 1) {}

                    if (end < val.len) {
                        const field_name = val[start..end];
                        // Skip if it's a loop variable reference
                        if (!isLoopVarReference(field_name, loop_vars)) {
                            try fields.put(field_name, {});
                        }
                        i = end + 1;
                        continue;
                    }
                }
                i += 1;
            }

            // For Code nodes with buffer=true, the val itself is a field reference
            if (node.type == .Code and node.buffer) {
                // Skip if it's a loop variable reference
                if (!isLoopVarReference(val, loop_vars)) {
                    try fields.put(val, {});
                }
            }
        }
    }

    // Extract from attribute bindings
    if (node.type == .Tag or node.type == .InterpolatedTag) {
        for (node.attrs.items) |attr| {
            if (attr.val) |val| {
                // Only extract if not quoted (quoted values are static strings)
                if (!attr.quoted and val.len > 0) {
                    var is_identifier = true;
                    for (val, 0..) |c, idx| {
                        if (idx == 0) {
                            if (!std.ascii.isAlphabetic(c) and c != '_') {
                                is_identifier = false;
                                break;
                            }
                        } else {
                            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.') {
                                is_identifier = false;
                                break;
                            }
                        }
                    }
                    // Skip if it's a loop variable reference
                    if (is_identifier and !isLoopVarReference(val, loop_vars)) {
                        try fields.put(val, {});
                    }
                }
            }
        }
    }

    // Extract from conditional test expressions
    if (node.type == .Conditional) {
        if (node.test_expr) |test_expr| {
            const field_name = std.mem.trim(u8, test_expr, " \t");
            // Simple field reference
            if (field_name.len > 0) {
                var is_identifier = true;
                for (field_name, 0..) |c, idx| {
                    if (idx == 0) {
                        if (!std.ascii.isAlphabetic(c) and c != '_') {
                            is_identifier = false;
                            break;
                        }
                    } else {
                        if (!std.ascii.isAlphanumeric(c) and c != '_') {
                            is_identifier = false;
                            break;
                        }
                    }
                }
                // Skip if it's a loop variable reference
                if (is_identifier and !isLoopVarReference(field_name, loop_vars)) {
                    try fields.put(field_name, {});
                }
            }
        }

        // Recurse into consequent and alternate
        if (node.consequent) |cons| {
            try extractFieldNamesRecursive(cons, fields, loop_vars);
        }
        if (node.alternate) |alt| {
            try extractFieldNamesRecursive(alt, fields, loop_vars);
        }
    }

    // Recurse into children
    for (node.nodes.items) |child| {
        try extractFieldNamesRecursive(child, fields, loop_vars);
    }
}

/// Check if a field name is a loop variable reference (e.g., "item" or "item.name")
fn isLoopVarReference(field_name: []const u8, loop_vars: *std.StringHashMap(void)) bool {
    // Check exact match (e.g., "item")
    if (loop_vars.contains(field_name)) return true;

    // Check field access (e.g., "item.name" -> check "item")
    if (std.mem.indexOf(u8, field_name, ".")) |dot_idx| {
        const base = field_name[0..dot_idx];
        if (loop_vars.contains(base)) return true;
    }

    return false;
}

// ============================================================================
// Type Hint Parsing
// ============================================================================

/// Parse a type spec string (e.g., "[]{name: []const u8, price: f32}")
pub fn parseTypeHintSpec(allocator: Allocator, spec: []const u8) !TypeInfo {
    var info = TypeInfo{};
    var remaining = std.mem.trim(u8, spec, " \t");

    // Check for optional prefix ?
    if (remaining.len > 0 and remaining[0] == '?') {
        info.is_optional = true;
        remaining = remaining[1..];
    }

    // Check for array prefix []
    if (std.mem.startsWith(u8, remaining, "[]")) {
        info.is_array = true;
        remaining = remaining[2..];
    }

    // Check for @import(...) type expression (verbatim Zig type)
    if (std.mem.startsWith(u8, remaining, "@import(")) {
        info.import_type = remaining;
        return info;
    }

    // Check for struct definition {...}
    if (remaining.len > 0 and remaining[0] == '{') {
        info.struct_fields = try parseStructFields(allocator, remaining);
    } else {
        info.primitive_type = remaining;
    }

    return info;
}

/// Parse struct fields from "{field1: type1, field2: type2}"
fn parseStructFields(allocator: Allocator, spec: []const u8) !std.StringHashMap([]const u8) {
    var fields = std.StringHashMap([]const u8).init(allocator);
    errdefer fields.deinit();

    // Remove braces
    if (spec.len < 2) return fields;
    const inner = spec[1 .. spec.len - 1];

    // Split by comma and parse each field
    var iter = std.mem.splitSequence(u8, inner, ",");
    while (iter.next()) |field_spec| {
        const trimmed = std.mem.trim(u8, field_spec, " \t");
        if (trimmed.len == 0) continue;

        // Find colon separator
        if (std.mem.indexOf(u8, trimmed, ":")) |colon_idx| {
            const field_name = std.mem.trim(u8, trimmed[0..colon_idx], " \t");
            const field_type = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " \t");
            try fields.put(field_name, field_type);
        }
    }

    return fields;
}

/// Collect type hints from an AST into a hash map
pub fn collectTypeHints(allocator: Allocator, ast: *Node, type_hints: *std.StringHashMap(TypeInfo)) !void {
    try collectTypeHintsRecursive(allocator, ast, type_hints);
}

fn collectTypeHintsRecursive(allocator: Allocator, node: *Node, type_hints: *std.StringHashMap(TypeInfo)) !void {
    // Handle TypeHint nodes
    if (node.type == .TypeHint) {
        if (node.type_hint_field) |field| {
            if (node.type_hint_type) |type_spec| {
                const info = try parseTypeHintSpec(allocator, type_spec);
                try type_hints.put(field, info);
            }
        }
        return;
    }

    // Recurse into conditional branches
    if (node.type == .Conditional) {
        if (node.consequent) |cons| {
            try collectTypeHintsRecursive(allocator, cons, type_hints);
        }
        if (node.alternate) |alt| {
            try collectTypeHintsRecursive(allocator, alt, type_hints);
        }
    }

    // Recurse into children
    for (node.nodes.items) |child| {
        try collectTypeHintsRecursive(allocator, child, type_hints);
    }
}

test "zig_codegen - field extraction" {
    const allocator = std.testing.allocator;
    const source =
        \\p Hello #{name}
        \\p= message
        \\a(href=url) Link
    ;

    var parse_result = try template.parseWithSource(allocator, source);
    defer parse_result.deinit(allocator);

    const fields = try extractFieldNames(allocator, parse_result.ast);
    defer {
        for (fields) |field| allocator.free(field);
        allocator.free(fields);
    }

    // Should find "message", "name", "url" (sorted alphabetically)
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("message", fields[0]);
    try std.testing.expectEqualStrings("name", fields[1]);
    try std.testing.expectEqualStrings("url", fields[2]);
}

test "zig_codegen - static attributes" {
    const allocator = std.testing.allocator;
    const source =
        \\a(href="/home" class="btn") Home
    ;

    var parse_result = try template.parseWithSource(allocator, source);
    defer parse_result.deinit(allocator);

    const fields = try extractFieldNames(allocator, parse_result.ast);
    defer {
        for (fields) |field| allocator.free(field);
        allocator.free(fields);
    }

    var cg = Codegen.init(allocator);
    defer cg.deinit();

    const zig_code = try cg.generate(parse_result.ast, "render", fields, null);
    defer allocator.free(zig_code);

    // Static attributes should be in the string literal
    try std.testing.expect(std.mem.indexOf(u8, zig_code, "href=\\\"/home\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_code, "class=\\\"btn\\\"") != null);
}

test "zig_codegen - dynamic attributes" {
    const allocator = std.testing.allocator;

    const source =
        \\a(href=url class="btn") Link
    ;

    var parse_result = try template.parseWithSource(allocator, source);
    defer parse_result.deinit(allocator);

    const fields = try extractFieldNames(allocator, parse_result.ast);
    defer {
        for (fields) |field| allocator.free(field);
        allocator.free(fields);
    }

    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("url", fields[0]);

    var cg = Codegen.init(allocator);
    defer cg.deinit();

    const zig_code = try cg.generate(parse_result.ast, "render", fields, null);
    defer allocator.free(zig_code);

    // Dynamic href should use data.url
    try std.testing.expect(std.mem.indexOf(u8, zig_code, "data.url") != null);
    // Static class should still be in string
    try std.testing.expect(std.mem.indexOf(u8, zig_code, "class=\\\"btn\\\"") != null);
}

test "zig_codegen - @TypeOf with optional @import type" {
    const allocator = std.testing.allocator;

    const source =
        \\//- @TypeOf(user): ?@import("api").account.AuthUser
        \\if user
        \\  span= user.name
        \\else
        \\  a(href="/login") Login
    ;

    var parse_result = try template.parseWithSource(allocator, source);
    defer parse_result.deinit(allocator);

    // Field extraction should collapse user.name to just user
    const fields = try extractFieldNames(allocator, parse_result.ast);
    defer {
        for (fields) |field| allocator.free(field);
        allocator.free(fields);
    }

    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("user", fields[0]);

    // Generated code should have correct type and field access
    var cg = Codegen.init(allocator);
    defer cg.deinit();

    const zig_code = try cg.generate(parse_result.ast, "render", fields, null);
    defer allocator.free(zig_code);

    // Data struct should have optional import type with null default
    try std.testing.expect(std.mem.indexOf(u8, zig_code, "?@import(\"api\").account.AuthUser = null") != null);
    // Should NOT contain user_name as a separate field
    try std.testing.expect(std.mem.indexOf(u8, zig_code, "user_name") == null);
    // Should use .? for optional unwrap in field access
    try std.testing.expect(std.mem.indexOf(u8, zig_code, "data.user.?.name") != null);
}

test "zig_codegen - @TypeOf with non-optional @import type" {
    const allocator = std.testing.allocator;

    const source =
        \\//- @TypeOf(config) = @import("conf").Config
        \\p= config.title
    ;

    var parse_result = try template.parseWithSource(allocator, source);
    defer parse_result.deinit(allocator);

    const fields = try extractFieldNames(allocator, parse_result.ast);
    defer {
        for (fields) |field| allocator.free(field);
        allocator.free(fields);
    }

    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("config", fields[0]);

    var cg = Codegen.init(allocator);
    defer cg.deinit();

    const zig_code = try cg.generate(parse_result.ast, "render", fields, null);
    defer allocator.free(zig_code);

    // Non-optional import type: no ? prefix, no = null default
    try std.testing.expect(std.mem.indexOf(u8, zig_code, "@import(\"conf\").Config,") != null);
    // Field access without .? (not optional)
    try std.testing.expect(std.mem.indexOf(u8, zig_code, "data.config.title") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_code, "config_title") == null);
}
