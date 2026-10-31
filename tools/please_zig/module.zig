//! Zig modules as Please builds them. Each zig_library writes a manifest
//! (`please_zig manifest`): its module's name, the name it is imported by, its
//! root source and its direct dependencies. A binary, test or library is then
//! compiled from every manifest in its build directory (`please_zig compile`),
//! which zig_binary and friends gather with needs_transitive_deps: the module
//! graph is walked from the root and handed to zig as --dep and -M flags.
const std = @import("std");
const cc = @import("cc.zig");

/// The file extension that marks a module manifest among a build's inputs.
pub const manifest_suffix = ".zigmod.json";

/// What one zig_library declares about its module.
pub const Manifest = struct {
    /// The module's name, unique in the build: derived from its target label.
    module: []const u8,
    /// The name others @import it by, unless they choose another.
    import_name: []const u8,
    /// Its root source file, relative to the build directory.
    root: []const u8,
    /// The modules it imports.
    deps: []const Dep = &.{},
    /// C sources compiled into it, and the flags they are compiled with.
    csrcs: []const []const u8 = &.{},
    copts: []const []const u8 = &.{},

    pub const Dep = struct {
        module: []const u8,
        import_name: []const u8,
    };
};

/// What a compile produces.
pub const Kind = enum {
    exe,
    @"test",
    lib,
    dylib,

    fn command(kind: Kind) []const []const u8 {
        return switch (kind) {
            .exe => &.{"build-exe"},
            .@"test" => &.{ "test", "--test-no-exec" },
            .lib => &.{"build-lib"},
            .dylib => &.{ "build-lib", "-dynamic" },
        };
    }
};

/// zig's optimisation modes, as 0.17 names them.
pub const Mode = enum { debug, safe, fast, small };

pub const Error = error{
    /// A module imports one that no manifest in the build declares.
    MissingModule,
    /// One module is declared by two different manifests.
    DuplicateModule,
    /// An import name override was given for a dependency with several modules.
    AmbiguousOverride,
    /// A dependency group declares no module.
    NotAModule,
};

pub const CompileOptions = struct {
    zig: []const u8,
    kind: Kind,
    target: []const u8,
    mode: Mode,
    strip: bool = false,
    out: []const u8,
    global_cache: []const u8,
    local_cache: []const u8,
    /// Include directories of C libraries linked in (cc:inc: labels).
    cc_includes: []const []const u8 = &.{},
    /// Archives and linker flags of C libraries linked in (cc:ld: labels).
    cc_links: []const []const u8 = &.{},
    link_libc: bool = false,
    extra: []const []const u8 = &.{},
};

/// The modules of a build, by module name.
pub const Modules = std.StringArrayHashMapUnmanaged(Manifest);

/// Adds a manifest to the modules. The same module twice is fine only if both
/// manifests say the same thing (a dependency reached by two paths).
pub fn addModule(allocator: std.mem.Allocator, modules: *Modules, manifest: Manifest) !void {
    const entry = try modules.getOrPut(allocator, manifest.module);
    if (!entry.found_existing) {
        entry.value_ptr.* = manifest;
        return;
    }
    if (!std.mem.eql(u8, entry.value_ptr.root, manifest.root)) return error.DuplicateModule;
}

