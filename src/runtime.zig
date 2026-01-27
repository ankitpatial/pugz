const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

// ============================================================================
// Pug Runtime - HTML generation utilities
// ============================================================================

/// DOCTYPE mappings - shared across codegen and template modules
pub const doctypes = std.StaticStringMap([]const u8).initComptime(.{
    .{ "html", "<!DOCTYPE html>" },
    .{ "xml", "<?xml version=\"1.0\" encoding=\"utf-8\" ?>" },
    .{ "transitional", "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Transitional//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd\">" },
    .{ "strict", "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\">" },
    .{ "frameset", "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Frameset//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-frameset.dtd\">" },
    .{ "1.1", "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">" },
    .{ "basic", "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML Basic 1.1//EN\" \"http://www.w3.org/TR/xhtml-basic/xhtml-basic11.dtd\">" },
    .{ "mobile", "<!DOCTYPE html PUBLIC \"-//WAPFORUM//DTD XHTML Mobile 1.2//EN\" \"http://www.openmobilealliance.org/tech/DTD/xhtml-mobile12.dtd\">" },
    .{ "plist", "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" },
});

/// Whitespace-sensitive tags - shared across codegen and template modules
pub const whitespace_sensitive_tags = std.StaticStringMap(void).initComptime(.{
    .{ "pre", {} },
    .{ "textarea", {} },
    .{ "script", {} },
    .{ "style", {} },
    .{ "code", {} },
});

/// Escape HTML special characters in a string.
/// Characters escaped: " & < >
pub fn escape(allocator: Allocator, html: []const u8) ![]const u8 {
    // Quick check if escaping is needed
    var needs_escape = false;
    for (html) |c| {
        if (c == '"' or c == '&' or c == '<' or c == '>') {
            needs_escape = true;
            break;
        }
    }

    if (!needs_escape) {
        return try allocator.dupe(u8, html);
    }

    var result: ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    for (html) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "&quot;"),
            '&' => try result.appendSlice(allocator, "&amp;"),
            '<' => try result.appendSlice(allocator, "&lt;"),
            '>' => try result.appendSlice(allocator, "&gt;"),
            else => try result.append(allocator, c),
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Style value types
pub const StyleValue = union(enum) {
    string: []const u8,
    object: []const StyleProperty,
    none,
};

pub const StyleProperty = struct {
    name: []const u8,
    value: []const u8,
};

/// Convert a style value to a CSS string.
/// If val is an object, formats as "key:value;key:value;"
/// If val is a string, returns it as-is.
pub fn style(allocator: Allocator, val: StyleValue) ![]const u8 {
    switch (val) {
        .none => return try allocator.dupe(u8, ""),
        .string => |s| {
            if (s.len == 0) return try allocator.dupe(u8, "");
            return try allocator.dupe(u8, s);
        },
        .object => |props| {
            var result: ArrayListUnmanaged(u8) = .{};
            errdefer result.deinit(allocator);

            for (props) |prop| {
                try result.appendSlice(allocator, prop.name);
                try result.append(allocator, ':');
                try result.appendSlice(allocator, prop.value);
                try result.append(allocator, ';');
            }

            return try result.toOwnedSlice(allocator);
        },
    }
}

/// Attribute value types
pub const AttrValue = union(enum) {
    string: []const u8,
    boolean: bool,
    number: i64,
    none, // null/undefined equivalent
};

/// Render a single HTML attribute.
/// Returns empty string for false/null values.
/// For true values, returns terse form " key" or full form " key="key"".
pub fn attr(allocator: Allocator, key: []const u8, val: AttrValue, escaped: bool, terse: bool) ![]const u8 {
    var result: ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);
    try appendAttr(allocator, &result, key, val, escaped, terse);
    if (result.items.len == 0) {
        return "";
    }
    return try result.toOwnedSlice(allocator);
}

/// Append attribute directly to output buffer - avoids intermediate allocations
/// This is the preferred method for rendering attributes in hot paths
pub fn appendAttr(allocator: Allocator, output: *ArrayListUnmanaged(u8), key: []const u8, val: AttrValue, escaped: bool, terse: bool) !void {
    switch (val) {
        .none => return,
        .boolean => |b| {
            if (!b) return;
            // true value
            try output.append(allocator, ' ');
            try output.appendSlice(allocator, key);
            if (!terse) {
                try output.appendSlice(allocator, "=\"");
                try output.appendSlice(allocator, key);
                try output.append(allocator, '"');
            }
        },
        .number => |n| {
            try output.append(allocator, ' ');
            try output.appendSlice(allocator, key);
            try output.appendSlice(allocator, "=\"");

            // Format number directly to buffer
            var buf: [32]u8 = undefined;
            const num_str = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
            try output.appendSlice(allocator, num_str);

            try output.append(allocator, '"');
        },
        .string => |s| {
            // Skip empty class or style
            if (s.len == 0 and (mem.eql(u8, key, "class") or mem.eql(u8, key, "style"))) {
                return;
            }

            try output.append(allocator, ' ');
            try output.appendSlice(allocator, key);
            try output.appendSlice(allocator, "=\"");

            if (escaped) {
                try appendEscaped(allocator, output, s);
            } else {
                try output.appendSlice(allocator, s);
            }

            try output.append(allocator, '"');
        },
    }
}

/// Class value types for the classes function
pub const ClassValue = union(enum) {
    string: []const u8,
    array: []const ClassValue,
    object: []const ClassCondition,
    none,
};

pub const ClassCondition = struct {
    name: []const u8,
    condition: bool,
};

