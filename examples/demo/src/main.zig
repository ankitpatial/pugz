//! Pugz Demo - Interpreted vs Compiled Templates
//!
//! This demo shows two approaches:
//! 1. **Interpreted** (ViewEngine) - supports extends/blocks, parsed at runtime
//! 2. **Compiled** (build-time) - 3x faster, templates compiled to Zig code
//!
//! Routes:
//!   GET /              - Compiled home page (fast)
//!   GET /users         - Compiled users list (fast)
//!   GET /interpreted   - Interpreted with inheritance (flexible)
//!   GET /page-a        - Interpreted page A

const std = @import("std");
const httpz = @import("httpz");
const pugz = @import("pugz");

// Compiled templates - generated at build time from views/compiled/*.pug
const tpls = @import("tpls");

const Allocator = std.mem.Allocator;

/// Application state shared across all requests
const App = struct {
    allocator: Allocator,
    view: pugz.ViewEngine,

    pub fn init(allocator: Allocator) App {
        return .{
            .allocator = allocator,
            .view = pugz.ViewEngine.init(.{
                .views_dir = "views",
            }),
        };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("leak");

    const allocator = gpa.allocator();

    var app = App.init(allocator);

    const port = 8080;
    var server = try httpz.Server(*App).init(allocator, .{ .port = port }, &app);
    defer server.deinit();

    var router = try server.router(.{});

    // Compiled template routes (fast - 3x faster than Pug.js)
    router.get("/", indexCompiled, .{});
    router.get("/users", usersCompiled, .{});

    // Interpreted template routes (flexible - supports extends/blocks)
    router.get("/interpreted", indexInterpreted, .{});
    router.get("/page-a", pageA, .{});

    std.debug.print(
        \\
        \\Pugz Demo - Interpreted vs Compiled Templates
        \\=============================================
        \\Server running at http://localhost:{d}
        \\
        \\Compiled routes (3x faster than Pug.js):
        \\  GET /        - Home page (compiled)
        \\  GET /users   - Users list (compiled)
        \\
        \\Interpreted routes (supports extends/blocks):
        \\  GET /interpreted  - Home with ViewEngine
        \\  GET /page-a       - Page with inheritance
        \\
        \\Press Ctrl+C to stop.
        \\
    , .{port});

    try server.listen();
}

// ─────────────────────────────────────────────────────────────────────────────
// Compiled template handlers (fast - no parsing at runtime)
// ─────────────────────────────────────────────────────────────────────────────

/// GET / - Compiled home page
fn indexCompiled(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const html = tpls.home(res.arena, .{
        .title = "Welcome - Compiled",
        .authenticated = true,
    }) catch |err| {
        res.status = 500;
        res.body = @errorName(err);
        return;
    };

    res.content_type = .HTML;
    res.body = html;
}

/// GET /users - Compiled users list
fn usersCompiled(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const User = struct {
        name: []const u8,
        email: []const u8,
    };

    const html = tpls.users(res.arena, .{
        .title = "Users - Compiled",
        .users = &[_]User{
            .{ .name = "Alice", .email = "alice@example.com" },
            .{ .name = "Bob", .email = "bob@example.com" },
            .{ .name = "Charlie", .email = "charlie@example.com" },
        },
    }) catch |err| {
        res.status = 500;
        res.body = @errorName(err);
        return;
    };

    res.content_type = .HTML;
    res.body = html;
}

// ─────────────────────────────────────────────────────────────────────────────
// Interpreted template handlers (flexible - supports inheritance)
// ─────────────────────────────────────────────────────────────────────────────

/// GET /interpreted - Uses ViewEngine (parsed at runtime)
fn indexInterpreted(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const html = app.view.render(res.arena, "index", .{
        .title = "Home - Interpreted",
        .authenticated = true,
    }) catch |err| {
        res.status = 500;
        res.body = @errorName(err);
        return;
    };

    res.content_type = .HTML;
    res.body = html;
}

/// GET /page-a - Demonstrates extends and block override
fn pageA(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const html = app.view.render(res.arena, "page-a", .{
        .title = "Page A - Pets",
        .items = &[_][]const u8{ "A", "B", "C" },
        .n = 0,
    }) catch |err| {
        res.status = 500;
        res.body = @errorName(err);
        return;
    };

    res.content_type = .HTML;
    res.body = html;
}
