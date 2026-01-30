const std = @import("std");
pub const compile_tpls = @import("src/compile_tpls.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main pugz module
    const mod = b.addModule("pugz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ============================================================================
    // CLI Tool - Pug Template Compiler
    // ============================================================================
    const cli_exe = b.addExecutable(.{
        .name = "pug-compile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tpl_compiler/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pugz", .module = mod },
            },
        }),
    });
    b.installArtifact(cli_exe);

    // CLI run step for manual testing
    const run_cli = b.addRunArtifact(cli_exe);
    if (b.args) |args| {
        run_cli.addArgs(args);
    }
    const cli_step = b.step("cli", "Run the pug-compile CLI tool");
    cli_step.dependOn(&run_cli.step);

    // ============================================================================
    // Tests
    // ============================================================================

    // Module tests (from root.zig)
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Source file unit tests
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

    // Integration tests
    const test_all = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pugz", .module = mod },
            },
        }),
    });
    const run_test_all = b.addRunArtifact(test_all);

    // Test steps
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_test_all.step);
    for (&source_test_steps) |step| {
        test_step.dependOn(&step.step);
    }

    const test_unit_step = b.step("test-unit", "Run unit tests (lexer, parser, etc.)");
    test_unit_step.dependOn(&run_mod_tests.step);
    for (&source_test_steps) |step| {
        test_unit_step.dependOn(&step.step);
    }

    const test_integration_step = b.step("test-integration", "Run integration tests");
    test_integration_step.dependOn(&run_test_all.step);

    // ============================================================================
    // Benchmarks
    // ============================================================================

    // Create module for compiled benchmark templates
    const bench_compiled_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/compiled/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/benchmarks/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "pugz", .module = mod },
                .{ .name = "bench_compiled", .module = bench_compiled_mod },
            },
        }),
    });
    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.setCwd(b.path("."));
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // ============================================================================
    // Examples
    // ============================================================================

    // Example: Using compiled templates (only if generated/ exists)
    const generated_exists = blk: {
        var f = std.fs.cwd().openDir("generated", .{}) catch break :blk false;
        f.close();
        break :blk true;
    };

    if (generated_exists) {
        const generated_mod = b.addModule("generated", .{
            .root_source_file = b.path("generated/root.zig"),
            .target = target,
            .optimize = optimize,
        });

        const example_compiled = b.addExecutable(.{
            .name = "example-compiled",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/use_compiled_templates.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "generated", .module = generated_mod },
                },
            }),
        });
        b.installArtifact(example_compiled);

        const run_example_compiled = b.addRunArtifact(example_compiled);
        const example_compiled_step = b.step("example-compiled", "Run compiled templates example");
        example_compiled_step.dependOn(&run_example_compiled.step);
    }

    // Example: Test includes
    const test_includes_exe = b.addExecutable(.{
        .name = "test-includes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/run/test_includes.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pugz", .module = mod },
            },
        }),
    });
    b.installArtifact(test_includes_exe);

    const run_test_includes = b.addRunArtifact(test_includes_exe);
    const test_includes_step = b.step("test-includes", "Run includes example");
    test_includes_step.dependOn(&run_test_includes.step);

    // Add template compile test
    addTemplateCompileTest(b);
}

// Public API for other build.zig files to use
pub fn addCompileStep(b: *std.Build, options: compile_tpls.CompileOptions) *compile_tpls.CompileStep {
    return compile_tpls.addCompileStep(b, options);
}

// Test the compile step
fn addTemplateCompileTest(b: *std.Build) void {
    const compile_step = addCompileStep(b, .{
        .name = "compile-test-templates",
        .source_dirs = &.{"examples/cli-templates-demo"},
        .output_dir = "zig-out/generated-test",
    });

    const test_compile = b.step("test-compile", "Test template compilation build step");
    test_compile.dependOn(&compile_step.step);
}
