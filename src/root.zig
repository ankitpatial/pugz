// Pugz - A Pug-like HTML template engine written in Zig
//
// Quick Start:
//   const pugz = @import("pugz");
//   const engine = pugz.ViewEngine.init(.{ .views_dir = "views" });
//   const html = try engine.render(allocator, "index", .{ .title = "Home" });

pub const pug = @import("pug.zig");
pub const view_engine = @import("view_engine.zig");
pub const template = @import("template.zig");
pub const parser = @import("parser.zig");
pub const mixin = @import("mixin.zig");
pub const runtime = @import("runtime.zig");
pub const codegen = @import("codegen.zig");
pub const compile_tpls = @import("compile_tpls.zig");

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

// Build step convenience exports
pub const addCompileStep = compile_tpls.addCompileStep;
pub const CompileTplsOptions = compile_tpls.CompileOptions;
