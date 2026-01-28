# Pugz Complete Features Reference

This document provides a comprehensive overview of ALL Pug features supported by Pugz, with examples from the demo templates.

## ✅ Fully Supported Features

### 1. **Doctypes**

Declare the HTML document type at the beginning of your template.

**Examples:**
```pug
doctype html
doctype xml
doctype transitional
doctype strict
doctype frameset
doctype 1.1
doctype basic
doctype mobile
```

**Demo Location:** `pages/all-features.pug` (Section 1)

**Rendered HTML:**
```html
<!DOCTYPE html>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
```

---

### 2. **Tags**

Basic HTML tags with automatic nesting based on indentation.

**Examples:**
```pug
// Basic tags
p This is a paragraph
div This is a div
span This is a span

// Nested tags
ul
  li Item 1
  li Item 2
  li Item 3

// Self-closing tags
img(src="/image.png")
br
hr
meta(charset="utf-8")

// Block expansion (inline nesting)
a: img(src="/icon.png")
```

**Demo Location:** `pages/all-features.pug` (Section 2)

---

### 3. **Attributes**

**Basic Attributes:**
```pug
a(href="/link" target="_blank" rel="noopener") Link
input(type="text" name="username" placeholder="Enter name")
```

**Boolean Attributes:**
```pug
input(type="checkbox" checked)
button(disabled) Disabled
option(selected) Selected
```

**Class & ID Shorthand:**
```pug
div#main-content Main content
.card Card element
#sidebar.widget.active Multiple classes with ID
```

**Multiple Classes (Array):**
```pug
div(class=['btn', 'btn-primary', 'btn-large']) Button
```

**Style Attributes:**
```pug
div(style="color: blue; font-weight: bold;") Styled text
div(style={color: 'red', background: 'yellow'}) Object style
```

**Data Attributes:**
```pug
div(data-id="123" data-name="example" data-active="true") Data attrs
```

**Attribute Interpolation:**
```pug
- var url = '/page'
a(href='/' + url) Link
a(href=url) Direct variable
button(class=`btn btn-${type}`) Template string
```

**Demo Location:** `pages/attributes-demo.pug`, `pages/all-features.pug` (Section 3)

---

### 4. **Plain Text**

**Inline Text:**
```pug
p This is inline text after the tag.
```

**Piped Text:**
```pug
p
  | This is piped text.
  | Multiple lines.
  | Each line starts with a pipe.
```

**Block Text (Dot Notation):**
```pug
script.
  if (typeof console !== 'undefined') {
    console.log('JavaScript block');
  }

style.
  .class { color: red; }
```

**Literal HTML:**
```pug
<div class="literal">
  <p>This is literal HTML</p>
</div>
```

**Demo Location:** `pages/all-features.pug` (Section 4)

---

### 5. **Text Interpolation**

**Escaped Interpolation (Default - Safe):**
```pug
p Hello, #{name}!
p Welcome to #{siteName}.
```

**Unescaped Interpolation (Use with caution):**
```pug
p Raw HTML: !{htmlContent}
```

**Tag Interpolation:**
```pug
p This has #[strong bold text] and #[a(href="/") links] inline.
p You can #[em emphasize] words in the middle of sentences.
```

**Demo Location:** `pages/all-features.pug` (Section 5)

---

### 6. **Code (Buffered Output)**

**Escaped Buffered Code (Safe):**
```pug
p= username
div= content
span= email
```

**Unescaped Buffered Code (Unsafe):**
```pug
div!= htmlContent
p!= rawMarkup
```

**Demo Location:** `pages/all-features.pug` (Section 6)

---

### 7. **Comments**

**HTML Comments (Visible in Source):**
```pug
// This appears in rendered HTML as <!-- comment -->
p Content after comment
```

**Silent Comments (Not in Output):**
```pug
//- This is NOT in the HTML output
p Content
```

**Block Comments:**
```pug
//-
  This entire block is commented out.
  Multiple lines.
  None of this appears in output.
```

**Demo Location:** `pages/all-features.pug` (Section 7)

---

### 8. **Conditionals**

**If Statement:**
```pug
if isLoggedIn
  p Welcome back!
```

**If-Else:**
```pug
if isPremium
  p Premium user
else
  p Free user
```

