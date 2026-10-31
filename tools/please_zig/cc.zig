//! please_zig's C toolchain mode. Installed beside zig as cc, c++, ar, ranlib
//! and ld, and called by those names, because a build tool setting names one
//! program and passes it no arguments of its own. For an action building for
//! the host it runs the host's own tool, so a host build is what it would be
//! without it; for one building for Linux, zig, linking musl statically.
const std = @import("std");
const builtin = @import("builtin");

/// An operating system and architecture, as Go and Please name them.
pub const Platform = struct {
    os: []const u8,
    arch: []const u8,

    pub fn eql(a: Platform, b: Platform) bool {
        return std.mem.eql(u8, a.os, b.os) and std.mem.eql(u8, a.arch, b.arch);
    }
};

/// A C toolchain command please_zig is installed as.
pub const Tool = enum {
    cc,
    @"c++",
    ar,
    ranlib,
    ld,

    /// The zig subcommand that does this tool's job for another platform.
    fn zigCommand(tool: Tool) []const []const u8 {
        return switch (tool) {
            .cc => &.{"cc"},
            .@"c++" => &.{"c++"},
            .ar => &.{"ar"},
            .ranlib => &.{"ranlib"},
            .ld => &.{"ld.lld"},
        };
    }

    fn compiles(tool: Tool) bool {
        return tool == .cc or tool == .@"c++";
    }
};

/// zig's target for each platform please_zig builds for other than the host:
/// musl, so a binary links fully static.
const zig_targets = std.StaticStringMap([]const u8).initComptime(.{
    .{ "linux/amd64", "x86_64-linux-musl" },
    .{ "linux/arm64", "aarch64-linux-musl" },
});

/// The files a compiler compiles, as opposed to flags and their values.
const source_suffixes = [_][]const u8{ ".c", ".cc", ".cpp", ".cxx", ".s", ".S" };

pub const Error = error{
    /// Neither GOOS and GOARCH nor OS and ARCH say what the action builds for.
    UnknownTargetPlatform,
    /// The action builds for a platform zig_targets does not name.
    NoTargetForPlatform,
    /// TMP_DIR is not under plz-out and ZIG_CACHE_DIR is not set.
    NoCacheDir,
};

/// The platform the calling build action builds for: GOOS and GOARCH when set
/// (Go sets them for each cross build, including a toolchain's standard
/// library), otherwise OS and ARCH, which Please sets on every action.
pub fn targetPlatform(env: *const std.process.Environ.Map) Error!Platform {
    const os = env.get("GOOS") orelse env.get("OS") orelse return error.UnknownTargetPlatform;
    const arch = env.get("GOARCH") orelse env.get("ARCH") orelse return error.UnknownTargetPlatform;
    return .{ .os = os, .arch = arch };
}

/// The platform please_zig runs on, named as Go and Please name it.
pub fn hostPlatform() Platform {
    const os = switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        else => @compileError("please_zig runs on macOS and Linux"),
    };
    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        else => @compileError("please_zig runs on amd64 and arm64"),
    };
    return .{ .os = os, .arch = arch };
}

/// zig's cache directory. zig compiles libc for a target the first time it
/// links for it, which takes seconds, and its cache only works where it was
/// built (its entries hold absolute paths), so every action shares one:
/// plz-out/zig-cache in the repo the action runs in, found from TMP_DIR, which
/// Please sets under plz-out. ZIG_CACHE_DIR names another.
pub fn cacheDir(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) (Error || std.mem.Allocator.Error)![]const u8 {
    if (env.get("ZIG_CACHE_DIR")) |dir| return dir;
    const tmp = env.get("TMP_DIR") orelse return error.NoCacheDir;
    const marker = "/plz-out/";
    const at = std.mem.indexOf(u8, tmp, marker) orelse return error.NoCacheDir;
    return std.fmt.allocPrint(allocator, "{s}/plz-out/zig-cache", .{tmp[0..at]});
}

