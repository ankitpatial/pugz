# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Pugz is a Pug-like HTML template engine written in Zig 0.15.2. It implements Pug 3 syntax for indentation-based HTML templating with a focus on server-side rendering.

## Build Commands

- `zig build` - Build the project (output in `zig-out/`)
- `zig build test` - Run all tests
- `zig build app-01` - Run the example web app (http://localhost:8080)

## Architecture Overview

The template engine follows a classic compiler pipeline:

```
Source → Lexer → Tokens → Parser → AST → Runtime → HTML
```

### Core Modules

| Module | Purpose |
|--------|---------|
| **src/lexer.zig** | Tokenizes Pug source into tokens. Handles indentation tracking, raw text blocks, interpolation. |
| **src/parser.zig** | Converts token stream into AST. Handles nesting via indent/dedent tokens. |
| **src/ast.zig** | AST node definitions (Element, Text, Conditional, Each, Mixin, etc.) |
| **src/runtime.zig** | Evaluates AST with data context, produces final HTML. Handles variable interpolation, conditionals, loops, mixins. |
| **src/codegen.zig** | Static HTML generation (without runtime evaluation). Outputs placeholders for dynamic content. |
| **src/view_engine.zig** | High-level ViewEngine for web servers. Manages views directory, auto-loads mixins. |
| **src/root.zig** | Public library API - exports `ViewEngine`, `renderTemplate()` and core types. |

### Test Files

- **src/tests/general_test.zig** - Comprehensive integration tests for all features

## Memory Management

**Important**: The runtime is designed to work with `ArenaAllocator`:

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();  // Frees all template memory at once

const html = try pugz.renderTemplate(arena.allocator(), template, data);
```

This pattern is recommended because template rendering creates many small allocations that are all freed together after the response is sent.

## Key Implementation Details

### Lexer State Machine

The lexer tracks several states for handling complex syntax:
- `in_raw_block` / `raw_block_indent` / `raw_block_started` - For dot block text (e.g., `script.`)
- `indent_stack` - Stack-based indent/dedent token generation

### Token Types

Key tokens: `tag`, `class`, `id`, `lparen`, `rparen`, `attr_name`, `attr_value`, `text`, `interp_start`, `interp_end`, `indent`, `dedent`, `dot_block`, `pipe_text`, `literal_html`, `self_close`, `mixin_call`, etc.

### AST Node Types

- `element` - HTML elements with tag, classes, id, attributes, children
- `text` - Text with segments (literal, escaped interpolation, unescaped interpolation, tag interpolation)
- `conditional` - if/else if/else/unless branches
- `each` - Iteration with value, optional index, else branch
- `mixin_def` / `mixin_call` - Mixin definitions and invocations
- `block` - Named blocks for template inheritance
- `include` / `extends` - File inclusion and inheritance
- `raw_text` - Literal HTML or text blocks

### Runtime Value System

```zig
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    array: []const Value,
    object: std.StringHashMapUnmanaged(Value),
};
```

The `toValue()` function converts Zig structs to runtime Values automatically.

## Supported Pug Features

### Tags & Nesting
```pug
div
  h1 Title
  p Paragraph
```

### Classes & IDs (shorthand)
```pug
div#main.container.active
.box        // defaults to div
#sidebar    // defaults to div
```

### Attributes
```pug
a(href="/link" target="_blank") Click
input(type="checkbox" checked)
div(style={color: 'red'})
div(class=['foo', 'bar'])
button(disabled=false)      // omitted when false
button(disabled=true)       // disabled="disabled"
```

### Text & Interpolation
```pug
p Hello #{name}             // escaped interpolation
p Hello !{rawHtml}          // unescaped interpolation
p= variable                 // buffered code (escaped)
p!= rawVariable             // buffered code (unescaped)
| Piped text line
p.
  Multi-line
  text block
<p>Literal HTML</p>         // passed through as-is
```

### Tag Interpolation
```pug
p This is #[em emphasized] text
p Click #[a(href="/") here] to continue
```

### Block Expansion
```pug
a: img(src="logo.png")      // colon for inline nesting
```

### Explicit Self-Closing
```pug
foo/                        // renders as <foo />
```

### Conditionals
```pug
if condition
  p Yes
else if other
  p Maybe
else
  p No

unless loggedIn
  p Please login
```

### Iteration
```pug
each item in items
  li= item

