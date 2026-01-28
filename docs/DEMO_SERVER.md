# Pugz Demo Server

A simple HTTP server demonstrating Pugz template engine with both runtime and compiled template modes.

## Quick Start

### 1. Build Everything

From the **pugz root directory** (not this demo directory):

```bash
cd /path/to/pugz
zig build
```

This builds:
- The `pugz` library
- The `pug-compile` CLI tool (in `zig-out/bin/`)
- All tests and benchmarks

### 2. Build Demo Server

```bash
cd examples/demo
zig build
```

### 3. Run Demo Server

```bash
zig build run
```

The server will start on `http://localhost:5882`

## Using Compiled Templates (Optional)

For maximum performance, you can pre-compile templates to Zig code:

### Step 1: Compile Templates

From the **pugz root**:

```bash
./zig-out/bin/pug-compile --dir examples/demo/views --out examples/demo/generated pages
```

This compiles all `.pug` files in `views/pages/` to Zig functions.

### Step 2: Enable Compiled Mode

Edit `src/main.zig` and set:

```zig
const USE_COMPILED_TEMPLATES = true;
```

### Step 3: Rebuild and Run

```bash
zig build run
```

## Project Structure

```
demo/
├── build.zig              # Build configuration
├── build.zig.zon          # Dependencies
├── src/
│   └── main.zig           # Server implementation
├── views/                 # Pug templates (runtime mode)
│   ├── layouts/
│   │   └── main.pug
│   ├── partials/
│   │   ├── header.pug
│   │   └── footer.pug
│   └── pages/
│       ├── home.pug
│       └── about.pug
└── generated/             # Compiled templates (after compilation)
    ├── home.zig
    ├── about.zig
    ├── helpers.zig
    └── root.zig
```

## Available Routes

- `GET /` - Home page
- `GET /about` - About page
- `GET /simple` - Simple compiled template demo (if `USE_COMPILED_TEMPLATES=true`)

## Runtime vs Compiled Templates

### Runtime Mode (Default)
- ✅ Full Pug feature support (extends, includes, mixins, loops)
- ✅ Easy development - edit templates and refresh
- ⚠️ Parses templates on every request

### Compiled Mode
- ✅ 10-100x faster (no runtime parsing)
- ✅ Type-safe data structures
- ✅ Zero dependencies in generated code
- ⚠️ Limited features (no extends/includes/mixins yet)
- ⚠️ Must recompile after template changes

## Development Workflow

### Runtime Mode (Recommended for Development)

1. Edit `.pug` files in `views/`
2. Refresh browser - changes take effect immediately
3. No rebuild needed

### Compiled Mode (Recommended for Production)

1. Edit `.pug` files in `views/`
2. Recompile: `../../../zig-out/bin/pug-compile --dir views --out generated pages`
3. Rebuild: `zig build`
4. Restart server

## Dependencies

- **pugz** - Template engine (from parent directory)
- **httpz** - HTTP server ([karlseguin/http.zig](https://github.com/karlseguin/http.zig))

## Troubleshooting

### "unable to find module 'pugz'"

Make sure you built from the pugz root directory first:

```bash
cd /path/to/pugz  # Go to root, not demo/
zig build
```

### "File not found: views/..."

Make sure you're running the server from the demo directory:

```bash
cd examples/demo
zig build run
```

### Compiled templates not working

1. Verify templates were compiled: `ls -la generated/`
2. Check `USE_COMPILED_TEMPLATES` is set to `true` in `src/main.zig`
3. Rebuild: `zig build`

## Example: Adding a New Page

### Runtime Mode

1. Create `views/pages/contact.pug`:
```pug
extends ../layouts/main.pug

block content
  h1 Contact Us
  p Email: hello@example.com
```

2. Add route in `src/main.zig`:
```zig
fn contactPage(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const html = app.view.render(res.arena, "pages/contact", .{
        .siteName = "Demo Site",
    }) catch |err| {
        return renderError(res, err);
    };
    res.content_type = .HTML;
    res.body = html;
}

// In main(), add route:
server.router().get("/contact", contactPage);
```

3. Restart server and visit `http://localhost:5882/contact`

### Compiled Mode

1. Create simple template (no extends): `views/pages/contact.pug`
```pug
doctype html
html
  head
    title Contact
  body
    h1 Contact Us
    p Email: #{email}
```

2. Compile: `../../../zig-out/bin/pug-compile --dir views --out generated pages`

3. Add route:
```zig
const templates = @import("templates");

fn contactPage(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const html = try templates.pages_contact.render(res.arena, .{
        .email = "hello@example.com",
    });
    res.content_type = .HTML;
    res.body = html;
}
```

4. Rebuild and restart

## Performance Tips

1. **Use compiled templates** for production (after development is complete)
2. **Use ArenaAllocator** - Templates are freed all at once after response
3. **Cache static assets** - Serve CSS/JS from CDN or static server
4. **Keep templates simple** - Avoid complex logic in templates

## Learn More

- [Pugz Documentation](../../docs/)
- [Pug Language Reference](https://pugjs.org/language/)
- [Compiled Templates Guide](../cli-templates-demo/FEATURES_REFERENCE.md)
- [Compatibility Matrix](../cli-templates-demo/PUGJS_COMPATIBILITY.md)
