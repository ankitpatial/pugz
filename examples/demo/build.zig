const std = @import("std");
const pugz = @import("pugz");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get dependencies
    const pugz_dep = b.dependency("pugz", .{
        .target = target,
        .optimize = optimize,
    });
    const httpz_dep = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    const pugz_mod = pugz_dep.module("pugz");

    // ===========================================================================
    // Template Compilation Step - OPTIONAL
    // ===========================================================================
    // This creates a "compile-templates" build step that users can run manually:
    //   zig build compile-templates
    //
    // Templates are compiled to generated/ and automatically used if they exist
    const compile_templates = pugz.compile_tpls.addCompileStep(b, .{
        .name = "compile-templates",
        .source_dirs = &.{
            "views/pages",
            "views/partials",
        },
        .output_dir = "generated",
    });

    const compile_step = b.step("compile-templates", "Compile Pug templates");
    compile_step.dependOn(&compile_templates.step);

    // ===========================================================================
    // Main Executable
    // ===========================================================================
    // Check if compiled templates exist
    const has_templates = blk: {
        var dir = std.fs.cwd().openDir("generated", .{}) catch break :blk false;
        dir.close();
        break :blk true;
    };

    // Build imports list
    var imports: std.ArrayListUnmanaged(std.Build.Module.Import) = .{};
    defer imports.deinit(b.allocator);

    imports.append(b.allocator, .{ .name = "pugz", .module = pugz_mod }) catch @panic("OOM");
    imports.append(b.allocator, .{ .name = "httpz", .module = httpz_dep.module("httpz") }) catch @panic("OOM");

    // Only add templates module if they exist
    if (has_templates) {
        const templates_mod = b.createModule(.{
            .root_source_file = b.path("generated/root.zig"),
        });
        imports.append(b.allocator, .{ .name = "templates", .module = templates_mod }) catch @panic("OOM");
    }

    const exe = b.addExecutable(.{
        .name = "demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports.items,
        }),
    });

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the demo server");
    run_step.dependOn(&run_cmd.step);
}
