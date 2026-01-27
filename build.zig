const std = @import("std");

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

    // Source file unit tests (lexer, parser, runtime, etc.)
    const source_files_with_tests = [_][]const u8{
        "src/lexer.zig",
        "src/parser.zig",
        "src/runtime.zig",
        "src/template.zig",
        "src/codegen.zig",
        "src/strip_comments.zig",
        "src/linker.zig",
        "src/load.zig",
        "src/error.zig",
        "src/pug.zig",
    };

    var source_test_steps: [source_files_with_tests.len]*std.Build.Step.Run = undefined;
    inline for (source_files_with_tests, 0..) |file, i| {
        const file_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .optimize = optimize,
            }),
        });
        source_test_steps[i] = b.addRunArtifact(file_tests);
    }

    // Integration tests - general template tests
    const general_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/general_test.zig"),
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
            .root_source_file = b.path("tests/doctype_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pugz", .module = mod },
            },
        }),
    });
    const run_doctype_tests = b.addRunArtifact(doctype_tests);

    // Integration tests - check_list tests (pug files vs expected html output)
    const check_list_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/check_list_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pugz", .module = mod },
            },
        }),
    });
    const run_check_list_tests = b.addRunArtifact(check_list_tests);

    // A top level step for running all tests.
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_general_tests.step);
    test_step.dependOn(&run_doctype_tests.step);
    test_step.dependOn(&run_check_list_tests.step);
    // Add source file tests
    for (&source_test_steps) |step| {
        test_step.dependOn(&step.step);
    }

    // Individual test steps
    const test_general_step = b.step("test-general", "Run general template tests");
    test_general_step.dependOn(&run_general_tests.step);

    const test_doctype_step = b.step("test-doctype", "Run doctype tests");
    test_doctype_step.dependOn(&run_doctype_tests.step);

    const test_unit_step = b.step("test-unit", "Run unit tests (lexer, parser, etc.)");
    test_unit_step.dependOn(&run_mod_tests.step);
    for (&source_test_steps) |step| {
        test_unit_step.dependOn(&step.step);
    }

    const test_check_list_step = b.step("test-check-list", "Run check_list template tests");
    test_check_list_step.dependOn(&run_check_list_tests.step);

    // Benchmark executable
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "pugz", .module = mod },
            },
        }),
    });
    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.setCwd(b.path("."));
    const bench_step = b.step("bench", "Run benchmark");
    bench_step.dependOn(&run_bench.step);

    // Test includes example
    const test_includes_exe = b.addExecutable(.{
        .name = "test-includes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_includes.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pugz", .module = mod },
            },
        }),
    });
    b.installArtifact(test_includes_exe);

    const run_test_includes = b.addRunArtifact(test_includes_exe);
    run_test_includes.setCwd(b.path("."));
    const test_includes_step = b.step("test-includes", "Test include/mixin rendering");
    test_includes_step.dependOn(&run_test_includes.step);
}
