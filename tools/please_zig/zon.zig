//! `please_zig zon`: zig_package rules from a build.zig.zon, the way puku
//! writes go_repo rules from a go.mod. Each dependency is fetched with
//! `zig fetch`, which computes Zig's own package hash; it must be the hash
//! build.zig.zon declares. Its build.zig.zon is then read in turn, so the
//! rules cover the whole package graph.
const std = @import("std");

/// One entry in a build.zig.zon's .dependencies.
pub const Dependency = struct {
    name: []const u8,
    url: []const u8,
    hash: []const u8,
};

/// A package's own declarations: its name and what it depends on.
pub const Declared = struct {
    name: []const u8,
    dependencies: []const Dependency,
};

pub const Error = error{
    /// The file is not a ZON struct, or a field has the wrong shape.
    InvalidZon,
    /// A dependency is a local path. Locally, a zig_library is the rule for it.
    PathDependency,
    /// zig fetch computed a different hash from the one declared.
    HashMismatch,
};

/// Reads the name and dependencies a build.zig.zon declares.
pub fn parse(gpa: std.mem.Allocator, arena: std.mem.Allocator, source: [:0]const u8) (Error || std.mem.Allocator.Error)!Declared {
    var tree = try std.zig.Ast.parse(gpa, source, .{ .mode = .zon });
    defer tree.deinit(gpa);
    const zoir = try std.zig.ZonGen.generate(gpa, tree, .{});
    defer zoir.deinit(gpa);
    if (zoir.hasCompileErrors()) return error.InvalidZon;

    const top = switch (std.zig.Zoir.Node.Index.root.get(&zoir)) {
        .struct_literal => |s| s,
        else => return error.InvalidZon,
    };
    var name: []const u8 = "";
    var dependencies: std.ArrayList(Dependency) = .empty;
    for (top.names, 0..) |field_name, i| {
        const field = field_name.get(&zoir);
        const value = top.vals.at(@intCast(i)).get(&zoir);
        if (std.mem.eql(u8, field, "name")) {
            // A bare identifier since 0.14 (.name = .clap); a string before.
            name = try arena.dupe(u8, switch (value) {
                .enum_literal => |literal| literal.get(&zoir),
                .string_literal => |string| string,
                else => return error.InvalidZon,
            });
        } else if (std.mem.eql(u8, field, "dependencies")) {
            const deps = switch (value) {
                .struct_literal => |s| s,
                .empty_literal => continue,
                else => return error.InvalidZon,
            };
            for (deps.names, 0..) |dep_name, j| {
                const entry = switch (deps.vals.at(@intCast(j)).get(&zoir)) {
                    .struct_literal => |s| s,
                    else => return error.InvalidZon,
                };
                var url: ?[]const u8 = null;
                var hash: ?[]const u8 = null;
                for (entry.names, 0..) |key, k| {
                    const key_name = key.get(&zoir);
                    const string = switch (entry.vals.at(@intCast(k)).get(&zoir)) {
                        .string_literal => |s| s,
                        else => continue,
                    };
                    if (std.mem.eql(u8, key_name, "url")) url = try arena.dupe(u8, string);
                    if (std.mem.eql(u8, key_name, "hash")) hash = try arena.dupe(u8, string);
                    if (std.mem.eql(u8, key_name, "path")) return error.PathDependency;
                }
                try dependencies.append(arena, .{
                    .name = try arena.dupe(u8, dep_name.get(&zoir)),
                    .url = url orelse return error.InvalidZon,
                    .hash = hash orelse return error.InvalidZon,
                });
            }
        }
    }
    return .{ .name = name, .dependencies = dependencies.items };
}

/// A zig_package rule to write.
pub const Package = struct {
    target: []const u8,
    url: []const u8,
    hash: []const u8,
    /// Import name to root source, relative to the package.
    modules: []const [2][]const u8,
    /// Targets of the packages this one depends on.
    deps: []const []const u8,
};

/// The zig_package rule for a package, as BUILD text.
pub fn render(allocator: std.mem.Allocator, package: Package) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(allocator, "zig_package(\n    name = \"{s}\",\n", .{package.target});
    if (package.deps.len > 0) {
        try out.appendSlice(allocator, "    deps = [\n");
        for (package.deps) |dep| try out.print(allocator, "        \":{s}\",\n", .{dep});
        try out.appendSlice(allocator, "    ],\n");
    }
    try out.print(allocator, "    hash = \"{s}\",\n", .{package.hash});
    if (package.modules.len == 0) {
        try out.appendSlice(allocator, "    # No src/root.zig or root.zig: name its modules' root files here.\n    modules = {},\n");
    } else {
        try out.appendSlice(allocator, "    modules = {\n");
        for (package.modules) |module| try out.print(allocator, "        \"{s}\": \"{s}\",\n", .{ module[0], module[1] });
        try out.appendSlice(allocator, "    },\n");
    }
    try out.print(allocator, "    url = \"{s}\",\n)\n", .{package.url});
    return out.items;
}