/// The commands one call of please_zig runs, in order. Building for the host,
/// it is the host's own tool of the same name. Building for a platform
/// zig_targets names, it is zig, as many times as the call needs. Any other
/// platform is refused.
pub fn commands(
    allocator: std.mem.Allocator,
    tool: Tool,
    args: []const []const u8,
    target: Platform,
    host: Platform,
    zig: []const u8,
) (Error || std.mem.Allocator.Error)![]const []const []const u8 {
    if (target.eql(host)) {
        const command = try std.mem.concat(allocator, []const u8, &.{ &.{@tagName(tool)}, args });
        return allocator.dupe([]const []const u8, &.{command});
    }
    const key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ target.os, target.arch });
    const triple = zig_targets.get(key) orelse return error.NoTargetForPlatform;

    const zig_command = try std.mem.concat(allocator, []const u8, &.{ &.{zig}, tool.zigCommand() });
    if (!tool.compiles()) {
        const command = try std.mem.concat(allocator, []const u8, &.{ zig_command, args });
        return allocator.dupe([]const []const u8, &.{command});
    }

    // zig compiles unoptimised C with UndefinedBehaviorSanitizer on, which gcc
    // never does: an object would then need zig's sanitizer runtime, which a
    // link by another driver (Go's) does not bring. Off, it compiles as cc does.
    const compiler = try std.mem.concat(allocator, []const u8, &.{ zig_command, &.{ "-target", triple, "-fno-sanitize=undefined" } });

    // `cc -c a.c b.c`, with no -o, writes a.o and b.o. zig writes only a.o and
    // still succeeds, so the call becomes one per source, each writing what cc
    // would have.
    var flags: std.ArrayList([]const u8) = .empty;
    var sources: std.ArrayList([]const u8) = .empty;
    var compile_only = false;
    var has_output = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-c")) {
            compile_only = true;
            try flags.append(allocator, arg);
        } else if (std.mem.eql(u8, arg, "-o")) {
            has_output = true;
            try flags.append(allocator, arg);
        } else if (isSource(arg)) {
            try sources.append(allocator, arg);
        } else {
            try flags.append(allocator, arg);
        }
    }
    if (!compile_only or has_output or sources.items.len <= 1) {
        const command = try std.mem.concat(allocator, []const u8, &.{ compiler, args });
        return allocator.dupe([]const []const u8, &.{command});
    }
    const split = try allocator.alloc([]const []const u8, sources.items.len);
    for (sources.items, split) |source, *command| {
        const base = std.fs.path.basename(source);
        const object = try std.fmt.allocPrint(allocator, "{s}.o", .{base[0 .. base.len - std.fs.path.extension(base).len]});
        command.* = try std.mem.concat(allocator, []const u8, &.{ compiler, flags.items, &.{ source, "-o", object } });
    }
    return split;
}

fn isSource(arg: []const u8) bool {
    for (source_suffixes) |suffix| {
        if (std.mem.endsWith(u8, arg, suffix)) return true;
    }
    return false;
}

/// Runs please_zig as the C toolchain tool it was called as.
pub fn run(init: std.process.Init, tool: Tool, args: []const []const u8) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;
    const name = @tagName(tool);

    const target = targetPlatform(env) catch
        std.process.fatal("the target platform is unknown: set GOOS and GOARCH, or OS and ARCH", .{});
    const host = hostPlatform();
    const self_dir = try std.process.executableDirPathAlloc(io, arena);
    const zig = try std.fs.path.join(arena, &.{ self_dir, "zig", "zig" });

    const planned = commands(arena, tool, args, target, host, zig) catch |err| switch (err) {
        error.NoTargetForPlatform => std.process.fatal("please_zig has no target for {s}/{s}", .{ target.os, target.arch }),
        else => return err,
    };

    if (target.eql(host)) {
        // The host's tool is found on PATH. If this toolchain is on PATH too,
        // that could be please_zig calling itself for ever.
        var entries = std.mem.tokenizeScalar(u8, env.get("PATH") orelse "", ':');
        while (entries.next()) |entry| {
            if (std.mem.eql(u8, std.mem.trimEnd(u8, entry, "/"), self_dir))
                std.process.fatal("{s} is on PATH, so {s} there would be please_zig itself, not the host's", .{ self_dir, name });
        }
    } else {
        const cache = cacheDir(arena, env) catch |err| switch (err) {
            error.NoCacheDir => std.process.fatal("TMP_DIR \"{s}\" is not under plz-out; set ZIG_CACHE_DIR", .{env.get("TMP_DIR") orelse ""}),
            else => return err,
        };
        try env.put("ZIG_GLOBAL_CACHE_DIR", cache);
        try env.put("ZIG_LOCAL_CACHE_DIR", cache);
    }

    // One command replaces this process, so its output and exit status are the
    // caller's; several run in turn, stopping at the first that fails.
    if (planned.len == 1) {
        return std.process.replace(io, .{ .argv = planned[0], .environ_map = env });
    }
    for (planned) |command| {
        var child = try std.process.spawn(io, .{ .argv = command, .environ_map = env });
        switch (try child.wait(io)) {
            .exited => |code| if (code != 0) std.process.exit(code),
            else => std.process.exit(1),
        }
    }
}

