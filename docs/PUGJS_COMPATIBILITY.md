# Pugz vs Pug.js Official Documentation - Feature Compatibility

This document maps each section of the official Pug.js documentation (https://pugjs.org/language/) to Pugz's support level.

## Feature Support Summary

| Feature | Pugz Support | Notes |
|---------|--------------|-------|
| Attributes | ✅ **Partial** | See detailed breakdown below |
| Case | ✅ **Full** | Switch statements fully supported |
| Code | ⚠️ **Partial** | Only buffered code (`=`, `!=`), no unbuffered (`-`) |
| Comments | ✅ **Full** | HTML and silent comments supported |
| Conditionals | ✅ **Full** | if/else/else if/unless supported |
| Doctype | ✅ **Full** | All standard doctypes supported |
| Filters | ❌ **Not Supported** | JSTransformer filters not available |
| Includes | ✅ **Full** | Include .pug files supported |
| Inheritance | ✅ **Full** | extends/block/append/prepend supported |
| Interpolation | ⚠️ **Partial** | Escaped/unescaped/tag interpolation, but no JS expressions |
| Iteration | ✅ **Full** | each/while loops supported |
| Mixins | ✅ **Full** | All mixin features supported |
| Plain Text | ✅ **Full** | Inline, piped, block, and literal HTML |
| Tags | ✅ **Full** | All tag features supported |

---

## 1. Attributes (https://pugjs.org/language/attributes.html)

### ✅ Supported

```pug
//- Basic attributes
a(href='//google.com') Google
a(class='button' href='//google.com') Google
a(class='button', href='//google.com') Google

//- Multiline attributes
input(
  type='checkbox'
  name='agreement'
  checked
)

//- Quoted attributes for special characters
div(class='div-class', (click)='play()')
div(class='div-class' '(click)'='play()')

//- Boolean attributes
input(type='checkbox' checked)
input(type='checkbox' checked=true)
input(type='checkbox' checked=false)

//- Unescaped attributes
div(escaped="<code>")
div(unescaped!="<code>")

//- Style attributes (object syntax)
a(style={color: 'red', background: 'green'})

//- Class attributes (array)
- var classes = ['foo', 'bar', 'baz']
a(class=classes)

//- Class attributes (object for conditionals)
- var currentUrl = '/about'
a(class={active: currentUrl === '/'} href='/') Home

//- Class literal
a.button

//- ID literal
a#main-link

//- &attributes
div#foo(data-bar="foo")&attributes({'data-foo': 'bar'})
```

### ⚠️ Partially Supported / Workarounds Needed

```pug
//- Template strings - NOT directly supported in Pugz
//- Official Pug.js:
- var btnType = 'info'
button(class=`btn btn-${btnType}`)

//- Pugz workaround - use string concatenation:
- var btnType = 'info'
button(class='btn btn-' + btnType)

//- Attribute interpolation - OLD syntax NO LONGER supported in Pug.js either
//- Both Pug.js 2.0+ and Pugz require:
- var url = 'pug-test.html'
a(href='/' + url) Link
//- NOT: a(href="/#{url}") Link
```

### ❌ Not Supported

```pug
//- ES2015 template literals in attributes
//- Pugz doesn't support backtick strings with ${} interpolation
button(class=`btn btn-${btnType} btn-${btnSize}`)
```

---

## 2. Case (https://pugjs.org/language/case.html)

### ✅ Fully Supported

```pug
//- Basic case
- var friends = 10
case friends
  when 0
    p you have no friends
  when 1
    p you have a friend
  default
    p you have #{friends} friends

//- Case fall through
- var friends = 0
case friends
  when 0
  when 1
    p you have very few friends
  default
    p you have #{friends} friends

//- Block expansion
- var friends = 1
case friends
  when 0: p you have no friends
  when 1: p you have a friend
  default: p you have #{friends} friends
```

### ❌ Not Supported

```pug
//- Explicit break in case (unbuffered code not supported)
case friends
  when 0
    - break
  when 1
    p you have a friend
```

---

## 3. Code (https://pugjs.org/language/code.html)

### ✅ Supported

```pug
//- Buffered code (escaped)
p
  = 'This code is <escaped>!'
p= 'This code is' + ' <escaped>!'

//- Unescaped buffered code
p
  != 'This code is <strong>not</strong> escaped!'
p!= 'This code is' + ' <strong>not</strong> escaped!'
```

### ❌ Not Supported - Unbuffered Code

```pug
//- Unbuffered code with '-' is NOT supported in Pugz
- for (var x = 0; x < 3; x++)
  li item

- var list = ["Uno", "Dos", "Tres"]
each item in list
  li= item
```

**Pugz Workaround:** Pass data from Zig code instead of defining variables in templates.

---

## 4. Comments (https://pugjs.org/language/comments.html)

### ✅ Fully Supported

```pug
//- Buffered comments (appear in HTML)
// just some paragraphs
p foo
p bar

//- Unbuffered comments (silent, not in HTML)
//- will not output within markup
p foo
p bar

//- Block comments
body
  //-
    Comments for your template writers.
    Use as much text as you want.
  //
    Comments for your HTML readers.
    Use as much text as you want.

//- Conditional comments (as literal HTML)
doctype html
<!--[if IE 8]>
<html lang="en" class="lt-ie9">
<![endif]-->
<!--[if gt IE 8]><!-->
<html lang="en">
<!--<![endif]-->
```

---

## 5. Conditionals (https://pugjs.org/language/conditionals.html)

### ✅ Fully Supported

```pug
//- Basic if/else
- var user = {description: 'foo bar baz'}
- var authorised = false
#user
  if user.description
    h2.green Description
    p.description= user.description
  else if authorised
    h2.blue Description
    p.description.
      User has no description,
      why not add one...
  else
    h2.red Description
    p.description User has no description

//- Unless (negated if)
unless user.isAnonymous
  p You're logged in as #{user.name}

//- Equivalent to:
if !user.isAnonymous
  p You're logged in as #{user.name}
```

**Note:** Pugz requires data to be passed from Zig code, not defined with `- var` in templates.

---

## 6. Doctype (https://pugjs.org/language/doctype.html)

### ✅ Fully Supported

```pug
doctype html
//- Output: <!DOCTYPE html>

doctype xml
//- Output: <?xml version="1.0" encoding="utf-8" ?>

doctype transitional
//- Output: <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" ...>

doctype strict
doctype frameset
doctype 1.1
doctype basic
doctype mobile
doctype plist

//- Custom doctypes
doctype html PUBLIC "-//W3C//DTD XHTML Basic 1.1//EN"
```

---

## 7. Filters (https://pugjs.org/language/filters.html)

### ❌ Not Supported

Filters like `:markdown-it`, `:babel`, `:coffee-script`, etc. are **not supported** in Pugz.

```pug
//- NOT SUPPORTED in Pugz
:markdown-it(linkify langPrefix='highlight-')
  # Markdown
  Markdown document with http://links.com

script
  :coffee-script
    console.log 'This is coffee script'
```

**Workaround:** Pre-process content before passing to Pugz templates.

---

## 8. Includes (https://pugjs.org/language/includes.html)

### ✅ Fully Supported

```pug
//- index.pug
doctype html
html
  include includes/head.pug
  body
    h1 My Site
    p Welcome to my site.
    include includes/foot.pug

//- Including plain text
doctype html
html
  head
    style
      include style.css
  body
    script
      include script.js
```

### ❌ Not Supported

```pug
//- Filtered includes NOT supported
include:markdown-it article.md
```

---

## 9. Inheritance (https://pugjs.org/language/inheritance.html)

### ✅ Fully Supported

```pug
//- layout.pug
html
  head
    title My Site - #{title}
    block scripts
      script(src='/jquery.js')
  body
    block content
    block foot
      #footer
        p some footer content

//- page-a.pug
extends layout.pug

block scripts
  script(src='/jquery.js')
  script(src='/pets.js')

block content
  h1= title
  each petName in pets
    p= petName

//- Block append/prepend
extends layout.pug

block append head
  script(src='/vendor/three.js')

append head
  script(src='/game.js')

block prepend scripts
  script(src='/analytics.js')
```

---

## 10. Interpolation (https://pugjs.org/language/interpolation.html)

### ✅ Supported

```pug
//- String interpolation, escaped
- var title = "On Dogs: Man's Best Friend"
- var author = "enlore"
- var theGreat = "<span>escape!</span>"

h1= title
p Written with love by #{author}
p This will be safe: #{theGreat}

//- Expression in interpolation
- var msg = "not my inside voice"
p This is #{msg.toUpperCase()}

//- String interpolation, unescaped
- var riskyBusiness = "<em>Some of the girls are wearing my mother's clothing.</em>"
.quote
  p Joel: !{riskyBusiness}

//- Tag interpolation
p.
  This is a very long paragraph.
  Suddenly there is a #[strong strongly worded phrase] that cannot be
  #[em ignored].

p.
  And here's an example of an interpolated tag with an attribute:
  #[q(lang="es") ¡Hola Mundo!]
```

### ⚠️ Limited Support

Pugz supports interpolation but **data must come from Zig structs**, not from `- var` declarations in templates.

---

## 11. Iteration (https://pugjs.org/language/iteration.html)

### ✅ Fully Supported

```pug
//- Each with arrays
ul
  each val in [1, 2, 3, 4, 5]
    li= val

//- Each with index
ul
  each val, index in ['zero', 'one', 'two']
    li= index + ': ' + val

//- Each with objects
ul
  each val, key in {1: 'one', 2: 'two', 3: 'three'}
    li= key + ': ' + val

//- Each with else fallback
- var values = []
ul
  each val in values
    li= val
  else
    li There are no values

//- While loops
- var n = 0
ul
  while n < 4
    li= n++
```

**Note:** Data must be passed from Zig code, not defined with `- var`.

---

## 12. Mixins (https://pugjs.org/language/mixins.html)

### ✅ Fully Supported

```pug
//- Declaration
mixin list
  ul
    li foo
    li bar
    li baz

//- Use
+list
+list

//- Mixins with arguments
mixin pet(name)
  li.pet= name

ul
  +pet('cat')
  +pet('dog')
  +pet('pig')

//- Mixin blocks
mixin article(title)
  .article
    .article-wrapper
      h1= title
      if block
        block
      else
        p No content provided

+article('Hello world')

+article('Hello world')
  p This is my
  p Amazing article

//- Mixin attributes
mixin link(href, name)
  //- attributes == {class: "btn"}
  a(class!=attributes.class href=href)= name

+link('/foo', 'foo')(class="btn")

//- Using &attributes
mixin link(href, name)
  a(href=href)&attributes(attributes)= name

+link('/foo', 'foo')(class="btn")

//- Default argument values
mixin article(title='Default Title')
  .article
    .article-wrapper
      h1= title

+article()
+article('Hello world')

//- Rest arguments
mixin list(id, ...items)
  ul(id=id)
    each item in items
      li= item

+list('my-list', 1, 2, 3, 4)
```

---

## 13. Plain Text (https://pugjs.org/language/plain-text.html)

### ✅ Fully Supported

```pug
//- Inline in a tag
p This is plain old <em>text</em> content.

//- Literal HTML
<html>
  body
    p Indenting the body tag here would make no difference.
    p HTML itself isn't whitespace-sensitive.
</html>

//- Piped text
p
  | The pipe always goes at the beginning of its own line,
  | not counting indentation.

//- Block in a tag
script.
  if (usingPug)
    console.log('you are awesome')
  else
    console.log('use pug')

div
  p This text belongs to the paragraph tag.
  br
  .
    This text belongs to the div tag.

//- Whitespace control
| Don't
button#self-destruct touch
|
| me!

p.
  Using regular tags can help keep your lines short,
  but interpolated tags may be easier to #[em visualize]
  whether the tags and text are whitespace-separated.
```

---

## 14. Tags (https://pugjs.org/language/tags.html)

### ✅ Fully Supported

```pug
//- Basic nested tags
ul
  li Item A
  li Item B
  li Item C

//- Self-closing tags
img
meta(charset="utf-8")
br
hr

//- Block expansion (inline nesting)
a: img

//- Explicit self-closing
foo/
foo(bar='baz')/

//- Div shortcuts with class/id
.content
#sidebar
div#main.container
```

---

## Key Differences: Pugz vs Pug.js

### What Pugz DOES Support
- ✅ All tag syntax and nesting
- ✅ Attributes (static and data-bound)
- ✅ Text interpolation (`#{}`, `!{}`, `#[]`)
- ✅ Buffered code (`=`, `!=`)
- ✅ Comments (HTML and silent)
- ✅ Conditionals (if/else/unless)
- ✅ Case/when statements
- ✅ Iteration (each/while)
- ✅ Mixins (full featured)
- ✅ Includes
- ✅ Template inheritance (extends/blocks)
- ✅ Doctypes
- ✅ Plain text (all methods)

### What Pugz DOES NOT Support
- ❌ **Unbuffered code** (`-` for variable declarations, loops, etc.)
- ❌ **Filters** (`:markdown`, `:coffee`, etc.)
- ❌ **JavaScript expressions** in templates
- ❌ **Nested field access** (`#{user.name}` - only `#{name}`)
- ❌ **ES2015 template literals** with backticks in attributes

### Data Binding Model

**Pug.js:** Define variables IN templates with `- var x = 1`

**Pugz:** Pass data FROM Zig code as struct fields

```zig
// Zig code
const html = try pugz.renderTemplate(allocator,
    template_source,
    .{
        .title = "My Page",
        .items = &[_][]const u8{"One", "Two"},
        .isLoggedIn = true,
    }
);
```

```pug
//- Template uses passed data
h1= title
each item in items
  p= item
if isLoggedIn
  p Welcome back!
```

---

## Testing Your Templates

To verify compatibility:

1. **Runtime Mode** (Full Support):
   ```bash
   # Use ViewEngine for maximum feature support
   const html = try engine.render(allocator, "template", data);
   ```

2. **Compiled Mode** (Limited Support):
   ```bash
   # Only simple templates without extends/includes/mixins
   ./zig-out/bin/cli --dir views --out generated pages
   ```

See `FEATURES_REFERENCE.md` for complete usage examples.
