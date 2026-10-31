//! please_zig, the zig plugin's one program, built by the zig it wraps so it
//! needs no other compiler. Called by its installed name (cc, c++, ar, ranlib,
//! ld) it is a C toolchain (cc.zig). Called as please_zig, it is the rules'
//! helper: `manifest` and `compile` for Zig modules (module.zig), and `zon`
//! for package rules (zon.zig).
const std = @import("std");
const cc = @import("cc.zig");
const module = @import("module.zig");
const zon = @import("zon.zig");

const Subcommand = enum { manifest, compile, zon };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const name = std.fs.path.basename(args[0]);
    if (std.meta.stringToEnum(cc.Tool, name)) |tool| return cc.run(init, tool, args[1..]);

    if (args.len < 2) std.process.fatal("usage: please_zig manifest|compile|zon ...; or install it as cc, c++, ar, ranlib or ld", .{});
    const subcommand = std.meta.stringToEnum(Subcommand, args[1]) orelse
        std.process.fatal("please_zig has no subcommand {s}: it has manifest, compile and zon", .{args[1]});
    return switch (subcommand) {
        .manifest => module.manifestMain(init, args[2..]),
        .compile => module.compileMain(init, args[2..]),
        .zon => zon.zonMain(init, args[2..]),
    };
}

test {
    _ = cc;
    _ = module;
    _ = zon;
}
