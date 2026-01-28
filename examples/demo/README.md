# Pugz Demo App

A comprehensive e-commerce demo showcasing Pugz template engine capabilities.

## Features

- Template inheritance (extends/block)
- Partial includes (header, footer)
- Mixins with parameters (product-card, rating, forms)
- Conditionals and loops
- Data binding
- Pretty printing

## Running the Demo

### Option 1: Runtime Templates (Default)

```bash
cd examples/demo
zig build run
```

Then visit `http://localhost:5882` in your browser.

### Option 2: Compiled Templates (Experimental)

Compiled templates offer maximum performance by pre-compiling templates to Zig functions at build time.

**Note:** Compiled templates currently have some code generation issues and are disabled by default.

To try compiled templates:

1. **Compile templates**:
   ```bash
   # From demo directory
   ./compile_templates.sh
   
   # Or manually from project root
   cd ../..
   zig build demo-compile-templates
   ```
   
   This generates compiled templates in `generated/root.zig`

2. **Enable in code**:
   - Open `src/main.zig`
   - Set `USE_COMPILED_TEMPLATES = true`

3. **Build and run**:
   ```bash
   zig build run
   ```

The `build.zig` automatically detects if `generated/` exists and includes the templates module.

## Template Structure

```
views/
├── layouts/          # Layout templates
│   └── base.pug
├── pages/            # Page templates
│   ├── home.pug
│   ├── products.pug
│   ├── cart.pug
│   └── ...
├── partials/         # Reusable partials
│   ├── header.pug
│   ├── footer.pug
│   └── head.pug
├── mixins/           # Reusable components
│   ├── product-card.pug
│   ├── buttons.pug
│   ├── forms.pug
│   └── ...
└── includes/         # Other includes
    └── ...
```

## Known Issues with Compiled Templates

The template code generation (`src/tpl_compiler/zig_codegen.zig`) has some bugs:

1. `helpers.zig` import paths need to be relative
2. Double quotes being escaped incorrectly in string literals
3. Field names with dots causing syntax errors
4. Some undefined variables in generated code

These will be fixed in a future update. For now, runtime templates work perfectly!
