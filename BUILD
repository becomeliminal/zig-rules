# zig, pinned per host platform, and a C toolchain over it that targets the
# platform each build action builds for (tools/please_zig). Bump _VERSION and
# refresh _HASHES from https://ziglang.org/download/index.json, checking each
# against a download.
_VERSION = "0.17.0"

_HASHES = {
    "darwin_amd64": "4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6",
    "darwin_arm64": "b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a",
    "linux_amd64": "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026",
    "linux_arm64": "9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8",
}

# zig's own names for the host platform, as its release files are named.
_ZIG_OS = {
    "darwin": "macos",
    "linux": "linux",
}

_ZIG_ARCH = {
    "amd64": "x86_64",
    "arm64": "aarch64",
}

_PLATFORM = f"{CONFIG.HOSTOS}_{CONFIG.HOSTARCH}"

if _PLATFORM not in _HASHES:
    fail(f"the zig plugin has no zig release pinned for {_PLATFORM}; pinned for " + ", ".join(sorted(_HASHES.keys())))

_hash = _HASHES[_PLATFORM]

_zig_arch = _ZIG_ARCH[CONFIG.HOSTARCH]

_zig_os = _ZIG_OS[CONFIG.HOSTOS]

_ZIG_NAME = f"zig-{_zig_arch}-{_zig_os}-{_VERSION}"

remote_file(
    name = "zig_release",
    extract = True,
    hashes = [_hash],
    licences = ["MIT"],
    url = f"https://ziglang.org/download/{_VERSION}/{_ZIG_NAME}.tar.xz",
    visibility = ["PUBLIC"],
)

_TOOLS = [
    "ar",
    "c++",
    "cc",
    "ld",
    "ranlib",
]

_PLEASE_ZIG_MAIN = "tools/please_zig/main.zig"

_PLEASE_ZIG_SRCS = [
    "tools/please_zig/cc.zig",
    "tools/please_zig/module.zig",
    "tools/please_zig/zon.zig",
]

# please_zig (tools/please_zig), the plugin's one program: the C toolchain
# below, and the rules' helper (build_defs/zig.build_defs). It is built by the
# zig it wraps, so it needs no other compiler, which matters because on a Mac
# it is the C compiler Go links with. Stripped, so a build is the same bytes
# whatever directory it is built in.
#
# TODO: consider releasing please_zig as prebuilt binaries pinned by sha256,
# as go-rules releases please_go; built from source it costs a user one zig
# compile.
genrule(
    name = "please_zig",
    srcs = {
        "main": [_PLEASE_ZIG_MAIN],
        "src": _PLEASE_ZIG_SRCS,
        "zig": [":zig_release"],
    },
    outs = ["please_zig"],
    binary = True,
    cmd = "$SRCS_ZIG/zig build-exe -O safe -fstrip --cache-dir $TMP_DIR/zig-local --global-cache-dir $TMP_DIR/zig-global -femit-bin=$OUT $SRCS_MAIN",
    visibility = ["PUBLIC"],
)

filegroup(
    name = "please_zig_srcs",
    srcs = [_PLEASE_ZIG_MAIN] + _PLEASE_ZIG_SRCS,
    visibility = ["PUBLIC"],
)

_ENTRY_POINTS = {tool: f"toolchain/{tool}" for tool in _TOOLS}

_ENTRY_POINTS["zig"] = "toolchain/zig/zig"

# The toolchain: zig, and please_zig installed under each C tool's name. Use
# it as :toolchain|zig, :toolchain|cc, :toolchain|ar and so on.
build_rule(
    name = "toolchain",
    srcs = {
        "please_zig": [":please_zig"],
        "zig": [":zig_release"],
    },
    outs = ["toolchain"],
    binary = True,
    cmd = " && ".join([
        "mkdir -p $OUT",
        "cp -R $SRCS_ZIG $OUT/zig",
    ] + [f"cp $SRCS_PLEASE_ZIG $OUT/{tool} && chmod 0755 $OUT/{tool}" for tool in _TOOLS]),
    entry_points = _ENTRY_POINTS,
    visibility = ["PUBLIC"],
)
