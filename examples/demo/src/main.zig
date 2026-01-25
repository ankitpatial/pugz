//! Pugz Store Demo - A comprehensive e-commerce demo showcasing Pugz capabilities
//!
//! Features demonstrated:
//!   - Template inheritance (extends/block)
//!   - Partial includes (header, footer)
//!   - Mixins with parameters (product-card, rating, forms)
//!   - Conditionals and loops
//!   - Data binding
//!   - Pretty printing
//!   - LRU cache with TTL

const std = @import("std");
const httpz = @import("httpz");
const pugz = @import("pugz");

const Allocator = std.mem.Allocator;

// ============================================================================
// Data Types
// ============================================================================

const Product = struct {
    id: []const u8,
    name: []const u8,
    price: []const u8,
    image: []const u8,
    rating: u8,
    category: []const u8,
    categorySlug: []const u8,
    sale: bool = false,
    description: []const u8 = "",
    reviewCount: []const u8 = "0",
};

const Category = struct {
    name: []const u8,
    slug: []const u8,
    icon: []const u8,
    count: []const u8,
    active: bool = false,
};

const CartItem = struct {
    id: []const u8,
    name: []const u8,
    price: []const u8,
    image: []const u8,
    variant: []const u8,
    quantity: []const u8,
    total: []const u8,
};

const Cart = struct {
    items: []const CartItem,
    subtotal: []const u8,
    shipping: []const u8,
    discount: ?[]const u8 = null,
    discountCode: ?[]const u8 = null,
    tax: []const u8,
    total: []const u8,
};

const ShippingMethod = struct {
    id: []const u8,
    name: []const u8,
    time: []const u8,
    price: []const u8,
};

const State = struct {
    code: []const u8,
    name: []const u8,
};

// ============================================================================
// Sample Data
// ============================================================================

const sample_products = [_]Product{
    .{
        .id = "1",
        .name = "Wireless Headphones",
        .price = "79.99",
        .image = "/images/headphones.jpg",
        .rating = 4,
        .category = "Electronics",
        .categorySlug = "electronics",
        .sale = true,
        .description = "Premium wireless headphones with noise cancellation",
        .reviewCount = "128",
    },
    .{
        .id = "2",
        .name = "Smart Watch Pro",
        .price = "199.99",
        .image = "/images/watch.jpg",
        .rating = 5,
        .category = "Electronics",
        .categorySlug = "electronics",
        .description = "Advanced fitness tracking and notifications",
        .reviewCount = "256",
    },
    .{
        .id = "3",
        .name = "Laptop Stand",
        .price = "49.99",
        .image = "/images/stand.jpg",
        .rating = 4,
        .category = "Accessories",
        .categorySlug = "accessories",
        .description = "Ergonomic aluminum laptop stand",
        .reviewCount = "89",
    },
    .{
        .id = "4",
        .name = "USB-C Hub",
        .price = "39.99",
        .image = "/images/hub.jpg",
        .rating = 4,
        .category = "Accessories",
        .categorySlug = "accessories",
        .sale = true,
        .description = "7-in-1 USB-C hub with HDMI and card reader",
        .reviewCount = "312",
    },
    .{
        .id = "5",
        .name = "Mechanical Keyboard",
        .price = "129.99",
        .image = "/images/keyboard.jpg",
        .rating = 5,
        .category = "Electronics",
        .categorySlug = "electronics",
        .description = "RGB mechanical keyboard with Cherry MX switches",
        .reviewCount = "445",
    },
    .{
        .id = "6",
        .name = "Desk Lamp",
        .price = "34.99",
        .image = "/images/lamp.jpg",
        .rating = 4,
        .category = "Home Office",
        .categorySlug = "home-office",
        .description = "LED desk lamp with adjustable brightness",
        .reviewCount = "67",
    },
};

const sample_categories = [_]Category{
    .{ .name = "Electronics", .slug = "electronics", .icon = "E", .count = "24" },
    .{ .name = "Accessories", .slug = "accessories", .icon = "A", .count = "18" },
    .{ .name = "Home Office", .slug = "home-office", .icon = "H", .count = "12" },
    .{ .name = "Clothing", .slug = "clothing", .icon = "C", .count = "36" },
};

const sample_cart_items = [_]CartItem{
    .{
        .id = "1",
        .name = "Wireless Headphones",
        .price = "79.99",
        .image = "/images/headphones.jpg",
        .variant = "Black",
        .quantity = "1",
        .total = "79.99",
    },
    .{
        .id = "5",
        .name = "Mechanical Keyboard",
        .price = "129.99",
        .image = "/images/keyboard.jpg",
        .variant = "RGB",
        .quantity = "1",
        .total = "129.99",
    },
};

const sample_cart = Cart{
    .items = &sample_cart_items,
    .subtotal = "209.98",
    .shipping = "0",
    .tax = "18.90",
    .total = "228.88",
};

const shipping_methods = [_]ShippingMethod{
    .{ .id = "standard", .name = "Standard Shipping", .time = "5-7 business days", .price = "0" },
    .{ .id = "express", .name = "Express Shipping", .time = "2-3 business days", .price = "9.99" },
    .{ .id = "overnight", .name = "Overnight Shipping", .time = "Next business day", .price = "19.99" },
};

const us_states = [_]State{
    .{ .code = "CA", .name = "California" },
    .{ .code = "NY", .name = "New York" },
    .{ .code = "TX", .name = "Texas" },
    .{ .code = "FL", .name = "Florida" },
    .{ .code = "WA", .name = "Washington" },
};

// ============================================================================
// Application
// ============================================================================

