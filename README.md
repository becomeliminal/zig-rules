# zig rules for Please

Zig for [Please](https://please.build): modules, executables, tests, libraries
for C to link, C headers as modules, and packages pinned by their Zig hash.
Also a C toolchain over zig that cross-compiles, which other languages' rules
can use as their C compiler and linker.

Zig is pinned by sha256 for macOS and Linux on amd64 and arm64 (`BUILD`). One
Zig version per release of these rules: 0.17.0.

## Installing

```python
# plugins/BUILD
plugin_repo(
    name = "zig",
    owner = "becomeliminal",
    plugin = "zig-rules",
    revision = "v0.1.0",
)
```

```ini
# .plzconfig
[Plugin "zig"]
Target = //plugins:zig
```

```python
# any BUILD file
subinclude("///zig//build_defs:zig")
```

| Setting | Default | |
| --- | --- | --- |
| `ZigTool` | `//:toolchain\|zig` | The zig the rules compile with: the pinned one. |
| `PleaseZigTool` | `//:please_zig` | The rules' helper, built from source by the pinned zig. |
| `DefaultLibc` | `musl` | The libc a Linux target links: `musl`, fully static, or `gnu`, glibc, dynamic (zig cannot link glibc statically). |

## Rules

```python
zig_library(
    name = "util",
    main = "util.zig",
)

zig_binary(
    name = "tool",
    main = "main.zig",
    deps = [":util"],  # @import("util")
)

zig_test(
    name = "util_test",
    main = "util.zig",
)
```

- **`zig_library`**: a module, for others to `@import`. Zig compiles a
  program's modules together, so a library is not compiled on its own: what
  depends on it compiles it. It takes `main`, `srcs`, `deps`, `import_name`
  (default: its name), `import_names` (a dependency's label to the name this
  module imports it by), `extra_srcs` (files it `@embedFile`s), `csrcs` and
  `copts`.
- **`zig_binary`**: an executable. Its own module takes the same attributes,
  plus `mode` (`debug`, `safe`, `fast` or `small`), `strip`, `link_libc`,
  `zigopts` and `data`.
- **`zig_test`**: every `test` block reachable from `main`, built with
  `zig test --test-no-exec` and run by Please, which owns its timeout and
  result.
- **`zig_static_library`**, **`zig_shared_library`**: a module's `export`
  functions, for C, Go (cgo) or Rust to link: depending on one adds it to
  their link and its `hdrs` to their include path, through `cc:ld:` and
  `cc:inc:` labels, as a cc_library would. Give `hdrs`: zig 0.17 does not
  write a C header (`-femit-h` does nothing).
- **`zig_c_library`**: a C library's `hdrs` translated with `zig translate-c`,
  as a module others `@import`; what `@cImport` does, shared.
- **`zig_package`**: a package, as `build.zig.zon` declares one, from a `url`
  or a `src` archive. It is pinned by its Zig `hash`: `zig fetch` on the
  archive must compute it, or the build fails. A package's `build.zig`
  declares its modules, which is Zig code these rules cannot read, so
  `modules` names each one's root file.

### Platforms and modes

Each rule compiles for the platform its package builds for, with
`-mcpu baseline`: in `///linux_arm64` it is aarch64 Linux, whatever the host,
because zig cross-compiles everything itself. In the `opt` configuration a
build is `-O safe` and stripped, which makes it the same bytes wherever it is
built; `dbg` is `-O debug` with debug info. `mode` and `strip` override both.

### C

A module's `csrcs` are compiled into it. A compile links every archive and
object its build gathers, as cc_binary does, so a `c_library` in `deps` is
linked; its `cc:inc:` and `cc:ld:` labels add include directories and linker
flags. Note that cc-rules' `cc_library` compiles C++; use `c_library` for C.

## Packages from build.zig.zon

```sh
plz run ///zig//:please_zig -- zon --zig "$(plz query outputs ///zig//:toolchain)/zig/zig" build.zig.zon > third_party/zig/BUILD
```

`please_zig zon` fetches each dependency with `zig fetch`, which must compute
the hash `build.zig.zon` declares, then reads that package's own
`build.zig.zon`, so the rules cover the whole package graph. Each package's
module is guessed from zig init's layout (`src/root.zig`, then `root.zig`,
then `src/main.zig`); check it against the package's `build.zig`. A local
`.path` dependency is refused: build it with `zig_library`.

## The C toolchain

`:toolchain` is zig and please_zig installed as `cc`, `c++`, `ar`, `ranlib`
and `ld`. Point another plugin's C tools at it:

```ini
[Plugin "go"]
CCTool = ///zig//:toolchain|cc
ARTool = ///zig//:toolchain|ar
```

Each call reads the platform its action builds for: `GOOS`/`GOARCH` when Go
set them, otherwise `OS`/`ARCH`, which Please sets on every action.

- **Building for the host:** the host's own tool of that name runs, so a host
  build is what it would be without this plugin.
- **Building for Linux:** `zig cc -target <arch>-linux-musl` (or `zig ar`,
  `zig ld.lld`), linking musl statically.
- **Any other platform:** the call fails, naming it.

Two differences from gcc are handled: `cc -c a.c b.c` with no `-o` writes
`a.o` and `b.o`, where zig writes only the first and succeeds, so the call is
split per source; and zig compiles unoptimised C with UndefinedBehaviorSanitizer
on, which gcc never does, so it is turned off.

## please_zig

`tools/please_zig` is the plugin's one program, in Zig, built by the pinned
zig itself, so it needs no other compiler. That matters on a Mac, where it is
the C compiler Go links with. Called by an installed name it is the C
toolchain (`cc.zig`); as `please_zig` it is the rules' helper: `manifest` and
`compile` for modules (`module.zig`), `zon` for packages (`zon.zig`).

A module is described by a manifest: its name in the build (from its label),
its import name, its root file and its direct imports. A compile gathers every
manifest in its build directory (`needs_transitive_deps`), walks the graph
from the root and hands it to zig as `--dep` and `-M` flags.

## The zig cache

zig caches libc and compiler-rt for each target, and compiles parts of itself
(fetch, translate-c) the first time each is used, which takes a minute. Its
cache only works where it was built (entries hold absolute paths), so every
local action shares one, at `plz-out/zig-cache`; `ZIG_CACHE_DIR` names another.
An action run remotely has no repo to share with and gets its own, so it
compiles those parts from cold: the same output, more slowly.

## Developing

```sh
./pleasew test //...
```

runs please_zig's unit tests (`zig test`) and the rules' tests: a module graph
with an import-name override and `@embedFile`, `zig_test`, cross-compiling to
each Linux target, a stripped binary free of build paths, C sources, a
translated C library, static and shared libraries linked by C, a package
pinned by hash, and `please_zig zon` end to end.
`test/cgo` builds a Go binary with two cgo libraries, go-ethereum's secp256k1
and libopus (from configure and make, through hraban/opus), statically linked:
for the host, where it runs, and for `///linux_amd64`, which on a Mac is Go's
cgo going through this plugin's toolchain (`.plzconfig_darwin_*`).
CI runs them on Ubuntu and macOS for every pull request.

## Updating zig

Bump `_VERSION` in `BUILD` and refresh `_HASHES` from
<https://ziglang.org/download/index.json>, checking each against a download.
Zig's standard library changes between versions, so expect please_zig to
need changes too.

## Releasing

A release is made when `VERSION` changes on `main` and the tests pass: the
release workflow tags `v<version>` with that version's `ChangeLog` entry. A
version that already has a release is left as it is.
