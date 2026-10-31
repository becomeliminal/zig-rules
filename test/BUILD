# The toolchain builds for a platform other than the action's host with zig,
# and refuses one it has no target for. Linux arm64 is foreign to both CI
# (linux/amd64) and an Intel or Apple Silicon Mac, so this exercises zig on
# every host this runs on.
gentest(
    name = "toolchain_test",
    data = {"toolchain": ["//:toolchain"]},
    no_test_output = True,
    test_cmd = " && ".join([
        "export ZIG_CACHE_DIR=$TMP_DIR/zig-cache",
        "printf 'int main(void) { return 0; }\\n' > main.c",
        # A static executable for aarch64: ELF magic, then e_machine 0xb7.
        "OS=linux ARCH=arm64 $DATA_TOOLCHAIN/cc -O2 -static -o main main.c",
        "test \"$(head -c 4 main | od -An -c | tr -d ' ')\" = '177ELF'",
        "test \"$(od -An -tx1 -j18 -N2 main | tr -d ' ')\" = b700",
        # Two sources, -c and no -o: one object each, as cc writes them.
        "cp main.c other.c && OS=linux ARCH=arm64 $DATA_TOOLCHAIN/cc -c main.c other.c && test -s main.o && test -s other.o",
        # A platform with no target fails, naming it.
        "! OS=windows ARCH=amd64 $DATA_TOOLCHAIN/cc -c main.c 2> refused",
        "grep -q 'no target for windows/amd64' refused",
    ]),
)

# please_zig's unit tests: the commands it plans for each tool, platform and
# set of arguments, the target platform it reads, and zig's cache directory.
gentest(
    name = "please_zig_test",
    data = {
        "src": ["//:please_zig_srcs"],
        "zig": ["//:zig_release"],
    },
    no_test_output = True,
    test_cmd = "$DATA_ZIG/zig test --cache-dir $TMP_DIR/zig-local --global-cache-dir $TMP_DIR/zig-global $(echo $DATA_SRC | tr ' ' '\\n' | grep '/main.zig$')",
)
