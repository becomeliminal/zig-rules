const std = @import("std");
const left = @import("left");
const right = @import("right");
const motd = @embedFile("motd.txt");

pub fn main() void {
    std.debug.print("{s} {s} {s}", .{ left.word(), right.word(), std.mem.trimEnd(u8, motd, "\n") });
}