const App = struct {
    allocator: Allocator,
    view: pugz.ViewEngine,

    pub fn init(allocator: Allocator) !App {
        return .{
            .allocator = allocator,
            .view = try pugz.ViewEngine.init(allocator, .{
                .views_dir = "views",
                .pretty = true,
                .max_cached_templates = 50,
                .cache_ttl_seconds = 10, // 10s TTL for development
            }),
        };
    }

    pub fn deinit(self: *App) void {
        self.view.deinit();
    }
};

// ============================================================================
// Request Handlers
// ============================================================================

fn home(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const html = app.view.render(res.arena, "pages/home", .{
        .title = "Home",
        .cartCount = "2",
        .authenticated = true,
        .items = &[_][]const u8{ "Wireless Headphones", "Smart Watch", "Laptop Stand", "USB-C Hub" },
    }) catch |err| {
        return renderError(res, err);
    };

    res.content_type = .HTML;
    res.body = html;
}

fn products(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const html = app.view.render(res.arena, "pages/products", .{
        .title = "All Products",
        .cartCount = "2",
        .productCount = "6",
    }) catch |err| {
        return renderError(res, err);
    };

    res.content_type = .HTML;
    res.body = html;
}

fn productDetail(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = req.param("id") orelse "1";
    _ = id;

    const html = app.view.render(res.arena, "pages/product-detail", .{
        .cartCount = "2",
        .productName = "Wireless Headphones",
        .category = "Electronics",
        .price = "79.99",
        .description = "Premium wireless headphones with active noise cancellation. Experience crystal-clear audio whether you're working, traveling, or relaxing at home.",
        .sku = "WH-001-BLK",
    }) catch |err| {
        return renderError(res, err);
    };

    res.content_type = .HTML;
    res.body = html;
}

fn cart(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const html = app.view.render(res.arena, "pages/cart", .{
        .title = "Shopping Cart",
        .cartCount = "2",
        .cartItems = &sample_cart_items,
        .subtotal = sample_cart.subtotal,
        .shipping = sample_cart.shipping,
        .tax = sample_cart.tax,
        .total = sample_cart.total,
    }) catch |err| {
        return renderError(res, err);
    };

    res.content_type = .HTML;
    res.body = html;
}

fn about(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const html = app.view.render(res.arena, "pages/about", .{
        .title = "About",
        .cartCount = "2",
    }) catch |err| {
        return renderError(res, err);
    };

    res.content_type = .HTML;
    res.body = html;
}

fn includeDemo(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const html = app.view.render(res.arena, "pages/include-demo", .{
        .title = "Include Demo",
        .cartCount = "2",
    }) catch |err| {
        return renderError(res, err);
    };

    res.content_type = .HTML;
    res.body = html;
}

fn notFound(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 404;

    const html = app.view.render(res.arena, "pages/404", .{
        .title = "Page Not Found",
        .cartCount = "2",
    }) catch |err| {
        return renderError(res, err);
    };

    res.content_type = .HTML;
    res.body = html;
}

fn renderError(res: *httpz.Response, err: anyerror) void {
    res.status = 500;
    res.content_type = .HTML;
    res.body = std.fmt.allocPrint(res.arena,
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>Error</title></head>
        \\<body>
        \\<h1>500 - Server Error</h1>
        \\<p>Error: {s}</p>
        \\</body>
        \\</html>
    , .{@errorName(err)}) catch "Internal Server Error";
}

// ============================================================================
// Static Files
// ============================================================================

fn serveStatic(_: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const path = req.url.path;

    // Strip leading slash and prepend public folder
    const rel_path = if (path.len > 0 and path[0] == '/') path[1..] else path;
    const full_path = std.fmt.allocPrint(res.arena, "public/{s}", .{rel_path}) catch {
        res.status = 500;
        res.body = "Internal Server Error";
        return;
    };

    // Read file from disk
    const content = std.fs.cwd().readFileAlloc(res.arena, full_path, 10 * 1024 * 1024) catch {
        res.status = 404;
        res.body = "Not Found";
        return;
    };

    // Set content type based on extension
    if (std.mem.endsWith(u8, path, ".css")) {
        res.content_type = .CSS;
    } else if (std.mem.endsWith(u8, path, ".js")) {
        res.content_type = .JS;
    } else if (std.mem.endsWith(u8, path, ".html")) {
        res.content_type = .HTML;
    }

    res.body = content;
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("leak");

    const allocator = gpa.allocator();

    var app = try App.init(allocator);
    defer app.deinit();

    const port = 8081;
    var server = try httpz.Server(*App).init(allocator, .{ .port = port }, &app);
    defer server.deinit();

    var router = try server.router(.{});

    // Pages
    router.get("/", home, .{});
    router.get("/products", products, .{});
    router.get("/products/:id", productDetail, .{});
    router.get("/cart", cart, .{});
    router.get("/about", about, .{});
    router.get("/include-demo", includeDemo, .{});

    // Static files
    router.get("/css/*", serveStatic, .{});

    std.debug.print(
        \\
        \\  ____                    ____  _
        \\ |  _ \ _   _  __ _ ____ / ___|| |_ ___  _ __ ___
        \\ | |_) | | | |/ _` |_  / \___ \| __/ _ \| '__/ _ \
        \\ |  __/| |_| | (_| |/ /   ___) | || (_) | | |  __/
        \\ |_|    \__,_|\__, /___| |____/ \__\___/|_|  \___|
        \\              |___/
        \\
        \\ Server running at http://localhost:{d}
        \\
        \\ Routes:
        \\   GET /              - Home page
        \\   GET /products      - Products page
        \\   GET /products/:id  - Product detail
        \\   GET /cart          - Shopping cart
        \\   GET /about         - About page
        \\   GET /include-demo  - Include directive demo
        \\
        \\ Press Ctrl+C to stop.
        \\
    , .{port});

    try server.listen();
}
