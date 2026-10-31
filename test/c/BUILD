subinclude("///cc//build_defs:c", "//build_defs:zig")

# C into Zig: a C library (c_library: cc_library is C++), its header
# translated into a module, and a module
# with a C source of its own.
c_library(
    name = "mathc",
    srcs = ["mathc.c"],
    hdrs = ["mathc.h"],
    test_only = True,
)

zig_c_library(
    name = "mathc_zig",
    hdrs = ["mathc.h"],
    import_name = "mathc",
    test_only = True,
    deps = [":mathc"],
)

zig_library(
    name = "calc",
    csrcs = ["add.c"],
    main = "calc.zig",
    test_only = True,
    deps = [":mathc_zig"],
)

zig_binary(
    name = "calc_bin",
    main = "main.zig",
    test_only = True,
    deps = [":calc"],
)

# (2 + 3) * 10, from add.c, mathc.c and the translated MATHC_SCALE.
gentest(
    name = "calc_test",
    data = {"bin": [":calc_bin"]},
    no_test_output = True,
    test_cmd = "test \"$($DATA_BIN 2>&1)\" = 50",
)

# Zig into C: a static library and its header, linked by a c_binary, and a
# shared library exporting the same symbol.
zig_static_library(
    name = "square",
    hdrs = ["square.h"],
    main = "square.zig",
    test_only = True,
)

c_binary(
    name = "use_square",
    srcs = ["use_square.c"],
    test_only = True,
    deps = [":square"],
)

gentest(
    name = "static_library_test",
    data = {"bin": [":use_square"]},
    no_test_output = True,
    test_cmd = "test \"$($DATA_BIN)\" = 49",
)

zig_shared_library(
    name = "square_shared",
    hdrs = ["square.h"],
    main = "square.zig",
    test_only = True,
)

# A C program loads the shared library at run time and calls its export.
c_binary(
    name = "load_square",
    srcs = ["load_square.c"],
    test_only = True,
)

gentest(
    name = "shared_library_test",
    data = {
        "lib": [":square_shared"],
        "loader": [":load_square"],
    },
    no_test_output = True,
    test_cmd = "test \"$($DATA_LOADER $PWD/$(echo $DATA_LIB | tr ' ' '\\n' | grep -E '[.](so|dylib)$'))\" = 64",
)