/// Process class values into a space-delimited string.
/// Arrays are flattened, objects include keys with truthy values.
/// Optimized to minimize allocations by writing directly to result buffer.
pub fn classes(allocator: Allocator, val: ClassValue, escaping: ?[]const bool) ![]const u8 {
    var result: ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    try classesInternal(allocator, val, escaping, &result, 0);

    if (result.items.len == 0) {
        result.deinit(allocator);
        return try allocator.dupe(u8, "");
    }

    return try result.toOwnedSlice(allocator);
}

/// Internal recursive helper that writes directly to result buffer (avoids intermediate allocations)
fn classesInternal(
    allocator: Allocator,
    val: ClassValue,
    escaping: ?[]const bool,
    result: *ArrayListUnmanaged(u8),
    depth: usize,
) !void {
    switch (val) {
        .none => {},
        .string => |s| {
            if (s.len == 0) return;
            // Add space separator if not first item
            if (result.items.len > 0) try result.append(allocator, ' ');
            try result.appendSlice(allocator, s);
        },
        .object => |conditions| {
            for (conditions) |cond| {
                if (cond.condition and cond.name.len > 0) {
                    if (result.items.len > 0) try result.append(allocator, ' ');
                    try result.appendSlice(allocator, cond.name);
                }
            }
        },
        .array => |items| {
            for (items, 0..) |item, i| {
                // Check if this item needs escaping (only at top level)
                const should_escape = if (depth == 0) blk: {
                    break :blk if (escaping) |esc| (i < esc.len and esc[i]) else false;
                } else false;

                if (should_escape) {
                    // Need to escape: collect item first, then escape and append
                    const start_len = result.items.len;
                    const had_content = start_len > 0;

                    // Temporarily collect the class string
                    var temp: ArrayListUnmanaged(u8) = .{};
                    defer temp.deinit(allocator);
                    try classesInternal(allocator, item, null, &temp, depth + 1);

                    if (temp.items.len > 0) {
                        if (had_content) try result.append(allocator, ' ');
                        // Escape directly into result
                        try appendEscaped(allocator, result, temp.items);
                    }
                } else {
                    // No escaping: write directly to result
                    try classesInternal(allocator, item, null, result, depth + 1);
                }
            }
        },
    }
}

/// Append escaped HTML directly to result buffer (avoids intermediate allocation)
/// Public for use by codegen and other modules
pub fn appendEscaped(allocator: Allocator, result: *ArrayListUnmanaged(u8), html: []const u8) !void {
    for (html) |c| {
        if (escapeChar(c)) |escaped| {
            try result.appendSlice(allocator, escaped);
        } else {
            try result.append(allocator, c);
        }
    }
}

/// Comptime-generated lookup table for HTML character escaping
const escape_table: [256]?[]const u8 = blk: {
    var table: [256]?[]const u8 = .{null} ** 256;
    table['"'] = "&quot;";
    table['&'] = "&amp;";
    table['<'] = "&lt;";
    table['>'] = "&gt;";
    break :blk table;
};

/// Escape a single character, returning the escape sequence or null if no escaping needed
/// Uses comptime lookup table for O(1) access instead of switch statement
pub inline fn escapeChar(c: u8) ?[]const u8 {
    return escape_table[c];
}

/// Attribute entry for attrs function
pub const AttrEntry = struct {
    key: []const u8,
    value: AttrValue,
    is_class: bool = false,
    is_style: bool = false,
    class_value: ?ClassValue = null,
    style_value: ?StyleValue = null,
};

