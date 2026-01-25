# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Pugz is a Pug-like HTML template engine written in Zig 0.15.2. It compiles Pug templates directly to HTML (unlike JS pug which compiles to JavaScript functions). It implements Pug 3 syntax for indentation-based HTML templating with a focus on server-side rendering.

## Rules
- Do not auto commit, user will do it.
- At the start of each new session, read this CLAUDE.md file to understand project context and rules.
- When the user specifies a new rule, update this CLAUDE.md file to include it.
- Code comments are required but must be meaningful, not bloated. Focus on explaining "why" not "what". Avoid obvious comments like "// increment counter" - instead explain complex logic, non-obvious decisions, or tricky edge cases.

## Build Commands

- `zig build` - Build the project (output in `zig-out/`)
- `zig build test` - Run all tests
- `zig build bench-v1` - Run v1 template benchmark
- `zig build bench-interpreted` - Run interpreted templates benchmark

## Architecture Overview

### Compilation Pipeline

```
Source → Lexer → Tokens → StripComments → Parser → AST → Linker → Codegen → HTML
```

### Two Rendering Modes

1. **Static compilation** (`pug.compile`): Outputs HTML directly
2. **Data binding** (`template.renderWithData`): Supports `#{field}` interpolation with Zig structs

### Core Modules

| Module | File | Purpose |
|--------|------|---------|
| **Lexer** | `src/lexer.zig` | Tokenizes Pug source into tokens |
| **Parser** | `src/parser.zig` | Builds AST from tokens |
| **Runtime** | `src/runtime.zig` | Shared utilities (HTML escaping, etc.) |
| **Error** | `src/error.zig` | Error formatting with source context |
| **Walk** | `src/walk.zig` | AST traversal with visitor pattern |
| **Strip Comments** | `src/strip_comments.zig` | Token filtering for comments |
| **Load** | `src/load.zig` | File loading for includes/extends |
| **Linker** | `src/linker.zig` | Template inheritance (extends/blocks) |
| **Codegen** | `src/codegen.zig` | AST to HTML generation |
| **Template** | `src/template.zig` | Data binding renderer |
| **Pug** | `src/pug.zig` | Main entry point |
| **ViewEngine** | `src/view_engine.zig` | High-level API for web servers |
| **Root** | `src/root.zig` | Public library API exports |

### Test Files

- **tests/general_test.zig** - Comprehensive integration tests
- **tests/doctype_test.zig** - Doctype-specific tests
- **tests/check_list_test.zig** - Template output validation tests

## API Usage

### Static Compilation (no data)

```zig
const std = @import("std");
const pug = @import("pugz").pug;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var result = try pug.compile(allocator, "p Hello World", .{});
    defer result.deinit(allocator);

    std.debug.print("{s}\n", .{result.html}); // <p>Hello World</p>
}
```

### Dynamic Rendering with Data

```zig
const std = @import("std");
const pugz = @import("pugz");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const html = try pugz.renderTemplate(arena.allocator(),
        \\h1 #{title}
        \\p #{message}
    , .{
        .title = "Welcome",
        .message = "Hello, World!",
    });

    std.debug.print("{s}\n", .{html});
    // Output: <h1>Welcome</h1><p>Hello, World!</p>
}
```

### Data Binding Features

- **Interpolation**: `#{fieldName}` in text content
- **Attribute binding**: `a(href=url)` binds `url` field to href
- **Buffered code**: `p= message` outputs the `message` field
- **Auto-escaping**: HTML is escaped by default (XSS protection)

```zig
const html = try pugz.renderTemplate(allocator,
    \\a(href=url, class=style) #{text}
, .{
    .url = "https://example.com",
    .style = "btn",
    .text = "Click me!",
});
// Output: <a href="https://example.com" class="btn">Click me!</a>
```

### ViewEngine (for Web Servers)

```zig
const std = @import("std");
const pugz = @import("pugz");

const engine = pugz.ViewEngine.init(.{
    .views_dir = "src/views",
    .extension = ".pug",
});

// In request handler
pub fn handleRequest(allocator: std.mem.Allocator) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    return try engine.render(arena.allocator(), "pages/home", .{
        .title = "Home",
        .user = .{ .name = "Alice" },
    });
}
```

### Compile Options

