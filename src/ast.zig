//! AST (Abstract Syntax Tree) definitions for Pug templates.
//!
//! The AST represents the hierarchical structure of a Pug document.
//! Each node type corresponds to a Pug language construct.

const std = @import("std");

/// An attribute on an element: name, value, and whether it's escaped.
pub const Attribute = struct {
    name: []const u8,
    value: ?[]const u8, // null for boolean attributes (e.g., `checked`)
    escaped: bool, // true for `=`, false for `!=`
};

/// A segment of text content, which may be plain text or interpolation.
pub const TextSegment = union(enum) {
    /// Plain text content.
    literal: []const u8,
    /// Escaped interpolation: #{expr} - HTML entities escaped.
    interp_escaped: []const u8,
    /// Unescaped interpolation: !{expr} - raw HTML output.
    interp_unescaped: []const u8,
    /// Tag interpolation: #[tag text] - inline HTML element.
    interp_tag: InlineTag,
};

/// Inline tag from tag interpolation syntax: #[em text] or #[a(href='/') link]
pub const InlineTag = struct {
    /// Tag name (e.g., "em", "a", "strong").
    tag: []const u8,
    /// CSS classes from `.class` syntax.
    classes: []const []const u8,
    /// Element ID from `#id` syntax.
    id: ?[]const u8,
    /// Attributes from `(attr=value)` syntax.
    attributes: []Attribute,
    /// Text content (may contain nested interpolations).
    text_segments: []TextSegment,
};

/// All AST node types.
pub const Node = union(enum) {
    /// Root document node containing all top-level nodes.
    document: Document,
    /// Doctype declaration: `doctype html`.
    doctype: Doctype,
    /// HTML element with optional tag, classes, id, attributes, and children.
    element: Element,
    /// Text content (may contain interpolations).
    text: Text,
    /// Buffered code output: `= expr` (escaped) or `!= expr` (unescaped).
    code: Code,
    /// Comment: `//` (rendered) or `//-` (silent).
    comment: Comment,
    /// Conditional: if/else if/else/unless chains.
    conditional: Conditional,
    /// Each loop: `each item in collection` or `each item, index in collection`.
    each: Each,
    /// While loop: `while condition`.
    @"while": While,
    /// Case/switch statement.
    case: Case,
    /// Mixin definition: `mixin name(args)`.
    mixin_def: MixinDef,
    /// Mixin call: `+name(args)`.
    mixin_call: MixinCall,
    /// Mixin block placeholder: `block` inside a mixin.
    mixin_block: void,
    /// Include directive: `include path`.
    include: Include,
    /// Extends directive: `extends path`.
    extends: Extends,
    /// Named block: `block name`.
    block: Block,
    /// Raw text block (after `.` on element).
    raw_text: RawText,
};

/// Root document containing all top-level nodes.
pub const Document = struct {
    nodes: []Node,
    /// Optional extends directive (must be first if present).
    extends_path: ?[]const u8 = null,
};

/// Doctype declaration node.
pub const Doctype = struct {
    /// The doctype value (e.g., "html", "xml", "strict", or custom string).
    /// Empty string means default to "html".
    value: []const u8,
};

/// HTML element node.
pub const Element = struct {
    /// Tag name (defaults to "div" if only class/id specified).
    tag: []const u8,
    /// CSS classes from `.class` syntax.
    classes: []const []const u8,
    /// Element ID from `#id` syntax.
    id: ?[]const u8,
    /// Attributes from `(attr=value)` syntax.
    attributes: []Attribute,
    /// Spread attributes from `&attributes({...})` syntax.
    spread_attributes: ?[]const u8 = null,
    /// Child nodes (nested elements, text, etc.).
    children: []Node,
    /// Whether this is a self-closing tag.
    self_closing: bool,
    /// Inline text content (e.g., `p Hello`).
    inline_text: ?[]TextSegment,
    /// Buffered code content (e.g., `p= expr` or `p!= expr`).
    buffered_code: ?Code = null,
    /// Whether children should be rendered inline (block expansion with `:`).
    is_inline: bool = false,
};

/// Text content node.
pub const Text = struct {
    /// Segments of text (literals and interpolations).
    segments: []TextSegment,
};

/// Code output node: `= expr` or `!= expr`.
pub const Code = struct {
    /// The expression to evaluate.
    expression: []const u8,
    /// Whether output is HTML-escaped.
    escaped: bool,
};

/// Comment node.
pub const Comment = struct {
    /// Comment text content.
    content: []const u8,
    /// Whether comment is rendered in output (`//`) or silent (`//-`).
    rendered: bool,
    /// Nested content (for block comments).
    children: []Node,
};

/// Conditional node for if/else if/else/unless chains.
pub const Conditional = struct {
    /// The condition branches in order.
    branches: []Branch,

    pub const Branch = struct {
        /// Condition expression (null for `else`).
        condition: ?[]const u8,
        /// Whether this is `unless` (negated condition).
        is_unless: bool,
        /// Child nodes for this branch.
        children: []Node,
    };
};

/// Each loop node.
pub const Each = struct {
    /// Iterator variable name.
    value_name: []const u8,
    /// Optional index variable name.
    index_name: ?[]const u8,
    /// Collection expression to iterate.
    collection: []const u8,
    /// Loop body nodes.
    children: []Node,
    /// Optional else branch (when collection is empty).
    else_children: []Node,
};

/// While loop node.
pub const While = struct {
    /// Loop condition expression.
    condition: []const u8,
    /// Loop body nodes.
    children: []Node,
};

/// Case/switch node.
pub const Case = struct {
    /// Expression to match against.
    expression: []const u8,
    /// When branches (in order, for fall-through support).
    whens: []When,
    /// Default branch children (if any).
    default_children: []Node,

    pub const When = struct {
        /// Value to match.
        value: []const u8,
        /// Child nodes for this case. Empty means fall-through to next case.
        children: []Node,
        /// Explicit break (- break) means output nothing.
        has_break: bool,
    };
};

/// Mixin definition node.
pub const MixinDef = struct {
    /// Mixin name.
    name: []const u8,
    /// Parameter names.
    params: []const []const u8,
    /// Default values for parameters (null if no default).
    defaults: []?[]const u8,
    /// Whether last param is rest parameter (...args).
    has_rest: bool,
    /// Mixin body nodes.
    children: []Node,
};

/// Mixin call node.
pub const MixinCall = struct {
    /// Mixin name to call.
    name: []const u8,
    /// Argument expressions.
    args: []const []const u8,
    /// Attributes passed to mixin.
    attributes: []Attribute,
    /// Block content passed to mixin.
    block_children: []Node,
};

/// Include directive node.
pub const Include = struct {
    /// Path to include.
    path: []const u8,
    /// Optional filter (e.g., `:markdown`).
    filter: ?[]const u8,
};

/// Extends directive node.
pub const Extends = struct {
    /// Path to parent template.
    path: []const u8,
};

/// Named block node for template inheritance.
pub const Block = struct {
    /// Block name.
    name: []const u8,
    /// Block mode: replace, append, or prepend.
    mode: Mode,
    /// Block content nodes.
    children: []Node,

    pub const Mode = enum {
        replace,
        append,
        prepend,
    };
};

/// Raw text block (from `.` syntax).
pub const RawText = struct {
    /// Raw text content lines.
    content: []const u8,
};