/// Render multiple attributes.
/// Class attributes are processed specially and placed first.
pub fn attrs(allocator: Allocator, entries: []const AttrEntry, terse: bool) ![]const u8 {
    var result: ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    // First pass: find and render class attribute
    for (entries) |entry| {
        if (entry.is_class) {
            if (entry.class_value) |cv| {
                const class_str = try classes(allocator, cv, null);
                defer allocator.free(class_str);

                if (class_str.len > 0) {
                    const attr_str = try attr(allocator, "class", .{ .string = class_str }, false, terse);
                    defer allocator.free(attr_str);
                    try result.appendSlice(allocator, attr_str);
                }
            }
            break;
        }
    }

    // Second pass: render other attributes
    for (entries) |entry| {
        if (entry.is_class) continue;

        if (entry.is_style) {
            if (entry.style_value) |sv| {
                const style_str = try style(allocator, sv);
                defer allocator.free(style_str);

                if (style_str.len > 0) {
                    const attr_str = try attr(allocator, "style", .{ .string = style_str }, false, terse);
                    defer allocator.free(attr_str);
                    try result.appendSlice(allocator, attr_str);
                }
            }
        } else {
            const attr_str = try attr(allocator, entry.key, entry.value, false, terse);
            defer allocator.free(attr_str);
            try result.appendSlice(allocator, attr_str);
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Merge entry for combining attribute objects
pub const MergeEntry = struct {
    key: []const u8,
    value: MergeValue,
};

pub const MergeValue = union(enum) {
    string: []const u8,
    class_array: []const []const u8,
    style_object: []const StyleProperty,
    none,
};

/// Merge result for a single key
pub const MergedValue = struct {
    key: []const u8,
    value: MergeValue,
    allocator: Allocator,
    owned_strings: ArrayListUnmanaged([]const u8),

    pub fn deinit(self: *MergedValue) void {
        for (self.owned_strings.items) |s| {
            self.allocator.free(s);
        }
        self.owned_strings.deinit(self.allocator);
    }
};

/// Ensure style string ends with semicolon
fn ensureTrailingSemicolon(allocator: Allocator, s: []const u8) ![]const u8 {
    if (s.len == 0) return try allocator.dupe(u8, "");
    if (s[s.len - 1] == ';') return try allocator.dupe(u8, s);

    var result: ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, s);
    try result.append(allocator, ';');
    return try result.toOwnedSlice(allocator);
}

/// Convert style value to string with trailing semicolon
fn styleToString(allocator: Allocator, val: StyleValue) ![]const u8 {
    const s = try style(allocator, val);
    defer allocator.free(s);
    return try ensureTrailingSemicolon(allocator, s);
}

// ============================================================================
// Merge function
// ============================================================================

/// Merged attributes result with O(1) lookups for class/style
pub const MergedAttrs = struct {
    allocator: Allocator,
    entries: ArrayListUnmanaged(MergedAttrEntry),
    owned_strings: ArrayListUnmanaged([]const u8),
    owned_class_arrays: ArrayListUnmanaged([][]const u8),
    // O(1) index tracking for special keys
    class_idx: ?usize = null,
    style_idx: ?usize = null,

    pub fn init(allocator: Allocator) MergedAttrs {
        return .{
            .allocator = allocator,
            .entries = .{},
            .owned_strings = .{},
            .owned_class_arrays = .{},
            .class_idx = null,
            .style_idx = null,
        };
    }

    pub fn deinit(self: *MergedAttrs) void {
        for (self.owned_strings.items) |s| {
            self.allocator.free(s);
        }
        self.owned_strings.deinit(self.allocator);

        for (self.owned_class_arrays.items) |arr| {
            self.allocator.free(arr);
        }
        self.owned_class_arrays.deinit(self.allocator);

        self.entries.deinit(self.allocator);
    }

    pub fn get(self: *const MergedAttrs, key: []const u8) ?MergedAttrValue {
        // O(1) lookup for class and style
        if (mem.eql(u8, key, "class")) {
            if (self.class_idx) |idx| {
                return self.entries.items[idx].value;
            }
            return null;
        }
        if (mem.eql(u8, key, "style")) {
            if (self.style_idx) |idx| {
                return self.entries.items[idx].value;
            }
            return null;
        }
        // Linear search for other keys
        for (self.entries.items) |entry| {
            if (mem.eql(u8, entry.key, key)) {
                return entry.value;
            }
        }
        return null;
    }

    /// Find index of a key (O(1) for class/style, O(n) for others)
    fn findKey(self: *const MergedAttrs, key: []const u8) ?usize {
        if (mem.eql(u8, key, "class")) return self.class_idx;
        if (mem.eql(u8, key, "style")) return self.style_idx;
        for (self.entries.items, 0..) |entry, i| {
            if (mem.eql(u8, entry.key, key)) return i;
        }
        return null;
    }
};

pub const MergedAttrEntry = struct {
    key: []const u8,
    value: MergedAttrValue,
};

pub const MergedAttrValue = union(enum) {
    string: []const u8,
    class_array: [][]const u8,
    none,
};

/// Merge two attribute objects.
/// class attributes are combined into arrays.
/// style attributes are concatenated with semicolons.
/// Optimized with O(1) lookups for class/style and branch prediction hints.
pub fn merge(allocator: Allocator, a: []const MergedAttrEntry, b: []const MergedAttrEntry) !MergedAttrs {
    var result = MergedAttrs.init(allocator);
    errdefer result.deinit();

    // Pre-allocate capacity to avoid reallocations
    const total_entries = a.len + b.len;
    if (total_entries > 0) {
        try result.entries.ensureTotalCapacity(allocator, total_entries);
    }

    // Process first object
    for (a) |entry| {
        try mergeEntry(&result, entry);
    }

    // Process second object
    for (b) |entry| {
        try mergeEntry(&result, entry);
    }

    return result;
}

/// Fast key classification for branch prediction
const KeyType = enum { class, style, other };

inline fn classifyKey(key: []const u8) KeyType {
    // Most common case: short keys that aren't class/style
    // Use length check first (branch-friendly, avoids string compare)
    if (key.len == 5) {
        if (key[0] == 'c' and mem.eql(u8, key, "class")) return .class;
        if (key[0] == 's' and mem.eql(u8, key, "style")) return .style;
    }
    return .other;
}

fn mergeEntry(result: *MergedAttrs, entry: MergedAttrEntry) !void {
    const allocator = result.allocator;

    // Branch prediction: classify key type once
    const key_type = classifyKey(entry.key);

    switch (key_type) {
        .class => {
            // O(1) lookup using stored index
            if (result.class_idx) |idx| {
                @branchHint(.likely);
                try mergeClassValue(result, idx, entry.value);
            } else {
                @branchHint(.unlikely);
                try addNewClassEntry(result, entry.value);
            }
        },
        .style => {
            // O(1) lookup using stored index
            if (result.style_idx) |idx| {
                @branchHint(.likely);
                try mergeStyleValue(result, idx, entry.value);
            } else {
                @branchHint(.unlikely);
                try addNewStyleEntry(result, entry.value);
            }
        },
        .other => {
            // Regular attribute - linear search but rare in typical usage
            const found_idx = result.findKey(entry.key);
            if (found_idx) |idx| {
                result.entries.items[idx].value = entry.value;
            } else {
                try result.entries.append(allocator, entry);
            }
        },
    }
}

/// Merge a class value with existing class at index
fn mergeClassValue(result: *MergedAttrs, idx: usize, value: MergedAttrValue) !void {
    const allocator = result.allocator;
    const existing = result.entries.items[idx].value;

    switch (value) {
        .string => |s| {
            switch (existing) {
                .class_array => |arr| {
                    const new_arr = try allocator.alloc([]const u8, arr.len + 1);
                    @memcpy(new_arr[0..arr.len], arr);
                    new_arr[arr.len] = s;
                    try result.owned_class_arrays.append(allocator, new_arr);
                    result.entries.items[idx].value = .{ .class_array = new_arr };
                },
                .string => |existing_s| {
                    const new_arr = try allocator.alloc([]const u8, 2);
                    new_arr[0] = existing_s;
                    new_arr[1] = s;
                    try result.owned_class_arrays.append(allocator, new_arr);
                    result.entries.items[idx].value = .{ .class_array = new_arr };
                },
                .none => {
                    const new_arr = try allocator.alloc([]const u8, 1);
                    new_arr[0] = s;
                    try result.owned_class_arrays.append(allocator, new_arr);
                    result.entries.items[idx].value = .{ .class_array = new_arr };
                },
            }
        },
        .class_array => |arr| {
            switch (existing) {
                .class_array => |existing_arr| {
                    const new_arr = try allocator.alloc([]const u8, existing_arr.len + arr.len);
                    @memcpy(new_arr[0..existing_arr.len], existing_arr);
                    @memcpy(new_arr[existing_arr.len..], arr);
                    try result.owned_class_arrays.append(allocator, new_arr);
                    result.entries.items[idx].value = .{ .class_array = new_arr };
                },
                .string => |existing_s| {
                    const new_arr = try allocator.alloc([]const u8, 1 + arr.len);
                    new_arr[0] = existing_s;
                    @memcpy(new_arr[1..], arr);
                    try result.owned_class_arrays.append(allocator, new_arr);
                    result.entries.items[idx].value = .{ .class_array = new_arr };
                },
                .none => {
                    result.entries.items[idx].value = .{ .class_array = arr };
                },
            }
        },
        .none => {
            // null class, convert existing to array if string
            switch (existing) {
                .string => |existing_s| {
                    const new_arr = try allocator.alloc([]const u8, 1);
                    new_arr[0] = existing_s;
                    try result.owned_class_arrays.append(allocator, new_arr);
                    result.entries.items[idx].value = .{ .class_array = new_arr };
                },
                else => {},
            }
        },
    }
}

/// Add a new class entry (first occurrence)
fn addNewClassEntry(result: *MergedAttrs, value: MergedAttrValue) !void {
    const allocator = result.allocator;
    switch (value) {
        .string => |s| {
            const new_arr = try allocator.alloc([]const u8, 1);
            new_arr[0] = s;
            try result.owned_class_arrays.append(allocator, new_arr);
            result.class_idx = result.entries.items.len;
            try result.entries.append(allocator, .{ .key = "class", .value = .{ .class_array = new_arr } });
        },
        .class_array => |arr| {
            result.class_idx = result.entries.items.len;
            try result.entries.append(allocator, .{ .key = "class", .value = .{ .class_array = arr } });
        },
        .none => {},
    }
}

/// Merge a style value with existing style at index
fn mergeStyleValue(result: *MergedAttrs, idx: usize, value: MergedAttrValue) !void {
    const allocator = result.allocator;
    const existing = result.entries.items[idx].value;

    switch (value) {
        .string => |s| {
            switch (existing) {
                .string => |existing_s| {
                    // Concatenate styles with semicolons
                    const s1 = try ensureTrailingSemicolon(allocator, existing_s);
                    defer allocator.free(s1);
                    const s2 = try ensureTrailingSemicolon(allocator, s);
                    defer allocator.free(s2);

                    var combined: ArrayListUnmanaged(u8) = .{};
                    errdefer combined.deinit(allocator);
                    try combined.appendSlice(allocator, s1);
                    try combined.appendSlice(allocator, s2);
                    const combined_str = try combined.toOwnedSlice(allocator);
                    try result.owned_strings.append(allocator, combined_str);
                    result.entries.items[idx].value = .{ .string = combined_str };
                },
                .none => {
                    const s_with_semi = try ensureTrailingSemicolon(allocator, s);
                    try result.owned_strings.append(allocator, s_with_semi);
                    result.entries.items[idx].value = .{ .string = s_with_semi };
                },
                else => {},
            }
        },
        .none => {
            // null style, ensure existing has trailing semicolon
            switch (existing) {
                .string => |existing_s| {
                    const s_with_semi = try ensureTrailingSemicolon(allocator, existing_s);
                    try result.owned_strings.append(allocator, s_with_semi);
                    result.entries.items[idx].value = .{ .string = s_with_semi };
                },
                else => {},
            }
        },
        else => {},
    }
}

/// Add a new style entry (first occurrence)
fn addNewStyleEntry(result: *MergedAttrs, value: MergedAttrValue) !void {
    const allocator = result.allocator;
    switch (value) {
        .string => |s| {
            const s_with_semi = try ensureTrailingSemicolon(allocator, s);
            try result.owned_strings.append(allocator, s_with_semi);
            result.style_idx = result.entries.items.len;
            try result.entries.append(allocator, .{ .key = "style", .value = .{ .string = s_with_semi } });
        },
        .none => {},
        else => {},
    }
}

// ============================================================================
// Rethrow function for error handling
// ============================================================================

pub const PugError = struct {
    message: []const u8,
    filename: ?[]const u8,
    line: usize,
    src: ?[]const u8,
    formatted_message: ?[]const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, err_message: []const u8, filename: ?[]const u8, line: usize, src: ?[]const u8) !PugError {
        var pug_err = PugError{
            .message = err_message,
            .filename = filename,
            .line = line,
            .src = src,
            .formatted_message = null,
            .allocator = allocator,
        };

        // Format the error message with context
        if (src) |s| {
            pug_err.formatted_message = try formatErrorMessage(allocator, err_message, filename, line, s);
        }

        return pug_err;
    }

    pub fn deinit(self: *PugError) void {
        if (self.formatted_message) |msg| {
            self.allocator.free(msg);
        }
    }

    pub fn getMessage(self: *const PugError) []const u8 {
        if (self.formatted_message) |msg| {
            return msg;
        }
        return self.message;
    }
};

fn formatErrorMessage(allocator: Allocator, err_message: []const u8, filename: ?[]const u8, line: usize, src: []const u8) ![]const u8 {
    var result: ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    // Add filename and line
    if (filename) |f| {
        try result.appendSlice(allocator, f);
    }
    try result.append(allocator, ':');

    // Format line number
    var line_buf: [32]u8 = undefined;
    const line_str = std.fmt.bufPrint(&line_buf, "{d}", .{line}) catch return error.FormatError;
    try result.appendSlice(allocator, line_str);
    try result.append(allocator, '\n');

    // Split source into lines and show context
    var lines_iter = mem.splitSequence(u8, src, "\n");
    var line_num: usize = 1;
    while (lines_iter.next()) |src_line| {
        // Show lines around the error (context window)
        const start_line = if (line > 3) line - 3 else 1;
        const end_line = line + 3;

        if (line_num >= start_line and line_num <= end_line) {
            // Line number prefix
            var num_buf: [32]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d: >4}| ", .{line_num}) catch return error.FormatError;
            try result.appendSlice(allocator, num_str);
            try result.appendSlice(allocator, src_line);
            try result.append(allocator, '\n');
        }

        line_num += 1;

        if (line_num > end_line) break;
    }

    // Add the original error message
    try result.appendSlice(allocator, err_message);

    return try result.toOwnedSlice(allocator);
}

