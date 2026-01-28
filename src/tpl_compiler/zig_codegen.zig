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

pub const Codegen = struct {
    allocator: Allocator,
    output: std.ArrayListUnmanaged(u8),
    indent_level: usize,
    terse: bool, // HTML5 mode vs XHTML
    // Buffer for combining consecutive static strings
    static_buffer: std.ArrayListUnmanaged(u8),

    pub fn init(allocator: Allocator) Codegen {
        return .{
            .allocator = allocator,
            .output = .{},
            .indent_level = 0,
            .terse = true, // Default to HTML5
            .static_buffer = .{},
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.output.deinit(self.allocator);
        self.static_buffer.deinit(self.allocator);
    }

    /// Generate Zig code for a template
    pub fn generate(self: *Codegen, ast: *Node, function_name: []const u8, fields: []const []const u8) ![]const u8 {
        // Reset state
        self.output.clearRetainingCapacity();
        self.static_buffer.clearRetainingCapacity();
        self.indent_level = 0;
        self.terse = true;

        // Detect doctype to set terse mode
        self.detectDoctype(ast);

        // Generate imports
        try self.writeLine("const std = @import(\"std\");");
        try self.writeLine("const helpers = @import(\"helpers.zig\");");
        try self.writeLine("");

        // Generate Data struct
        try self.writeIndent();
        try self.writeLine("pub const Data = struct {");
        self.indent_level += 1;
        for (fields) |field| {
            try self.writeIndent();
            try self.write(field);
            try self.writeLine(": []const u8 = \"\",");
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
        try self.writeLine("var buf: std.ArrayListUnmanaged(u8) = .{};");
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

                        try self.writeIndent();
                        if (attr.must_escape) {
                            try self.write("try helpers.appendEscaped(&buf, allocator, data.");
                        } else {
                            try self.write("try buf.appendSlice(allocator, data.");
                        }
                        // Sanitize field name
                        try self.writeSanitizedFieldName(val);
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
                    if (text_node.buffer) {
                        // Escaped (default)
                        try self.write("try helpers.appendEscaped(&buf, allocator, data.");
                    } else {
                        // Unescaped (unsafe)
                        try self.write("try buf.appendSlice(allocator, data.");
                    }
                    // Sanitize field name (replace dots with underscores)
                    try self.writeSanitizedFieldName(field_name);
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

            try self.writeIndent();
            if (code_node.must_escape) {
                try self.write("try helpers.appendEscaped(&buf, allocator, data.");
            } else {
                try self.write("try buf.appendSlice(allocator, data.");
            }
            // Sanitize field name
            try self.writeSanitizedFieldName(val);
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

                self.indent_level -= 1;

                // Handle nested alternates
                if (alt.alternate) |nested_alt| {
                    try self.writeIndent();
                    try self.writeLine("} else {");
                    self.indent_level += 1;
                    try self.generateNode(nested_alt);
                    self.indent_level -= 1;
                }

                try self.writeIndent();
                try self.writeLine("}");
            } else {
                // else
                try self.writeLine("} else {");
                self.indent_level += 1;
                try self.generateNode(alt);
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
                if (std.mem.eql(u8, val, "xml") or
                    std.mem.eql(u8, val, "strict") or
                    std.mem.eql(u8, val, "transitional") or
                    std.mem.eql(u8, val, "frameset") or
                    std.mem.eql(u8, val, "1.1") or
                    std.mem.eql(u8, val, "basic") or
                    std.mem.eql(u8, val, "mobile"))
                {
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

    /// Write a field name with sanitization (replace dots with underscores)
    fn writeSanitizedFieldName(self: *Codegen, field_name: []const u8) !void {
        for (field_name) |c| {
            try self.output.append(self.allocator, if (c == '.') '_' else c);
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
/// Sanitizes field names to be valid Zig identifiers (replaces '.' with '_')
pub fn extractFieldNames(allocator: Allocator, ast: *Node) ![][]const u8 {
    var fields = std.StringHashMap(void).init(allocator);
    defer fields.deinit();

    try extractFieldNamesRecursive(ast, &fields);

    // Convert to sorted slice and sanitize field names
    var result: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (result.items) |item| allocator.free(item);
        result.deinit(allocator);
    }

    var iter = fields.keyIterator();
    while (iter.next()) |key| {
        // Sanitize: replace dots with underscores for valid Zig identifiers
        const sanitized = try allocator.alloc(u8, key.*.len);
        errdefer allocator.free(sanitized);

        for (key.*, 0..) |c, i| {
            sanitized[i] = if (c == '.') '_' else c;
        }

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

fn extractFieldNamesRecursive(node: *Node, fields: *std.StringHashMap(void)) !void {
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
                        try fields.put(field_name, {});
                        i = end + 1;
                        continue;
                    }
                }
                i += 1;
            }

            // For Code nodes with buffer=true, the val itself is a field reference
            if (node.type == .Code and node.buffer) {
                try fields.put(val, {});
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
                    if (is_identifier) {
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
                if (is_identifier) {
                    try fields.put(field_name, {});
                }
            }
        }

        // Recurse into consequent and alternate
        if (node.consequent) |cons| {
            try extractFieldNamesRecursive(cons, fields);
        }
        if (node.alternate) |alt| {
            try extractFieldNamesRecursive(alt, fields);
        }
    }

    // Recurse into children
    for (node.nodes.items) |child| {
        try extractFieldNamesRecursive(child, fields);
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

    var cg = Codegen.init(allocator, .{});
    defer cg.deinit();

    const zig_code = try cg.generate(parse_result.ast, "render", fields);
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

    var cg = Codegen.init(allocator, .{});
    defer cg.deinit();

    const zig_code = try cg.generate(parse_result.ast, "render", fields);
    defer allocator.free(zig_code);

    // Dynamic href should use data.url
    try std.testing.expect(std.mem.indexOf(u8, zig_code, "data.url") != null);
    // Static class should still be in string
    try std.testing.expect(std.mem.indexOf(u8, zig_code, "class=\\\"btn\\\"") != null);
}
