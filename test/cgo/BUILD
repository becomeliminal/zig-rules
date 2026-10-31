subinclude("///go//build_defs:go")

# A Go binary with two cgo libraries: go-ethereum's secp256k1 and libopus
# through hraban/opus. With cgo on, statically linked, and on a Mac Go's C
# tools this plugin's toolchain (.plzconfig_darwin_*), as a repo whose images
# hold such binaries builds them.
go_binary(
    name = "cgo_app",
    srcs = ["main.go"],
    test_only = True,
    deps = [
        "//third_party/go:go-ethereum",
        "//third_party/go/hraban_opus",
    ],
)

_RUNS = "test \"$($DATA_APP)\" = \"$(printf 'secp256k1: signed and verified\\nopus: 960 samples round-tripped')\""

# Built for the host, it runs.
gentest(
    name = "cgo_test",
    data = {"app": [":cgo_app"]},
    no_test_output = True,
    test_cmd = _RUNS,
)

# Built for linux/amd64, from any host: a Mac's cgo goes through zig. A static
# x86-64 ELF executable (e_machine 0x3e) with no interpreter to load it. On a
# linux/amd64 host it is the host's build, so it is also run.
gentest(
    name = "cgo_linux_amd64_test",
    data = {"app": ["///linux_amd64//test/cgo:cgo_app"]},
    no_test_output = True,
    test_cmd = " && ".join([
        "test \"$(head -c 4 $DATA_APP | od -An -c | tr -d ' ')\" = '177ELF'",
        "test \"$(od -An -tx1 -j18 -N2 $DATA_APP | tr -d ' ')\" = 3e00",
        "! grep -a -q -e '/lib64/ld-linux' -e '/lib/ld-musl' $DATA_APP",
        "if [ \"$(uname -s)/$(uname -m)\" = Linux/x86_64 ]; then " + _RUNS + "; fi",
    ]),
)