/// Rethrow an error with file context.
/// Creates a PugError with formatted message including source line context.
pub fn rethrow(allocator: Allocator, err_message: []const u8, filename: ?[]const u8, line: usize, src: ?[]const u8) !PugError {
    return try PugError.init(allocator, err_message, filename, line, src);
}

// ============================================================================
// Tests
// ============================================================================

test "escape - no escaping needed" {
    const allocator = std.testing.allocator;
    const result = try escape(allocator, "foo");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("foo", result);
}

test "escape - less than" {
    const allocator = std.testing.allocator;
    const result = try escape(allocator, "foo<bar");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("foo&lt;bar", result);
}

test "escape - ampersand and less than" {
    const allocator = std.testing.allocator;
    const result = try escape(allocator, "foo&<bar");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("foo&amp;&lt;bar", result);
}

test "escape - all special chars" {
    const allocator = std.testing.allocator;
    const result = try escape(allocator, "foo&<>\"bar\"");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("foo&amp;&lt;&gt;&quot;bar&quot;", result);
}

test "style - empty string" {
    const allocator = std.testing.allocator;
    const result = try style(allocator, .{ .string = "" });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "style - none" {
    const allocator = std.testing.allocator;
    const result = try style(allocator, .none);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "style - string passthrough" {
    const allocator = std.testing.allocator;
    const result = try style(allocator, .{ .string = "foo: bar" });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("foo: bar", result);
}

test "style - object" {
    const allocator = std.testing.allocator;
    const props = [_]StyleProperty{
        .{ .name = "foo", .value = "bar" },
    };
    const result = try style(allocator, .{ .object = &props });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("foo:bar;", result);
}

test "style - object multiple" {
    const allocator = std.testing.allocator;
    const props = [_]StyleProperty{
        .{ .name = "foo", .value = "bar" },
        .{ .name = "baz", .value = "bash" },
    };
    const result = try style(allocator, .{ .object = &props });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("foo:bar;baz:bash;", result);
}

test "attr - boolean true terse" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .{ .boolean = true }, true, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" key", result);
}

