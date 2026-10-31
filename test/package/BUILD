subinclude("//build_defs:zig")

# A package, as a release archive of it would be: the greet directory. Its
# Zig hash covers the files build.zig.zon's paths name, not the archive's
# bytes, so this genrule's tar can differ between hosts and still match.
genrule(
    name = "greet_archive",
    srcs = [
        "greet/build.zig.zon",
        "greet/src/root.zig",
    ],
    outs = ["greet.tar.gz"],
    cmd = "tar -czf $OUT -C $PKG_DIR greet",
    test_only = True,
)

_GREET_HASH = "greet-0.1.0-NUtAWQABAAD4d78ctyGtAvcaei0PTnYlQOz5R1bcHd3x"

# The package, pinned by that hash: zig fetch must compute it from the
# archive, or the build fails.
zig_package(
    name = "greet",
    src = ":greet_archive",
    hash = _GREET_HASH,
    modules = {"greet": "src/root.zig"},
    test_only = True,
    visibility = None,
)

zig_binary(
    name = "greeter",
    main = "greeter.zig",
    test_only = True,
    deps = [":greet"],
)

gentest(
    name = "package_test",
    data = {"bin": [":greeter"]},
    no_test_output = True,
    test_cmd = "test \"$($DATA_BIN 2>&1)\" = 'hello from a package'",
)

# please_zig zon writes the zig_package rule above from a build.zig.zon that
# depends on the package. zig fetch takes a local path as well as a URL, so
# the dependency's url is the archive's path and this needs no network.
gentest(
    name = "zon_test",
    data = {
        "archive": [":greet_archive"],
        "pz": ["//:please_zig"],
        "toolchain": ["//:toolchain"],
    },
    no_test_output = True,
    test_cmd = " && ".join([
        "printf '.{ .name = .app, .version = \"0.1.0\", .dependencies = .{ .greet = .{ .url = \"%s\", .hash = \"%s\" } } }' \"$PWD/$DATA_ARCHIVE\" " + _GREET_HASH + " > build.zig.zon",
        "$PWD/$DATA_PZ zon --zig $PWD/$DATA_TOOLCHAIN/zig/zig --cache $TMP_DIR/zig-zon build.zig.zon > generated",
        "grep -q '^zig_package($' generated",
        "grep -q '    name = \"greet\",' generated",
        "grep -q '    hash = \"" + _GREET_HASH + "\",' generated",
        "grep -q '        \"greet\": \"src/root.zig\",' generated",
    ]),
)
