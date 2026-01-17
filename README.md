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

2000 iterations on MacBook Air M2:

| Template | Pugz | Pug.js | Speedup |
|----------|------|--------|---------|
| simple-0 | 0.6ms | 2ms | 3.4x |
| simple-1 | 6.9ms | 9ms | 1.3x |
| simple-2 | 7.7ms | 9ms | 1.2x |
| if-expression | 6.0ms | 12ms | 2.0x |
| projects-escaped | 9.3ms | 86ms | 9.2x |

## License

MIT