test "attr - boolean true not terse" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .{ .boolean = true }, true, false);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" key=\"key\"", result);
}

test "attr - boolean false" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .{ .boolean = false }, true, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "attr - none" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .none, true, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "attr - number" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .{ .number = 500 }, true, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" key=\"500\"", result);
}

test "attr - string" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .{ .string = "foo" }, false, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" key=\"foo\"", result);
}

test "attr - string escaped" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .{ .string = "foo>bar" }, true, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" key=\"foo&gt;bar\"", result);
}

test "attr - empty class" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "class", .{ .string = "" }, false, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "attr - empty style" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "style", .{ .string = "" }, false, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "classes - string array" {
    const allocator = std.testing.allocator;
    const items = [_]ClassValue{
        .{ .string = "foo" },
        .{ .string = "bar" },
    };
    const result = try classes(allocator, .{ .array = &items }, null);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("foo bar", result);
}

test "classes - nested array" {
    const allocator = std.testing.allocator;
    const inner1 = [_]ClassValue{
        .{ .string = "foo" },
        .{ .string = "bar" },
    };
    const inner2 = [_]ClassValue{
        .{ .string = "baz" },
        .{ .string = "bash" },
    };
    const items = [_]ClassValue{
        .{ .array = &inner1 },
        .{ .array = &inner2 },
    };
    const result = try classes(allocator, .{ .array = &items }, null);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("foo bar baz bash", result);
}

test "classes - object" {
    const allocator = std.testing.allocator;
    const conditions = [_]ClassCondition{
        .{ .name = "baz", .condition = true },
        .{ .name = "bash", .condition = false },
    };
    const result = try classes(allocator, .{ .object = &conditions }, null);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("baz", result);
}

