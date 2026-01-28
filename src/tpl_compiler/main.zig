// CLI tool to compile .pug templates to Zig code
//
// Usage:
//   pug-compile <input.pug> <output.zig>
//   pug-compile --dir views --out generated

const std = @import("std");
const pugz = @import("pugz");
const zig_codegen = @import("zig_codegen.zig");
const fs = std.fs;
const mem = std.mem;
const pug = pugz.pug;
const template = pugz.template;
const view_engine = pugz.view_engine;
const mixin = pugz.mixin;
const Codegen = zig_codegen.Codegen;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Memory leak detected!\n", .{});
        }
    }
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        try printUsage();
        return error.InvalidArgs;
    }

    const mode = args[1];

    if (mem.eql(u8, mode, "--dir")) {
        // Directory mode: compile all .pug files in a directory recursively
        if (args.len < 5) {
            try printUsage();
            return error.InvalidArgs;
        }

        const input_dir = args[2];
        if (!mem.eql(u8, args[3], "--out")) {
            try printUsage();
            return error.InvalidArgs;
        }
        const output_dir = args[4];

        try compileDirectory(allocator, input_dir, output_dir);
    } else {
        // Single file mode
        if (args.len < 3) {
            try printUsage();
            return error.InvalidArgs;
        }

        const input_file = args[1];
        const output_file = args[2];

        try compileSingleFile(allocator, input_file, output_file, null);
    }

    std.debug.print("Compilation complete!\n", .{});
}

fn printUsage() !void {
    std.debug.print(
        \\Usage:
        \\  pug-compile <input.pug> <output.zig>         Compile single file
        \\  pug-compile --dir <dir> --out <output>       Compile directory recursively
        \\
        \\Examples:
        \\  pug-compile home.pug home.zig
        \\  pug-compile --dir views --out generated      (compiles all .pug files in views/)
        \\  pug-compile --dir pages --out generated      (compiles all .pug files in pages/)
        \\
        \\Directory mode compiles ALL .pug files found recursively in the input directory.
        \\The input directory is used as the views root for resolving extends/includes.
        \\
    , .{});
}

fn compileSingleFile(allocator: mem.Allocator, input_path: []const u8, output_path: []const u8, views_dir: ?[]const u8) !void {
    std.debug.print("Compiling {s} -> {s}\n", .{ input_path, output_path });

    // Use ViewEngine to properly resolve extends, includes, and mixins at build time
    const view_basedir = views_dir orelse if (fs.path.dirname(input_path)) |dir| dir else ".";

    // Initialize ViewEngine with views directory
    var engine = view_engine.ViewEngine.init(.{
        .views_dir = view_basedir,
    });
    defer engine.deinit();

    // Initialize mixin registry
    var registry = mixin.MixinRegistry.init(allocator);
    defer registry.deinit();

    // Get the template path relative to views_dir
    const template_path = if (mem.startsWith(u8, input_path, view_basedir)) blk: {
        const rel = input_path[view_basedir.len..];
        // Skip leading slash
        break :blk if (rel.len > 0 and rel[0] == '/') rel[1..] else rel;
    } else input_path;

    // Remove .pug extension if present
    const template_name = if (mem.endsWith(u8, template_path, ".pug"))
        template_path[0 .. template_path.len - 4]
    else
        template_path;

    // Parse template with full includes/extends resolution
    // This loads all parent templates and includes, processes extends, and collects mixins
    const final_ast = try engine.parseWithIncludes(allocator, template_name, &registry);
    // Note: Don't free final_ast as it's managed by the ViewEngine
    // The normalized_source is intentionally leaked as AST strings point into it
    // Both will be cleaned up by the allocator when the CLI exits

    // Extract field names from final resolved AST
    const fields = try zig_codegen.extractFieldNames(allocator, final_ast);
    defer {
        for (fields) |field| allocator.free(field);
        allocator.free(fields);
    }

    std.debug.print("  Found {d} data fields: ", .{fields.len});
    for (fields, 0..) |field, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{field});
    }
    std.debug.print("\n", .{});

    // Generate function name from file path (always "render")
    const function_name = "render"; // Always use "render", no allocation needed

    // Generate Zig code from final resolved AST
    var codegen = Codegen.init(allocator);
    defer codegen.deinit();

    const zig_code = try codegen.generate(final_ast, function_name, fields);
    defer allocator.free(zig_code);

    // Write output file
    try fs.cwd().writeFile(.{ .sub_path = output_path, .data = zig_code });

    std.debug.print("  Generated {d} bytes of Zig code\n", .{zig_code.len});
}

