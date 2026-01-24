//! General template tests for Pugz engine

const helper = @import("helper.zig");
const expectOutput = helper.expectOutput;

// ─────────────────────────────────────────────────────────────────────────────
// Test Case 1: Simple interpolation
// ─────────────────────────────────────────────────────────────────────────────
test "Simple interpolation" {
    // Quotes don't need escaping in text content (only in attribute values)
    try expectOutput(
        "p #{name}'s Pug source code!",
        .{ .name = "ankit patial" },
        "<p>ankit patial's Pug source code!</p>",
    );
}

test "Interpolation only as text" {
    try expectOutput(
        "h1.header #{header}",
        .{ .header = "MyHeader" },
        "<h1 class=\"header\">MyHeader</h1>",
    );
}

test "Interpolation in each loop" {
    try expectOutput(
        \\ul.list
        \\  each item in list
        \\    li.item #{item}
    , .{ .list = &[_][]const u8{ "a", "b" } },
        \\<ul class="list">
        \\  <li class="item">a</li>
        \\  <li class="item">b</li>
        \\</ul>
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Test Case 2: Attributes with inline text
// ─────────────────────────────────────────────────────────────────────────────
test "Link with href attribute" {
    try expectOutput(
        "a(href='//google.com') Google",
        .{},
        "<a href=\"//google.com\">Google</a>",
    );
}

test "Link with class and href (space separated)" {
    try expectOutput(
        "a(class='button' href='//google.com') Google",
        .{},
        "<a class=\"button\" href=\"//google.com\">Google</a>",
    );
}

test "Link with class and href (comma separated)" {
    try expectOutput(
        "a(class='button', href='//google.com') Google",
        .{},
        "<a class=\"button\" href=\"//google.com\">Google</a>",
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Test Case 3: Boolean attributes (multiline)
// ─────────────────────────────────────────────────────────────────────────────
test "Checkbox with boolean checked attribute" {
    try expectOutput(
        \\input(
        \\  type='checkbox'
        \\  name='agreement'
        \\  checked
        \\)
    ,
        .{},
        "<input type=\"checkbox\" name=\"agreement\" checked=\"checked\"/>",
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Test Case 4: Backtick template literal with multiline JSON
// ─────────────────────────────────────────────────────────────────────────────
test "Input with multiline JSON data attribute" {
    try expectOutput(
        \\input(data-json=`
        \\  {
        \\    "very-long": "piece of ",
        \\    "data": true
        \\  }
        \\`)
    ,
        .{},
        \\<input data-json="
        \\  {
        \\    &quot;very-long&quot;: &quot;piece of &quot;,
        \\    &quot;data&quot;: true
        \\  }
        \\"/>
        ,
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Test Case 5: Escaped vs unescaped attribute values
// ─────────────────────────────────────────────────────────────────────────────
test "Escaped attribute value" {
    try expectOutput(
        "div(escaped=\"<code>\")",
        .{},
        "<div escaped=\"&lt;code&gt;\"></div>",
    );
}

test "Unescaped attribute value" {
    try expectOutput(
        "div(unescaped!=\"<code>\")",
        .{},
        "<div unescaped=\"<code>\"></div>",
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Test Case 6: Boolean attributes with true/false values
// ─────────────────────────────────────────────────────────────────────────────
test "Checkbox with checked (no value)" {
    try expectOutput(
        "input(type='checkbox' checked)",
        .{},
        "<input type=\"checkbox\" checked=\"checked\"/>",
    );
}

test "Checkbox with checked=true" {
    try expectOutput(
        "input(type='checkbox' checked=true)",
        .{},
        "<input type=\"checkbox\" checked=\"checked\"/>",
    );
}

test "Checkbox with checked=false (omitted)" {
    try expectOutput(
        "input(type='checkbox' checked=false)",
        .{},
        "<input type=\"checkbox\"/>",
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Test Case 7: Object literal as style attribute
// ─────────────────────────────────────────────────────────────────────────────
test "Style object literal" {
    try expectOutput(
        "a(style={color: 'red', background: 'green'})",
        .{},
        "<a style=\"color:red;background:green;\"></a>",
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Test Case 8: Array literals for class attribute
// ─────────────────────────────────────────────────────────────────────────────
test "Class array literal" {
    try expectOutput("a(class=['foo', 'bar', 'baz'])", .{}, "<a class=\"foo bar baz\"></a>");
}

test "Class array merged with shorthand and array" {
    try expectOutput(
        "a.bang(class=['foo', 'bar', 'baz'] class=['bing'])",
        .{},
        "<a class=\"bang foo bar baz bing\"></a>",
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Test Case 9: Shorthand class syntax
// ─────────────────────────────────────────────────────────────────────────────
test "Shorthand class on anchor" {
    try expectOutput("a.button", .{}, "<a class=\"button\"></a>");
}

test "Implicit div with class" {
    try expectOutput(".content", .{}, "<div class=\"content\"></div>");
}

test "Shorthand ID on anchor" {
    try expectOutput("a#main-link", .{}, "<a id=\"main-link\"></a>");
}

test "Implicit div with ID" {
    try expectOutput("#content", .{}, "<div id=\"content\"></div>");
}

// ─────────────────────────────────────────────────────────────────────────────
// Test Case 10: &attributes spread operator
// ─────────────────────────────────────────────────────────────────────────────
test "Attributes spread with &attributes" {
    try expectOutput(
        "div#foo(data-bar=\"foo\")&attributes({'data-foo': 'bar'})",
        .{},
        "<div id=\"foo\" data-bar=\"foo\" data-foo=\"bar\"></div>",
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Test Case 11: case/when/default
// ─────────────────────────────────────────────────────────────────────────────
test "Case statement with friends=1" {
    try expectOutput(
        \\case friends
        \\  when 0
        \\    p you have no friends
        \\  when 1
        \\    p you have a friend
        \\  default
        \\    p you have #{friends} friends
    , .{ .friends = @as(i64, 1) }, "<p>you have a friend</p>");
}

test "Case statement with friends=10" {
    try expectOutput(
        \\case friends
        \\  when 0
        \\    p you have no friends
        \\  when 1
        \\    p you have a friend
        \\  default
        \\    p you have #{friends} friends
    , .{ .friends = @as(i64, 10) }, "<p>you have 10 friends</p>");
}

// ─────────────────────────────────────────────────────────────────────────────
// Test Case 12: Conditionals (if/else if/else)
// ─────────────────────────────────────────────────────────────────────────────
test "If condition true" {
    try expectOutput(
        \\if showMessage
        \\  p Hello!
    , .{ .showMessage = true }, "<p>Hello!</p>");
}

test "If condition false (no data)" {
    try expectOutput(
        \\if showMessage
        \\  p Hello!
    , .{}, "");
}

test "If condition false with else" {
    try expectOutput(
        \\if showMessage
        \\  p Hello!
        \\else
        \\  p Goodbye!
    , .{ .showMessage = false }, "<p>Goodbye!</p>");
}

test "Unless condition (negated if)" {
    try expectOutput(
        \\unless isHidden
        \\  p Visible content
    , .{ .isHidden = false }, "<p>Visible content</p>");
}

// ─────────────────────────────────────────────────────────────────────────────
// Test Case 13: Nested conditionals with dot notation
// ─────────────────────────────────────────────────────────────────────────────
test "Condition with nested user.description" {
    try expectOutput(
        \\#user
        \\  if user.description
        \\    h2.green Description
        \\    p.description= user.description
        \\  else if authorised
        \\    h2.blue Description
        \\    p.description No description (authorised)
        \\  else
        \\    h2.red Description
        \\    p.description User has no description
    , .{ .user = .{ .description = "foo bar baz" }, .authorised = false },
        \\<div id="user">
        \\  <h2 class="green">Description</h2>
        \\  <p class="description">foo bar baz</p>
        \\</div>
    );
}

test "Condition with nested user.description and autorized" {
    try expectOutput(
        \\#user
        \\  if user.description
        \\    h2.green Description
        \\    p.description= user.description
        \\  else if authorised
        \\    h2.blue Description
        \\    p.description No description (authorised)
        \\  else
        \\    h2.red Description
        \\    p.description User has no description
    , .{ .authorised = true },
        \\<div id="user">
        \\  <h2 class="blue">Description</h2>
        \\  <p class="description">No description (authorised)</p>
        \\</div>
    );
}

test "Condition with nested user.description and no data" {
    try expectOutput(
        \\#user
        \\  if user.description
        \\    h2.green Description
        \\    p.description= user.description
        \\  else if authorised
        \\    h2.blue Description
        \\    p.description No description (authorised)
        \\  else
        \\    h2.red Description
        \\    p.description User has no description
    , .{},
        \\<div id="user">
        \\  <h2 class="red">Description</h2>
        \\  <p class="description">User has no description</p>
        \\</div>
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Tag Interpolation Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Simple tag interpolation" {
    try expectOutput(
        "p This is #[em emphasized] text.",
        .{},
        "<p>This is <em>emphasized</em> text.</p>",
    );
}

test "Tag interpolation with strong" {
    try expectOutput(
        "p This is #[strong important] text.",
        .{},
        "<p>This is <strong>important</strong> text.</p>",
    );
}

test "Tag interpolation with link" {
    try expectOutput(
        "p Click #[a(href='/') here] to continue.",
        .{},
        "<p>Click <a href=\"/\">here</a> to continue.</p>",
    );
}

test "Tag interpolation with class" {
    try expectOutput(
        "p This is #[span.highlight highlighted] text.",
        .{},
        "<p>This is <span class=\"highlight\">highlighted</span> text.</p>",
    );
}

test "Tag interpolation with id" {
    try expectOutput(
        "p See #[span#note this note] for details.",
        .{},
        "<p>See <span id=\"note\">this note</span> for details.</p>",
    );
}

test "Tag interpolation with class and id" {
    try expectOutput(
        "p Check #[span#info.tooltip the tooltip] here.",
        .{},
        "<p>Check <span id=\"info\" class=\"tooltip\">the tooltip</span> here.</p>",
    );
}

test "Multiple tag interpolations" {
    try expectOutput(
        "p This has #[em emphasis] and #[strong strength].",
        .{},
        "<p>This has <em>emphasis</em> and <strong>strength</strong>.</p>",
    );
}

test "Tag interpolation with multiple classes" {
    try expectOutput(
        "p Text with #[span.red.bold styled content] here.",
        .{},
        "<p>Text with <span class=\"red bold\">styled content</span> here.</p>",
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Iteration Tests
// ─────────────────────────────────────────────────────────────────────────────

test "each loop with array" {
    try expectOutput(
        \\ul
        \\  each item in items
        \\    li= item
    , .{ .items = &[_][]const u8{ "apple", "banana", "cherry" } },
        \\<ul>
        \\  <li>apple</li>
        \\  <li>banana</li>
        \\  <li>cherry</li>
        \\</ul>
    );
}

test "for loop as alias for each" {
    try expectOutput(
        \\ul
        \\  for item in items
        \\    li= item
    , .{ .items = &[_][]const u8{ "one", "two", "three" } },
        \\<ul>
        \\  <li>one</li>
        \\  <li>two</li>
        \\  <li>three</li>
        \\</ul>
    );
}

test "each loop with index" {
    try expectOutput(
        \\ul
        \\  each item, idx in items
        \\    li #{idx}: #{item}
    , .{ .items = &[_][]const u8{ "a", "b", "c" } },
        \\<ul>
        \\  <li>0: a</li>
        \\  <li>1: b</li>
        \\  <li>2: c</li>
        \\</ul>
    );
}

test "each loop with else block" {
    try expectOutput(
        \\ul
        \\  each item in items
        \\    li= item
        \\  else
        \\    li No items found
    , .{ .items = &[_][]const u8{} },
        \\<ul>
        \\  <li>No items found</li>
        \\</ul>
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Mixin Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Basic mixin declaration and call" {
    try expectOutput(
        \\mixin list
        \\  ul
        \\    li foo
        \\    li bar
        \\+list
    , .{},
        \\<ul>
        \\  <li>foo</li>
        \\  <li>bar</li>
        \\</ul>
    );
}

test "Mixin with arguments" {
    try expectOutput(
        \\mixin pet(name)
        \\  li.pet= name
        \\ul
        \\  +pet('cat')
        \\  +pet('dog')
    , .{},
        \\<ul>
        \\  <li class="pet">cat</li>
        \\  <li class="pet">dog</li>
        \\</ul>
    );
}

test "Mixin with default argument" {
    try expectOutput(
        \\mixin greet(name='World')
        \\  p Hello, #{name}!
        \\+greet
        \\+greet('Zig')
    , .{},
        \\<p>Hello, World!</p>
        \\<p>Hello, Zig!</p>
    );
}

test "Mixin with block content" {
    try expectOutput(
        \\mixin article(title)
        \\  .article
        \\    h1= title
        \\    block
        \\+article('Hello')
        \\  p This is content
        \\  p More content
    , .{},
        \\<div class="article">
        \\  <h1>Hello</h1>
        \\  <p>This is content</p>
        \\  <p>More content</p>
        \\</div>
    );
}

test "Mixin with block and no content passed" {
    try expectOutput(
        \\mixin box
        \\  .box
        \\    block
        \\+box
    , .{},
        \\<div class="box">
        \\</div>
    );
}

test "Mixin with attributes" {
    try expectOutput(
        \\mixin link(href, name)
        \\  a(href=href)&attributes(attributes)= name
        \\+link('/foo', 'foo')(class="btn")
    , .{},
        \\<a href="/foo" class="btn">foo</a>
    );
}

test "Mixin with rest arguments" {
    try expectOutput(
        \\mixin list(id, ...items)
        \\  ul(id=id)
        \\    each item in items
        \\      li= item
        \\+list('my-list', 'one', 'two', 'three')
    , .{},
        \\<ul id="my-list">
        \\  <li>one</li>
        \\  <li>two</li>
        \\  <li>three</li>
        \\</ul>
    );
}

test "Mixin with rest arguments empty" {
    try expectOutput(
        \\mixin list(id, ...items)
        \\  ul(id=id)
        \\    each item in items
        \\      li= item
        \\+list('my-list')
    , .{},
        \\<ul id="my-list">
        \\</ul>
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Plain Text Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Inline text in tag" {
    try expectOutput(
        \\p This is plain old text content.
    , .{},
        \\<p>This is plain old text content.</p>
    );
}

test "Piped text basic" {
    try expectOutput(
        \\p
        \\  | The pipe always goes at the beginning of its own line,
        \\  | not counting indentation.
    , .{},
        \\<p>
        \\  The pipe always goes at the beginning of its own line,
        \\  not counting indentation.
        \\</p>
    );
}

// test "Piped text with inline tags" {
//     try expectOutput(
//         \\| You put the em
//         \\em pha
//         \\| sis on the wrong syl
//         \\em la
//         \\| ble.
//     , .{},
//         \\You put the em
//         \\<em>pha</em>sis on the wrong syl
//         \\<em>la</em>ble.
//     );
// }

test "Block text with dot" {
    // Multi-line content in whitespace-preserving elements gets leading newline and preserved indentation
    try expectOutput(
        \\script.
        \\  if (usingPug)
        \\    console.log('you are awesome')
    , .{},
        \\<script>
        \\  if (usingPug)
        \\    console.log('you are awesome')
        \\</script>
    );
}

test "Block text with dot and attributes" {
    // Multi-line content in whitespace-preserving elements gets leading newline and preserved indentation
    try expectOutput(
        \\style(type='text/css').
        \\  body {
        \\    color: red;
        \\  }
    , .{},
        \\<style type="text/css">
        \\  body {
        \\    color: red;
        \\  }
        \\</style>
    );
}

test "Literal HTML passthrough" {
    try expectOutput(
        \\<html>
        \\p Hello from Pug
        \\</html>
    , .{},
        \\<html>
        \\<p>Hello from Pug</p>
        \\</html>
    );
}

test "Literal HTML mixed with Pug" {
    try expectOutput(
        \\div
        \\  <span>Literal HTML</span>
        \\  p Pug paragraph
    , .{},
        \\<div>
        \\<span>Literal HTML</span>
        \\  <p>Pug paragraph</p>
        \\</div>
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Tag Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Nested tags with indentation" {
    try expectOutput(
        \\ul
        \\  li Item A
        \\  li Item B
        \\  li Item C
    , .{},
        \\<ul>
        \\  <li>Item A</li>
        \\  <li>Item B</li>
        \\  <li>Item C</li>
        \\</ul>
    );
}

test "Self-closing void elements" {
    try expectOutput(
        \\img
        \\br
        \\input
    , .{},
        \\<img/>
        \\<br/>
        \\<input/>
    );
}

test "Block expansion with colon" {
    // Block expansion renders children inline (on same line)
    try expectOutput(
        \\a: img
    , .{},
        \\<a><img/></a>
    );
}

test "Block expansion nested" {
    // Block expansion renders children inline (on same line)
    try expectOutput(
        \\ul
        \\  li: a(href='/') Home
        \\  li: a(href='/about') About
    , .{},
        \\<ul>
        \\  <li><a href="/">Home</a></li>
        \\  <li><a href="/about">About</a></li>
        \\</ul>
    );
}

test "Explicit self-closing tag" {
    try expectOutput(
        \\foo/
    , .{},
        \\<foo/>
    );
}

test "Explicit self-closing tag with attributes" {
    try expectOutput(
        \\foo(bar='baz')/
    , .{},
        \\<foo bar="baz"/>
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// String concatenation in attributes
// ─────────────────────────────────────────────────────────────────────────────

test "Attribute with string concatenation" {
    try expectOutput(
        \\button(class="btn btn-" + btnType) Click
    , .{ .btnType = "secondary" },
        \\<button class="btn btn-secondary">Click</button>
    );
}

test "Mixin with string concatenation in class" {
    try expectOutput(
        \\mixin btn(text, btnType="primary")
        \\  button(class="btn btn-" + btnType)= text
        \\+btn("Click me", "secondary")
    , .{},
        \\<button class="btn btn-secondary">Click me</button>
    );
}
