subinclude("//build_defs:zig")

# A module graph: the binary imports left and right, which both import util,
# right under a name of its own choosing.
zig_library(
    name = "util",
    main = "util.zig",
    test_only = True,
)

zig_library(
    name = "left",
    main = "left.zig",
    test_only = True,
    deps = [":util"],
)

zig_library(
    name = "right",
    import_names = {":util": "u"},
    main = "right.zig",
    test_only = True,
    deps = [":util"],
)

zig_binary(
    name = "hello",
    extra_srcs = ["motd.txt"],
    main = "main.zig",
    test_only = True,
    deps = [
        ":left",
        ":right",
    ],
)

# The binary runs, with each module and the embedded file where it should be.
gentest(
    name = "hello_test",
    data = {"hello": [":hello"]},
    no_test_output = True,
    test_cmd = "test \"$($DATA_HELLO 2>&1)\" = 'left! right! from the embed'",
)

# zig_test runs a module's test blocks, its imports resolved as a binary's are.
zig_test(
    name = "left_test",
    main = "left.zig",
    deps = [":util"],
)

# The same binary for each Linux architecture, from any host: zig cross-
# compiles, so ///linux_arm64 needs nothing but the subrepo. Each is a static
# ELF executable for its machine (e_machine 0xb7 aarch64, 0x3e x86-64). One
# test each: both land at the same path in a test's directory.
gentest(
    name = "cross_arm64_test",
    data = {"hello": ["///linux_arm64//test/lang:hello"]},
    no_test_output = True,
    test_cmd = " && ".join([
        "test \"$(head -c 4 $DATA_HELLO | od -An -c | tr -d ' ')\" = '177ELF'",
        "test \"$(od -An -tx1 -j18 -N2 $DATA_HELLO | tr -d ' ')\" = b700",
    ]),
)

gentest(
    name = "cross_amd64_test",
    data = {"hello": ["///linux_amd64//test/lang:hello"]},
    no_test_output = True,
    test_cmd = " && ".join([
        "test \"$(head -c 4 $DATA_HELLO | od -An -c | tr -d ' ')\" = '177ELF'",
        "test \"$(od -An -tx1 -j18 -N2 $DATA_HELLO | tr -d ' ')\" = 3e00",
    ]),
)

# Built in opt, the binary is stripped: no path of the directory it was built
# in, so it is the same bytes wherever it is built.
gentest(
    name = "reproducible_test",
    data = {"hello": [":hello"]},
    no_test_output = True,
    test_cmd = "! grep -a -q -e 'plz-out' -e '_build/' $DATA_HELLO",
)
