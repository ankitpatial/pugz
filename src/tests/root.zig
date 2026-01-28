const std = @import("std");

comptime {
    _ = @import("check_list_test.zig");
    _ = @import("doctype_test.zig");
    _ = @import("general_test.zig");
}

test {
    std.testing.refAllDecls(@This());
}
