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

## 0.2.0 — No More Excuses

Three platforms. Self-sustained pipeline. Sig builds sig.

```
$ sig version
sig 0.2.0 (zig 0.17.0-dev, LLVM 22)
```

| Platform | Backend | Download |
|---|---|---|
| x86_64-linux | Full (LLVM 22 + self-hosted) | [tar.xz](https://github.com/SB0LTD/sig/releases/latest) |
| aarch64-macos | Self-hosted | [tar.xz](https://github.com/SB0LTD/sig/releases/latest) |
| x86_64-windows | Self-hosted | [zip](https://github.com/SB0LTD/sig/releases/latest) |

The Linux binary has the full LLVM backend — it can emit machine code for every target LLVM supports. macOS and Windows ship with the self-hosted backends (x86_64, aarch64, wasm, arm, riscv64). All three produce working binaries today.

The entire release is produced by sig itself. No cmake. No external zig. One `sig build-exe` invocation compiles the compiler, links LLVM, and outputs a static binary. That binary can then cross-compile itself for other targets. Bootstrap complete.

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
| **Latest upstream commit** | [`ce021153`](https://codeberg.org/ziglang/zig/commit/ce02115365759a9b7f9ccfdd8577bee20da54b84) |
| **Last sync** | 2026-08-07 |
| **Upstream** | [codeberg.org/ziglang/zig](https://codeberg.org/ziglang/zig) |
| **Base version** | zig 0.17.0-dev · LLVM 22.1.3 |
| **Sync frequency** | Every commit (< 1 min latency) |

---

## Getting started

```bash
# Download the latest release
curl -sL https://github.com/SB0LTD/sig/releases/latest/download/sig-x86_64-linux.tar.xz | tar -xJ
export PATH="$PWD/sig/bin:$PATH"

# Or build from source (requires a sig or zig binary)
git clone https://github.com/SB0LTD/sig.git && cd sig
sig build -OReleaseFast
```

It's a drop-in replacement. Every `.zig` file compiles unchanged. Rename to `.sig` when you're ready to go strict.

## How it's built

```
build-llvm (one-time)  →  build-bootstrap (one-time)  →  release (every version)
     LLVM 22 .a files        v28 bootstrap binary            sig builds sig
```

The bootstrap is a previous sig release. It compiles the current source with LLVM 22 linked in. The output is a static musl binary that cross-compiles for all targets. No external dependencies at runtime.

## License

Same as upstream Zig — MIT. See [LICENSE](LICENSE).
