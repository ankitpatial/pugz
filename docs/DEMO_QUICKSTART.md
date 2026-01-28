# Demo Server - Quick Start Guide

## Prerequisites

```bash
# From pugz root directory
cd /path/to/pugz
zig build
```

## Running the Demo

```bash
cd examples/demo
zig build run
```

The server will start on **http://localhost:8081**

## Available Routes

| Route | Description |
|-------|-------------|
| `GET /` | Home page with hero section and featured products |
| `GET /products` | All products listing |
| `GET /products/:id` | Individual product detail page |
| `GET /cart` | Shopping cart (with sample items) |
| `GET /about` | About page with company info |
| `GET /include-demo` | Demonstrates include directive |
| `GET /simple` | Simple compiled template demo |

## Features Demonstrated

### 1. Template Inheritance
- Uses `extends` and `block` for layout system
- `views/layouts/main.pug` - Main layout
- Pages extend the layout and override blocks

### 2. Includes
- `views/partials/header.pug` - Site header with navigation
- `views/partials/footer.pug` - Site footer
- Demonstrates code reuse

### 3. Mixins
- `views/mixins/products.pug` - Product card component
- `views/mixins/buttons.pug` - Reusable button styles
- Shows component-based design

### 4. Data Binding
- Dynamic content from Zig structs
- Type-safe data passing
- HTML escaping by default

### 5. Iteration
- Product listings with `each` loops
- Cart items iteration
- Dynamic list rendering

### 6. Conditionals
- Show/hide based on data
- Feature flags
- User state handling

## Testing

### Quick Test

```bash
# Start server
cd examples/demo
./zig-out/bin/demo &

# Test endpoints
curl http://localhost:8081/
curl http://localhost:8081/products
curl http://localhost:8081/about

# Stop server
killall demo
```

### All Routes Test

```bash
cd examples/demo
./zig-out/bin/demo &
DEMO_PID=$!
sleep 1

# Test all routes
for route in / /products /products/1 /cart /about /include-demo /simple; do
  echo "Testing: $route"
  curl -s http://localhost:8081$route | grep -o "<title>.*</title>"
done

kill $DEMO_PID
```

## Project Structure

```
demo/
├── build.zig           # Build configuration
├── build.zig.zon       # Dependencies
├── src/
│   └── main.zig        # Server implementation
└── views/
    ├── layouts/
    │   └── main.pug    # Main layout
    ├── partials/
    │   ├── header.pug  # Site header
    │   └── footer.pug  # Site footer
    ├── mixins/
    │   ├── products.pug
    │   └── buttons.pug
    └── pages/
        ├── home.pug
        ├── products.pug
        ├── product-detail.pug
        ├── cart.pug
        ├── about.pug
        └── include-demo.pug
```

## Code Walkthrough

### Server Setup (main.zig)

```zig
// Initialize ViewEngine
const engine = pugz.ViewEngine.init(.{
    .views_dir = "views",
    .extension = ".pug",
});

// Create server
var server = try httpz.Server(*App).init(allocator, .{
    .port = 8081,
}, .{
    .view = engine,
});

// Add routes
server.router().get("/", homePage);
server.router().get("/products", productsPage);
server.router().get("/about", aboutPage);
```

### Rendering Templates

```zig
fn homePage(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const html = app.view.render(res.arena, "pages/home", .{
        .siteName = "Pugz Store",
        .featured = &products[0..3],
    }) catch |err| {
        return renderError(res, err);
    };
    
    res.content_type = .HTML;
    res.body = html;
}
```

## Common Issues

### Port Already in Use

If you see "AddressInUse" error:

```bash
# Find and kill the process
lsof -ti:8081 | xargs kill

# Or use a different port (edit main.zig):
.port = 8082,  // Change from 8081
```

### Views Not Found

Make sure you're running from the demo directory:

```bash
cd examples/demo  # Important!
zig build run
```

### Memory Leaks

The demo uses ArenaAllocator per request - all memory is freed when the response is sent:

```zig
// res.arena is automatically freed after response
const html = app.view.render(res.arena, ...);
```

## Performance

### Runtime Mode (Default)
- Templates parsed on every request
- Full Pug feature support
- Great for development

### Compiled Mode (Optional)
- Pre-compile templates to Zig functions
- 10-100x faster
- See [DEMO_SERVER.md](DEMO_SERVER.md) for setup

## Next Steps

1. **Modify templates** - Edit files in `views/` and refresh browser
2. **Add new routes** - Follow the pattern in `main.zig`
3. **Create new pages** - Add `.pug` files in `views/pages/`
4. **Build your app** - Use this demo as a starting point

## Full Documentation

See [DEMO_SERVER.md](DEMO_SERVER.md) for complete documentation including:
- Compiled templates setup
- Production deployment
- Advanced features
- Troubleshooting

---

**Quick Start Complete!** 🚀

Server running at: **http://localhost:8081**
