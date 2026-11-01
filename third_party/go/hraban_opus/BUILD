subinclude("///go//build_defs:cgo")

# The binding's four Go files, out of its download, as files of this package:
# cgo_library runs cgo over every Go file in its sources' directory and writes
# what it generates beside them, so its sources cannot be a download's.
build_rule(
    name = "srcs",
    srcs = ["//third_party/go:hraban_opus_dl"],
    outs = [
        "decoder.go",
        "encoder.go",
        "errors.go",
        "opus.go",
    ],
    cmd = "cp $SRCS/decoder.go $SRCS/encoder.go $SRCS/errors.go $SRCS/opus.go .",
)

cgo_library(
    name = "hraban_opus",
    srcs = [":srcs"],
    # The cgo step runs in this package's directory and the C compile in the
    # build's root, so the headers are found by absolute path.
    compiler_flags = ['-I"$TMP_DIR/third_party/go/libopus/include"'],
    import_path = "github.com/hraban/opus",
    visibility = ["PUBLIC"],
    deps = ["//third_party/go:libopus"],
)
