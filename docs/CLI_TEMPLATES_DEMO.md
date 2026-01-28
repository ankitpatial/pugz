# CLI Templates Demo

This directory contains comprehensive Pug template examples for testing the `pug-compile` CLI tool.

## What's Here

This is a complete demonstration of:
- **Layouts** with extends/blocks
- **Partials** (header, footer)
- **Mixins** (buttons, forms, cards, alerts)
- **Pages** demonstrating all Pug features

## Structure

```
cli-templates-demo/
├── layouts/
│   ├── main.pug           # Main layout with header/footer
│   └── simple.pug         # Minimal layout
├── partials/
│   ├── header.pug         # Site header with navigation
│   └── footer.pug         # Site footer
├── mixins/
│   ├── buttons.pug        # Button components
│   ├── forms.pug          # Form input components
│   ├── cards.pug          # Card components
│   └── alerts.pug         # Alert/notification components
├── pages/
│   ├── index.pug          # Homepage
│   ├── features-demo.pug  # Complete features demonstration
│   ├── attributes-demo.pug # All attribute syntax examples
│   └── about.pug          # About page
├── public/
│   └── css/
│       └── style.css      # Demo styles
├── generated/             # Compiled templates output (after compilation)
└── README.md             # This file
```

## Testing the CLI Tool

### 1. Compile All Pages

From the pugz root directory:

```bash
# Build the CLI tool
zig build

# Compile templates
./zig-out/bin/cli --dir src/tests/examples/cli-templates-demo/pages --out src/tests/examples/cli-templates-demo/generated
```

This will generate:
- `generated/pages/*.zig` - Compiled page templates
- `generated/helpers.zig` - Shared helper functions
- `generated/root.zig` - Module exports

### 2. Test Individual Templates

Compile a single template:

```bash
./zig-out/bin/cli src/tests/examples/cli-templates-demo/pages/index.pug src/tests/examples/cli-templates-demo/generated/index.zig
```

### 3. Use in Application

```zig
const tpls = @import("cli-templates-demo/generated/root.zig");

// Render a page
const html = try tpls.pages_index.render(allocator, .{
    .pageTitle = "Home",
    .currentPage = "home",
    .year = "2024",
});
```

## What's Demonstrated

### Pages

1. **index.pug** - Homepage
   - Hero section
   - Feature cards using mixins
   - Demonstrates: extends, includes, mixins

2. **features-demo.pug** - Complete Features
   - Mixins: buttons, forms, cards, alerts
   - Conditionals: if/else, unless
   - Loops: each with arrays/objects
   - Case/when statements
   - Text interpolation
   - Code blocks

3. **attributes-demo.pug** - All Attributes
   - Basic attributes
   - JavaScript expressions
   - Multiline attributes
   - Quoted attributes
   - Attribute interpolation
   - Unescaped attributes
   - Boolean attributes
   - Style attributes (string/object)
   - Class attributes (array/object/conditional)
   - Class/ID literals
   - &attributes spreading
   - Data and ARIA attributes

4. **about.pug** - Standard Content
   - Tables, lists, links
   - Regular content page

### Mixins

- **buttons.pug**: Various button styles and types
- **forms.pug**: Input, textarea, select, checkbox
- **cards.pug**: Different card layouts
- **alerts.pug**: Alert notifications

### Layouts

- **main.pug**: Full layout with header/footer
- **simple.pug**: Minimal layout

### Partials

- **header.pug**: Navigation header
- **footer.pug**: Site footer

## Supported vs Not Supported

### ✅ Runtime Mode (Full Support)
All features work perfectly in runtime mode:
- All mixins
- Includes and extends
- Conditionals and loops
- All attribute types

### ⚠️ Compiled Mode (Partial Support)

Currently supported:
- ✅ Basic tags and nesting
- ✅ Text interpolation `#{var}`
- ✅ Attributes (static and dynamic)
- ✅ Doctypes
- ✅ Comments
- ✅ Buffered code `p= var`

Not yet supported:
- ❌ Conditionals (in progress, has bugs)
- ❌ Loops
- ❌ Mixins
- ❌ Runtime includes (resolved at compile time)

## Testing Workflow

1. **Edit templates** in this directory
2. **Compile** using the CLI tool
3. **Check generated code** in `generated/`
4. **Test runtime** by using templates directly
5. **Test compiled** by importing generated modules

## Notes

- Templates use demo data variables (set with `-` in templates)
- The `generated/` directory is recreated each compilation
- CSS is provided for visual reference but not required
- All templates follow Pug best practices

## For Compiled Templates Development

This directory serves as a comprehensive test suite for the `pug-compile` CLI tool. When adding new features to the compiler:

1. Add examples here
2. Compile and verify output
3. Test generated Zig code compiles
4. Test generated code produces correct HTML
5. Compare with runtime rendering

## Resources

- [Pug Documentation](https://pugjs.org/)
- [Pugz Main README](../../../../README.md)
- [Compiled Templates Docs](../../../../docs/COMPILED_TEMPLATES.md)