/// The command that compiles `root` and everything it imports, root module
/// first, then each other module once, in the order they are reached.
pub fn compileArgs(
    allocator: std.mem.Allocator,
    options: CompileOptions,
    root: Manifest,
    modules: *const Modules,
) (Error || std.mem.Allocator.Error)![]const []const u8 {
    var order: std.ArrayList(Manifest) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    try order.append(allocator, root);
    try seen.put(allocator, root.module, {});
    var next: usize = 0;
    var uses_c = options.link_libc or options.cc_links.len > 0;
    while (next < order.items.len) : (next += 1) {
        const current = order.items[next];
        if (current.csrcs.len > 0) uses_c = true;
        for (current.deps) |dep| {
            if (seen.contains(dep.module)) continue;
            const manifest = modules.get(dep.module) orelse return error.MissingModule;
            try seen.put(allocator, dep.module, {});
            try order.append(allocator, manifest);
        }
    }

    var args: std.ArrayList([]const u8) = .empty;
    try args.append(allocator, options.zig);
    try args.appendSlice(allocator, options.kind.command());
    if (options.kind == .lib or options.kind == .dylib) {
        // A library C, Go or Rust will link: position independent, for their
        // PIE executables, and carrying the compiler-rt symbols Zig code calls,
        // which their linker would not otherwise find.
        try args.appendSlice(allocator, &.{ "-fPIC", "-fcompiler-rt" });
    }
    try args.appendSlice(allocator, &.{
        // Baseline, not the build machine's CPU: the same output wherever it
        // is built, and it runs on any machine of the target.
        "-target",             options.target,
        "-mcpu",               "baseline",
        "-O",                  @tagName(options.mode),
        "--global-cache-dir",  options.global_cache,
        "--cache-dir",         options.local_cache,
        try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{options.out}),
    });
    if (options.strip) try args.append(allocator, "-fstrip");
    if (uses_c) try args.append(allocator, "-lc");
    for (options.cc_links) |link| {
        // A cc:ld: label can hold several words: an archive and its flags.
        var words = std.mem.tokenizeScalar(u8, link, ' ');
        while (words.next()) |word| try args.append(allocator, word);
    }
    try args.appendSlice(allocator, options.extra);

    for (order.items) |manifest| {
        for (manifest.deps) |dep| {
            try args.appendSlice(allocator, &.{ "--dep", try std.fmt.allocPrint(allocator, "{s}={s}", .{ dep.import_name, dep.module }) });
        }
        for (options.cc_includes) |include| {
            try args.append(allocator, try std.fmt.allocPrint(allocator, "-I{s}", .{include}));
        }
        if (manifest.csrcs.len > 0) {
            try args.append(allocator, "-cflags");
            try args.appendSlice(allocator, manifest.copts);
            try args.append(allocator, "--");
            try args.appendSlice(allocator, manifest.csrcs);
        }
        try args.append(allocator, try std.fmt.allocPrint(allocator, "-M{s}={s}", .{ manifest.module, manifest.root }));
    }
    return args.items;
}

/// One dependency of a module as the manifest command is told it: an import
/// name override (empty for none) and the files the dependency target outputs,
/// among which its modules' manifests.
pub const DepGroup = struct {
    import_override: []const u8,
    manifests: []const Manifest,
};

/// The imports a module has, from its dependency targets' manifests. A target
/// that outputs no manifest (a C library) adds none. A target with several
/// modules (a package) adds each under its own name, and cannot take an
/// override.
pub fn resolveDeps(allocator: std.mem.Allocator, groups: []const DepGroup) (Error || std.mem.Allocator.Error)![]const Manifest.Dep {
    var deps: std.ArrayList(Manifest.Dep) = .empty;
    for (groups) |group| {
        if (group.import_override.len > 0 and group.manifests.len != 1) {
            return if (group.manifests.len == 0) error.NotAModule else error.AmbiguousOverride;
        }
        for (group.manifests) |manifest| {
            const name = if (group.import_override.len > 0) group.import_override else manifest.import_name;
            try deps.append(allocator, .{ .module = manifest.module, .import_name = name });
        }
    }
    return deps.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn parseManifest(arena: std.mem.Allocator, bytes: []const u8) !Manifest {
    return std.json.parseFromSliceLeaky(Manifest, arena, bytes, .{ .allocate = .alloc_always });
}

fn readManifest(io: std.Io, arena: std.mem.Allocator, path: []const u8) !Manifest {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    return parseManifest(arena, bytes);
}

/// `please_zig manifest --module M --import I --root R [--csrc F]... [--copt X]...
/// [--dep OVERRIDE FILES... --end]... --out O`: writes a module's manifest. Each
/// --dep group is one dependency target: an override or "-", then the files
/// it outputs, as $(locations) expands them.
pub fn manifestMain(init: std.process.Init, args: []const []const u8) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    var module: ?[]const u8 = null;
    var import_name: ?[]const u8 = null;
    var root: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var csrcs: std.ArrayList([]const u8) = .empty;
    var copts: std.ArrayList([]const u8) = .empty;
    var groups: std.ArrayList(DepGroup) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dep")) {
            if (i + 1 >= args.len) std.process.fatal("--dep needs an override or -", .{});
            const override = if (std.mem.eql(u8, args[i + 1], "-")) "" else args[i + 1];
            i += 2;
            var manifests: std.ArrayList(Manifest) = .empty;
            while (i < args.len and !std.mem.eql(u8, args[i], "--end")) : (i += 1) {
                if (std.mem.endsWith(u8, args[i], manifest_suffix)) try manifests.append(arena, try readManifest(io, arena, args[i]));
            }
            if (i >= args.len) std.process.fatal("--dep group not closed by --end", .{});
            try groups.append(arena, .{ .import_override = override, .manifests = manifests.items });
            continue;
        }
        if (i + 1 >= args.len) std.process.fatal("{s} needs a value", .{arg});
        const value = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, arg, "--module")) {
            module = value;
        } else if (std.mem.eql(u8, arg, "--import")) {
            import_name = value;
        } else if (std.mem.eql(u8, arg, "--root")) {
            root = value;
        } else if (std.mem.eql(u8, arg, "--out")) {
            out = value;
        } else if (std.mem.eql(u8, arg, "--csrc")) {
            try csrcs.append(arena, value);
        } else if (std.mem.eql(u8, arg, "--copt")) {
            try copts.append(arena, value);
        } else {
            std.process.fatal("manifest: unknown flag {s}", .{arg});
        }
    }

    const deps = resolveDeps(arena, groups.items) catch |err| switch (err) {
        error.AmbiguousOverride => std.process.fatal("an import name override is for a dependency with one module; this one has several", .{}),
        error.NotAModule => std.process.fatal("an import name override names a dependency that is not a Zig module", .{}),
        else => return err,
    };
    const manifest: Manifest = .{
        .module = module orelse std.process.fatal("manifest: --module is required", .{}),
        .import_name = import_name orelse std.process.fatal("manifest: --import is required", .{}),
        .root = root orelse std.process.fatal("manifest: --root is required", .{}),
        .deps = deps,
        .csrcs = csrcs.items,
        .copts = copts.items,
    };
    const json = try std.fmt.allocPrint(arena, "{f}\n", .{std.json.fmt(manifest, .{})});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out orelse std.process.fatal("manifest: --out is required", .{}), .data = json });
}

