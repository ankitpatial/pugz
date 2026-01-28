# Pugz Examples

This directory contains comprehensive examples demonstrating how to use the Pugz template engine.

## Quick Navigation

| Example | Description | Best For |
|---------|-------------|----------|
| **[use_compiled_templates.zig](#use_compiled_templateszig)** | Simple standalone example | Quick start, learning basics |
| **[demo/](#demo-http-server)** | Full HTTP server with runtime templates | Web applications, production use |
| **[cli-templates-demo/](#cli-templates-demo)** | Complete Pug feature reference | Learning all Pug features |

---

## use_compiled_templates.zig

A minimal standalone example showing how to use pre-compiled templates.

**What it demonstrates:**
- Compiling .pug files to Zig functions
- Type-safe data structures
- Memory management with compiled templates
- Conditional rendering

**How to run:**

```bash
# 1. Build the CLI tool
cd /path/to/pugz
zig build

# 2. Compile templates (if not already done)
./zig-out/bin/pug-compile --dir examples/cli-templates-demo --out generated pages

# 3. Run the example
zig build example-compiled
```

**Files:**
- `use_compiled_templates.zig` - Example code
- Uses templates from `generated/` directory

---

## demo/ - HTTP Server

A complete web server demonstrating both runtime and compiled template modes.

**What it demonstrates:**
- HTTP server integration with [httpz](https://github.com/karlseguin/http.zig)
- Runtime template rendering (default mode)
- Compiled template mode (optional, for performance)
- Layout inheritance (extends/blocks)
- Partials (header/footer)
- Error handling
- Request handling with data binding

**Features:**
- ✅ Full Pug syntax support in runtime mode
- ✅ Fast compiled templates (optional)
- ✅ Hot reload in runtime mode (edit templates, refresh browser)
- ✅ Production-ready architecture

**How to run:**

```bash
# From pugz root
cd examples/demo

# Build and run
zig build run

# Visit: http://localhost:5882
```

**Available routes:**
- `GET /` - Home page
- `GET /about` - About page  
- `GET /simple` - Compiled template demo (if enabled)

**See [demo/README.md](demo/README.md) for full documentation.**

---

## cli-templates-demo/ - Complete Feature Reference

Comprehensive examples demonstrating **every** Pug feature supported by Pugz.

**What it demonstrates:**
- All 14 Pug features from [pugjs.org](https://pugjs.org/language/)
- Template layouts and inheritance
- Reusable mixins (buttons, forms, cards, alerts)
- Includes and partials
- Complete attribute syntax examples
- Conditionals, loops, case statements
- Real-world template patterns

**Contents:**
- `pages/all-features.pug` - Comprehensive feature demo
- `pages/attributes-demo.pug` - All attribute variations
- `layouts/` - Template inheritance examples
- `mixins/` - Reusable components
- `partials/` - Header/footer includes
- `generated/` - Compiled output (after running CLI)

**Documentation:**
- `FEATURES_REFERENCE.md` - Complete guide with examples
- `PUGJS_COMPATIBILITY.md` - Feature-by-feature compatibility with Pug.js
- `VERIFICATION.md` - Test results and code quality checks

**How to compile templates:**

```bash
# From pugz root
./zig-out/bin/pug-compile --dir examples/cli-templates-demo --out examples/cli-templates-demo/generated pages
```

**See [cli-templates-demo/README.md](cli-templates-demo/README.md) for full documentation.**

---

## Getting Started

### 1. Choose Your Use Case

**Just learning?** → Start with `use_compiled_templates.zig`

**Building a web app?** → Use `demo/` as a template

**Want to see all features?** → Explore `cli-templates-demo/`

### 2. Build Pugz

All examples require building Pugz first:

```bash
cd /path/to/pugz
zig build
```

This creates:
- `zig-out/bin/pug-compile` - Template compiler CLI
- `zig-out/lib/` - Pugz library
- All test executables

### 3. Run Examples

See individual README files in each example directory for specific instructions.

---

## Runtime vs Compiled Templates

### Runtime Mode (Recommended for Development)

**Pros:**
- ✅ Full feature support (extends, includes, mixins, loops)
- ✅ Edit templates and refresh - instant updates
- ✅ Easy debugging
- ✅ Great for development

**Cons:**
- ⚠️ Parses templates on every request
- ⚠️ Slightly slower

**When to use:** Development, prototyping, templates with complex features

### Compiled Mode (Recommended for Production)

**Pros:**
- ✅ 10-100x faster (no parsing overhead)
- ✅ Type-safe data structures
- ✅ Compile-time error checking
- ✅ Zero runtime dependencies

**Cons:**
- ⚠️ Must recompile after template changes
- ⚠️ Limited features (no extends/includes/mixins yet)

**When to use:** Production deployment, performance-critical apps, simple templates

---

## Performance Comparison

Based on benchmarks with 2000 iterations:

| Mode | Time (7 templates) | Per Template |
|------|-------------------|--------------|
| **Runtime** | ~71ms | ~10ms |
| **Compiled** | ~0.7ms | ~0.1ms |
| **Speedup** | **~100x** | **~100x** |

*Actual performance varies based on template complexity*

---

## Feature Support Matrix

| Feature | Runtime | Compiled | Example Location |
|---------|---------|----------|------------------|
| Tags & Nesting | ✅ | ✅ | all-features.pug §2 |
| Attributes | ✅ | ✅ | attributes-demo.pug |
| Text Interpolation | ✅ | ✅ | all-features.pug §5 |
| Buffered Code | ✅ | ✅ | all-features.pug §6 |
| Comments | ✅ | ✅ | all-features.pug §7 |
| Conditionals | ✅ | 🚧 | all-features.pug §8 |
| Case/When | ✅ | 🚧 | all-features.pug §9 |
| Iteration | ✅ | ❌ | all-features.pug §10 |
| Mixins | ✅ | ❌ | mixins/*.pug |
| Includes | ✅ | ❌ | partials/*.pug |
| Extends/Blocks | ✅ | ❌ | layouts/*.pug |
| Doctypes | ✅ | ✅ | all-features.pug §1 |
| Plain Text | ✅ | ✅ | all-features.pug §4 |
| Filters | ❌ | ❌ | Not supported |

**Legend:** ✅ Full Support | 🚧 Partial | ❌ Not Supported

---

## Common Patterns

### Basic Template Rendering

```zig
const pugz = @import("pugz");

// Runtime mode
const html = try pugz.renderTemplate(allocator,
    "h1 Hello #{name}!",
    .{ .name = "World" }
);
```

### With ViewEngine

```zig
const engine = pugz.ViewEngine.init(.{
    .views_dir = "views",
});

const html = try engine.render(allocator, "pages/home", .{
    .title = "Home Page",
});
```

### Compiled Templates

```zig
const templates = @import("generated/root.zig");

const html = try templates.home.render(allocator, .{
    .title = "Home Page",
});
```

---

## Troubleshooting

### "unable to find module 'pugz'"

Build from the root directory first:
```bash
cd /path/to/pugz  # Not examples/
zig build
```

### Templates not compiling

Make sure you're using the right subdirectory:
```bash
# Correct - compiles views/pages/*.pug
./zig-out/bin/pug-compile --dir views --out generated pages

# Wrong - tries to compile views/*.pug directly
./zig-out/bin/pug-compile --dir views --out generated
```

### Memory leaks

Always use ArenaAllocator for template rendering:
```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();

const html = try engine.render(arena.allocator(), ...);
// No need to free html - arena.deinit() handles it
```

---

## Learn More

- [Pugz Documentation](../docs/)
- [Build System Guide](../build.zig)
- [Pug Official Docs](https://pugjs.org/)
- [Feature Compatibility](cli-templates-demo/PUGJS_COMPATIBILITY.md)

---

## Contributing Examples

Have a useful example? Please contribute!

1. Create a new directory under `examples/`
2. Add a README.md explaining what it demonstrates
3. Keep it focused and well-documented
4. Test that it builds with `zig build`

**Good example topics:**
- Specific framework integration (e.g., http.zig, zap)
- Real-world use cases (e.g., blog, API docs generator)
- Performance optimization techniques
- Advanced template patterns
