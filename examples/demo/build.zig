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
    // Templates module - uses output from compile step
    const templates_mod = b.createModule(.{
        .root_source_file = compile_templates.getOutput(),
    });

    const exe = b.addExecutable(.{
        .name = "demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pugz", .module = pugz_mod },
                .{ .name = "httpz", .module = httpz_dep.module("httpz") },
                .{ .name = "templates", .module = templates_mod },
            },
        }),
    });

    // Ensure templates are compiled before building the executable
    exe.step.dependOn(&compile_templates.step);

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