fn compileDirectory(allocator: mem.Allocator, input_dir: []const u8, output_dir: []const u8) !void {
    std.debug.print("Compiling directory {s} -> {s}\n", .{ input_dir, output_dir });
    std.debug.print("  Compiling all .pug files recursively\n", .{});

    // Create output directory if it doesn't exist
    fs.cwd().makeDir(output_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Find all .pug files in input_dir recursively
    const pug_files = try findPugFiles(allocator, input_dir);
    defer {
        for (pug_files) |file| allocator.free(file);
        allocator.free(pug_files);
    }

    std.debug.print("Found {d} templates\n", .{pug_files.len});

    // Track compiled templates for root.zig generation
    var template_map = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = template_map.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        template_map.deinit();
    }

    // Compile each file
    for (pug_files) |pug_file| {
        std.debug.print("Processing: {s}\n", .{pug_file});

        // Generate output path (relative to input_dir)
        const rel_path = if (mem.startsWith(u8, pug_file, input_dir))
            pug_file[input_dir.len..]
        else
            pug_file;

        // Skip leading slash
        const trimmed_rel = if (rel_path.len > 0 and rel_path[0] == '/')
            rel_path[1..]
        else
            rel_path;

        // Replace .pug with .zig
        const output_rel = try mem.replaceOwned(u8, allocator, trimmed_rel, ".pug", ".zig");
        defer allocator.free(output_rel);

        const output_path = try fs.path.join(allocator, &.{ output_dir, output_rel });
        defer allocator.free(output_path);

        // Create parent directories for output
        if (fs.path.dirname(output_path)) |parent| {
            try fs.cwd().makePath(parent);
        }

        // Compile the file (pass input_dir as views_dir for includes/extends resolution)
        compileSingleFile(allocator, pug_file, output_path, input_dir) catch |err| {
            std.debug.print("  ERROR: Failed to compile {s}: {}\n", .{ pug_file, err });
            continue;
        };

        // Track for root.zig: template name -> output file path
        // Convert "pages/home.pug" -> "pages_home"
        const template_name = try makeTemplateName(allocator, trimmed_rel);
        const output_rel_copy = try allocator.dupe(u8, output_rel);

        try template_map.put(template_name, output_rel_copy);
    }

    // Copy helpers.zig to generated directory
    try copyHelpersZig(allocator, output_dir);

    // Generate root.zig
    try generateRootZig(allocator, output_dir, &template_map);
}

/// Copy helpers.zig to the generated directory so generated templates can import it
fn copyHelpersZig(allocator: mem.Allocator, output_dir: []const u8) !void {
    const helpers_source = @embedFile("helpers_template.zig");

    const output_path = try fs.path.join(allocator, &.{ output_dir, "helpers.zig" });
    defer allocator.free(output_path);

    try fs.cwd().writeFile(.{ .sub_path = output_path, .data = helpers_source });
    std.debug.print("Copied helpers.zig to {s}\n", .{output_path});
}

