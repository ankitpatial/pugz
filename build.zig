const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("pugz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "pugz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pugz", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Integration tests - general template tests
    const general_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/general_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pugz", .module = mod },
            },
        }),
    });
    const run_general_tests = b.addRunArtifact(general_tests);

    // Integration tests - doctype tests
    const doctype_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/doctype_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pugz", .module = mod },
            },
        }),
    });
    const run_doctype_tests = b.addRunArtifact(doctype_tests);

    // Integration tests - inheritance tests
    const inheritance_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/inheritance_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pugz", .module = mod },
            },
        }),
    });
    const run_inheritance_tests = b.addRunArtifact(inheritance_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_general_tests.step);
    test_step.dependOn(&run_doctype_tests.step);
    test_step.dependOn(&run_inheritance_tests.step);

    // Individual test steps
    const test_general_step = b.step("test-general", "Run general template tests");
    test_general_step.dependOn(&run_general_tests.step);

    const test_doctype_step = b.step("test-doctype", "Run doctype tests");
    test_doctype_step.dependOn(&run_doctype_tests.step);

    const test_inheritance_step = b.step("test-inheritance", "Run inheritance tests");
    test_inheritance_step.dependOn(&run_inheritance_tests.step);

    const test_unit_step = b.step("test-unit", "Run unit tests (lexer, parser, etc.)");
    test_unit_step.dependOn(&run_mod_tests.step);

    // ─────────────────────────────────────────────────────────────────────────
    // Example: app_01 - Template Inheritance Demo with http.zig
    // ─────────────────────────────────────────────────────────────────────────
    const httpz_dep = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    const app_01 = b.addExecutable(.{
        .name = "app_01",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/app_01/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pugz", .module = mod },
                .{ .name = "httpz", .module = httpz_dep.module("httpz") },
            },
        }),
    });

    b.installArtifact(app_01);

    const run_app_01 = b.addRunArtifact(app_01);
    run_app_01.step.dependOn(b.getInstallStep());

    const app_01_step = b.step("app-01", "Run the template inheritance demo web app");
    app_01_step.dependOn(&run_app_01.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
