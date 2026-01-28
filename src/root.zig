// Pugz - A Pug-like HTML template engine written in Zig
//
// Quick Start:
//   const pugz = @import("pugz");
//   const engine = pugz.ViewEngine.init(.{ .views_dir = "views" });
//   const html = try engine.render(allocator, "index", .{ .title = "Home" });

const builtin = @import("builtin");

pub const pug = @import("pug.zig");
pub const view_engine = @import("view_engine.zig");
pub const template = @import("template.zig");
pub const parser = @import("parser.zig");
pub const mixin = @import("mixin.zig");
pub const runtime = @import("runtime.zig");
pub const codegen = @import("codegen.zig");

// Build step for compiling templates (only available in build scripts)
pub const compile_tpls = if (builtin.is_test or @import("builtin").output_mode == .Obj)
    void
else
    @import("compile_tpls.zig");

// Re-export main types
pub const ViewEngine = view_engine.ViewEngine;
pub const compile = pug.compile;
pub const compileFile = pug.compileFile;
pub const render = pug.render;
pub const renderFile = pug.renderFile;
pub const CompileOptions = pug.CompileOptions;
pub const CompileResult = pug.CompileResult;
pub const CompileError = pug.CompileError;

// Convenience function for inline templates with data
pub const renderTemplate = template.renderWithData;

// Build step convenience exports (only available in build context)
pub const addCompileStep = if (@TypeOf(compile_tpls) == type and compile_tpls != void)
    compile_tpls.addCompileStep
else
    void;
pub const CompileTplsOptions = if (@TypeOf(compile_tpls) == type and compile_tpls != void)
    compile_tpls.CompileOptions
else
    void;