/// `please_zig compile --zig Z --kind K --root MANIFEST --target T --mode M --out O
/// [--strip] [--cc-include D]... [--cc-link L]... [--link-libc]
/// [-- EXTRA...]`: compiles the module graph rooted at MANIFEST from every
/// manifest in the build directory.
pub fn compileMain(init: std.process.Init, args: []const []const u8) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;
    var options: CompileOptions = .{
        .zig = "",
        .kind = .exe,
        .target = "",
        .mode = .debug,
        .out = "",
        .global_cache = "",
        .local_cache = "",
    };
    var root_path: ?[]const u8 = null;
    var cc_includes: std.ArrayList([]const u8) = .empty;
    var cc_links: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            options.extra = args[i + 1 ..];
            break;
        }
        if (std.mem.eql(u8, arg, "--strip")) {
            options.strip = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--link-libc")) {
            options.link_libc = true;
            continue;
        }
        if (i + 1 >= args.len) std.process.fatal("{s} needs a value", .{arg});
        const value = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, arg, "--zig")) {
            options.zig = value;
        } else if (std.mem.eql(u8, arg, "--kind")) {
            options.kind = std.meta.stringToEnum(Kind, value) orelse std.process.fatal("compile: no kind {s}", .{value});
        } else if (std.mem.eql(u8, arg, "--root")) {
            root_path = value;
        } else if (std.mem.eql(u8, arg, "--target")) {
            options.target = value;
        } else if (std.mem.eql(u8, arg, "--mode")) {
            options.mode = std.meta.stringToEnum(Mode, value) orelse std.process.fatal("compile: no mode {s}", .{value});
        } else if (std.mem.eql(u8, arg, "--out")) {
            options.out = value;
        } else if (std.mem.eql(u8, arg, "--cc-include")) {
            try cc_includes.append(arena, value);
        } else if (std.mem.eql(u8, arg, "--cc-link")) {
            try cc_links.append(arena, value);
        } else {
            std.process.fatal("compile: unknown flag {s}", .{arg});
        }
    }
    if (options.zig.len == 0 or options.target.len == 0 or options.out.len == 0) {
        std.process.fatal("compile: --zig, --target and --out are required", .{});
    }
    options.cc_includes = cc_includes.items;
    options.cc_links = cc_links.items;
    options.global_cache = cc.cacheDir(arena, env) catch |err| switch (err) {
        error.NoCacheDir => std.process.fatal("neither TMP_DIR nor ZIG_CACHE_DIR is set, so there is no directory for zig's cache", .{}),
        else => return err,
    };
    options.local_cache = try std.fmt.allocPrint(arena, "{s}/zig-local-cache", .{env.get("TMP_DIR") orelse "."});

    // Every manifest the build gathered, the root's and each dependency's; and,
    // as cc_binary links them, every archive and object: C libraries this
    // links, from cc_library deps.
    var modules: Modules = .empty;
    var archives: std.ArrayList([]const u8) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (std.mem.endsWith(u8, entry.path, ".a") or std.mem.endsWith(u8, entry.path, ".o")) {
            try archives.append(arena, try arena.dupe(u8, entry.path));
            continue;
        }
        if (!std.mem.endsWith(u8, entry.path, manifest_suffix)) continue;
        const manifest = try readManifest(io, arena, try arena.dupe(u8, entry.path));
        addModule(arena, &modules, manifest) catch |err| switch (err) {
            error.DuplicateModule => std.process.fatal("module {s} is declared twice, with different roots", .{manifest.module}),
            else => return err,
        };
    }
    const root = try readManifest(io, arena, root_path orelse std.process.fatal("compile: --root is required", .{}));
    std.mem.sort([]const u8, archives.items, {}, lessThan);
    try cc_links.appendSlice(arena, archives.items);
    options.cc_links = cc_links.items;

    const argv = compileArgs(arena, options, root, &modules) catch |err| switch (err) {
        error.MissingModule => std.process.fatal("a module imports one with no manifest in this build: is its zig_library in deps?", .{}),
        else => return err,
    };
    return std.process.replace(io, .{ .argv = argv, .environ_map = env });
}