test "classes - mixed array and object" {
    const allocator = std.testing.allocator;
    const inner = [_]ClassValue{
        .{ .string = "foo" },
        .{ .string = "bar" },
    };
    const conditions = [_]ClassCondition{
        .{ .name = "baz", .condition = true },
        .{ .name = "bash", .condition = false },
    };
    const items = [_]ClassValue{
        .{ .array = &inner },
        .{ .object = &conditions },
    };
    const result = try classes(allocator, .{ .array = &items }, null);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("foo bar baz", result);
}

test "classes - with escaping" {
    const allocator = std.testing.allocator;
    const inner = [_]ClassValue{
        .{ .string = "fo<o" },
        .{ .string = "bar" },
    };
    const conditions = [_]ClassCondition{
        .{ .name = "ba>z", .condition = true },
        .{ .name = "bash", .condition = false },
    };
    const items = [_]ClassValue{
        .{ .array = &inner },
        .{ .object = &conditions },
    };
    const escaping = [_]bool{ true, false };
    const result = try classes(allocator, .{ .array = &items }, &escaping);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("fo&lt;o bar ba>z", result);
}

test "attrs - simple" {
    const allocator = std.testing.allocator;
    const entries = [_]AttrEntry{
        .{ .key = "foo", .value = .{ .string = "bar" } },
    };
    const result = try attrs(allocator, &entries, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" foo=\"bar\"", result);
}

test "attrs - multiple" {
    const allocator = std.testing.allocator;
    const entries = [_]AttrEntry{
        .{ .key = "foo", .value = .{ .string = "bar" } },
        .{ .key = "hoo", .value = .{ .string = "boo" } },
    };
    const result = try attrs(allocator, &entries, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" foo=\"bar\" hoo=\"boo\"", result);
}

test "attrs - with class" {
    const allocator = std.testing.allocator;
    const class_items = [_]ClassValue{
        .{ .string = "foo" },
        .{ .object = &[_]ClassCondition{.{ .name = "bar", .condition = true }} },
    };
    const entries = [_]AttrEntry{
        .{ .key = "class", .value = .none, .is_class = true, .class_value = .{ .array = &class_items } },
        .{ .key = "foo", .value = .{ .string = "bar" } },
    };
    const result = try attrs(allocator, &entries, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" class=\"foo bar\" foo=\"bar\"", result);
}

test "attrs - with style object" {
    const allocator = std.testing.allocator;
    const style_props = [_]StyleProperty{
        .{ .name = "foo", .value = "bar" },
    };
    const entries = [_]AttrEntry{
        .{ .key = "style", .value = .none, .is_style = true, .style_value = .{ .object = &style_props } },
    };
    const result = try attrs(allocator, &entries, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" style=\"foo:bar;\"", result);
}

// ============================================================================
// Additional tests from index.test.js
// ============================================================================

// attr tests - boolean combinations
test "attr - boolean true escaped=false terse=true" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .{ .boolean = true }, false, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" key", result);
}

test "attr - boolean true escaped=true terse=false" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .{ .boolean = true }, true, false);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" key=\"key\"", result);
}

test "attr - boolean true escaped=false terse=false" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .{ .boolean = true }, false, false);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" key=\"key\"", result);
}

test "attr - boolean false escaped=false terse=true" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .{ .boolean = false }, false, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "attr - boolean false escaped=true terse=false" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .{ .boolean = false }, true, false);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "attr - boolean false escaped=false terse=false" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .{ .boolean = false }, false, false);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "attr - none escaped=false terse=true" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .none, false, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "attr - none escaped=true terse=false" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .none, true, false);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "attr - none escaped=false terse=false" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .none, false, false);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

// attr number combinations
test "attr - number escaped=false terse=true" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .{ .number = 500 }, false, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" key=\"500\"", result);
}

test "attr - number escaped=true terse=false" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .{ .number = 500 }, true, false);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" key=\"500\"", result);
}

test "attr - number escaped=false terse=false" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .{ .number = 500 }, false, false);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" key=\"500\"", result);
}

// attr string combinations
test "attr - string escaped=true terse=true" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .{ .string = "foo" }, true, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" key=\"foo\"", result);
}

test "attr - string escaped=true terse=false" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .{ .string = "foo" }, true, false);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" key=\"foo\"", result);
}

test "attr - string escaped=false terse=false" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .{ .string = "foo" }, false, false);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" key=\"foo\"", result);
}

test "attr - string with > escaped=false" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .{ .string = "foo>bar" }, false, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" key=\"foo>bar\"", result);
}

test "attr - string with > escaped=true terse=false" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .{ .string = "foo>bar" }, true, false);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" key=\"foo&gt;bar\"", result);
}

test "attr - string with > escaped=false terse=false" {
    const allocator = std.testing.allocator;
    const result = try attr(allocator, "key", .{ .string = "foo>bar" }, false, false);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" key=\"foo>bar\"", result);
}

// attrs tests
test "attrs - empty string value" {
    const allocator = std.testing.allocator;
    const entries = [_]AttrEntry{
        .{ .key = "foo", .value = .{ .string = "" } },
    };
    const result = try attrs(allocator, &entries, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" foo=\"\"", result);
}