each val, index in list
  li #{index}: #{val}

each item in items
  li= item
else
  li No items

// Works with objects too (key as index)
each val, key in object
  p #{key}: #{val}
```

### Case/When
```pug
case status
  when "active"
    p Active
  when "pending"
    p Pending
  default
    p Unknown
```

### Mixins
```pug
mixin button(text, type="primary")
  button(class="btn btn-" + type)= text

+button("Click me")
+button("Submit", "success")

// With block content
mixin card(title)
  .card
    h3= title
    block

+card("My Card")
  p Card content here

// Rest arguments
mixin list(id, ...items)
  ul(id=id)
    each item in items
      li= item

+list("mylist", "a", "b", "c")

// Attributes pass-through
mixin link(href, text)
  a(href=href)&attributes(attributes)= text

+link("/home", "Home")(class="nav-link" data-id="1")
```

### Includes & Inheritance
```pug
include header.pug

extends layout.pug
block content
  h1 Page Title

// Block modes
block append scripts
  script(src="extra.js")

block prepend styles
  link(rel="stylesheet" href="extra.css")
```

### Comments
```pug
// This renders as HTML comment
//- This is a silent comment (not in output)
```

## Server Usage

### ViewEngine (Recommended)

The `ViewEngine` provides the simplest API for web servers:

```zig
const std = @import("std");
const pugz = @import("pugz");

// Initialize once at server startup
var engine = try pugz.ViewEngine.init(allocator, .{
    .views_dir = "src/views",     // Root views directory
    .mixins_dir = "mixins",       // Auto-load mixins from views/mixins/ (optional)
    .extension = ".pug",          // File extension (default: .pug)
    .pretty = true,               // Pretty-print output (default: true)
});
defer engine.deinit();

// In request handler - use arena allocator per request
pub fn handleRequest(engine: *pugz.ViewEngine, allocator: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Template path is relative to views_dir, extension added automatically
    return try engine.render(arena.allocator(), "pages/home", .{
        .title = "Home",
        .user = .{ .name = "Alice" },
    });
}
```

### Directory Structure

```
src/views/
├── mixins/           # Auto-loaded mixins (optional)
│   ├── buttons.pug   # mixin btn(text), mixin btn-link(href, text)
│   └── cards.pug     # mixin card(title), mixin card-simple(title, body)
├── layouts/
│   └── base.pug      # Base layout with blocks
├── partials/
│   ├── header.pug
│   └── footer.pug
└── pages/
    ├── home.pug      # extends layouts/base
    └── about.pug     # extends layouts/base
```

Templates can use:
- `extends layouts/base` - Paths relative to views_dir
- `include partials/header` - Paths relative to views_dir
- `+btn("Click")` - Mixins from mixins/ dir available automatically

### Low-Level API

For inline templates or custom use cases:

```zig
const std = @import("std");
const pugz = @import("pugz");

pub fn handleRequest(allocator: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    return try pugz.renderTemplate(arena.allocator(),
        \\html
        \\  head
        \\    title= title
        \\  body
        \\    h1 Hello, #{name}!
        \\    if showList
        \\      ul
        \\        each item in items
        \\          li= item
    , .{
        .title = "My Page",
        .name = "World",
        .showList = true,
        .items = &[_][]const u8{ "One", "Two", "Three" },
    });
}
```

## Testing

Run tests with `zig build test`. Tests cover:
- Basic element parsing and rendering
- Class and ID shorthand syntax
- Attribute parsing (quoted, unquoted, boolean, object literals)
- Text interpolation (escaped, unescaped, tag interpolation)
- Conditionals (if/else if/else/unless)
- Iteration (each with index, else branch, objects)
- Case/when statements
- Mixin definitions and calls (with defaults, rest args, block content, attributes)
- Plain text (piped, dot blocks, literal HTML)
- Self-closing tags (void elements, explicit `/`)
- Block expansion with colon
- Comments (rendered and silent)

## Error Handling

The lexer and parser return errors for invalid syntax:
- `ParserError.UnexpectedToken`
- `ParserError.MissingCondition`
- `ParserError.MissingMixinName`
- `RuntimeError.ParseError` (wrapped for convenience API)

## Future Improvements

Potential areas for enhancement:
- Filter support (`:markdown`, `:stylus`, etc.)
- More complete JavaScript expression evaluation
- Source maps for debugging
- Compile-time template validation
