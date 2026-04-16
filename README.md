# Sig

A Zig fork where `.sig` files make allocator usage a compile error.

## What it looks like

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

## Getting started

Download a binary from [releases](https://github.com/SB0LTD/sig/releases), or build from source:

```bash
git clone https://github.com/SB0LTD/sig.git
cd sig && sig build
```

Drop-in replacement for `zig`. All existing `.zig` code works unchanged.

## Upstream sync

Sig tracks [codeberg.org/ziglang/zig](https://codeberg.org/ziglang/zig) continuously. Every upstream commit is merged automatically. Current base: **zig 0.16.0-dev**, **LLVM 22.1.3**.

## 0.1.2 release

- Ported to LLVM 22.1.3
- Synced with upstream zig 0.16.0
- Three-stage release pipeline (build-llvm → build-bootstrap → release)
- Ships for x86_64-linux, aarch64-macos, x86_64-windows

Full changelog: [CHANGELOG.md](CHANGELOG.md)

## Contributing

All sig stdlib APIs must follow the capacity-first model — no `Allocator` parameters in public interfaces. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

Same as upstream Zig. See [LICENSE](LICENSE).
