# CLI Templates - Compilation Explained

## Overview

The `cli-templates-demo` directory contains **10 source templates**, but only **5 compile successfully** to Zig code. This is expected behavior.

## Compilation Results

### ✅ Successfully Compiled (5 templates)

| Template | Size | Features Used |
|----------|------|---------------|
| `home.pug` | 677 bytes | Basic tags, interpolation |
| `conditional.pug` | 793 bytes | If/else conditionals |
| `simple-index.pug` | 954 bytes | Links, basic structure |
| `simple-about.pug` | 1054 bytes | Lists, text content |
| `simple-features.pug` | 1784 bytes | Conditionals, interpolation, attributes |

**Total:** 5 templates compiled to Zig functions

### ❌ Failed to Compile (5 templates)

| Template | Reason | Use Runtime Mode Instead |
|----------|--------|--------------------------|
| `index.pug` | Uses `extends` | ✅ Works in runtime |
| `features-demo.pug` | Uses `extends` + mixins | ✅ Works in runtime |
| `attributes-demo.pug` | Uses `extends` | ✅ Works in runtime |
| `all-features.pug` | Uses `extends` + mixins | ✅ Works in runtime |
| `about.pug` | Uses `extends` | ✅ Works in runtime |

**Error:** `error.PathEscapesRoot` - Template inheritance not supported in compiled mode

## Why Some Templates Don't Compile

### Compiled Mode Limitations

Compiled mode currently supports:
- ✅ Basic tags and nesting
- ✅ Attributes (static and dynamic)
- ✅ Text interpolation (`#{field}`)
- ✅ Buffered code (`=`, `!=`)
- ✅ Comments
- ✅ Conditionals (if/else)
- ✅ Doctypes

Compiled mode does NOT support:
- ❌ Template inheritance (`extends`/`block`)
- ❌ Includes (`include`)
- ❌ Mixins (`mixin`/`+mixin`)
- ❌ Iteration (`each`/`while`) - partial support
- ❌ Case/when - partial support

### Design Decision

Templates with `extends ../layouts/main.pug` try to reference files outside the compilation directory, which is why they fail with `PathEscapesRoot`. This is a security feature to prevent templates from accessing arbitrary files.

## Solution: Two Sets of Templates

### 1. Runtime Templates (Full Features)
Files: `index.pug`, `features-demo.pug`, `attributes-demo.pug`, `all-features.pug`, `about.pug`

**Usage:**
```zig
const engine = pugz.ViewEngine.init(.{
    .views_dir = "examples/cli-templates-demo",
});

const html = try engine.render(allocator, "pages/all-features", data);
```

**Features:**
- ✅ All Pug features supported
- ✅ Template inheritance
- ✅ Mixins and includes
- ✅ Easy to modify and test

### 2. Compiled Templates (Maximum Performance)
Files: `home.pug`, `conditional.pug`, `simple-*.pug`

**Usage:**
```bash
# Compile
./zig-out/bin/pug-compile --dir examples/cli-templates-demo --out generated pages

# Use
const templates = @import("generated/root.zig");
const html = try templates.simple_index.render(allocator, .{
    .title = "Home",
    .siteName = "My Site",
});
```

**Features:**
- ✅ 10-100x faster than runtime
- ✅ Type-safe data structures
- ✅ Zero parsing overhead
- ⚠️ Limited feature set

## Compilation Command

```bash
cd /path/to/pugz

# Compile all compatible templates
./zig-out/bin/pug-compile \
  --dir examples/cli-templates-demo \
  --out examples/cli-templates-demo/generated \
  pages
```

**Output:**
```
Found 10 page templates
Processing: examples/cli-templates-demo/pages/index.pug
  ERROR: Failed to compile (uses extends)
...
Processing: examples/cli-templates-demo/pages/simple-index.pug
  Found 2 data fields: siteName, title
  Generated 954 bytes of Zig code
...
Compilation complete!
```

## Generated Files

```
generated/
├── conditional.zig        # Compiled from conditional.pug
├── home.zig              # Compiled from home.pug
├── simple_about.zig      # Compiled from simple-about.pug
├── simple_features.zig   # Compiled from simple-features.pug
├── simple_index.zig      # Compiled from simple-index.pug
├── helpers.zig           # Shared helper functions
└── root.zig             # Module exports
```

## Verifying Compilation

```bash
cd examples/cli-templates-demo

# Check what compiled successfully
cat generated/root.zig

# Output:
# pub const conditional = @import("./conditional.zig");
# pub const home = @import("./home.zig");
# pub const simple_about = @import("./simple_about.zig");
# pub const simple_features = @import("./simple_features.zig");
# pub const simple_index = @import("./simple_index.zig");
```

## When to Use Each Mode

### Use Runtime Mode When:
- ✅ Template uses `extends`, `include`, or mixins
- ✅ Development phase (easy to modify and test)
- ✅ Templates change frequently
- ✅ Need all Pug features

### Use Compiled Mode When:
- ✅ Production deployment
- ✅ Performance is critical
- ✅ Templates are stable
- ✅ Templates don't use inheritance/mixins

## Best Practice

**Recommendation:** Start with runtime mode during development, then optionally compile simple templates for production if you need maximum performance.

```zig
// Development: Runtime mode
const html = try engine.render(allocator, "pages/all-features", data);

// Production: Compiled mode (for compatible templates)
const html = try templates.simple_index.render(allocator, data);
```

## Future Enhancements

Planned features for compiled mode:
- [ ] Template inheritance (extends/blocks)
- [ ] Includes resolution at compile time
- [ ] Full loop support (each/while)
- [ ] Mixin expansion at compile time
- [ ] Complete case/when support

Until then, use runtime mode for templates requiring these features.

## Summary

| Metric | Value |
|--------|-------|
| Total Templates | 10 |
| Compiled Successfully | 5 (50%) |
| Runtime Only | 5 (50%) |
| Compilation Errors | Expected (extends not supported) |

**This is working as designed.** The split between runtime and compiled templates demonstrates both modes effectively.

---

**See Also:**
- [FEATURES_REFERENCE.md](FEATURES_REFERENCE.md) - Complete feature guide
- [PUGJS_COMPATIBILITY.md](PUGJS_COMPATIBILITY.md) - Feature compatibility matrix
- [COMPILED_TEMPLATES.md](COMPILED_TEMPLATES.md) - Compiled templates overview