const test_options: CompileOptions = .{
    .zig = "zig",
    .kind = .exe,
    .target = "x86_64-linux-musl",
    .mode = .safe,
    .out = "out/bin",
    .global_cache = "/g",
    .local_cache = "/l",
};

fn testModules(allocator: std.mem.Allocator, manifests: []const Manifest) !Modules {
    var modules: Modules = .empty;
    for (manifests) |manifest| try addModule(allocator, &modules, manifest);
    return modules;
}

test "compileArgs: the root module first, then each module it reaches, once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // GIVEN a binary importing two modules, both of which import a third
    const util: Manifest = .{ .module = "pkg_util", .import_name = "util", .root = "pkg/util.zig" };
    const left: Manifest = .{ .module = "pkg_left", .import_name = "left", .root = "pkg/left.zig", .deps = &.{.{ .module = "pkg_util", .import_name = "util" }} };
    const right: Manifest = .{ .module = "pkg_right", .import_name = "right", .root = "pkg/right.zig", .deps = &.{.{ .module = "pkg_util", .import_name = "u" }} };
    const root: Manifest = .{ .module = "pkg_bin", .import_name = "bin", .root = "pkg/main.zig", .deps = &.{
        .{ .module = "pkg_left", .import_name = "left" },
        .{ .module = "pkg_right", .import_name = "right" },
    } };
    var modules = try testModules(a, &.{ util, left, right, root });

    // WHEN its command is assembled
    const got = try compileArgs(a, test_options, root, &modules);

    // THEN each module is declared once, its imports before it, root first
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{
        "zig",          "build-exe",
        "-target",      "x86_64-linux-musl",
        "-mcpu",        "baseline",
        "-O",           "safe",
        "--global-cache-dir", "/g",
        "--cache-dir",  "/l",
        "-femit-bin=out/bin",
        "--dep",        "left=pkg_left",
        "--dep",        "right=pkg_right",
        "-Mpkg_bin=pkg/main.zig",
        "--dep",        "util=pkg_util",
        "-Mpkg_left=pkg/left.zig",
        "--dep",        "u=pkg_util",
        "-Mpkg_right=pkg/right.zig",
        "-Mpkg_util=pkg/util.zig",
    }), got);
}

test "compileArgs: C sources, C libraries and the kind of output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // GIVEN a static library whose root module compiles a C file and links a C library
    const root: Manifest = .{ .module = "pkg_lib", .import_name = "lib", .root = "pkg/lib.zig", .csrcs = &.{"pkg/shim.c"}, .copts = &.{"-O2"} };
    var modules = try testModules(a, &.{root});
    var options = test_options;
    options.kind = .lib;
    options.mode = .debug;
    options.strip = true;
    options.cc_includes = &.{"third_party/opus/include"};
    options.cc_links = &.{"third_party/opus/lib/libopus.a -lm"};

    // WHEN its command is assembled
    const got = try compileArgs(a, options, root, &modules);

    // THEN it builds a library, links libc and the C library, and compiles the C file into the module
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{
        "zig",          "build-lib",
        "-fPIC",        "-fcompiler-rt",
        "-target",      "x86_64-linux-musl",
        "-mcpu",        "baseline",
        "-O",           "debug",
        "--global-cache-dir", "/g",
        "--cache-dir",  "/l",
        "-femit-bin=out/bin",
        "-fstrip",
        "-lc",
        "third_party/opus/lib/libopus.a", "-lm",
        "-Ithird_party/opus/include",
        "-cflags",      "-O2", "--", "pkg/shim.c",
        "-Mpkg_lib=pkg/lib.zig",
    }), got);
}

