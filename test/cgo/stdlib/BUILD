subinclude("///go//build_defs:go")

# A Go binary whose only cgo is the standard library's (net, os/user), as most
# Go services are. With no cgo library of its own, Go links it with its own
# linker unless it is static, and that linker cannot link a Linux cgo binary
# on a Mac: this is the binary a Mac config that turned DefaultStatic off broke
# in ///linux_amd64, where test/cgo's cgo_app, linked externally by Go anyway,
# still passed.
go_binary(
    name = "stdlib_app",
    srcs = ["main.go"],
    test_only = True,
)

_RUNS = "test \"$($DATA_APP)\" = 'net and os/user: ok'"

# Built for the host, it runs.
gentest(
    name = "stdlib_test",
    data = {"app": [":stdlib_app"]},
    no_test_output = True,
    test_cmd = _RUNS,
)

# Built for linux/amd64, from any host: a static x86-64 ELF executable
# (e_machine 0x3e) with no interpreter to load it. On a linux/amd64 host it is
# the host's build, so it is also run.
gentest(
    name = "stdlib_linux_amd64_test",
    data = {"app": ["///linux_amd64//test/cgo/stdlib:stdlib_app"]},
    no_test_output = True,
    test_cmd = " && ".join([
        "test \"$(head -c 4 $DATA_APP | od -An -c | tr -d ' ')\" = '177ELF'",
        "test \"$(od -An -tx1 -j18 -N2 $DATA_APP | tr -d ' ')\" = 3e00",
        "! grep -a -q -e '/lib64/ld-linux' -e '/lib/ld-musl' $DATA_APP",
        "if [ \"$(uname -s)/$(uname -m)\" = Linux/x86_64 ]; then " + _RUNS + "; fi",
    ]),
)
