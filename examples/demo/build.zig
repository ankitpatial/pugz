const std = @import("std");

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

    // Compile templates at build time using pugz's build_templates
    // Generates views/generated.zig with all templates
    const build_templates = @import("pugz").build_templates;
    const compiled_templates = build_templates.compileTemplates(b, .{
        .source_dir = "views",
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pugz", .module = pugz_dep.module("pugz") },
                .{ .name = "httpz", .module = httpz_dep.module("httpz") },
                .{ .name = "tpls", .module = compiled_templates },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the demo server");
    run_step.dependOn(&run_cmd.step);
}
