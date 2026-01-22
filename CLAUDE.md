# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Pugz is a Pug-like HTML template engine written in Zig 0.15.2. It implements Pug 3 syntax for indentation-based HTML templating with a focus on server-side rendering.

## Build Commands

- `zig build` - Build the project (output in `zig-out/`)
- `zig build test` - Run all tests
- `zig build bench-compiled` - Run compiled templates benchmark (compare with Pug.js)

## Architecture Overview

The template engine supports two rendering modes:

### 1. Runtime Rendering (Interpreted)
```
Source → Lexer → Tokens → Parser → AST → Runtime → HTML
```

### 2. Build-Time Compilation (Compiled)
```
Source → Lexer → Tokens → Parser → AST → build_templates.zig → generated.zig → Native Zig Code
```

The compiled mode is **~3x faster** than Pug.js.

### Core Modules

| Module | Purpose |
|--------|---------|
| **src/lexer.zig** | Tokenizes Pug source into tokens. Handles indentation tracking, raw text blocks, interpolation. |
| **src/parser.zig** | Converts token stream into AST. Handles nesting via indent/dedent tokens. |
| **src/ast.zig** | AST node definitions (Element, Text, Conditional, Each, Mixin, etc.) |
| **src/runtime.zig** | Evaluates AST with data context, produces final HTML. Handles variable interpolation, conditionals, loops, mixins. |
| **src/build_templates.zig** | Build-time template compiler. Generates optimized Zig code from `.pug` templates. |
| **src/view_engine.zig** | High-level ViewEngine for web servers. Manages views directory, auto-loads mixins. |
| **src/root.zig** | Public library API - exports `ViewEngine`, `renderTemplate()`, `build_templates` and core types. |

### Test Files

- **src/tests/general_test.zig** - Comprehensive integration tests for all features
- **src/tests/doctype_test.zig** - Doctype-specific tests
- **src/tests/inheritance_test.zig** - Template inheritance tests

## Build-Time Template Compilation

For maximum performance, templates can be compiled to native Zig code at build time.

### Setup in build.zig

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const pugz_dep = b.dependency("pugz", .{});
    
    // Compile templates at build time
    const build_templates = @import("pugz").build_templates;
    const compiled_templates = build_templates.compileTemplates(b, .{
        .source_dir = "views",  // Directory containing .pug files
    });

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{
                .{ .name = "pugz", .module = pugz_dep.module("pugz") },
                .{ .name = "tpls", .module = compiled_templates },
            },
        }),
    });
}
```

### Usage in Code

```zig
const tpls = @import("tpls");

pub fn handleRequest(allocator: std.mem.Allocator) ![]u8 {
    // Zero-cost template rendering - just native Zig code
    return try tpls.home(allocator, .{
        .title = "Welcome",
        .user = .{ .name = "Alice", .email = "alice@example.com" },
        .items = &[_][]const u8{ "One", "Two", "Three" },
    });
}
```

### Generated Code Features

The compiler generates optimized Zig code with:
- **Static string merging** - Consecutive static content merged into single `appendSlice` calls
- **Zero allocation for static templates** - Returns string literal directly
- **Type-safe data access** - Uses `@field(d, "name")` for compile-time checked field access
- **Automatic type conversion** - `strVal()` helper converts integers to strings
- **Optional handling** - Nullable slices handled with `orelse &.{}`
- **HTML escaping** - Lookup table for fast character escaping

### Benchmark Results (2000 iterations)

| Template | Pug.js | Pugz | Speedup |
|----------|--------|------|---------|
| simple-0 | 0.8ms | 0.1ms | **8x** |
| simple-1 | 1.4ms | 0.6ms | **2.3x** |
| simple-2 | 1.8ms | 0.6ms | **3x** |
| if-expression | 0.6ms | 0.2ms | **3x** |
| projects-escaped | 4.4ms | 0.6ms | **7.3x** |
| search-results | 15.2ms | 5.6ms | **2.7x** |
| friends | 153.5ms | 54.0ms | **2.8x** |
| **TOTAL** | **177.6ms** | **61.6ms** | **~3x faster** |

Run benchmarks:
```bash
# Pugz (Zig)
zig build bench-compiled

# Pug.js (for comparison)
cd src/benchmarks/pugjs && npm install && npm run bench
```

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

**Important**: The lexer distinguishes between `#id` (ID selector), `#{expr}` (interpolation), and `#[tag]` (tag interpolation) by looking ahead at the next character.

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

// Interpolation-only text works too
h1.header #{title}          // renders <h1 class="header">Title Value</h1>
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

// String comparison in conditions
if status == "active"
  p Active
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

// Nested iteration with field access
each friend in friends
  li #{friend.name}
  each tag in friend.tags
    span= tag
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

### Compiled Templates (Recommended for Production)

Use build-time compilation for best performance. See "Build-Time Template Compilation" section above.

### ViewEngine (Runtime Rendering)

The `ViewEngine` provides runtime template rendering with lazy-loading:

```zig
const std = @import("std");
const pugz = @import("pugz");

// Initialize once at server startup
var engine = try pugz.ViewEngine.init(allocator, .{
    .views_dir = "src/views",     // Root views directory
    .mixins_dir = "mixins",       // Mixins dir for lazy-loading (optional, default: "mixins")
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

### Mixin Resolution (Lazy Loading)

Mixins are resolved in the following order:
1. **Same template** - Mixins defined in the current template file
2. **Mixins directory** - If not found, searches `views/mixins/*.pug` files (lazy-loaded on first use)

This lazy-loading approach means:
- Mixins are only parsed when first called
- No upfront loading of all mixin files at server startup
- Templates can override mixins from the mixins directory by defining them locally

### Directory Structure

```
src/views/
├── mixins/           # Lazy-loaded mixins (searched when mixin not found in template)
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
- `+btn("Click")` - Mixins from mixins/ dir loaded on-demand

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
- Interpolation-only text (e.g., `h1.class #{var}`)
- Conditionals (if/else if/else/unless)
- Iteration (each with index, else branch, objects, nested loops)
- Case/when statements
- Mixin definitions and calls (with defaults, rest args, block content, attributes)
- Plain text (piped, dot blocks, literal HTML)
- Self-closing tags (void elements, explicit `/`)
- Block expansion with colon
- Comments (rendered and silent)
- String comparison in conditions

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
- Mixin support in compiled templates
