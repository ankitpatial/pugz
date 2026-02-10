const std = @import("std");
const pugz = @import("pugz");

comptime {
    _ = @import("check_list_test.zig");
    _ = @import("doctype_test.zig");
    _ = @import("general_test.zig");
    _ = @import("tag_interp_test.zig");
    _ = pugz.zig_codegen;
}

test {
    std.testing.refAllDecls(@This());
}
