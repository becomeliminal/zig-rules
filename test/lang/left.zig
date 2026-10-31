const util = @import("util");

pub fn word() []const u8 {
    return util.shout("left");
}

test "left shouts" {
    const std = @import("std");
    try std.testing.expectEqualStrings("left!", word());
}
