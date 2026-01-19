//! Pugz Template Inheritance Demo
//!
//! A web application demonstrating Pug-style template inheritance
//! using the Pugz ViewEngine with http.zig server.
//!
//! Routes:
//!   GET /           - Home page (layout.pug)
//!   GET /page-a     - Page A with custom scripts and content
//!   GET /page-b     - Page B with sub-layout
//!   GET /append     - Page with block append
//!   GET /append-opt - Page with optional block syntax

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
                .views_dir = "src/examples/demo/views",
            }),
        };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("leak");

    const allocator = gpa.allocator();

    // Initialize view engine once at startup
    var app = App.init(allocator);

    const port = 8080;
    var server = try httpz.Server(*App).init(allocator, .{ .port = port }, &app);
    defer server.deinit();

    var router = try server.router(.{});

    // Routes
    router.get("/", index, .{});
    router.get("/page-a", pageA, .{});
    router.get("/page-b", pageB, .{});
    router.get("/append", pageAppend, .{});
    router.get("/append-opt", pageAppendOptional, .{});

    std.debug.print(
        \\
        \\Pugz Template Inheritance Demo
        \\==============================
        \\Server running at http://localhost:{d}
        \\
        \\Routes:
        \\  GET /           - Home page (base layout)
        \\  GET /page-a     - Page with custom scripts and content blocks
        \\  GET /page-b     - Page with sub-layout inheritance
        \\  GET /append     - Page with block append
        \\  GET /append-opt - Page with optional block keyword
        \\
        \\Press Ctrl+C to stop.
        \\
    , .{port});

    try server.listen();
}

/// Handler for GET /
fn index(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    // Use res.arena - memory is automatically freed after response is sent
    const html = app.view.render(res.arena, "index", .{
        .title = "Home",
        .authenticated = true,
    }) catch |err| {
        res.status = 500;
        res.body = @errorName(err);
        return;
    };

    res.content_type = .HTML;
    res.body = html;
}

/// Handler for GET /page-a - demonstrates extends and block override
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

/// Handler for GET /page-b - demonstrates sub-layout inheritance
fn pageB(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const html = app.view.render(res.arena, "page-b", .{
        .title = "Page B - Sub Layout",
    }) catch |err| {
        res.status = 500;
        res.body = @errorName(err);
        return;
    };

    res.content_type = .HTML;
    res.body = html;
}

/// Handler for GET /append - demonstrates block append
fn pageAppend(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const html = app.view.render(res.arena, "page-append", .{
        .title = "Page Append",
    }) catch |err| {
        res.status = 500;
        res.body = @errorName(err);
        return;
    };

    res.content_type = .HTML;
    res.body = html;
}

/// Handler for GET /append-opt - demonstrates optional block keyword
fn pageAppendOptional(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const html = app.view.render(res.arena, "page-appen-optional-blk", .{
        .title = "Page Append Optional",
    }) catch |err| {
        res.status = 500;
        res.body = @errorName(err);
        return;
    };

    res.content_type = .HTML;
    res.body = html;
}
