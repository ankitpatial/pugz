//! Pugz Template Inheritance Demo
//!
//! A web application demonstrating Pug-style template inheritance
//! using the Pugz template engine with http.zig server.
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
    views_dir: []const u8,

    /// File resolver for loading templates from disk
    pub fn fileResolver(allocator: Allocator, path: []const u8) ?[]const u8 {
        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();
        return file.readToEndAlloc(allocator, 1024 * 1024) catch null;
    }

    /// Render a template with data
    pub fn render(self: *App, template_name: []const u8, data: anytype) ![]u8 {
        // Build full path
        const template_path = try std.fs.path.join(self.allocator, &.{ self.views_dir, template_name });
        defer self.allocator.free(template_path);

        // Load template source
        const source = fileResolver(self.allocator, template_path) orelse {
            return error.TemplateNotFound;
        };
        defer self.allocator.free(source);

        // Parse template
        var lexer = pugz.Lexer.init(self.allocator, source);
        const tokens = try lexer.tokenize();

        var parser = pugz.Parser.init(self.allocator, tokens);
        const doc = try parser.parse();

        // Setup context with data
        var ctx = pugz.runtime.Context.init(self.allocator);
        defer ctx.deinit();

        try ctx.pushScope();
        inline for (std.meta.fields(@TypeOf(data))) |field| {
            const value = @field(data, field.name);
            try ctx.set(field.name, pugz.runtime.toValue(self.allocator, value));
        }

        // Render with file resolver for includes/extends
        var runtime = pugz.runtime.Runtime.init(self.allocator, &ctx, .{
            .file_resolver = fileResolver,
            .base_dir = self.views_dir,
        });
        defer runtime.deinit();

        return runtime.renderOwned(doc);
    }
};

/// Handler for GET /
fn index(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const html = app.render("layout.pug", .{
        .title = "Home",
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
    const html = app.render("page-a.pug", .{
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
    const html = app.render("page-b.pug", .{
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
    const html = app.render("page-append.pug", .{
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
    const html = app.render("page-appen-optional-blk.pug", .{
        .title = "Page Append Optional",
    }) catch |err| {
        res.status = 500;
        res.body = @errorName(err);
        return;
    };

    res.content_type = .HTML;
    res.body = html;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Views directory - relative to current working directory
    const views_dir = "src/examples/app_01/views";

    var app = App{
        .allocator = allocator,
        .views_dir = views_dir,
    };

    var server = try httpz.Server(*App).init(allocator, .{ .port = 8080 }, &app);
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
        \\Server running at http://localhost:8080
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
    , .{});

    try server.listen();
}