/// The root file a package's module is most likely rooted at: zig init's
/// layout first. A package's build.zig names its modules, and that is Zig
/// code, so this is a default the generated rule shows for review.
const conventional_roots = [_][]const u8{ "src/root.zig", "root.zig", "src/main.zig" };

/// Where a fetched package's files are: zig keeps what it hashed under p/, a
/// directory or (since 0.17) an archive of one, which is unpacked beside it.
/// The root is the shallowest directory with a build.zig.zon.
fn packageRoot(io: std.Io, arena: std.mem.Allocator, cache: []const u8, hash: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const stored = try std.fmt.allocPrint(arena, "{s}/p/{s}", .{ cache, hash });
    var top = stored;
    const archive = try std.fmt.allocPrint(arena, "{s}.tar.gz", .{stored});
    if (cwd.access(io, archive, .{})) |_| {
        top = try std.fmt.allocPrint(arena, "{s}.unpacked", .{stored});
        try cwd.createDirPath(io, top);
        const unpacked = try std.process.run(arena, io, .{ .argv = &.{ "tar", "-xzf", archive, "-C", top } });
        if (unpacked.term != .exited or unpacked.term.exited != 0) std.process.fatal("unpacking {s}: {s}", .{ archive, unpacked.stderr });
    } else |_| {}

    // Breadth first, so the package's own build.zig.zon wins over any deeper.
    var level: std.ArrayList([]const u8) = .empty;
    try level.append(arena, top);
    var depth: usize = 0;
    while (depth < 3 and level.items.len > 0) : (depth += 1) {
        var next: std.ArrayList([]const u8) = .empty;
        for (level.items) |dir_path| {
            const zon = try std.fmt.allocPrint(arena, "{s}/build.zig.zon", .{dir_path});
            if (cwd.access(io, zon, .{})) |_| return dir_path else |_| {}
            var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var it = dir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind == .directory) try next.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name }));
            }
        }
        level = next;
    }
    return top;
}

/// `please_zig zon --zig ZIG [--cache DIR] build.zig.zon`: prints zig_package
/// rules for the dependencies it declares, and theirs, to stdout.
pub fn zonMain(init: std.process.Init, args: []const []const u8) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;
    var zig: ?[]const u8 = null;
    var cache: []const u8 = "zig-fetch-cache";
    var zon_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--zig") and i + 1 < args.len) {
            zig = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--cache") and i + 1 < args.len) {
            cache = args[i + 1];
            i += 1;
        } else {
            zon_path = args[i];
        }
    }
    const zig_exe = zig orelse std.process.fatal("zon: --zig is required", .{});
    const cwd = std.Io.Dir.cwd();

    var pending: std.ArrayList(Dependency) = .empty;
    const top_source = try cwd.readFileAllocOptions(io, zon_path orelse std.process.fatal("zon: give a build.zig.zon", .{}), arena, .unlimited, .of(u8), 0);
    const top = parse(gpa, arena, top_source) catch |err| switch (err) {
        error.PathDependency => std.process.fatal("a dependency is a local path; build it with zig_library", .{}),
        error.InvalidZon => std.process.fatal("not a build.zig.zon this understands", .{}),
        else => return err,
    };
    try pending.appendSlice(arena, top.dependencies);

    // Packages by hash, so a package two others depend on is one rule.
    var packages: std.StringArrayHashMapUnmanaged(Package) = .empty;
    var targets: std.StringHashMapUnmanaged(void) = .empty;
    while (pending.pop()) |dep| {
        if (packages.contains(dep.hash)) continue;
        var fetch_env = try init.environ_map.clone(arena);
        try fetch_env.put("ZIG_GLOBAL_CACHE_DIR", cache);
        try fetch_env.put("ZIG_LOCAL_CACHE_DIR", cache);
        const fetched = try std.process.run(arena, io, .{ .argv = &.{ zig_exe, "fetch", dep.url }, .environ_map = &fetch_env });
        const got = std.mem.trim(u8, fetched.stdout, " \n");
        if (!std.mem.eql(u8, got, dep.hash)) {
            std.process.fatal("{s}: zig fetch computed {s}, build.zig.zon declares {s}\n{s}", .{ dep.url, got, dep.hash, fetched.stderr });
        }
        const dir = try packageRoot(io, arena, cache, dep.hash);

        var own_deps: []const Dependency = &.{};
        const package_zon = try std.fmt.allocPrint(arena, "{s}/build.zig.zon", .{dir});
        if (cwd.readFileAllocOptions(io, package_zon, arena, .unlimited, .of(u8), 0)) |source| {
            const declared = parse(gpa, arena, source) catch |err| switch (err) {
                error.PathDependency => std.process.fatal("{s} has a local path dependency, which a fetched package cannot", .{dep.url}),
                error.InvalidZon => std.process.fatal("{s}: its build.zig.zon is not one this understands", .{dep.url}),
                else => return err,
            };
            own_deps = declared.dependencies;
            try pending.appendSlice(arena, declared.dependencies);
        } else |_| {}

        var modules: std.ArrayList([2][]const u8) = .empty;
        for (conventional_roots) |root| {
            const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, root });
            cwd.access(io, path, .{}) catch continue;
            try modules.append(arena, .{ dep.name, root });
            break;
        }

        // One target per name; a second version of a name gets its hash.
        var target = dep.name;
        if (targets.contains(target)) target = try std.fmt.allocPrint(arena, "{s}_{s}", .{ dep.name, dep.hash[dep.hash.len - 8 ..] });
        try targets.put(arena, target, {});

        var dep_targets: std.ArrayList([]const u8) = .empty;
        for (own_deps) |own| try dep_targets.append(arena, own.name);
        try packages.put(arena, dep.hash, .{
            .target = target,
            .url = dep.url,
            .hash = dep.hash,
            .modules = modules.items,
            .deps = dep_targets.items,
        });
    }

    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, "# Generated by please_zig zon from build.zig.zon. Each package is pinned by\n# its Zig hash, which zig_package checks with zig fetch.\nsubinclude(\"///zig//build_defs:zig\")\n");
    for (packages.values()) |package| {
        try text.appendSlice(arena, "\n");
        try text.appendSlice(arena, try render(arena, package));
    }
    var buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    try stdout.interface.writeAll(text.items);
    try stdout.interface.flush();
}

