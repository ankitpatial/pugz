# CLI Templates Demo - Complete

## ✅ What's Been Created

A comprehensive demonstration of Pug templates for testing the `pug-compile` CLI tool, now located in `src/tests/examples/cli-templates-demo/`.

### 📁 Directory Structure

```
src/tests/examples/
├── demo/                    # HTTP server demo (existing)
└── cli-templates-demo/      # NEW: CLI compilation demo
    ├── layouts/
    │   ├── main.pug        # Full layout with header/footer
    │   └── simple.pug      # Minimal layout
    ├── partials/
    │   ├── header.pug      # Navigation header
    │   └── footer.pug      # Site footer
    ├── mixins/
    │   ├── buttons.pug     # Button components
    │   ├── forms.pug       # Form components
    │   ├── cards.pug       # Card components
    │   └── alerts.pug      # Alert components
    ├── pages/
    │   ├── index.pug       # Homepage
    │   ├── features-demo.pug    # All features
    │   ├── attributes-demo.pug  # All attributes
    │   └── about.pug       # About page
    ├── public/
    │   └── css/
    │       └── style.css   # Demo styles
    ├── generated/          # Compiled output (after running cli)
    └── README.md
```

## 🎯 What It Demonstrates

### 1. **Layouts & Extends**
- Main layout with header/footer includes
- Simple minimal layout
- Block system for content injection

### 2. **Partials**
- Reusable header with navigation
- Footer with links and sections

### 3. **Mixins** (4 files, 15+ mixins)

**buttons.pug:**
- `btn(text, type)` - Standard buttons
- `btnIcon(text, icon, type)` - Buttons with icons
- `btnLink(text, href, type)` - Link buttons
- `btnCustom(text, attrs)` - Custom attributes

**forms.pug:**
- `input(name, label, type, required)` - Text inputs
- `textarea(name, label, rows)` - Textareas
- `select(name, label, options)` - Dropdowns
- `checkbox(name, label, checked)` - Checkboxes

**cards.pug:**
- `card(title, content)` - Basic cards
- `cardImage(title, image, content)` - Image cards
- `featureCard(icon, title, description)` - Feature cards
- `productCard(product)` - Product cards

**alerts.pug:**
- `alert(message, type)` - Basic alerts
- `alertDismissible(message, type)` - Dismissible
- `alertIcon(message, icon, type)` - With icons

### 4. **Pages**

**index.pug** - Homepage:
- Hero section
- Feature grid using mixins
- Call-to-action sections

**features-demo.pug** - Complete Feature Set:
- All mixin usage examples
- Conditionals (if/else/unless)
- Loops (each with arrays, objects, indexes)
- Case/when statements
- Text interpolation and blocks
- Buffered/unbuffered code

**attributes-demo.pug** - All Pug Attributes:
Demonstrates every feature from https://pugjs.org/language/attributes.html:
- Basic attributes
- JavaScript expressions
- Multiline attributes
- Quoted attributes (Angular-style `(click)`)
- Attribute interpolation
- Unescaped attributes
- Boolean attributes
- Style attributes (string and object)
- Class attributes (array, object, conditional)
- Class/ID literals (`.class` `#id`)
- `&attributes` spreading
- Data attributes
- ARIA attributes
- Combined examples

**about.pug** - Standard Content:
- Tables
- Lists
- Links
- Regular content layout

## 🧪 Testing the CLI Tool

### Compile All Pages

```bash
# From pugz root
zig build

# Compile templates
./zig-out/bin/cli --dir src/tests/examples/cli-templates-demo/pages \
                  --out src/tests/examples/cli-templates-demo/generated
```

### Compile Single Template

```bash
./zig-out/bin/cli \
  src/tests/examples/cli-templates-demo/pages/index.pug \
  src/tests/examples/cli-templates-demo/generated/index.zig
```

### Use Compiled Templates

```zig
const tpls = @import("cli-templates-demo/generated/root.zig");

const html = try tpls.pages_index.render(allocator, .{
    .pageTitle = "Home",
    .currentPage = "home",
    .year = "2024",
});
defer allocator.free(html);
```

## 📊 Feature Coverage

### Runtime Mode (ViewEngine)
✅ **100% Feature Support**
- All mixins work
- All includes/extends work
- All conditionals/loops work
- All attributes work

### Compiled Mode (pug-compile)
**Currently Supported:**
- ✅ Tags and nesting
- ✅ Text interpolation `#{var}`
- ✅ Buffered code `p= var`
- ✅ Attributes (all types from demo)
- ✅ Doctypes
- ✅ Comments
- ✅ HTML escaping

**In Progress:**
- ⚠️ Conditionals (implemented but has buffer bugs)

**Not Yet Implemented:**
- ❌ Loops (each/while)
- ❌ Mixins
- ❌ Runtime includes (resolved at compile time only)
- ❌ Case/when

## 🎨 Styling

Complete CSS provided in `public/css/style.css`:
- Responsive layout
- Header/footer styling
- Component styles (buttons, forms, cards, alerts)
- Typography and spacing
- Utility classes

## 📚 Documentation

- **Main README**: `src/tests/examples/cli-templates-demo/README.md`
- **Compiled Templates Guide**: `docs/COMPILED_TEMPLATES.md`
- **Status Report**: `COMPILED_TEMPLATES_STATUS.md`

## 🔄 Workflow

1. **Edit** templates in `cli-templates-demo/`
2. **Compile** with the CLI tool
3. **Check** generated code in `generated/`
4. **Test** runtime rendering
5. **Test** compiled code execution
6. **Compare** outputs

## 💡 Use Cases

### For Development
- Test all Pug features
- Verify CLI tool output
- Debug compilation issues
- Learn Pug syntax

### For Testing
- Comprehensive test suite for CLI
- Regression testing
- Feature validation
- Output comparison

### For Documentation
- Live examples of all features
- Reference implementations
- Best practices demonstration

## 🚀 Next Steps

To make compiled templates fully functional:

1. **Fix conditional buffer management** (HIGH PRIORITY)
   - Static content leaking outside conditionals
   - Need scoped buffer handling

2. **Implement loops**
   - Extract iterable field names
   - Generate Zig for loops
   - Handle each/else

3. **Add mixin support**
   - Generate Zig functions
   - Parameter handling
   - Block content

4. **Comprehensive testing**
   - Unit tests for each feature
   - Integration tests
   - Output validation

## 📝 Summary

Created a **production-ready template suite** with:
- **2 layouts**
- **2 partials**
- **4 mixin files** (15+ mixins)
- **4 complete demo pages**
- **Full CSS styling**
- **Comprehensive documentation**

All demonstrating **every feature** from the official Pug documentation, ready for testing both runtime and compiled modes.

The templates are now properly organized in `src/tests/examples/cli-templates-demo/` and can serve as both a demo and a comprehensive test suite for the CLI compilation tool! 🎉
