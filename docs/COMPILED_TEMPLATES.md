# Using Compiled Templates in Demo App

This demo supports both runtime template rendering (default) and compiled templates for maximum performance.

## Quick Start

### 1. Build the pug-compile tool (from main pugz directory)

```bash
cd ../../..  # Go to pugz root
zig build
```

### 2. Compile templates

```bash
cd src/tests/examples/demo
zig build compile-templates
```

This generates Zig code in the `generated/` directory.

### 3. Enable compiled templates

Edit `src/main.zig` and change:

```zig
const USE_COMPILED_TEMPLATES = false;
```

to:

```zig
const USE_COMPILED_TEMPLATES = true;
```

### 4. Build and run

```bash
zig build run
```

Visit http://localhost:8081/simple to see the compiled template in action.

## How It Works

1. **Template Compilation**: The `pug-compile` tool converts `.pug` files to native Zig functions
2. **Generated Code**: Templates in `generated/` are pure Zig with zero parsing overhead
3. **Type Safety**: Data structures are generated with compile-time type checking
4. **Performance**: ~10-100x faster than runtime parsing

## Directory Structure

```
demo/
├── views/pages/          # Source .pug templates
│   └── simple.pug       # Simple template for testing
├── generated/           # Generated Zig code (after compilation)
│   ├── helpers.zig     # Shared helper functions
│   ├── pages/
│   │   └── simple.zig  # Compiled template
│   └── root.zig        # Exports all templates
└── src/
    └── main.zig        # Demo app with template routing
```

## Switching Modes

**Runtime Mode** (default):
- Templates parsed on every request
- Instant template reload during development
- No build step required
- Supports all Pug features

**Compiled Mode**:
- Templates pre-compiled to Zig
- Maximum performance in production
- Requires rebuild when templates change
- Currently supports: basic tags, text interpolation, attributes, doctypes

## Example

**Template** (`views/pages/simple.pug`):
```pug
doctype html
html
  head
    title #{title}
  body
    h1 #{heading}
    p Welcome to #{siteName}!
```

**Generated** (`generated/pages/simple.zig`):
```zig
pub const Data = struct {
    heading: []const u8 = "",
    siteName: []const u8 = "",
    title: []const u8 = "",
};

pub fn render(allocator: std.mem.Allocator, data: Data) ![]const u8 {
    // ... optimized rendering code ...
}
```

**Usage** (`src/main.zig`):
```zig
const templates = @import("templates");
const html = try templates.pages_simple.render(arena, .{
    .title = "My Page",
    .heading = "Hello!",
    .siteName = "Demo Site",
});
```

## Benefits

- **Performance**: No parsing overhead, direct HTML generation
- **Type Safety**: Compile-time checks for missing fields
- **Bundle Size**: Templates embedded in binary
- **Zero Dependencies**: Generated code is self-contained

## Limitations

Currently supported features:
- ✅ Tags and nesting
- ✅ Text and interpolation (`#{field}`)
- ✅ Attributes (static and dynamic)
- ✅ Doctypes
- ✅ Comments
- ✅ Buffered code (`p= field`)
- ✅ HTML escaping

Not yet supported:
- ⏳ Conditionals (if/unless) - in progress
- ⏳ Loops (each)
- ⏳ Mixins
- ⏳ Includes/extends
- ⏳ Case/when

For templates using unsupported features, continue using runtime mode.
