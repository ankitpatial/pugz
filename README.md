# Pugz

A Pug template engine for Zig.

## Features

- Pug syntax (tags, classes, IDs, attributes)
- Interpolation (`#{var}`, `!{unescaped}`)
- Conditionals (`if`, `else if`, `else`, `unless`)
- Iteration (`each`, `while`)
- Template inheritance (`extends`, `block`, `append`, `prepend`)
- Includes
- Mixins with parameters, defaults, rest args, and block content
- Comments (rendered and unbuffered)

## Installation

Add to `build.zig.zon`:

```zig
.dependencies = .{
    .pugz = .{
        .url = "git+https://github.com/ankitpatial/pugz",
    },
},
```

Then in `build.zig`:

```zig
const pugz = b.dependency("pugz", .{});
exe.root_module.addImport("pugz", pugz.module("pugz"));
```

## Usage

```zig
const std = @import("std");
const pugz = @import("pugz");

pub fn main() !void {
    const engine = pugz.ViewEngine.init(.{
        .views_dir = "views",
    });

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const html = try engine.render(arena.allocator(), "index", .{
        .title = "Hello",
        .name = "World",
    });

    std.debug.print("{s}\n", .{html});
}
```

### Template String

```zig
const html = try engine.renderTpl(allocator,
    \\h1 Hello, #{name}!
    \\ul
    \\  each item in items
    \\    li= item
, .{
    .name = "World",
    .items = &[_][]const u8{ "one", "two", "three" },
});
```

## Development

### Run Tests

```bash
zig build test
```

### Run Benchmarks

```bash
zig build bench      # Run rendering benchmarks
zig build bench-2    # Run comparison benchmarks
```

## Template Syntax

```pug
doctype html
html
  head
    title= title
  body
    h1.header Hello, #{name}!
    
    if authenticated
      p Welcome back!
    else
      a(href="/login") Sign in
    
    ul
      each item in items
        li= item
```

## Benchmarks

### Rendering Benchmarks (`zig build bench`)

20,000 iterations on MacBook Air M2:

| Template | Avg | Renders/sec | Output |
|----------|-----|-------------|--------|
| Simple | 11.81 us | 84,701 | 155 bytes |
| Medium | 21.10 us | 47,404 | 1,211 bytes |
| Complex | 33.48 us | 29,872 | 4,852 bytes |

### Comparison Benchmarks (`zig build bench-2`)

2,000 iterations vs Pug.js:

| Template | Pugz | Pug.js | Speedup |
|----------|------|--------|---------|
| simple-0 | 0.5ms | 2ms | 3.8x |
| simple-1 | 6.7ms | 9ms | 1.3x |
| simple-2 | 5.4ms | 9ms | 1.7x |
| if-expression | 4.4ms | 12ms | 2.7x |
| projects-escaped | 7.3ms | 86ms | 11.7x |
| search-results | 70.6ms | 41ms | 0.6x |
| friends | 682.1ms | 110ms | 0.2x |

## License

MIT