const test_zig = "/toolchain/zig/zig";
const test_mac: Platform = .{ .os = "darwin", .arch = "arm64" };
const test_linux_amd64: Platform = .{ .os = "linux", .arch = "amd64" };
const test_linux_arm64: Platform = .{ .os = "linux", .arch = "arm64" };

fn testEnv(vars: []const [2][]const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    for (vars) |kv| try env.put(kv[0], kv[1]);
    return env;
}

test "commands: the host's own tool when building for the host" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // GIVEN an action on a Mac building for the Mac
    // WHEN please_zig is called as cc with two sources
    const got = try commands(arena.allocator(), .cc, &.{ "-c", "a.c", "b.c" }, test_mac, test_mac, test_zig);

    // THEN the Mac's own cc runs with the arguments as given, unsplit
    try std.testing.expectEqualDeep(@as([]const []const []const u8, &.{&.{ "cc", "-c", "a.c", "b.c" }}), got);
}

test "commands: zig compiles for Linux, with no sanitizer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // GIVEN an action on a Mac building for linux/amd64
    // WHEN please_zig is called as cc to compile and link one file
    const got = try commands(arena.allocator(), .cc, &.{ "-O2", "-static", "-o", "main", "main.c" }, test_linux_amd64, test_mac, test_zig);

    // THEN zig compiles it for x86_64 musl
    try std.testing.expectEqualDeep(@as([]const []const []const u8, &.{&.{
        test_zig, "cc", "-target", "x86_64-linux-musl", "-fno-sanitize=undefined", "-O2", "-static", "-o", "main", "main.c",
    }}), got);
}

test "commands: zig's c++ compiles C++ for Linux" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // GIVEN an action on a Mac building for linux/arm64
    // WHEN please_zig is called as c++
    const got = try commands(arena.allocator(), .@"c++", &.{ "-c", "a.cc" }, test_linux_arm64, test_mac, test_zig);

    // THEN zig's c++ compiles it for aarch64 musl
    try std.testing.expectEqualDeep(@as([]const []const []const u8, &.{&.{
        test_zig, "c++", "-target", "aarch64-linux-musl", "-fno-sanitize=undefined", "-c", "a.cc",
    }}), got);
}

test "commands: a compile of several sources with no output is split per source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // GIVEN an action building for linux/amd64
    // WHEN please_zig is called as cc to compile two sources with no -o, as
    // cc-rules compiles cgo's C
    const got = try commands(arena.allocator(), .cc, &.{ "-c", "-I", ".", "src/a.c", "b.cgo2.c", "-fPIC" }, test_linux_amd64, test_mac, test_zig);

    // THEN each source is compiled on its own, to the object cc would write
    try std.testing.expectEqualDeep(@as([]const []const []const u8, &.{
        &.{ test_zig, "cc", "-target", "x86_64-linux-musl", "-fno-sanitize=undefined", "-c", "-I", ".", "-fPIC", "src/a.c", "-o", "a.o" },
        &.{ test_zig, "cc", "-target", "x86_64-linux-musl", "-fno-sanitize=undefined", "-c", "-I", ".", "-fPIC", "b.cgo2.c", "-o", "b.cgo2.o" },
    }), got);
}

test "commands: a compile with an output is left whole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // GIVEN an action building for linux/amd64
    // WHEN please_zig is called as cc with -c, -o and two sources
    const got = try commands(arena.allocator(), .cc, &.{ "-c", "a.c", "b.c", "-o", "out.o" }, test_linux_amd64, test_mac, test_zig);

    // THEN it runs as one call, as cc would take it
    try std.testing.expectEqualDeep(@as([]const []const []const u8, &.{&.{
        test_zig, "cc", "-target", "x86_64-linux-musl", "-fno-sanitize=undefined", "-c", "a.c", "b.c", "-o", "out.o",
    }}), got);
}

