//! Pugz - A Pug-like HTML template engine written in Zig.
//!
//! Pugz provides a clean, indentation-based syntax for writing HTML templates,
//! inspired by Pug (formerly Jade). It supports:
//! - Indentation-based nesting
//! - Tag, class, and ID shorthand syntax
//! - Attributes and text interpolation
//! - Control flow (if/else, each, while)
//! - Mixins and template inheritance
//!
//! ## Quick Start (Server Usage)
//!
//! ```zig
//! const pugz = @import("pugz");
//!
//! // Initialize view engine once at startup
//! var engine = try pugz.ViewEngine.init(allocator, .{
//!     .views_dir = "src/views",
//! });
//! defer engine.deinit();
//!
//! // Render templates (use arena allocator per request)
//! var arena = std.heap.ArenaAllocator.init(allocator);
//! defer arena.deinit();
//!
//! const html = try engine.render(arena.allocator(), "pages/home", .{
//!     .title = "Home",
//! });
//! ```

pub const lexer = @import("lexer.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const codegen = @import("codegen.zig");
pub const runtime = @import("runtime.zig");
pub const view_engine = @import("view_engine.zig");

// Re-export main types for convenience
pub const Lexer = lexer.Lexer;
pub const Token = lexer.Token;
pub const TokenType = lexer.TokenType;

pub const Parser = parser.Parser;
pub const Node = ast.Node;
pub const Document = ast.Document;

pub const CodeGen = codegen.CodeGen;
pub const generate = codegen.generate;

pub const Runtime = runtime.Runtime;
pub const Context = runtime.Context;
pub const Value = runtime.Value;
pub const render = runtime.render;
pub const renderTemplate = runtime.renderTemplate;

// High-level API
pub const ViewEngine = view_engine.ViewEngine;

test {
    _ = @import("std").testing.refAllDecls(@This());
}