test "parse: a build.zig.zon's name and URL dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // GIVEN a build.zig.zon as zig init writes it, with two dependencies
    const source =
        \\.{
        \\    .name = .app,
        \\    .version = "0.1.0",
        \\    .fingerprint = 0x1234,
        \\    .dependencies = .{
        \\        .clap = .{
        \\            .url = "https://example.com/clap.tar.gz",
        \\            .hash = "clap-0.10.0-AAAA",
        \\        },
        \\        .ziglyph = .{
        \\            .url = "https://example.com/ziglyph.tar.gz",
        \\            .hash = "ziglyph-0.1.0-BBBB",
        \\            .lazy = true,
        \\        },
        \\    },
        \\    .paths = .{ "build.zig", "src" },
        \\}
    ;

    // WHEN it is parsed
    const got = try parse(std.testing.allocator, arena.allocator(), source);

    // THEN its name and both dependencies are read, lazy or not
    try std.testing.expectEqualDeep(Declared{ .name = "app", .dependencies = &.{
        .{ .name = "clap", .url = "https://example.com/clap.tar.gz", .hash = "clap-0.10.0-AAAA" },
        .{ .name = "ziglyph", .url = "https://example.com/ziglyph.tar.gz", .hash = "ziglyph-0.1.0-BBBB" },
    } }, got);
}

test "parse: no dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // GIVEN a build.zig.zon with an empty .dependencies and a string name
    const source = ".{ .name = \"lib\", .version = \"1.0.0\", .dependencies = .{} }";

    // WHEN it is parsed
    const got = try parse(std.testing.allocator, arena.allocator(), source);

    // THEN there are none
    try std.testing.expectEqualDeep(Declared{ .name = "lib", .dependencies = &.{} }, got);
}

test "parse: a local path dependency is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // GIVEN a dependency on a local directory
    const source = ".{ .name = .app, .dependencies = .{ .local = .{ .path = \"../local\" } } }";

    // WHEN it is parsed
    // THEN it is refused
    try std.testing.expectError(error.PathDependency, parse(std.testing.allocator, arena.allocator(), source));
}

test "parse: not ZON is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // GIVEN something that is not a struct literal
    // WHEN it is parsed
    // THEN it is refused
    try std.testing.expectError(error.InvalidZon, parse(std.testing.allocator, arena.allocator(), "\"just a string\""));
}

test "render: a package's rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // GIVEN a package with one module and one dependency
    const package: Package = .{
        .target = "clap",
        .url = "https://example.com/clap.tar.gz",
        .hash = "clap-0.10.0-AAAA",
        .modules = &.{.{ "clap", "src/root.zig" }},
        .deps = &.{"ziglyph"},
    };

    // WHEN its rule is written
    const got = try render(arena.allocator(), package);

    // THEN it is the zig_package rule, attributes in BUILD order
    try std.testing.expectEqualStrings(
        \\zig_package(
        \\    name = "clap",
        \\    deps = [
        \\        ":ziglyph",
        \\    ],
        \\    hash = "clap-0.10.0-AAAA",
        \\    modules = {
        \\        "clap": "src/root.zig",
        \\    },
        \\    url = "https://example.com/clap.tar.gz",
        \\)
        \\
    , got);
}
