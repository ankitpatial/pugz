// Build step for compiling Pug templates at build time
//
// Usage in build.zig:
//   const pugz = @import("pugz");
//   const compile_step = pugz.addCompileStep(b, .{
//       .name = "compile-templates",
//       .source_dirs = &.{"src/views", "src/pages"},
//       .output_dir = "generated",
//   });
//   exe.step.dependOn(&compile_step.step);

const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Build = std.Build;
const Step = Build.Step;
const GeneratedFile = Build.GeneratedFile;

const zig_codegen = @import("tpl_compiler/zig_codegen.zig");
const view_engine = @import("view_engine.zig");
const mixin = @import("mixin.zig");

pub const CompileOptions = struct {
    /// Name for the compile step
    name: []const u8 = "compile-pug-templates",

    /// Source directories containing .pug files (can be multiple)
    source_dirs: []const []const u8,

    /// Output directory for generated .zig files
    output_dir: []const u8,

    /// Base directory for resolving includes/extends
    /// If not specified, automatically inferred as the common parent of all source_dirs
    /// e.g., ["views/pages", "views/partials"] -> "views"
    views_root: ?[]const u8 = null,
};

pub const CompileStep = struct {
    step: Step,
    options: CompileOptions,
    output_file: GeneratedFile,

    pub fn create(owner: *Build, options: CompileOptions) *CompileStep {
        const self = owner.allocator.create(CompileStep) catch @panic("OOM");

        self.* = .{
            .step = Step.init(.{
                .id = .custom,
                .name = options.name,
                .owner = owner,
                .makeFn = make,
            }),
            .options = options,
            .output_file = .{ .step = &self.step },
        };

        return self;
    }

    fn make(step: *Step, options: Step.MakeOptions) !void {
        _ = options;
        const self: *CompileStep = @fieldParentPtr("step", step);
        const b = step.owner;
        const allocator = b.allocator;

        // Use output_dir relative to project root (not zig-out/)
        const output_path = b.pathFromRoot(self.options.output_dir);
        try fs.cwd().makePath(output_path);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // Track all compiled templates
        var all_templates = std.StringHashMap([]const u8).init(allocator);
        defer {
            var iter = all_templates.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            all_templates.deinit();
        }

        // Determine views_root (common parent directory for all templates)
        const views_root = if (self.options.views_root) |root|
            b.pathFromRoot(root)
        else if (self.options.source_dirs.len > 0) blk: {
            // Infer common parent from all source_dirs
            // e.g., ["views/pages", "views/partials"] -> "views"
            const first_dir = b.pathFromRoot(self.options.source_dirs[0]);
            const common_parent = fs.path.dirname(first_dir) orelse first_dir;

            // Verify all source_dirs share this parent
            for (self.options.source_dirs) |dir| {
                const abs_dir = b.pathFromRoot(dir);
                if (!mem.startsWith(u8, abs_dir, common_parent)) {
                    // Dirs don't share common parent, use first dir's parent
                    break :blk common_parent;
                }
            }

            break :blk common_parent;
        } else b.pathFromRoot(".");

        // Compile each source directory
        for (self.options.source_dirs) |source_dir| {
            const abs_source_dir = b.pathFromRoot(source_dir);

            std.debug.print("Compiling templates from {s}...\n", .{source_dir});

            try compileDirectory(
                allocator,
                arena_allocator,
                abs_source_dir,
                views_root,
                output_path,
                &all_templates,
            );
        }

        // Generate root.zig
        try generateRootZig(allocator, output_path, &all_templates);

        // Copy helpers.zig
        try copyHelpersZig(allocator, output_path);

        std.debug.print("Compiled {d} templates to {s}/root.zig\n", .{ all_templates.count(), output_path });

        // Set the output file path
        self.output_file.path = try fs.path.join(allocator, &.{ output_path, "root.zig" });
    }

    pub fn getOutput(self: *CompileStep) Build.LazyPath {
        return .{ .generated = .{ .file = &self.output_file } };
    }
};

fn compileDirectory(
    allocator: mem.Allocator,
    arena_allocator: mem.Allocator,
    input_dir: []const u8,
    views_root: []const u8,
    output_dir: []const u8,
    template_map: *std.StringHashMap([]const u8),
) !void {
    // Find all .pug files recursively
    const pug_files = try findPugFiles(arena_allocator, input_dir);

    // Initialize ViewEngine with views_root for resolving includes/extends
    var engine = view_engine.ViewEngine.init(.{
        .views_dir = views_root,
    });
    defer engine.deinit();

    // Initialize mixin registry
    var registry = mixin.MixinRegistry.init(arena_allocator);
    defer registry.deinit();

    // Compile each file
    for (pug_files) |pug_file| {
        compileSingleFile(
            allocator,
            arena_allocator,
            &engine,
            &registry,
            pug_file,
            views_root,
            output_dir,
            template_map,
        ) catch |err| {
            std.debug.print("  ERROR: Failed to compile {s}: {}\n", .{ pug_file, err });
            continue;
        };
    }
}

