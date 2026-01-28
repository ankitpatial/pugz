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

### ViewEngine

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

### Compiled Templates (Maximum Performance)

For production deployments, pre-compile `.pug` templates to Zig functions at build time. This eliminates parsing overhead and provides type-safe data binding.

**Step 1: Update your `build.zig`**

```zig
const std = @import("std");
const pugz = @import("pugz");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pugz_dep = b.dependency("pugz", .{
        .target = target,
        .optimize = optimize,
    });

    // Add template compilation step
    const compile_templates = pugz.compile_tpls.addCompileStep(b, .{
        .name = "compile-templates",
        .source_dirs = &.{"views/pages", "views/partials"},
        .output_dir = "generated",
    });

    // Templates module from compiled output
    const templates_mod = b.createModule(.{
        .root_source_file = compile_templates.getOutput(),
    });

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pugz", .module = pugz_dep.module("pugz") },
                .{ .name = "templates", .module = templates_mod },
            },
        }),
    });

    // Ensure templates compile before building
    exe.step.dependOn(&compile_templates.step);

    b.installArtifact(exe);
}
```

**Step 2: Use compiled templates**

```zig
const templates = @import("templates");

fn handler(res: *httpz.Response) !void {
    res.content_type = .HTML;
    res.body = try templates.pages_home.render(res.arena, .{
        .title = "Home",
        .name = "Alice",
    });
}
```

**Template naming:**
- `views/pages/home.pug` → `templates.pages_home`
- `views/pages/product-detail.pug` → `templates.pages_product_detail`
- Directory separators and dashes become underscores

**Benefits:**
- Zero parsing overhead at runtime
- Type-safe data binding with compile-time errors
- Template inheritance (`extends`/`block`) fully resolved at build time

**Current limitations:**
- `each`/`if` statements not yet supported in compiled mode
- All data fields must be `[]const u8`

See `examples/demo/` for a complete working example.

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

Same templates and data (`src/tests/benchmarks/templates/`), MacBook Air M2, 2000 iterations, best of 5 runs.

### Benchmark Modes

| Mode | Description |
|------|-------------|
| **Pug.js** | Node.js Pug - compile once, render many |
| **Prerender** | Pugz - parse + render every iteration (no caching) |
| **Cached** | Pugz - parse once, render many (like Pug.js) |
| **Compiled** | Pugz - pre-compiled to Zig functions (zero parse overhead) |

### Results

| Template | Pug.js | Prerender | Cached | Compiled |
|----------|--------|-----------|--------|----------|
| simple-0 | 0.8ms | 23.1ms | 132.3µs | 15.9µs |
| simple-1 | 1.5ms | 33.5ms | 609.3µs | 17.3µs |
| simple-2 | 1.7ms | 38.4ms | 936.8µs | 17.8µs |
| if-expression | 0.6ms | 28.8ms | 23.0µs | 15.5µs |
| projects-escaped | 4.6ms | 34.2ms | 1.2ms | 15.8µs |
| search-results | 15.3ms | 34.0ms | 43.5µs | 15.6µs |
| friends | 156.7ms | 34.7ms | 739.0µs | 16.8µs |
| **TOTAL** | **181.3ms** | **227.7ms** | **3.7ms** | **114.8µs** |

Compiled templates are ~32x faster than cached and ~2000x faster than prerender.

### Run Benchmarks

```bash
# Pugz (all modes)
zig build bench

# Pug.js (for comparison)
cd src/tests/benchmarks/pugjs && npm install && npm run bench
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
