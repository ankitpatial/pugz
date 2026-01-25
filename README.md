# Pugz

A Pug template engine for Zig, supporting both build-time compilation and runtime interpretation.

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
- LRU cache with configurable size and TTL

## Installation

Add pugz as a dependency in your `build.zig.zon`:

```bash
zig fetch --save "git+https://github.com/ankitpatial/pugz#main"
```

---

## Usage

### Compiled Mode (Build-Time)

Templates are converted to native Zig code at build time. No parsing happens at runtime.

**build.zig:**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pugz_dep = b.dependency("pugz", .{
        .target = target,
        .optimize = optimize,
    });

    const build_templates = @import("pugz").build_templates;
    const compiled_templates = build_templates.compileTemplates(b, .{
        .source_dir = "views",
    });

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pugz", .module = pugz_dep.module("pugz") },
                .{ .name = "tpls", .module = compiled_templates },
            },
        }),
    });

    b.installArtifact(exe);
}
```

**Usage:**

```zig
const std = @import("std");
const tpls = @import("tpls");

pub fn handleRequest(allocator: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    return try tpls.home(arena.allocator(), .{
        .title = "Welcome",
        .user = .{ .name = "Alice" },
        .items = &[_][]const u8{ "One", "Two", "Three" },
    });
}
```

---

### Interpreted Mode (Runtime)

Templates are parsed and evaluated at runtime. Useful for development or dynamic templates.

```zig
const std = @import("std");
const pugz = @import("pugz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try pugz.ViewEngine.init(allocator, .{
        .views_dir = "views",
    });
    defer engine.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const html = try engine.render(arena.allocator(), "index", .{
        .title = "Hello",
        .name = "World",
    });

    std.debug.print("{s}\n", .{html});
}
```

**Inline template strings:**

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

---

### ViewEngine Options

```zig
var engine = try pugz.ViewEngine.init(allocator, .{
    .views_dir = "views",           // Root directory for templates
    .extension = ".pug",            // File extension (default: .pug)
    .pretty = false,                // Enable pretty-printed output
    .cache_enabled = true,          // Enable AST caching
    .max_cached_templates = 100,    // LRU cache size (0 = unlimited)
    .cache_ttl_seconds = 5,         // Cache TTL for development (0 = never expires)
});
```

**Options:**

| Option | Default | Description |
|--------|---------|-------------|
| `views_dir` | `"views"` | Root directory containing templates |
| `extension` | `".pug"` | File extension for templates |
| `pretty` | `false` | Enable pretty-printed HTML with indentation |
| `cache_enabled` | `true` | Enable AST caching for performance |
| `max_cached_templates` | `0` | Max templates in LRU cache (0 = unlimited hashmap) |
| `cache_ttl_seconds` | `0` | Cache TTL in seconds (0 = never expires) |

---

### With http.zig

```zig
fn handler(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    // Compiled mode
    const html = try tpls.home(res.arena, .{
        .title = "Hello",
    });

    res.content_type = .HTML;
    res.body = html;
}
```

---

## Memory Management

Always use an `ArenaAllocator` for rendering. Template rendering creates many small allocations that should be freed together.

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

Same templates and data (`src/benchmarks/templates/`), MacBook Air M2, 2000 iterations, best of 5 runs.

| Template | Pug.js | Pugz Compiled | Diff | Pugz Interpreted | Diff |
|----------|--------|---------------|------|------------------|------|
| simple-0 | 0.4ms | 0.1ms | +4x | 0.4ms | 1x |
| simple-1 | 1.3ms | 0.6ms | +2.2x | 5.8ms | -4.5x |
| simple-2 | 1.6ms | 0.5ms | +3.2x | 4.6ms | -2.9x |
| if-expression | 0.5ms | 0.2ms | +2.5x | 4.1ms | -8.2x |
| projects-escaped | 4.2ms | 0.6ms | +7x | 5.8ms | -1.4x |
| search-results | 14.7ms | 5.3ms | +2.8x | 50.7ms | -3.4x |
| friends | 145.5ms | 50.4ms | +2.9x | 450.8ms | -3.1x |

- Pug.js and Pugz Compiled: render-only (pre-compiled)
- Pugz Interpreted: parse + render on each iteration
- Diff: +Nx = N times faster, -Nx = N times slower

---

## Development

```bash
zig build test                # Run all tests
zig build bench-compiled      # Benchmark compiled mode
zig build bench-interpreted   # Benchmark interpreted mode

# Pug.js benchmark (for comparison)
cd src/benchmarks/pugjs && npm install && npm run bench
```

---

## License

MIT