```zig
pub const CompileOptions = struct {
    filename: ?[]const u8 = null,        // For error messages
    basedir: ?[]const u8 = null,         // For absolute includes
    pretty: bool = false,                 // Pretty print output
    strip_unbuffered_comments: bool = true,
    strip_buffered_comments: bool = false,
    debug: bool = false,
    doctype: ?[]const u8 = null,
};
```

## Memory Management

**Important**: The runtime is designed to work with `ArenaAllocator`:

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();  // Frees all template memory at once

const html = try pugz.renderTemplate(arena.allocator(), template, data);
```

This pattern is recommended because template rendering creates many small allocations that are all freed together after the response is sent.

## Key Implementation Notes

### Lexer (`lexer.zig`)
- `Lexer.init(allocator, source, options)` - Initialize
- `Lexer.getTokens()` - Returns token slice
- `Lexer.last_error` - Check for errors after failed `getTokens()`

### Parser (`parser.zig`)
- `Parser.init(allocator, tokens, filename, source)` - Initialize
- `Parser.parse()` - Returns AST root node
- `Parser.err` - Check for errors after failed `parse()`

### Codegen (`codegen.zig`)
- `Compiler.init(allocator, options)` - Initialize
- `Compiler.compile(ast)` - Returns HTML string

### Walk (`walk.zig`)
- Uses O(1) stack operations (append/pop) not O(n) insert/remove
- `getParent(index)` uses reverse indexing (0 = immediate parent)
- `initWithCapacity()` for pre-allocation optimization

### Runtime (`runtime.zig`)
- `escapeChar(c)` - Shared HTML escape function
- `appendEscaped(list, allocator, str)` - Append with escaping

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
p Hello #{name}             // escaped interpolation (SAFE - default)
p Hello !{rawHtml}          // unescaped interpolation (UNSAFE - trusted content only)
p= variable                 // buffered code (escaped, SAFE)
p!= rawVariable             // buffered code (unescaped, UNSAFE)
| Piped text line
p.
  Multi-line
  text block
<p>Literal HTML</p>         // passed through as-is
```

**Security Note**: By default, `#{}` and `=` escape HTML entities (`<`, `>`, `&`, `"`, `'`) to prevent XSS attacks. Only use `!{}` or `!=` for content you fully trust.

### Tag Interpolation
```pug
p This is #[em emphasized] text
p Click #[a(href="/") here] to continue
```

### Block Expansion
```pug
a: img(src="logo.png")      // colon for inline nesting
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
```

### Includes & Inheritance
```pug
include header.pug

extends layout.pug
block content
  h1 Page Title
```

### Comments
```pug
// This renders as HTML comment
//- This is a silent comment (not in output)
```

## Benchmark Results (2000 iterations)

| Template | Time |
|----------|------|
| simple-0 | 0.8ms |
| simple-1 | 11.6ms |
| simple-2 | 8.2ms |
| if-expression | 7.4ms |
| projects-escaped | 7.1ms |
| search-results | 13.4ms |
| friends | 22.9ms |
| **TOTAL** | **71.3ms** |

## Limitations vs JS Pug

1. **No JavaScript expressions**: `- var x = 1` not supported
2. **No nested field access**: `#{user.name}` not supported, only `#{name}`
3. **No filters**: `:markdown`, `:coffee` etc. not implemented
4. **String fields only**: Data binding works best with `[]const u8` fields

## Error Handling

Uses error unions with detailed `PugError` context including line, column, and source snippet:
- `LexerError` - Tokenization errors
- `ParserError` - Syntax errors  
- `ViewEngineError` - Template not found, parse errors

## File Structure

```
├── src/                # Source code
│   ├── root.zig            # Public library API
│   ├── view_engine.zig     # High-level ViewEngine
│   ├── pug.zig             # Main entry point (static compilation)
│   ├── template.zig        # Data binding renderer
│   ├── lexer.zig           # Tokenizer
│   ├── parser.zig          # AST parser
│   ├── runtime.zig         # Shared utilities
│   ├── error.zig           # Error formatting
│   ├── walk.zig            # AST traversal
│   ├── strip_comments.zig  # Comment filtering
│   ├── load.zig            # File loading
│   ├── linker.zig          # Template inheritance
│   └── codegen.zig         # HTML generation
├── tests/              # Integration tests
│   ├── general_test.zig
│   ├── doctype_test.zig
│   └── check_list_test.zig
├── benchmarks/         # Performance benchmarks
├── docs/               # Documentation
├── examples/           # Example templates
└── playground/         # Development playground
```
