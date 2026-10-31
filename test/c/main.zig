const std = @import("std");
const calc = @import("calc");

pub fn main() void {
    std.debug.print("{d}", .{calc.calc(2, 3)});
}
