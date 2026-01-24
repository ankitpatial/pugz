const std = @import("std");

// Re-export build_templates for use by dependent packages
pub const build_templates = @import("src/build_templates.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("pugz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
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

    // Integration tests - check_list tests (pug files vs expected html output)
    const check_list_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/check_list_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pugz", .module = mod },
            },
        }),
    });
    const run_check_list_tests = b.addRunArtifact(check_list_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_general_tests.step);
    test_step.dependOn(&run_doctype_tests.step);
    test_step.dependOn(&run_inheritance_tests.step);
    test_step.dependOn(&run_check_list_tests.step);

    // Individual test steps
    const test_general_step = b.step("test-general", "Run general template tests");
    test_general_step.dependOn(&run_general_tests.step);

    const test_doctype_step = b.step("test-doctype", "Run doctype tests");
    test_doctype_step.dependOn(&run_doctype_tests.step);

    const test_inheritance_step = b.step("test-inheritance", "Run inheritance tests");
    test_inheritance_step.dependOn(&run_inheritance_tests.step);

    const test_unit_step = b.step("test-unit", "Run unit tests (lexer, parser, etc.)");
    test_unit_step.dependOn(&run_mod_tests.step);

    const test_check_list_step = b.step("test-check-list", "Run check_list template tests");
    test_check_list_step.dependOn(&run_check_list_tests.step);

    // ─────────────────────────────────────────────────────────────────────────
    // Compiled Templates Benchmark (compare with Pug.js bench.js)
    // Uses auto-generated templates from src/benchmarks/templates/
    // ─────────────────────────────────────────────────────────────────────────
    const mod_fast = b.addModule("pugz-fast", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const bench_templates = build_templates.compileTemplates(b, .{
        .source_dir = "src/benchmarks/templates",
    });

    const bench_compiled = b.addExecutable(.{
        .name = "bench-compiled",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmarks/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "pugz", .module = mod_fast },
                .{ .name = "tpls", .module = bench_templates },
            },
        }),
    });

    b.installArtifact(bench_compiled);

    const run_bench_compiled = b.addRunArtifact(bench_compiled);
    run_bench_compiled.step.dependOn(b.getInstallStep());

    const bench_compiled_step = b.step("bench-compiled", "Benchmark compiled templates (compare with Pug.js)");
    bench_compiled_step.dependOn(&run_bench_compiled.step);

    // ─────────────────────────────────────────────────────────────────────────
    // Interpreted (Runtime) Benchmark
    // ─────────────────────────────────────────────────────────────────────────
    const bench_interpreted = b.addExecutable(.{
        .name = "bench-interpreted",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmarks/bench_interpreted.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "pugz", .module = mod_fast },
            },
        }),
    });

    b.installArtifact(bench_interpreted);

    const run_bench_interpreted = b.addRunArtifact(bench_interpreted);
    run_bench_interpreted.step.dependOn(b.getInstallStep());

    const bench_interpreted_step = b.step("bench-interpreted", "Benchmark interpreted (runtime) templates");
    bench_interpreted_step.dependOn(&run_bench_interpreted.step);

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
