# Pugz API Reference

## Compiled Mode

### Build Setup

In `build.zig`:

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
        .source_dir = "views",        // Required: directory containing .pug files
        .extension = ".pug",          // Optional: default ".pug"
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

### Using Compiled Templates

```zig
const std = @import("std");
const tpls = @import("tpls");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Template function name is derived from filename
    // views/home.pug -> tpls.home()
    // views/pages/about.pug -> tpls.pages_about()
    const html = try tpls.home(arena.allocator(), .{
        .title = "Welcome",
        .items = &[_][]const u8{ "One", "Two" },
    });

    std.debug.print("{s}\n", .{html});
}
```

### Template Names

File paths are converted to function names:
- `home.pug` → `home()`
- `pages/about.pug` → `pages_about()`
- `admin-panel.pug` → `admin_panel()`

List all available templates:
```zig
for (tpls.template_names) |name| {
    std.debug.print("{s}\n", .{name});
}
```

---

## Interpreted Mode

### ViewEngine

```zig
const std = @import("std");
const pugz = @import("pugz");

pub fn main() !void {
    // Initialize engine
    var engine = pugz.ViewEngine.init(.{
        .views_dir = "views",         // Required: root views directory
        .mixins_dir = "mixins",       // Optional: default "mixins"
        .extension = ".pug",          // Optional: default ".pug"
        .pretty = true,               // Optional: default true
    });

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Render template (path relative to views_dir, no extension needed)
    const html = try engine.render(arena.allocator(), "pages/home", .{
        .title = "Hello",
        .name = "World",
    });

    std.debug.print("{s}\n", .{html});
}
```

### renderTemplate

For inline template strings:

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

## Data Types

Templates accept Zig structs as data. Supported field types:

| Zig Type | Template Usage |
|----------|----------------|
| `[]const u8` | `#{field}` |
| `i64`, `i32`, etc. | `#{field}` (converted to string) |
| `bool` | `if field` |
| `[]const T` | `each item in field` |
| `?T` (optional) | `if field` (null = false) |
| nested struct | `#{field.subfield}` |

### Example

```zig
const data = .{
    .title = "My Page",
    .count = 42,
    .show_header = true,
    .items = &[_][]const u8{ "a", "b", "c" },
    .user = .{
        .name = "Alice",
        .email = "alice@example.com",
    },
};

const html = try tpls.home(allocator, data);
```

Template:
```pug
h1= title
p Count: #{count}
if show_header
  header Welcome
ul
  each item in items
    li= item
p #{user.name} (#{user.email})
```

---

## Directory Structure

Recommended project layout:

```
myproject/
├── build.zig
├── build.zig.zon
├── src/
│   └── main.zig
└── views/
    ├── mixins/
    │   ├── buttons.pug
    │   └── cards.pug
    ├── layouts/
    │   └── base.pug
    ├── partials/
    │   ├── header.pug
    │   └── footer.pug
    └── pages/
        ├── home.pug
        └── about.pug
```

### Mixin Resolution

Mixins are resolved in order:
1. Defined in the current template
2. Loaded from `views/mixins/*.pug` (lazy-loaded on first use)

---

## Web Framework Integration

### http.zig

```zig
const std = @import("std");
const httpz = @import("httpz");
const tpls = @import("tpls");

const App = struct {
    // app state
};

fn handler(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = app;
    _ = req;

    const html = try tpls.home(res.arena, .{
        .title = "Hello",
    });

    res.content_type = .HTML;
    res.body = html;
}
```

### Using ViewEngine with http.zig

```zig
const App = struct {
    engine: pugz.ViewEngine,
};

fn handler(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;

    const html = app.engine.render(res.arena, "home", .{
        .title = "Hello",
    }) catch |err| {
        res.status = 500;
        res.body = @errorName(err);
        return;
    };

    res.content_type = .HTML;
    res.body = html;
}
```

---

## Error Handling

```zig
const html = engine.render(allocator, "home", data) catch |err| {
    switch (err) {
        error.FileNotFound => // template file not found
        error.ParseError => // invalid template syntax
        error.OutOfMemory => // allocation failed
        else => // other errors
    }
};
```

---

## Memory Management

Always use `ArenaAllocator` for template rendering:

```zig
// Per-request pattern
fn handleRequest(allocator: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    return try tpls.home(arena.allocator(), .{ .title = "Hello" });
}
```

The arena pattern is efficient because:
- Template rendering creates many small allocations
- All allocations are freed at once with `arena.deinit()`
- No need to track individual allocations