/// Generate root.zig that exports all compiled templates
fn generateRootZig(allocator: mem.Allocator, output_dir: []const u8, template_map: *std.StringHashMap([]const u8)) !void {
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(allocator);

    try output.appendSlice(allocator, "// Auto-generated by pug-compile\n");
    try output.appendSlice(allocator, "// This file exports all compiled templates\n\n");

    // Sort template names for consistent output
    var names: std.ArrayListUnmanaged([]const u8) = .{};
    defer names.deinit(allocator);

    var iter = template_map.keyIterator();
    while (iter.next()) |key| {
        try names.append(allocator, key.*);
    }

    const names_slice = try names.toOwnedSlice(allocator);
    defer allocator.free(names_slice);

    std.mem.sort([]const u8, names_slice, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // Generate imports and exports
    for (names_slice) |name| {
        const file_path = template_map.get(name).?;

        // Remove .zig extension for import
        const import_path = file_path[0 .. file_path.len - 4];

        try output.appendSlice(allocator, "pub const ");
        if (std.ascii.isAlphabetic(name[0])) {
            try output.appendSlice(allocator, name);
        } else {
            const a = try allocator.alloc(u8, name.len + 1);
            defer allocator.free(a);
            @memcpy(a[0..1], "_");
            @memcpy(a[1..], name);
            try output.appendSlice(allocator, a);
        }

        try output.appendSlice(allocator, " = @import(\"");
        // Use ./ prefix for relative file imports
        try output.appendSlice(allocator, "./");
        try output.appendSlice(allocator, import_path);
        try output.appendSlice(allocator, ".zig\");\n");
    }

    // Write root.zig
    const root_path = try fs.path.join(allocator, &.{ output_dir, "root.zig" });
    defer allocator.free(root_path);

    try fs.cwd().writeFile(.{ .sub_path = root_path, .data = output.items });
    std.debug.print("\nGenerated {s} with {d} templates\n", .{ root_path, names_slice.len });
}

/// Find all .pug files in a directory recursively
fn findPugFiles(allocator: mem.Allocator, dir_path: []const u8) ![][]const u8 {
    var results: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (results.items) |item| allocator.free(item);
        results.deinit(allocator);
    }

    try findPugFilesRecursive(allocator, dir_path, &results);

    return results.toOwnedSlice(allocator);
}

fn findPugFilesRecursive(allocator: mem.Allocator, dir_path: []const u8, results: *std.ArrayListUnmanaged([]const u8)) !void {
    var dir = try fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const full_path = try fs.path.join(allocator, &.{ dir_path, entry.name });
        errdefer allocator.free(full_path);

        switch (entry.kind) {
            .file => {
                if (mem.endsWith(u8, entry.name, ".pug")) {
                    try results.append(allocator, full_path);
                } else {
                    allocator.free(full_path);
                }
            },
            .directory => {
                // Recurse into subdirectory
                try findPugFilesRecursive(allocator, full_path, results);
                allocator.free(full_path);
            },
            else => {
                allocator.free(full_path);
            },
        }
    }
}

/// Convert file path to valid Zig function name
/// Examples:
///   "home.pug" -> "render"
///   "pages/home.pug" -> "render"
///   "layouts/main.pug" -> "render"
fn makeFunctionName(allocator: mem.Allocator, path: []const u8) ![]const u8 {
    _ = allocator;
    _ = path;

    // Always use "render" as the function name
    // Each template is in its own file, so the file name provides the namespace
    return "render";
}

/// Convert template path to valid Zig identifier
/// Examples:
///   "home.pug" -> "home"
///   "pages/home.pug" -> "pages_home"
///   "layouts/main.pug" -> "layouts_main"
fn makeTemplateName(allocator: mem.Allocator, path: []const u8) ![]const u8 {
    // Remove .pug extension
    const without_ext = if (mem.endsWith(u8, path, ".pug"))
        path[0 .. path.len - 4]
    else
        path;

    // Replace / and - with _
    var result: std.ArrayListUnmanaged(u8) = .{};
    defer result.deinit(allocator);

    for (without_ext) |c| {
        if (c == '/' or c == '-' or c == '.') {
            try result.append(allocator, '_');
        } else {
            try result.append(allocator, c);
        }
    }

    return result.toOwnedSlice(allocator);
}