**If-Else If-Else:**
```pug
if role === "admin"
  p Admin access
else if role === "moderator"
  p Moderator access
else
  p Standard access
```

**Unless (Negative Conditional):**
```pug
unless isLoggedIn
  a(href="/login") Please log in
```

**Demo Location:** `pages/conditional.pug`, `pages/all-features.pug` (Section 8)

---

### 9. **Case/When (Switch Statements)**

**Basic Case:**
```pug
case status
  when "active"
    .badge Active
  when "pending"
    .badge Pending
  when "suspended"
    .badge Suspended
  default
    .badge Unknown
```

**Multiple Values:**
```pug
case userType
  when "admin"
  when "superadmin"
    p Administrative access
  when "user"
    p Standard access
  default
    p Guest access
```

**Demo Location:** `pages/all-features.pug` (Section 9)

---

### 10. **Iteration (Each Loops)**

**Basic Each:**
```pug
ul
  each item in items
    li= item
```

**Each with Index:**
```pug
ol
  each value, index in numbers
    li Item #{index}: #{value}
```

**Each with Else (Fallback):**
```pug
ul
  each product in products
    li= product
  else
    li No products available
```

**Demo Location:** `pages/features-demo.pug`, `pages/all-features.pug` (Section 10)

---

### 11. **Mixins (Reusable Components)**

**Basic Mixin:**
```pug
mixin button(text, type='primary')
  button(class=`btn btn-${type}`)= text

+button('Click Me')
+button('Submit', 'success')
```

**Mixin with Default Parameters:**
```pug
mixin card(title='Untitled', content='No content')
  .card
    .card-header= title
    .card-body= content

+card()
+card('My Title', 'My content')
```

**Mixin with Blocks:**
```pug
mixin article(title)
  .article
    h1= title
    if block
      block
    else
      p No content provided

+article('Hello')
  p This is the article content.
  p Multiple paragraphs.
```

**Mixin with Attributes:**
```pug
mixin link(href, name)
  a(href=href)&attributes(attributes)= name

+link('/page', 'Link')(class="btn" target="_blank")
```

**Rest Arguments:**
```pug
mixin list(id, ...items)
  ul(id=id)
    each item in items
      li= item

+list('my-list', 1, 2, 3, 4)
```

**Demo Location:** `mixins/*.pug`, `pages/all-features.pug` (Section 11)

---

### 12. **Includes (Partials)**

Include external Pug files as partials:

```pug
include partials/header.pug
include partials/footer.pug

div.content
  p Main content
```

**Demo Location:** All pages use `include` for mixins and partials

---

### 13. **Template Inheritance (Extends/Blocks)**

**Layout File (`layouts/main.pug`):**
```pug
doctype html
html
  head
    block head
      title Default Title
  body
    include ../partials/header.pug
    
    block content
      p Default content
    
    include ../partials/footer.pug
```

**Page File (`pages/home.pug`):**
```pug
extends ../layouts/main.pug

block head
  title Home Page

block content
  h1 Welcome Home
  p This is the home page content.
```

**Block Append/Prepend:**
```pug
extends layout.pug

block append scripts
  script(src="/extra.js")

block prepend styles
  link(rel="stylesheet" href="/custom.css")
```

**Demo Location:** All pages in `pages/` extend layouts from `layouts/`

---

## ❌ Not Supported Features

### 1. **Filters**

Filters like `:markdown`, `:coffee`, `:cdata` are **not supported**.

**Not Supported:**
```pug
:markdown
  # Heading
  This is **markdown**
```

**Workaround:** Pre-process markdown to HTML before passing to template.

---

### 2. **JavaScript Expressions**

Unbuffered code and JavaScript expressions are **not supported**.

**Not Supported:**
```pug
- var x = 1
- var items = [1, 2, 3]
- if (x > 0) console.log('test')
```

**Workaround:** Pass data from Zig code instead of defining in template.

---

### 3. **Nested Field Access**

Only top-level field access is supported in data binding.

**Not Supported:**
```pug
p= user.name
p #{address.city}
```

**Supported:**
```pug
p= userName
p #{city}
```

**Workaround:** Flatten data structures before passing to template.

---

## 📊 Feature Support Matrix

