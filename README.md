# Pugz

A Pug template engine written in Zig. Templates are parsed and rendered with data at runtime.

## Features

- Pug syntax (tags, classes, IDs, attributes)
- Interpolation (`#{var}`, `!{unescaped}`)
- Conditionals (`if`, `else if`, `else`, `unless`)
- Iteration (`each`, `while`)
- Template inheritance (`extends`, `block`, `append`, `prepend`)
- Includes
- Mixins with parameters, defaults, rest args, and block content
- Comments (rendered and unbuffered)
- Pretty printing with indentation

## Installation

Add pugz as a dependency in your `build.zig.zon`:

```bash
zig fetch --save "git+https://github.com/ankitpatial/pugz#main"
```

Then in your `build.zig`:

```zig
const pugz_dep = b.dependency("pugz", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("pugz", pugz_dep.module("pugz"));
```

---

## Usage

### ViewEngine (Recommended)

The `ViewEngine` provides file-based template management for web servers.

```zig
const std = @import("std");
const pugz = @import("pugz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize once at server startup
    var engine = pugz.ViewEngine.init(.{
        .views_dir = "views",
    });
    defer engine.deinit();

    // Per-request rendering with arena allocator
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const html = try engine.render(arena.allocator(), "pages/index", .{
        .title = "Hello",
        .name = "World",
    });

    std.debug.print("{s}\n", .{html});
}
```

### Inline Templates

For simple use cases or testing, render template strings directly:

```zig
const html = try pugz.renderTemplate(allocator,
    \\h1 Hello, #{name}!
    \\ul
    \\  each item in items
    \\    li= item
, .{
    .name = "World",
    .items = &[_][]const u8{ "one", "two", "three" },
});
```

### With http.zig

```zig
const pugz = @import("pugz");
const httpz = @import("httpz");

var engine: pugz.ViewEngine = undefined;

pub fn main() !void {
    engine = pugz.ViewEngine.init(.{
        .views_dir = "views",
    });
    defer engine.deinit();

    var server = try httpz.Server(*Handler).init(allocator, .{}, handler);
    try server.listen();
}

fn handler(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .HTML;
    res.body = try engine.render(res.arena, "pages/home", .{
        .title = "Hello",
        .user = .{ .name = "Alice" },
    });
}
```

---

## ViewEngine Options

```zig
var engine = pugz.ViewEngine.init(.{
    .views_dir = "views",           // Root directory for templates
    .extension = ".pug",            // File extension (default: .pug)
    .pretty = false,                // Enable pretty-printed output
});
```

| Option | Default | Description |
|--------|---------|-------------|
| `views_dir` | `"views"` | Root directory containing templates |
| `extension` | `".pug"` | File extension for templates |
| `pretty` | `false` | Enable pretty-printed HTML with indentation |

---

## Memory Management

Always use an `ArenaAllocator` for rendering. Template rendering creates many small allocations that should be freed together after the response is sent.

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();

const html = try engine.render(arena.allocator(), "index", data);
```

---

## Documentation

- [Template Syntax](docs/syntax.md) - Complete syntax reference
- [API Reference](docs/api.md) - Detailed API documentation

---

## Benchmarks

Same templates and data (`benchmarks/templates/`), MacBook Air M2, 2000 iterations, best of 5 runs.

Both Pug.js and Pugz parse templates once, then measure render-only time.

| Template | Pug.js | Pugz | Speedup |
|----------|--------|------|---------|
| simple-0 | 0.8ms | 0.2ms | 4x |
| simple-1 | 1.5ms | 0.9ms | 1.7x |
| simple-2 | 1.7ms | 2.4ms | 0.7x |
| if-expression | 0.6ms | 0.4ms | 1.5x |
| projects-escaped | 4.6ms | 2.4ms | 1.9x |
| search-results | 15.3ms | 17.7ms | 0.9x |
| friends | 156.7ms | 132.2ms | 1.2x |
| **TOTAL** | **181.3ms** | **156.2ms** | **1.16x** |

Run benchmarks:
```bash
# Pugz
zig build bench

# Pug.js (for comparison)
cd benchmarks/pugjs && npm install && npm run bench
```

---

## Development

```bash
zig build test    # Run all tests
zig build bench   # Run benchmarks
```

---

## License

MIT