fn compileSingleFile(
    allocator: mem.Allocator,
    arena_allocator: mem.Allocator,
    engine: *view_engine.ViewEngine,
    registry: *mixin.MixinRegistry,
    pug_file: []const u8,
    views_root: []const u8,
    output_dir: []const u8,
    template_map: *std.StringHashMap([]const u8),
) !void {
    // Get relative path from views_root (for template resolution)
    const views_rel = if (mem.startsWith(u8, pug_file, views_root))
        pug_file[views_root.len..]
    else
        pug_file;

    // Skip leading slash
    const trimmed_views = if (views_rel.len > 0 and views_rel[0] == '/')
        views_rel[1..]
    else
        views_rel;

    // Remove .pug extension for template name (used by ViewEngine)
    const template_name = if (mem.endsWith(u8, trimmed_views, ".pug"))
        trimmed_views[0 .. trimmed_views.len - 4]
    else
        trimmed_views;

    // Parse template with full resolution (handles includes, extends, mixins)
    const final_ast = try engine.parseTemplate(arena_allocator, template_name, registry);

    // Expand mixin calls into concrete AST nodes for codegen
    const expanded_ast = try mixin.expandMixins(arena_allocator, final_ast, registry);

    // Extract field names
    const fields = try zig_codegen.extractFieldNames(arena_allocator, expanded_ast);

    // Generate Zig code
    var codegen = zig_codegen.Codegen.init(arena_allocator);
    defer codegen.deinit();

    const zig_code = try codegen.generate(expanded_ast, "render", fields);

    // Create flat filename from views-relative path to avoid collisions
    // e.g., "pages/404.pug" → "pages_404.zig"
    const flat_name = try makeFlatFileName(allocator, trimmed_views);
    defer allocator.free(flat_name);

    const output_path = try fs.path.join(allocator, &.{ output_dir, flat_name });
    defer allocator.free(output_path);

    try fs.cwd().writeFile(.{ .sub_path = output_path, .data = zig_code });

    // Track for root.zig (use same naming convention for both)
    const name = try makeTemplateName(allocator, trimmed_views);
    const output_copy = try allocator.dupe(u8, flat_name);
    try template_map.put(name, output_copy);
}

fn findPugFiles(allocator: mem.Allocator, dir_path: []const u8) ![][]const u8 {
    var results: std.ArrayList([]const u8) = .{};
    errdefer {
        for (results.items) |item| allocator.free(item);
        results.deinit(allocator);
    }

    try findPugFilesRecursive(allocator, dir_path, &results);
    return results.toOwnedSlice(allocator);
}

fn findPugFilesRecursive(allocator: mem.Allocator, dir_path: []const u8, results: *std.ArrayList([]const u8)) !void {
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
                try findPugFilesRecursive(allocator, full_path, results);
                allocator.free(full_path);
            },
            else => {
                allocator.free(full_path);
            },
        }
    }
}

fn makeTemplateName(allocator: mem.Allocator, path: []const u8) ![]const u8 {
    const without_ext = if (mem.endsWith(u8, path, ".pug"))
        path[0 .. path.len - 4]
    else
        path;

    var result: std.ArrayList(u8) = .{};
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

fn makeFlatFileName(allocator: mem.Allocator, path: []const u8) ![]const u8 {
    // Convert "pages/404.pug" → "pages_404.zig"
    const without_ext = if (mem.endsWith(u8, path, ".pug"))
        path[0 .. path.len - 4]
    else
        path;

    var result: std.ArrayList(u8) = .{};
    defer result.deinit(allocator);

    for (without_ext) |c| {
        if (c == '/' or c == '-') {
            try result.append(allocator, '_');
        } else {
            try result.append(allocator, c);
        }
    }

    try result.appendSlice(allocator, ".zig");

    return result.toOwnedSlice(allocator);
}

fn generateRootZig(allocator: mem.Allocator, output_dir: []const u8, template_map: *std.StringHashMap([]const u8)) !void {
    var output: std.ArrayList(u8) = .{};
    defer output.deinit(allocator);

    try output.appendSlice(allocator, "// Auto-generated by Pugz build step\n");
    try output.appendSlice(allocator, "// This file exports all compiled templates\n\n");

    // Sort template names
    var names: std.ArrayList([]const u8) = .{};
    defer names.deinit(allocator);

    var iter = template_map.keyIterator();
    while (iter.next()) |key| {
        try names.append(allocator, key.*);
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // Generate exports
    for (names.items) |name| {
        const file_path = template_map.get(name).?;
        // file_path is already the flat filename like "pages_404.zig"
        const import_path = file_path[0 .. file_path.len - 4]; // Remove .zig to get "pages_404"

        try output.appendSlice(allocator, "pub const ");
        try output.appendSlice(allocator, name);
        try output.appendSlice(allocator, " = @import(\"");
        try output.appendSlice(allocator, import_path);
        try output.appendSlice(allocator, ".zig\");\n");
    }

    const root_path = try fs.path.join(allocator, &.{ output_dir, "root.zig" });
    defer allocator.free(root_path);

    try fs.cwd().writeFile(.{ .sub_path = root_path, .data = output.items });
}

fn copyHelpersZig(allocator: mem.Allocator, output_dir: []const u8) !void {
    const helpers_source = @embedFile("tpl_compiler/helpers_template.zig");
    const output_path = try fs.path.join(allocator, &.{ output_dir, "helpers.zig" });
    defer allocator.free(output_path);

    try fs.cwd().writeFile(.{ .sub_path = output_path, .data = helpers_source });
}

/// Convenience function to add a compile step to the build
pub fn addCompileStep(b: *Build, options: CompileOptions) *CompileStep {
    return CompileStep.create(b, options);
}
