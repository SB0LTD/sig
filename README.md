<p align="center">
  <img src="sig.png" alt="Sig" width="420" />
</p>

<h1 align="center">Sig — Strict Zig</h1>

<p align="center">
  <em>Memory is not a guess.</em>
</p>

<p align="center">
  A capacity-first memory model layer on top of the Zig compiler.<br/>
  Every buffer is caller-owned. Every container is bounded. Every allocation is visible.
</p>

<p align="center">
  <a href="https://github.com/SB0LTD/sig/releases"><img src="https://img.shields.io/github/v/release/SB0LTD/sig?label=sig&color=f7a41d&style=flat-square" alt="Release"></a>
  <a href="https://codeberg.org/ziglang/zig"><img src="https://img.shields.io/badge/upstream-zig%200.17.0--dev-blue?style=flat-square" alt="Upstream"></a>
  <a href="https://github.com/SB0LTD/sig/actions/workflows/sig-sync.yaml"><img src="https://img.shields.io/github/actions/workflow/status/SB0LTD/sig/sig-sync.yaml?label=sync&style=flat-square" alt="Sync Status"></a>
</p>

---

## What Sig looks like

```zig
// zig — allocator is a runtime parameter, capacity is implicit
var list = std.ArrayList(u8).init(allocator);
try list.appendSlice(data); // might realloc 1x, 2x, 4x…

// sig — you provide the buffer, capacity is the type
var buf: [4096]u8 = undefined;
const result = try sig.fmt.formatInto(&buf, "{s}: {d}", .{ name, count });
```

```zig
// bounded container — capacity is comptime-known
var vec = sig.containers.BoundedVec(u32, 1024){};
try vec.push(10);
try vec.push(20); // returns CapacityExceeded if full
```

## Strict mode

The `.sig` file extension enables strict mode. Same syntax as `.zig`, same parser, same compiler — but allocator usage is a compile error.

```
src/core.sig:42:5: error: direct allocation in 'init' (.sig file: strict mode enforced)
```

| File | `allocator.alloc(...)` | Behavior |
|---|---|---|
| `foo.zig` | Allowed | Warning (or error with `--sig-mode=strict`) |
| `foo.sig` | Not allowed | Compile error, always |

`.sig` and `.zig` files interoperate via `@import`. You can adopt strict mode one file at a time.

## Error model

Four explicit errors instead of silent reallocation:

| Error | Meaning |
|---|---|
| `BufferTooSmall` | Output exceeds the caller-provided buffer |
| `CapacityExceeded` | Bounded container is full |
| `DepthExceeded` | Recursive operation hit depth limit |
| `QuotaExceeded` | Resource usage limit reached |

Standard Zig error unions. Handle with `try`, `catch`, or `orelse`.

## Memory patterns

| Pattern | In `.sig` files |
|---|---|
| `var buf: [1024]u8 = undefined;` | ✅ |
| `fn read(buf: []u8) ![]u8` | ✅ |
| `BoundedVec(u8, 256)` | ✅ |
| `FixedPool(Node, 64)` | ✅ |
| `allocator.alloc(u8, n)` | ❌ compile error |
| `fn init(alloc: Allocator)` | ❌ compile error |
| `list.ensureTotalCapacity(n)` | ❌ compile error |

In `.zig` files, the ❌ patterns compile normally (with optional warnings).

---

## The Spoon Model

Sig is not a fork. It's a **Spoon** 🥄

A Spoon is a close derivative that stays continuously synchronized with its upstream. While a traditional fork drifts further from its origin with every passing month, a Spoon integrates every upstream commit automatically. Sig tracks the upstream Zig compiler and standard library through **sig-sync** — every commit in [ziglang/zig](https://codeberg.org/ziglang/zig) flows into Sig within minutes.

| | Traditional Fork | Spoon (Sig) |
|---|---|---|
| Upstream tracking | Manual, periodic | Continuous, automatic |
| Divergence over time | Grows unbounded | Near zero |
| Merge conflicts | Accumulate silently | Resolved immediately |
| Upstream compatibility | Degrades | Always maintained |

### Sync status

<!-- Updated automatically by sig-sync workflow -->

| | |
|---|---|
| **Latest upstream commit** | [`c9172710`](https://codeberg.org/ziglang/zig/commit/c91727108ec70019b0e1940e719bbf795ebf26c8) |
| **Last sync** | 2026-06-11 |
| **Upstream** | [codeberg.org/ziglang/zig](https://codeberg.org/ziglang/zig) |
| **Base version** | zig 0.17.0-dev · LLVM 22.1.3 |
| **Sync frequency** | Every commit (< 1 min latency) |

> The sync status above is updated automatically after each successful integration. See the [sig-sync workflow](https://github.com/SB0LTD/sig/actions/workflows/sig-sync.yaml) for live run history.

---

## Getting started

Download a binary from [releases](https://github.com/SB0LTD/sig/releases), or build from source:

```bash
git clone https://github.com/SB0LTD/sig.git
cd sig && sig build
```

Drop-in replacement for `zig`. All existing `.zig` code works unchanged.

```
$ sig version
sig 0.1.2 (zig 0.17.0-dev)
```

## Versioning

Sig follows its own semver while tracking the upstream Zig version it's built on. Release tags encode both: `sig-0.1.2+zig0.17.0.<sha>`.

## Contributing

All sig stdlib APIs must follow the capacity-first model — no `Allocator` parameters in public interfaces. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

Same as upstream Zig. See [LICENSE](LICENSE).
