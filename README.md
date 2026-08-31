<p align="center">
  <img src="sig.png" alt="Sig" width="420" />
</p>

<h1 align="center">Sig</h1>

<p align="center">
  <strong>The Sig compiler that knows how much memory it has.</strong>
</p>

<p align="center">
  <a href="https://github.com/SB0LTD/sig/releases"><img src="https://img.shields.io/github/v/release/SB0LTD/sig?label=latest&color=f7a41d&style=flat-square" alt="Release"></a>
  <a href="https://codeberg.org/ziglang/zig"><img src="https://img.shields.io/badge/language-base-Zig%200.17.0--dev-blue?style=flat-square" alt="Language base"></a>
  <a href="https://github.com/SB0LTD/sig/actions/workflows/sig-sync.yaml"><img src="https://img.shields.io/github/actions/workflow/status/SB0LTD/sig/sig-sync.yaml?label=sync&style=flat-square" alt="Sync Status"></a>
  <a href="https://github.com/SB0LTD/sig/actions/workflows/release.yaml"><img src="https://img.shields.io/github/actions/workflow/status/SB0LTD/sig/release.yaml?label=release&style=flat-square" alt="Release Status"></a>
</p>

<p align="center">
  <code>sig</code> retains Zig language compatibility. Rename a file to <code>.sig</code> and the compiler starts caring about where your bytes come from.
</p>

---

## 0.4.1 — Self-Hosted SB0 Linking

Sig gains a pure-Sig, self-hosted linker for the native SB0 target. Compiling
`aarch64-sb0` with `-ofmt=raw -fno-llvm` emits a complete SB0X image directly —
no LLD, no ELF/PE intermediate. The linker resolves external, global, and lazy
symbols, so ordinary programs (slices, loops, optionals, error unions, and the
`memset`/`memcpy` runtime they reference) compile end to end through the
self-hosted AArch64 code generator with no LLVM.

```
$ sig version
sig 0.4.1 (zig 0.17.0)
```

The SB0X/SB0K native image format is now a canonical, dependency-free
[zpm](https://github.com/SB0LTD/zpm) module (`platform/sb0x`), mirrored
byte-for-byte inside the compiler. The self-hosted backend is not yet the
default for the LLVM platforms; LLVM remains the release backend there. See the
[changelog](CHANGELOG.md#041--2026-08-29--self-hosted-sb0-linking) for the
verified capability and current limitations.

## 0.4.0 — Sovereign

The compiler, standard library, native build runner, and canonical test suite are
Sig source. The repository tracks no `.zig` source files, and the bootstrap and
release stages invoke Sig—not an upstream Zig executable.

```
$ sig version
sig 0.4.0 (zig 0.17.0)
```

`sig build` executes `build.sig` through the fixed-capacity native runner. The
production graph compiles Sig, installs the library, and runs the real 213-test
compiler suite. `-target aarch64-sb0` remains a first-class native target with
no libc or dynamic-linker fallback.

The packaged `Sig` alias preserves the upstream-compatible machine-readable
version-only output, while `sig version` identifies both the Sig and Zig-base
versions.

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
from the bootstrap and release stages: an immutable native Sig stage0 creates
the four verified bootstraps, and those bootstraps compile the final LLVM-backed
Sig executables with immutable LLVM closures.

---

## What makes it strict

The `.sig` extension activates strict mode. Same syntax. Same parser. Same compiler. But allocator usage becomes a compile error.

```Sig
// foo.sig — business as usual
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

Standard Sig error unions. `try`, `catch`, `orelse`. Nothing new to learn.

---

## The Spoon

Sig stays synchronized with upstream Zig while maintaining its sovereign compiler,
strict-mode, build-runner, and release layers.

When a new commit lands in `ziglang/zig`, it fires a GitHub dispatch. The sig-sync workflow cherry-picks the commit, resolves conflicts (keeping Sig-owned files), validates the bootstrap, and pushes. If the standard library changed in a way that breaks the bootstrap, it triggers a rebuild chain automatically.

The result: sig never drifts. You get upstream bug fixes, optimizations, and new features without waiting.

<!-- Updated automatically by sig-sync workflow -->

| | |
|---|---|
| **Latest upstream commit** | [`d26018b0`](https://codeberg.org/ziglang/zig/commit/d26018b0f46f14adac17f021782270e13ede5a92) |
| **Last sync** | 2026-08-31 |
| **Upstream** | [codeberg.org/ziglang/zig](https://codeberg.org/ziglang/zig) |
| **Base version** | Sig 0.17.0-dev · LLVM 22.1.8 |
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
finds the adjacent library automatically. If `SIG_LIB_DIR` is set globally,
unset it or point it at the extracted `sig-toolchain/lib`; mixing compiler and
library versions can make the build runner fail before your build begins.

It's language-compatible by design. Existing `.zig` files compile unchanged;
rename a source file to `.sig` when you're ready to enable strict mode.

## How it's built

```
build-llvm                 →  build-bootstrap              →  release
7 immutable LLVM closures    4 verified host bootstraps      4 LLVM-backed toolchains
```

Each stage publishes an exact manifest, SHA-256 set, source commit, producer,
and workflow run. Drafts become visible only after every required artifact and
target-specific execution probe succeeds. Bootstrap and final compilers also
run the canonical 213-test native compiler graph with an explicit fixed stack
budget, then cross-compile and validate an AArch64 object.

## License

Same as upstream Zig — MIT. See [LICENSE](LICENSE).
