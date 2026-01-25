# Pugz Template Syntax

Complete reference for Pugz template syntax.

## Tags & Nesting

Indentation defines nesting. Default tag is `div`.

```pug
div
  h1 Title
  p Paragraph
```

Output:
```html
<div><h1>Title</h1><p>Paragraph</p></div>
```

## Classes & IDs

Shorthand syntax using `.` for classes and `#` for IDs.

```pug
div#main.container.active
.box
#sidebar
```

Output:
```html
<div id="main" class="container active"></div>
<div class="box"></div>
<div id="sidebar"></div>
```

## Attributes

```pug
a(href="/link" target="_blank") Click
input(type="checkbox" checked)
button(disabled=false)
button(disabled=true)
```

Output:
```html
<a href="/link" target="_blank">Click</a>
<input type="checkbox" checked="checked" />
<button></button>
<button disabled="disabled"></button>
```

Boolean attributes: `false` omits the attribute, `true` renders `attr="attr"`.

## Text Content

### Inline text

```pug
p Hello World
```

### Piped text

```pug
p
  | Line one
  | Line two
```

### Block text (dot syntax)

```pug
script.
  console.log('hello');
  console.log('world');
```

### Literal HTML

```pug
<p>Passed through as-is</p>
```

## Interpolation

### Escaped (safe)

```pug
p Hello #{name}
p= variable
```

### Unescaped (raw HTML)

```pug
p Hello !{rawHtml}
p!= rawVariable
```

### Tag interpolation

```pug
p This is #[em emphasized] text
p Click #[a(href="/") here] to continue
```

## Conditionals

### if / else if / else

```pug
if condition
  p Yes
else if other
  p Maybe
else
  p No
```

### unless

```pug
unless loggedIn
  p Please login
```

### String comparison

```pug
if status == "active"
  p Active
```

## Iteration

### each

```pug
each item in items
  li= item
```

### with index

```pug
each val, index in list
  li #{index}: #{val}
```

### with else (empty collection)

```pug
each item in items
  li= item
else
  li No items
```

### Objects

```pug
each val, key in object
  p #{key}: #{val}
```

### Nested iteration

```pug
each friend in friends
  li #{friend.name}
  each tag in friend.tags
    span= tag
```

## Case / When

```pug
case status
  when "active"
    p Active
  when "pending"
    p Pending
  default
    p Unknown
```

## Mixins

### Basic mixin

```pug
mixin button(text)
  button= text

+button("Click me")
```

### Default parameters

```pug
mixin button(text, type="primary")
  button(class="btn btn-" + type)= text

+button("Click me")
+button("Submit", "success")
```

### Block content

```pug
mixin card(title)
  .card
    h3= title
    block

+card("My Card")
  p Card content here
```

### Rest arguments

```pug
mixin list(id, ...items)
  ul(id=id)
    each item in items
      li= item

+list("mylist", "a", "b", "c")
```

### Attributes pass-through

```pug
mixin link(href, text)
  a(href=href)&attributes(attributes)= text

+link("/home", "Home")(class="nav-link" data-id="1")
```

## Template Inheritance

### Base layout (layout.pug)

```pug
doctype html
html
  head
    title= title
    block styles
  body
    block content
    block scripts
```

### Child template

```pug
extends layout.pug

block content
  h1 Page Title
  p Page content
```

### Block modes

```pug
block append scripts
  script(src="extra.js")

block prepend styles
  link(rel="stylesheet" href="extra.css")
```

## Includes

```pug
include header.pug
include partials/footer.pug
```

## Comments

### HTML comment (rendered)

```pug
// This renders as HTML comment
```

Output:
```html
<!-- This renders as HTML comment -->
```

### Silent comment (not rendered)

```pug
//- This is a silent comment
```

## Block Expansion

Colon for inline nesting:

```pug
a: img(src="logo.png")
```

Output:
```html
<a><img src="logo.png" /></a>
```

## Self-Closing Tags

Explicit self-closing with `/`:

```pug
foo/
```

Output:
```html
<foo />
```

Void elements (`br`, `hr`, `img`, `input`, `meta`, `link`, etc.) are automatically self-closing.

## Doctype

```pug
doctype html
```

Output:
```html
<!DOCTYPE html>
```