| Feature | Runtime Mode | Compiled Mode | Notes |
|---------|-------------|---------------|-------|
| **Doctypes** | ✅ | ✅ | All standard doctypes |
| **Tags** | ✅ | ✅ | Including self-closing |
| **Attributes** | ✅ | ✅ | Static and dynamic |
| **Plain Text** | ✅ | ✅ | Inline, piped, block, literal |
| **Interpolation** | ✅ | ✅ | Escaped and unescaped |
| **Buffered Code** | ✅ | ✅ | `=` and `!=` |
| **Comments** | ✅ | ✅ | HTML and silent |
| **Conditionals** | ✅ | 🚧 | Partial compiled support |
| **Case/When** | ✅ | 🚧 | Partial compiled support |
| **Iteration** | ✅ | ❌ | Runtime only |
| **Mixins** | ✅ | ❌ | Runtime only |
| **Includes** | ✅ | ❌ | Runtime only |
| **Extends/Blocks** | ✅ | ❌ | Runtime only |
| **Filters** | ❌ | ❌ | Not supported |
| **JS Expressions** | ❌ | ❌ | Not supported |
| **Nested Fields** | ❌ | ❌ | Not supported |

Legend:
- ✅ Fully Supported
- 🚧 Partial Support / In Progress
- ❌ Not Supported

---

## 🎯 Usage Examples

### Runtime Mode (Full Feature Support)

```zig
const std = @import("std");
const pugz = @import("pugz");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    
    const html = try pugz.renderTemplate(arena.allocator(),
        \\extends layouts/main.pug
        \\
        \\block content
        \\  h1 #{title}
        \\  each item in items
        \\    p= item
    , .{
        .title = "My Page",
        .items = &[_][]const u8{"One", "Two", "Three"},
    });
    
    std.debug.print("{s}\n", .{html});
}
```

### Compiled Mode (Best Performance)

```zig
const std = @import("std");
const templates = @import("generated/root.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    
    // Simple page without extends/loops/mixins
    const html = try templates.home.render(arena.allocator(), .{
        .title = "Home Page",
        .name = "Alice",
    });
    
    std.debug.print("{s}\n", .{html});
}
```

---

## 📂 Demo Files by Feature

| Feature | Demo File | Description |
|---------|-----------|-------------|
| **All Features** | `pages/all-features.pug` | Comprehensive demo of every feature |
| **Attributes** | `pages/attributes-demo.pug` | All attribute syntax variations |
| **Features** | `pages/features-demo.pug` | Mixins, loops, case, conditionals |
| **Conditionals** | `pages/conditional.pug` | Simple if/else example |
| **Layouts** | `layouts/main.pug` | Full layout with extends/blocks |
| **Mixins** | `mixins/*.pug` | Buttons, forms, cards, alerts |
| **Partials** | `partials/*.pug` | Header, footer components |

---

## 🚀 Quick Start

1. **Compile the CLI tool:**
   ```bash
   cd /path/to/pugz
   zig build
   ```

2. **Compile simple templates (no extends/includes):**
   ```bash
   ./zig-out/bin/cli --dir src/tests/examples/cli-templates-demo --out generated pages
   ```

3. **Use runtime mode for full feature support:**
   ```zig
   const engine = pugz.ViewEngine.init(.{
       .views_dir = "src/tests/examples/cli-templates-demo",
   });
   
   const html = try engine.render(allocator, "pages/all-features", data);
   ```

---

## 💡 Best Practices

1. **Use Runtime Mode for:**
   - Templates with extends/includes
   - Dynamic mixins
   - Complex iteration patterns
   - Development and rapid iteration

2. **Use Compiled Mode for:**
   - Simple static pages
   - High-performance production deployments
   - Maximum type safety
   - Embedded templates

3. **Security:**
   - Always use `#{}` (escaped) for user input
   - Only use `!{}` (unescaped) for trusted content
   - Validate and sanitize data before passing to templates

---

## 📚 Reference Links

- Pug Official Language Reference: https://pugjs.org/language/
- Pugz GitHub Repository: (your repo URL)
- Zig Programming Language: https://ziglang.org/

---

**Version:** Pugz 1.0  
**Zig Version:** 0.15.2  
**Pug Syntax Version:** Pug 3
