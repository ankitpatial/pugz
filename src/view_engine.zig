// ViewEngine - Simple template engine for web servers
//
// Provides a high-level API for rendering Pug templates from a views directory.
// Works with any web server that provides an allocator (httpz, zap, etc).
//
// Usage:
//   const engine = ViewEngine.init(.{ .views_dir = "views" });
//   const html = try engine.render(allocator, "pages/home", .{ .title = "Home" });

const std = @import("std");
const pug = @import("pug.zig");

pub const Options = struct {
    /// Root directory containing view templates
    views_dir: []const u8 = "views",
    /// File extension for templates
    extension: []const u8 = ".pug",
    /// Enable pretty-printing with indentation
    pretty: bool = true,
};

pub const ViewEngine = struct {
    options: Options,

    pub fn init(options: Options) ViewEngine {
        return .{ .options = options };
    }

    /// Renders a template file with the given data context.
    /// Template path is relative to views_dir, extension added automatically.
    pub fn render(self: *const ViewEngine, allocator: std.mem.Allocator, template_path: []const u8, data: anytype) ![]const u8 {
        _ = data; // TODO: pass data to template

        // Build full path
        const full_path = try self.resolvePath(allocator, template_path);
        defer allocator.free(full_path);

        // Compile the template
        var result = pug.compileFile(allocator, full_path, .{
            .pretty = self.options.pretty,
            .filename = full_path,
        }) catch |err| {
            return err;
        };

        if (result.err) |*e| {
            e.deinit();
            return error.ParseError;
        }

        return result.html;
    }

    /// Resolves a template path relative to views directory
    fn resolvePath(self: *const ViewEngine, allocator: std.mem.Allocator, template_path: []const u8) ![]const u8 {
        // Add extension if not present
        const with_ext = if (std.mem.endsWith(u8, template_path, self.options.extension))
            try allocator.dupe(u8, template_path)
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ template_path, self.options.extension });
        defer allocator.free(with_ext);

        return std.fs.path.join(allocator, &.{ self.options.views_dir, with_ext });
    }
};
