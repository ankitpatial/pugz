# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Pugz is a Pug-like HTML template engine written in Zig 0.15.2. It compiles Pug templates directly to HTML (unlike JS pug which compiles to JavaScript functions). It implements Pug 3 syntax for indentation-based HTML templating with a focus on server-side rendering.

## Rules
- Do not auto commit, user will do it.
- At the start of each new session, read this CLAUDE.md file to understand project context and rules.
- When the user specifies a new rule, update this CLAUDE.md file to include it.
- Code comments are required but must be meaningful, not bloated. Focus on explaining "why" not "what". Avoid obvious comments like "// increment counter" - instead explain complex logic, non-obvious decisions, or tricky edge cases.
- **All documentation files (.md) must be saved to the `docs/` directory.** Do not create .md files in the root directory or examples directories - always place them in `docs/`.
- **Follow Zig standards for the version specified in `build.zig.zon`** (currently 0.15.2). This includes:
  - Use `std.ArrayList(T)` instead of the deprecated `std.ArrayListUnmanaged(T)` (renamed in Zig 0.15)
  - Pass allocator to method calls (`append`, `deinit`, etc.) as per the unmanaged pattern
  - Check Zig release notes for API changes when updating the minimum Zig version
- **Publish command**: Only when user explicitly says "publish", do the following:
  1. Bump the fix version (patch version in build.zig.zon)
  2. Git commit with appropriate message
  3. Git push to remote `origin` and remote `github`
  - Do NOT publish automatically or without explicit user request.

## Build Commands

- `zig build` - Build the project (output in `zig-out/`)
- `zig build test` - Run all tests
- `zig build test-compile` - Test the template compilation build step
- `zig build bench-v1` - Run v1 template benchmark
- `zig build bench-interpreted` - Run interpreted templates benchmark

## Architecture Overview

### Compilation Pipeline

```
Source → Lexer → Tokens → StripComments → Parser → AST → Linker → Codegen → HTML
```

### Three Rendering Modes

1. **Static compilation** (`pug.compile`): Outputs HTML directly via `codegen.zig`
2. **Data binding** (`template.renderWithData`): Supports `#{field}` interpolation with Zig structs via `template.zig`
3. **Compiled templates** (`.pug` → `.zig`): Pre-compile templates to Zig functions via `zig_codegen.zig`

### Important: Shared AST Consumers

**codegen.zig**, **template.zig**, and **zig_codegen.zig** all consume the AST from the parser. When fixing bugs related to AST structure (like attribute handling, class merging, etc.), prefer fixing in **parser.zig** so all three rendering paths benefit from the fix automatically. Only fix in the individual codegen modules if the behavior should differ between rendering modes.

### Shared Utilities in runtime.zig

The `runtime.zig` module is the single source of truth for shared utilities used across all rendering modes:

- **`isHtmlEntity(str)`** - Checks if string starts with valid HTML entity (`&name;`, `&#digits;`, `&#xhex;`)
- **`appendTextEscaped(allocator, output, str)`** - Escapes text content (`<`, `>`, `&`) preserving existing entities
- **`isXhtmlDoctype(val)`** - Checks if doctype is XHTML (xml, strict, transitional, frameset, 1.1, basic, mobile)
- **`escapeChar(c)`** - O(1) lookup table for HTML character escaping
- **`appendEscaped(allocator, output, str)`** - Escapes all HTML special chars including quotes
- **`doctypes`** - StaticStringMap of doctype names to DOCTYPE strings
- **`whitespace_sensitive_tags`** - Tags where whitespace matters (pre, textarea, script, style, code)

The `codegen.zig` module provides:
- **`void_elements`** - StaticStringMap of HTML5 void/self-closing elements (br, img, input, etc.)

### Core Modules

