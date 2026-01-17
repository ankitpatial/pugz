const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("pugz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Creates an executable that will run `test` blocks from the provided module.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

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
    // Example: demo - Template Inheritance Demo with http.zig
    // ─────────────────────────────────────────────────────────────────────────
    const httpz_dep = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    const demo = b.addExecutable(.{
        .name = "demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/demo/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pugz", .module = mod },
                .{ .name = "httpz", .module = httpz_dep.module("httpz") },
            },
        }),
    });

    b.installArtifact(demo);

    const run_demo = b.addRunArtifact(demo);
    run_demo.step.dependOn(b.getInstallStep());

    const demo_step = b.step("demo", "Run the template inheritance demo web app");
    demo_step.dependOn(&run_demo.step);

    // ─────────────────────────────────────────────────────────────────────────
    // Benchmark executable
    // ─────────────────────────────────────────────────────────────────────────
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast, // Always use ReleaseFast for benchmarks
        }),
    });

    b.installArtifact(bench);

    const run_bench = b.addRunArtifact(bench);
    run_bench.step.dependOn(b.getInstallStep());

    const bench_step = b.step("bench", "Run rendering benchmarks");
    bench_step.dependOn(&run_bench.step);

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