test "attrs - empty class" {
    const allocator = std.testing.allocator;
    const entries = [_]AttrEntry{
        .{ .key = "class", .value = .{ .string = "" } },
    };
    const result = try attrs(allocator, &entries, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "attrs - style string" {
    const allocator = std.testing.allocator;
    const entries = [_]AttrEntry{
        .{ .key = "style", .value = .{ .string = "foo: bar;" } },
    };
    const result = try attrs(allocator, &entries, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" style=\"foo: bar;\"", result);
}

test "attrs - class first then foo" {
    const allocator = std.testing.allocator;
    const class_items = [_]ClassValue{
        .{ .string = "foo" },
        .{ .object = &[_]ClassCondition{.{ .name = "bar", .condition = true }} },
    };
    const entries = [_]AttrEntry{
        .{ .key = "class", .value = .none, .is_class = true, .class_value = .{ .array = &class_items } },
        .{ .key = "foo", .value = .{ .string = "bar" } },
    };
    const result = try attrs(allocator, &entries, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" class=\"foo bar\" foo=\"bar\"", result);
}

test "attrs - foo then class reordered" {
    const allocator = std.testing.allocator;
    const class_items = [_]ClassValue{
        .{ .string = "foo" },
        .{ .object = &[_]ClassCondition{.{ .name = "bar", .condition = true }} },
    };
    const entries = [_]AttrEntry{
        .{ .key = "foo", .value = .{ .string = "bar" } },
        .{ .key = "class", .value = .none, .is_class = true, .class_value = .{ .array = &class_items } },
    };
    const result = try attrs(allocator, &entries, false);
    defer allocator.free(result);
    // Class should come first even if listed second
    try std.testing.expectEqualStrings(" class=\"foo bar\" foo=\"bar\"", result);
}

// style tests
test "style - string with trailing semicolon" {
    const allocator = std.testing.allocator;
    const result = try style(allocator, .{ .string = "foo: bar;" });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("foo: bar;", result);
}

// escape tests - additional
test "escape - ampersand less than greater than" {
    const allocator = std.testing.allocator;
    const result = try escape(allocator, "foo&<>bar");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("foo&amp;&lt;&gt;bar", result);
}

test "escape - ampersand less than greater than quote" {
    const allocator = std.testing.allocator;
    const result = try escape(allocator, "foo&<>\"bar");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("foo&amp;&lt;&gt;&quot;bar", result);
}

// ============================================================================
// Merge tests from index.test.js
// ============================================================================

test "merge - simple merge" {
    const allocator = std.testing.allocator;
    const a = [_]MergedAttrEntry{
        .{ .key = "foo", .value = .{ .string = "bar" } },
    };
    const b = [_]MergedAttrEntry{
        .{ .key = "baz", .value = .{ .string = "bash" } },
    };
    var result = try merge(allocator, &a, &b);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.entries.items.len);
    try std.testing.expectEqualStrings("bar", result.get("foo").?.string);
    try std.testing.expectEqualStrings("bash", result.get("baz").?.string);
}

test "merge - class string + class string" {
    const allocator = std.testing.allocator;
    const a = [_]MergedAttrEntry{
        .{ .key = "class", .value = .{ .string = "bar" } },
    };
    const b = [_]MergedAttrEntry{
        .{ .key = "class", .value = .{ .string = "bash" } },
    };
    var result = try merge(allocator, &a, &b);
    defer result.deinit();

    const class_val = result.get("class").?;
    try std.testing.expectEqual(@as(usize, 2), class_val.class_array.len);
    try std.testing.expectEqualStrings("bar", class_val.class_array[0]);
    try std.testing.expectEqualStrings("bash", class_val.class_array[1]);
}

test "merge - class array + class string" {
    const allocator = std.testing.allocator;
    const class_arr = [_][]const u8{"bar"};
    const a = [_]MergedAttrEntry{
        .{ .key = "class", .value = .{ .class_array = @constCast(&class_arr) } },
    };
    const b = [_]MergedAttrEntry{
        .{ .key = "class", .value = .{ .string = "bash" } },
    };
    var result = try merge(allocator, &a, &b);
    defer result.deinit();

    const class_val = result.get("class").?;
    try std.testing.expectEqual(@as(usize, 2), class_val.class_array.len);
    try std.testing.expectEqualStrings("bar", class_val.class_array[0]);
    try std.testing.expectEqualStrings("bash", class_val.class_array[1]);
}

test "merge - class string + class array" {
    const allocator = std.testing.allocator;
    const class_arr = [_][]const u8{"bash"};
    const a = [_]MergedAttrEntry{
        .{ .key = "class", .value = .{ .string = "bar" } },
    };
    const b = [_]MergedAttrEntry{
        .{ .key = "class", .value = .{ .class_array = @constCast(&class_arr) } },
    };
    var result = try merge(allocator, &a, &b);
    defer result.deinit();

    const class_val = result.get("class").?;
    try std.testing.expectEqual(@as(usize, 2), class_val.class_array.len);
    try std.testing.expectEqualStrings("bar", class_val.class_array[0]);
    try std.testing.expectEqualStrings("bash", class_val.class_array[1]);
}

test "merge - class string + class null" {
    const allocator = std.testing.allocator;
    const a = [_]MergedAttrEntry{
        .{ .key = "class", .value = .{ .string = "bar" } },
    };
    const b = [_]MergedAttrEntry{
        .{ .key = "class", .value = .none },
    };
    var result = try merge(allocator, &a, &b);
    defer result.deinit();

    const class_val = result.get("class").?;
    try std.testing.expectEqual(@as(usize, 1), class_val.class_array.len);
    try std.testing.expectEqualStrings("bar", class_val.class_array[0]);
}

test "merge - class null + class array" {
    const allocator = std.testing.allocator;
    const class_arr = [_][]const u8{"bar"};
    const a = [_]MergedAttrEntry{
        .{ .key = "class", .value = .none },
    };
    const b = [_]MergedAttrEntry{
        .{ .key = "class", .value = .{ .class_array = @constCast(&class_arr) } },
    };
    var result = try merge(allocator, &a, &b);
    defer result.deinit();

    const class_val = result.get("class").?;
    try std.testing.expectEqual(@as(usize, 1), class_val.class_array.len);
    try std.testing.expectEqualStrings("bar", class_val.class_array[0]);
}

test "merge - empty + class array" {
    const allocator = std.testing.allocator;
    const class_arr = [_][]const u8{"bar"};
    const a = [_]MergedAttrEntry{};
    const b = [_]MergedAttrEntry{
        .{ .key = "class", .value = .{ .class_array = @constCast(&class_arr) } },
    };
    var result = try merge(allocator, &a, &b);
    defer result.deinit();

    const class_val = result.get("class").?;
    try std.testing.expectEqual(@as(usize, 1), class_val.class_array.len);
    try std.testing.expectEqualStrings("bar", class_val.class_array[0]);
}

test "merge - class array + empty" {
    const allocator = std.testing.allocator;
    const class_arr = [_][]const u8{"bar"};
    const a = [_]MergedAttrEntry{
        .{ .key = "class", .value = .{ .class_array = @constCast(&class_arr) } },
    };
    const b = [_]MergedAttrEntry{};
    var result = try merge(allocator, &a, &b);
    defer result.deinit();

    const class_val = result.get("class").?;
    try std.testing.expectEqual(@as(usize, 1), class_val.class_array.len);
    try std.testing.expectEqualStrings("bar", class_val.class_array[0]);
}

test "merge - style string + style string" {
    const allocator = std.testing.allocator;
    const a = [_]MergedAttrEntry{
        .{ .key = "style", .value = .{ .string = "foo:bar" } },
    };
    const b = [_]MergedAttrEntry{
        .{ .key = "style", .value = .{ .string = "baz:bash" } },
    };
    var result = try merge(allocator, &a, &b);
    defer result.deinit();

    const style_val = result.get("style").?;
    try std.testing.expectEqualStrings("foo:bar;baz:bash;", style_val.string);
}

test "merge - style with semicolon + style string" {
    const allocator = std.testing.allocator;
    const a = [_]MergedAttrEntry{
        .{ .key = "style", .value = .{ .string = "foo:bar;" } },
    };
    const b = [_]MergedAttrEntry{
        .{ .key = "style", .value = .{ .string = "baz:bash" } },
    };
    var result = try merge(allocator, &a, &b);
    defer result.deinit();

    const style_val = result.get("style").?;
    try std.testing.expectEqualStrings("foo:bar;baz:bash;", style_val.string);
}

test "merge - style string + style null" {
    const allocator = std.testing.allocator;
    const a = [_]MergedAttrEntry{
        .{ .key = "style", .value = .{ .string = "foo:bar" } },
    };
    const b = [_]MergedAttrEntry{
        .{ .key = "style", .value = .none },
    };
    var result = try merge(allocator, &a, &b);
    defer result.deinit();

    const style_val = result.get("style").?;
    try std.testing.expectEqualStrings("foo:bar;", style_val.string);
}

test "merge - style with semicolon + style null" {
    const allocator = std.testing.allocator;
    const a = [_]MergedAttrEntry{
        .{ .key = "style", .value = .{ .string = "foo:bar;" } },
    };
    const b = [_]MergedAttrEntry{
        .{ .key = "style", .value = .none },
    };
    var result = try merge(allocator, &a, &b);
    defer result.deinit();

    const style_val = result.get("style").?;
    try std.testing.expectEqualStrings("foo:bar;", style_val.string);
}

test "merge - style null + style string" {
    const allocator = std.testing.allocator;
    const a = [_]MergedAttrEntry{
        .{ .key = "style", .value = .none },
    };
    const b = [_]MergedAttrEntry{
        .{ .key = "style", .value = .{ .string = "baz:bash" } },
    };
    var result = try merge(allocator, &a, &b);
    defer result.deinit();

    const style_val = result.get("style").?;
    try std.testing.expectEqualStrings("baz:bash;", style_val.string);
}

test "merge - empty + style string" {
    const allocator = std.testing.allocator;
    const a = [_]MergedAttrEntry{};
    const b = [_]MergedAttrEntry{
        .{ .key = "style", .value = .{ .string = "baz:bash" } },
    };
    var result = try merge(allocator, &a, &b);
    defer result.deinit();

    const style_val = result.get("style").?;
    try std.testing.expectEqualStrings("baz:bash;", style_val.string);
}

// ============================================================================
// Rethrow tests
// ============================================================================

test "rethrow - basic error without src" {
    const allocator = std.testing.allocator;
    var pug_err = try rethrow(allocator, "test error", "foo.pug", 3, null);
    defer pug_err.deinit();

    try std.testing.expectEqualStrings("test error", pug_err.getMessage());
    try std.testing.expectEqualStrings("foo.pug", pug_err.filename.?);
    try std.testing.expectEqual(@as(usize, 3), pug_err.line);
}

test "rethrow - error with src shows context" {
    const allocator = std.testing.allocator;
    var pug_err = try rethrow(allocator, "test error", "foo.pug", 1, "hello world");
    defer pug_err.deinit();

    const msg = pug_err.getMessage();
    // Should contain filename:line, source line, and error message
    try std.testing.expect(mem.indexOf(u8, msg, "foo.pug:1") != null);
    try std.testing.expect(mem.indexOf(u8, msg, "hello world") != null);
    try std.testing.expect(mem.indexOf(u8, msg, "test error") != null);
}
