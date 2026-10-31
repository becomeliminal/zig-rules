const std = @import("std");
const greet = @import("greet");

pub fn main() void {
    std.debug.print("{s}", .{greet.greeting()});
}