test "compileArgs: a test builds without running" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // GIVEN a test's root module
    const root: Manifest = .{ .module = "pkg_t", .import_name = "t", .root = "pkg/t.zig" };
    var modules = try testModules(a, &.{root});
    var options = test_options;
    options.kind = .@"test";

    // WHEN its command is assembled
    const got = try compileArgs(a, options, root, &modules);

    // THEN zig test builds the test binary and leaves running it to Please
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "zig", "test", "--test-no-exec" }), got[0..3]);
}

test "compileArgs: an import with no manifest is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // GIVEN a root importing a module no manifest declares
    const root: Manifest = .{ .module = "pkg_bin", .import_name = "bin", .root = "pkg/main.zig", .deps = &.{.{ .module = "pkg_gone", .import_name = "gone" }} };
    var modules = try testModules(a, &.{root});

    // WHEN its command is assembled
    // THEN it is refused
    try std.testing.expectError(error.MissingModule, compileArgs(a, test_options, root, &modules));
}

test "addModule: one module, two different roots, is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var modules: Modules = .empty;

    // GIVEN a module already added
    try addModule(a, &modules, .{ .module = "m", .import_name = "m", .root = "a.zig" });

    // WHEN the same module is added again with the same root, and then another
    try addModule(a, &modules, .{ .module = "m", .import_name = "m", .root = "a.zig" });

    // THEN the same declaration is fine, a different one is refused
    try std.testing.expectError(error.DuplicateModule, addModule(a, &modules, .{ .module = "m", .import_name = "m", .root = "b.zig" }));
}

test "resolveDeps: import names from the dependencies' manifests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // GIVEN a library dependency, one with an override, a C library, and a package with two modules
    const groups = [_]DepGroup{
        .{ .import_override = "", .manifests = &.{.{ .module = "pkg_a", .import_name = "a", .root = "a.zig" }} },
        .{ .import_override = "bee", .manifests = &.{.{ .module = "pkg_b", .import_name = "b", .root = "b.zig" }} },
        .{ .import_override = "", .manifests = &.{} },
        .{ .import_override = "", .manifests = &.{
            .{ .module = "clap_clap", .import_name = "clap", .root = "x/src/clap.zig" },
            .{ .module = "clap_extra", .import_name = "extra", .root = "x/src/extra.zig" },
        } },
    };

    // WHEN the module's imports are resolved
    const got = try resolveDeps(a, &groups);

    // THEN each module is imported under its own name or the override; the C library adds none
    try std.testing.expectEqualDeep(@as([]const Manifest.Dep, &.{
        .{ .module = "pkg_a", .import_name = "a" },
        .{ .module = "pkg_b", .import_name = "bee" },
        .{ .module = "clap_clap", .import_name = "clap" },
        .{ .module = "clap_extra", .import_name = "extra" },
    }), got);
}

test "resolveDeps: an override for a dependency with several modules, or none, is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // GIVEN overrides on a package with two modules and on a C library
    const two = [_]DepGroup{.{ .import_override = "x", .manifests = &.{
        .{ .module = "p_a", .import_name = "a", .root = "a.zig" },
        .{ .module = "p_b", .import_name = "b", .root = "b.zig" },
    } }};
    const none = [_]DepGroup{.{ .import_override = "x", .manifests = &.{} }};

    // WHEN their imports are resolved
    // THEN both are refused
    try std.testing.expectError(error.AmbiguousOverride, resolveDeps(a, &two));
    try std.testing.expectError(error.NotAModule, resolveDeps(a, &none));
}

test "parseManifest: a manifest round-trips through JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // GIVEN a manifest written as please_zig manifest writes it
    const manifest: Manifest = .{ .module = "pkg_m", .import_name = "m", .root = "pkg/m.zig", .deps = &.{.{ .module = "pkg_d", .import_name = "d" }}, .csrcs = &.{"pkg/c.c"}, .copts = &.{"-DX"} };
    const json = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(manifest, .{})});

    // WHEN it is read back
    const got = try parseManifest(a, json);

    // THEN it is the same manifest
    try std.testing.expectEqualDeep(manifest, got);
}
