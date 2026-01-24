//! Pugz Demo - ViewEngine Template Rendering
//!
//! This demo shows how to use ViewEngine for server-side rendering.
//!
//! Routes:
//!   GET /        - Home page
//!   GET /users   - Users list
//!   GET /page-a  - Page with data

const std = @import("std");
const httpz = @import("httpz");
const pugz = @import("pugz");

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

    const port = 8081;
    var server = try httpz.Server(*App).init(allocator, .{ .port = port }, &app);
    defer server.deinit();

    var router = try server.router(.{});

    router.get("/", index, .{});
    router.get("/users", users, .{});
    router.get("/page-a", pageA, .{});
    router.get("/mixin-test", mixinTest, .{});

    std.debug.print(
        \\
        \\Pugz Demo - ViewEngine Template Rendering
        \\==========================================
        \\Server running at http://localhost:{d}
        \\
        \\Routes:
        \\  GET /        - Home page
        \\  GET /users   - Users list
        \\  GET /page-a  - Page with data
        \\  GET /mixin-test - Mixin test page
        \\
        \\Press Ctrl+C to stop.
        \\
    , .{port});

    try server.listen();
}

/// GET / - Home page
fn index(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const html = app.view.render(res.arena, "index", .{
        .title = "Welcome",
        .authenticated = true,
    }) catch |err| {
        res.status = 500;
        res.body = @errorName(err);
        return;
    };

    res.content_type = .HTML;
    res.body = html;
}

/// GET /users - Users list
fn users(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const html = app.view.render(res.arena, "users", .{
        .title = "Users",
    }) catch |err| {
        res.status = 500;
        res.body = @errorName(err);
        return;
    };

    res.content_type = .HTML;
    res.body = html;
}

/// GET /page-a - Page with data
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

/// GET /mixin-test - Mixin test page
fn mixinTest(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const html = app.view.render(res.arena, "mixin-test", .{}) catch |err| {
        res.status = 500;
        res.body = @errorName(err);
        return;
    };

    res.content_type = .HTML;
    res.body = html;
}