test "commands: zig's own tools archive and link for Linux" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { tool: Tool, args: []const []const u8, want: []const []const u8 }{
        .{ .tool = .ar, .args = &.{ "s", "lib.a" }, .want = &.{ test_zig, "ar", "s", "lib.a" } },
        .{ .tool = .ranlib, .args = &.{"lib.a"}, .want = &.{ test_zig, "ranlib", "lib.a" } },
        .{ .tool = .ld, .args = &.{ "-r", "a.o", "-o", "b.o" }, .want = &.{ test_zig, "ld.lld", "-r", "a.o", "-o", "b.o" } },
    };
    for (cases) |case| {
        // GIVEN an action building for linux/amd64
        // WHEN please_zig is called as this tool
        const got = try commands(arena.allocator(), case.tool, case.args, test_linux_amd64, test_mac, test_zig);

        // THEN zig's own tool runs, with no compiler flags added
        try std.testing.expectEqualDeep(@as([]const []const []const u8, &.{case.want}), got);
    }
}

test "commands: a platform with no target is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // GIVEN an action building for windows/amd64
    // WHEN please_zig is called as cc
    const got = commands(arena.allocator(), .cc, &.{ "-c", "a.c" }, .{ .os = "windows", .arch = "amd64" }, test_mac, test_zig);

    // THEN it is refused
    try std.testing.expectError(error.NoTargetForPlatform, got);
}

test "targetPlatform: GOOS and GOARCH win over OS and ARCH" {
    // GIVEN an action whose Go build is cross-compiling
    var env = try testEnv(&.{ .{ "GOOS", "linux" }, .{ "GOARCH", "amd64" }, .{ "OS", "darwin" }, .{ "ARCH", "arm64" } });
    defer env.deinit();

    // WHEN its target platform is read
    const got = try targetPlatform(&env);

    // THEN it is Go's
    try std.testing.expectEqualDeep(test_linux_amd64, got);
}

test "targetPlatform: OS and ARCH when Go set nothing" {
    // GIVEN an action with only Please's platform
    var env = try testEnv(&.{ .{ "OS", "linux" }, .{ "ARCH", "arm64" } });
    defer env.deinit();

    // WHEN its target platform is read
    const got = try targetPlatform(&env);

    // THEN it is Please's
    try std.testing.expectEqualDeep(test_linux_arm64, got);
}

test "targetPlatform: neither is refused" {
    // GIVEN an action with no architecture set
    var env = try testEnv(&.{.{ "OS", "linux" }});
    defer env.deinit();

    // WHEN its target platform is read
    // THEN it is unknown
    try std.testing.expectError(error.UnknownTargetPlatform, targetPlatform(&env));
}

test "cacheDir: shared under the repo's plz-out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // GIVEN an action running in a Please build directory
    var env = try testEnv(&.{.{ "TMP_DIR", "/repo/plz-out/tmp/pkg/rule._build" }});
    defer env.deinit();

    // WHEN zig's cache directory is chosen
    const got = try cacheDir(arena.allocator(), &env);

    // THEN it is the repo's shared cache
    try std.testing.expectEqualStrings("/repo/plz-out/zig-cache", got);
}

test "cacheDir: ZIG_CACHE_DIR names another" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // GIVEN ZIG_CACHE_DIR set beside TMP_DIR
    var env = try testEnv(&.{ .{ "ZIG_CACHE_DIR", "/cache" }, .{ "TMP_DIR", "/repo/plz-out/tmp/x" } });
    defer env.deinit();

    // WHEN zig's cache directory is chosen
    const got = try cacheDir(arena.allocator(), &env);

    // THEN it is ZIG_CACHE_DIR
    try std.testing.expectEqualStrings("/cache", got);
}

test "cacheDir: TMP_DIR outside plz-out is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // GIVEN an action whose TMP_DIR is not under plz-out
    var env = try testEnv(&.{.{ "TMP_DIR", "/tmp/x" }});
    defer env.deinit();

    // WHEN zig's cache directory is chosen
    // THEN there is none to choose
    try std.testing.expectError(error.NoCacheDir, cacheDir(arena.allocator(), &env));
}
