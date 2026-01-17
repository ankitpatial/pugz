//! Pugz - A Pug-like HTML template engine written in Zig.
//!
//! Pugz provides a clean, indentation-based syntax for writing HTML templates,
//! inspired by Pug (formerly Jade). It supports:
//! - Indentation-based nesting
//! - Tag, class, and ID shorthand syntax
//! - Attributes and text interpolation
//! - Control flow (if/else, each, while)
//! - Mixins and template inheritance

pub const lexer = @import("lexer.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const codegen = @import("codegen.zig");
pub const runtime = @import("runtime.zig");

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

test {
    _ = @import("std").testing.refAllDecls(@This());
}
