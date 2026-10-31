subinclude("///go//build_defs:go")

package(default_visibility = ["PUBLIC"])

# On a Mac, also the standard library for linux/amd64, which test/cgo builds
# with cgo through this plugin's toolchain (.plzconfig_darwin_*).
go_toolchain(
    name = "toolchain",
    architectures = ["linux_amd64"] if CONFIG.HOSTOS == "darwin" else [],
    version = "1.27.1",
)

# go-ethereum's secp256k1: libsecp256k1's C, compiled through cgo. A
# go_module, as go_repo cannot compile it: its C includes headers by paths
# relative to the module.
go_module(
    name = "go-ethereum",
    # The linker sees only installed packages: secp256k1 and what it imports.
    install = [
        "common/math",
        "crypto/secp256k1",
    ],
    licences = ["LGPL-3.0"],
    module = "github.com/ethereum/go-ethereum",
    version = "v1.17.7",
)

# libopus, the reference Opus codec, built from its release with configure and
# make, as a C library a Go binary links through cgo (hraban_opus). Built for
# another platform (a Mac building ///linux_amd64), configure is told the
# target and given Go's C tools for it, this plugin's; built for the host, it
# is the plain build.
LIBOPUS_VERSION = "1.6.1"

_LIBOPUS_DIR = package_name() + "/libopus"

remote_file(
    name = "libopus_src",
    hashes = ["6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"],
    licences = ["BSD-3-Clause"],
    url = f"https://downloads.xiph.org/releases/opus/opus-{LIBOPUS_VERSION}.tar.gz",
)

_LIBOPUS_CROSS = CONFIG.OS != CONFIG.HOSTOS or CONFIG.ARCH != CONFIG.HOSTARCH

_LIBOPUS_TRIPLE_ARCH = {
    "amd64": "x86_64",
    "arm64": "aarch64",
}

if _LIBOPUS_CROSS and (CONFIG.OS != "linux" or CONFIG.ARCH not in _LIBOPUS_TRIPLE_ARCH):
    fail(f"libopus: no cross build for {CONFIG.OS}/{CONFIG.ARCH}")

_libopus_arch = _LIBOPUS_TRIPLE_ARCH.get(
    CONFIG.ARCH,
    "",
)

_LIBOPUS_CONFIGURE_CROSS = f' --host={_libopus_arch}-linux-musl CC="$TOOLS_CC" AR="$TOOLS_AR" RANLIB="$TOOLS_AR s"' if _LIBOPUS_CROSS else ""

# The headers are under libopus/include, the archive libopus/lib/libopus.a. Its
# label links the archive, and then libm, into every Go binary that depends on
# it, in that order.
build_rule(
    name = "libopus",
    srcs = [":libopus_src"],
    outs = ["libopus"],
    building_description = "Building libopus...",
    cmd = " && ".join([
        "tar -xzf $SRC",
        f"cd opus-{LIBOPUS_VERSION}",
        "./configure --quiet --disable-shared --enable-static --with-pic --disable-doc --disable-extra-programs CFLAGS=-O2" + _LIBOPUS_CONFIGURE_CROSS,
        "make -j$(getconf _NPROCESSORS_ONLN) libopus.la",
        "cd ..",
        "mkdir -p libopus/include libopus/lib",
        f"cp opus-{LIBOPUS_VERSION}/include/*.h libopus/include/",
        f"cp opus-{LIBOPUS_VERSION}/.libs/libopus.a libopus/lib/",
    ]),
    labels = [f"cc:ld:{_LIBOPUS_DIR}/lib/libopus.a -lm"],
    tools = {
        "ar": [CONFIG.GO.AR_TOOL],
        "cc": [CONFIG.GO.CC_TOOL],
    } if _LIBOPUS_CROSS else {},
)

# hraban/opus, the cgo binding to libopus, compiled against the libopus above
# (hraban_opus/BUILD). Left out: the Ogg file decoding, which needs
# libopusfile, and the tests.
go_mod_download(
    name = "hraban_opus_dl",
    licences = ["MIT"],
    module = "github.com/hraban/opus",
    strip = [
        ".gitignore",
        "Dockerfile.alpine",
        "Dockerfile.debian",
        "callbacks.c",
        "decoder_test.go",
        "default.nix",
        "encoder_test.go",
        "flake.lock",
        "flake.nix",
        "opus_test.go",
        "package.nix",
        "stream.go",
        "stream_errors.go",
        "stream_test.go",
        "streams_map.go",
        "utils_test.go",
    ],
    version = "v0.0.0-20260708213942-bde8e4304501",
)
