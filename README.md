<p align="center">
  <img src="sig.png" alt="Sig" width="420" />
</p>

<h1 align="center">Sig</h1>

<p align="center">
  <strong>The Zig compiler that knows how much memory it has.</strong>
</p>

<p align="center">
  <a href="https://github.com/SB0LTD/sig/releases"><img src="https://img.shields.io/github/v/release/SB0LTD/sig?label=latest&color=f7a41d&style=flat-square" alt="Release"></a>
  <a href="https://codeberg.org/ziglang/zig"><img src="https://img.shields.io/badge/upstream-zig%200.17.0--dev-blue?style=flat-square" alt="Upstream"></a>
  <a href="https://github.com/SB0LTD/sig/actions/workflows/sig-sync.yaml"><img src="https://img.shields.io/github/actions/workflow/status/SB0LTD/sig/sig-sync.yaml?label=sync&style=flat-square" alt="Sync Status"></a>
  <a href="https://github.com/SB0LTD/sig/actions/workflows/release.yaml"><img src="https://img.shields.io/github/actions/workflow/status/SB0LTD/sig/release.yaml?label=release&style=flat-square" alt="Release Status"></a>
</p>

<p align="center">
  <code>sig</code> is a drop-in replacement for <code>zig</code>. All your code works. Then you rename a file to <code>.sig</code> and the compiler starts caring about where your bytes come from.
</p>

---

## 0.3.2 — First-Class SB0 Target

Patch release adding the consolidated native `aarch64-sb0` target.

```
$ sig version
sig 0.3.2 (zig 0.17.0-dev)
```

`-target aarch64-sb0` now selects the SB0 OS and ABI directly, emits native
raw bytes, reserves x18 automatically, and has no libc or dynamic-linker
fallback. SB0K and SB0X remain artifact kinds under this one target rather
than separate compiler destinations.

The packaged `zig` alias preserves the upstream machine-readable version-only
output, while `sig version` identifies both the Sig and Zig versions.

| Platform | Backend | Download |
|---|---|---|
| x86_64-linux | Full LLVM 22.1.8 | [tar.xz](https://github.com/SB0LTD/sig/releases/latest/download/sig-x86_64-linux.tar.xz) |
| aarch64-linux | Full LLVM 22.1.8 | [tar.xz](https://github.com/SB0LTD/sig/releases/latest/download/sig-aarch64-linux.tar.xz) |
| aarch64-macos | Full LLVM 22.1.8 | [tar.xz](https://github.com/SB0LTD/sig/releases/latest/download/sig-aarch64-macos.tar.xz) |
| x86_64-windows | Full LLVM 22.1.8 | [zip](https://github.com/SB0LTD/sig/releases/latest/download/sig-x86_64-windows.zip) |
| aarch64-sb0 | Native allocator-free SB0K runner | [sb0k](https://github.com/SB0LTD/sig/releases/latest/download/sig-aarch64-sb0-runner.sb0k) |

Every package contains the same full LLVM target set and the same Sig standard
library. Linux and macOS execute on their build hosts, Windows executes on a
Windows runner, and aarch64 Linux executes under QEMU user-mode before the
release can be published.

The SB0K release asset boots as the compiler service itself: it accepts one
bounded SB0C request, compiles through the SB0-only fixed-capacity pipeline,
and returns an SB0X image. Its request encoder and response extractor are also
strict `.sig` programs using fixed storage and raw syscalls—Python is not part
of the runner or its release gate. See
[compiler/SB0_NATIVE_RUNNER.md](compiler/SB0_NATIVE_RUNNER.md) for the wire
contract and reproducible QEMU invocation.

The final release is produced by Sig itself. CMake and upstream Zig are absent
from the release stage. The checked-in `zig1.wasm` chain is used only to create
the native bootstrap set; those bootstraps then compile the four final Sig
executables with immutable LLVM closures.

---

## What makes it strict

The `.sig` extension activates strict mode. Same syntax. Same parser. Same compiler. But allocator usage becomes a compile error.

```zig
// foo.zig — business as usual
var list = std.ArrayList(u8).init(allocator);
try list.appendSlice(data);

// foo.sig — you bring the buffer, you know the cost
var buf: [4096]u8 = undefined;
const result = try sig.fmt.formatInto(&buf, "{s}: {d}", .{ name, count });
```

Four errors replace silent reallocation:

| Error | When |
|---|---|
| `BufferTooSmall` | Output exceeds the caller-provided buffer |
| `CapacityExceeded` | Bounded container is full |
| `DepthExceeded` | Recursion hit its limit |
| `QuotaExceeded` | Resource cap reached |

Standard Zig error unions. `try`, `catch`, `orelse`. Nothing new to learn.

---

## The Spoon

Sig is not a fork. It stays synchronized with upstream Zig within minutes of every commit.

When a new commit lands in `ziglang/zig`, it fires a GitHub dispatch. The sig-sync workflow cherry-picks the commit, resolves conflicts (keeping sig-owned files), validates the bootstrap, and pushes. If the standard library changed in a way that breaks the bootstrap, it triggers a rebuild chain automatically.

The result: sig never drifts. You get upstream bug fixes, optimizations, and new features without waiting.

<!-- Updated automatically by sig-sync workflow -->

| | |
|---|---|
| **Latest upstream commit** | [`75044cb0`](https://codeberg.org/ziglang/zig/commit/75044cb04cc67454db98ed7c054081806c3830c6) |
| **Last sync** | 2026-08-16 |
| **Upstream** | [codeberg.org/ziglang/zig](https://codeberg.org/ziglang/zig) |
| **Base version** | zig 0.17.0-dev · LLVM 22.1.8 |
| **Sync frequency** | Every commit (< 1 min latency) |

---

## Getting started

```bash
# Download the latest release
mkdir -p sig-toolchain
curl -sL https://github.com/SB0LTD/sig/releases/latest/download/sig-x86_64-linux.tar.xz \
  | tar -xJ -C sig-toolchain --strip-components=1
export PATH="$PWD/sig-toolchain/bin:$PATH"

# Or build from source (requires an existing Sig compiler)
git clone https://github.com/SB0LTD/sig.git && cd sig
sig build -OReleaseFast
```

The executable and `lib/` directory are a matched toolchain unit. Normally Sig
finds the adjacent library automatically. If `ZIG_LIB_DIR` is set globally,
unset it or point it at the extracted `sig-toolchain/lib`; mixing compiler and
library versions can make the build runner fail before your build begins.

It's a drop-in replacement. Every `.zig` file compiles unchanged. Rename to `.sig` when you're ready to go strict.

## How it's built

```
build-llvm                 →  build-bootstrap              →  release
7 immutable LLVM closures    4 verified host bootstraps      4 LLVM-backed toolchains
```

Each stage publishes an exact manifest, SHA-256 set, source commit, producer,
and workflow run. Drafts become visible only after every required artifact and
target-specific execution probe succeeds. Bootstrap and final compilers also
run the canonical 210-test native compiler graph with an explicit fixed stack
budget, then cross-compile and validate an AArch64 object.

## License

Same as upstream Zig — MIT. See [LICENSE](LICENSE).