| Module | File | Purpose |
|--------|------|---------|
| **Lexer** | `src/lexer.zig` | Tokenizes Pug source into tokens |
| **Parser** | `src/parser.zig` | Builds AST from tokens |
| **Runtime** | `src/runtime.zig` | Shared utilities (HTML escaping, entity detection, doctype helpers) |
| **Error** | `src/error.zig` | Error formatting with source context |
| **Walk** | `src/walk.zig` | AST traversal with visitor pattern |
| **Strip Comments** | `src/strip_comments.zig` | Token filtering for comments |
| **Load** | `src/load.zig` | File loading for includes/extends |
| **Linker** | `src/linker.zig` | Template inheritance (extends/blocks) |
| **Codegen** | `src/codegen.zig` | AST to HTML generation |
| **Template** | `src/template.zig` | Data binding renderer |
| **Pug** | `src/pug.zig` | Main entry point |
| **ViewEngine** | `src/view_engine.zig` | High-level API for web servers |
| **ZigCodegen** | `src/tpl_compiler/zig_codegen.zig` | Compiles .pug AST to Zig functions |
| **CompileTpls** | `src/compile_tpls.zig` | Build step for compiling templates at build time |
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

### Compiled Templates (Maximum Performance)

For production deployments where maximum performance is critical, you can pre-compile .pug templates to Zig functions using a build step:

**Step 1: Add build step to your build.zig**
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add pugz dependency
    const pugz_dep = b.dependency("pugz", .{
        .target = target,
        .optimize = optimize,
    });
    const pugz = pugz_dep.module("pugz");

    // Add template compilation build step
    const compile_templates = @import("pugz").addCompileStep(b, .{
        .name = "compile-templates",
        .source_dirs = &.{"src/views", "src/pages"},  // Can specify multiple directories
        .output_dir = "generated",
    });

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("pugz", pugz);
    exe.root_module.addImport("templates", compile_templates.getOutput());
    exe.step.dependOn(&compile_templates.step);

    b.installArtifact(exe);
}
```

**Step 2: Use compiled templates in your code**
```zig
const std = @import("std");
const tpls = @import("templates");  // Import from build step

pub fn handleRequest(allocator: std.mem.Allocator) ![]const u8 {
    // Access templates by their path: views/pages/home.pug -> tpls.views_pages_home
    return try tpls.views_home.render(allocator, .{
        .title = "Home",
        .name = "Alice",
    });
}

// Or use layouts
pub fn renderLayout(allocator: std.mem.Allocator) ![]const u8 {
    return try tpls.layouts_base.render(allocator, .{
        .content = "Main content here",
    });
}
```

**How templates are named:**
- `views/home.pug` → `tpls.views_home`
- `pages/about.pug` → `tpls.pages_about`
- `layouts/main.pug` → `tpls.layouts_main`
- `views/user-profile.pug` → `tpls.views_user_profile` (dashes become underscores)
- Directory separators and dashes are converted to underscores

**Performance Benefits:**
- **Zero parsing overhead** - templates compiled at build time
- **Type-safe data binding** - compile errors for missing fields
- **Optimized code** - direct string concatenation instead of AST traversal
- **~10-100x faster** than runtime parsing depending on template complexity

**What gets resolved at compile time:**
- Template inheritance (`extends`/`block`) - fully resolved
- Includes (`include`) - inlined into template
- Mixins - available in compiled templates

**Trade-offs:**
- Templates are regenerated automatically when you run `zig build`
- Includes/extends are resolved at compile time (no dynamic loading)
- Each/if statements not yet supported (coming soon)

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
├── src/                    # Source code
│   ├── root.zig            # Public library API
│   ├── view_engine.zig     # High-level ViewEngine
│   ├── pug.zig             # Main entry point (static compilation)
│   ├── template.zig        # Data binding renderer
│   ├── compile_tpls.zig    # Build step for template compilation
│   ├── lexer.zig           # Tokenizer
│   ├── parser.zig          # AST parser
│   ├── runtime.zig         # Shared utilities
│   ├── error.zig           # Error formatting
│   ├── walk.zig            # AST traversal
│   ├── strip_comments.zig  # Comment filtering
│   ├── load.zig            # File loading
│   ├── linker.zig          # Template inheritance
│   ├── codegen.zig         # HTML generation
│   └── tpl_compiler/       # Template-to-Zig code generation
│       ├── zig_codegen.zig     # AST to Zig function compiler
│       ├── main.zig            # CLI tool (standalone)
│       └── helpers_template.zig # Runtime helpers template
├── tests/              # Integration tests
│   ├── general_test.zig
│   ├── doctype_test.zig
│   └── check_list_test.zig
├── benchmarks/         # Performance benchmarks
├── docs/               # Documentation
├── examples/           # Example templates
└── playground/         # Development playground
```
