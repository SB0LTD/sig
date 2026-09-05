# Application APIs: reuse the foundation

Sig's Zig-derived standard library already supplies native compilation, types and comptime, C interoperability, networking, containers and JSON machinery. The application layer makes selected facilities convenient with caller-owned storage. It does not replace those implementations.

Available in the application SDK development preview:

```sh
zpm init --template web-server --name service
cd service
zpm build
zpm test
zpm run
# Open http://127.0.0.1:8080/health or /profile
```

The generated build graph uses `try ctx.applicationImport()` to find the APIs in the compiler's matched SDK. Application code imports `const app = @import("app");`. New empty, CLI and web-server templates have an `install` default step, so `zpm build` compiles without running the application. An older build graph without an install step can still execute all its steps by default; add an install step depending only on its compile step when migrating.

## Collections

```sig
var storage: [64]u32 = undefined;
var scores = app.List(u32).init(&storage);
try scores.append(42);
try scores.extend(&.{ 10, 20 });
for (scores.slice()) |score| { _ = score; }

var queue_storage: [16]u32 = undefined;
var jobs = app.Queue(u32).init(&queue_storage);
try jobs.push(7);
const next = jobs.pop();
_ = next;

var settings: app.StringMap(32, 128, 16) = .{};
try settings.put("theme", "pastel");
```

`List` wraps `std.ArrayList.initBuffer` and bounded operations. `Queue` wraps `std.Deque`; it is an in-memory FIFO, not a persistent or thread-safe job service. `Vector(T, capacity)` and `StringMap(key_bytes, value_bytes, entries)` reuse existing Sig containers. `StaticMap(T)` reuses `std.StaticStringMap` for compile-time lookup tables.

Keep one mutable owner of borrowed storage. Copies of a list/queue share its storage. Slices returned by a list or map borrow its backing memory; do not retain them across mutations that invalidate their contents. Capacity errors leave list/queue state unchanged. List removal preserves order and costs O(n); deque push/pop costs O(1). The existing bounded string map uses linear lookup and copies keys and values into its inline storage.

## Serialization and validation from types

```sig
const Profile = struct { name: []const u8, age: u8 };
const ProfileSchema = app.Schema(Profile, .{
    .{ .field = "name", .check = app.validation.lengthBetween(1, 32), .message = "Name needs 1 to 32 bytes" },
    .{ .field = "age", .check = app.validation.range(u8, 1, 120), .message = "Age needs 1 to 120" },
});

const profile = Profile{ .name = "Ada", .age = 9 };
try ProfileSchema.validate(profile);
var output: [256]u8 = undefined;
const body = try app.json.encode(profile, &output);
// {"name":"Ada","age":9}
_ = body;
```

JSON encoding delegates to `std.json.Stringify` with a fixed writer. It validates UTF-8, finite numbers and a nesting limit of 64, then measures output before writing. Capacity or validation failure leaves output unchanged. Input must remain stable and must not overlap output. Supported values include structs, bounded arrays/slices, single-item pointers, exhaustive enums, optional values, booleans and numbers. Custom serialization hooks are excluded from the two-pass API, and unsupported types produce compile errors. Use the standard writer directly for specialized hooks.

Schema rules are checked against actual field names at compile time. Predicate type mismatches fail when validation is compiled. `first` returns the first violation; `report(value, output)` collects all violations in declaration order using caller-owned storage. Length rules count bytes. Rules are pure predicates, and report messages borrow the rule's compile-time strings.

The allocating standard JSON decoder is not wrapped by this API. A future bounded decoder must preserve grammar validation, UTF-8, escaping, duplicate-field handling and typed conversion while adapting its allocator-dependent nesting/string storage. The older substring helpers in ZPM are not a replacement for validating untrusted JSON.

## HTTP foundation

```sig
fn handle(ctx: *app.http.Context) !void {
    return ctx.json(.ok, .{ .status = "ok", .ecosystem = "Sig" });
}
pub fn main(init: @import("std").process.Init) !void {
    try app.http.serve(init.io, .{}, handle);
}
```

The adapter reuses `std.Io.net` and `std.http.Server` for sockets, request parsing, response framing and HEAD handling. Defaults bind to `127.0.0.1:8080`. It serves sequential connections, closes each after one response, and uses fixed 8 KiB header, 4 KiB writer and 16 KiB response buffers. Standard I/O and the operating system manage their own resources; this is not a claim that the whole process performs no internal allocations.

This is a local-service foundation. Production TLS, request deadlines, concurrency, authentication, durable database access, job persistence and deployment integration remain to be supplied. Database work should wrap an existing driver with explicit result storage and bound parameters; authentication should use established provider/cryptographic APIs. Reuse and test those boundaries rather than creating new database engines or cryptography.

## Compatibility evidence and production gate

Run `tools/test-application.ps1 -Compiler <path-to-sig.exe>`. It checks the library on Windows, compiles its core tests for Linux, rejects misspelled schema fields and custom encoding hooks, and verifies five real HTTP responses. Linux runtime networking has not been tested by this Windows check.

The current Sig 0.5.2 SDK accepts `std.heap.page_allocator.alloc` in a `.sig` executable. It also accepts the fixed-buffer allocator probe. The extension currently does not prove the advertised allocator ban. This implementation enforces bounds through its APIs and tests; compiler-level enforcement is an unresolved production release gate. `-RequireAllocatorRejection` makes the compatibility check fail until the compiler rejects the allocating probe for an allocator-policy reason.

| Facility | Current evidence | Remaining work |
| --- | --- | --- |
| Caller-buffer lists and deque | Positive strict-source compilation and capacity/wraparound tests | Broader host/runtime coverage |
| Sig vector and string map | Reused unchanged; capacity/update tests | Large-scale performance characterization |
| Type-derived JSON output | std writer reuse; UTF-8/number/depth/capacity checks | Bounded typed decoding |
| Type-based validation | Typed predicates and compile-time field checking | Domain-specific reusable schemas |
| Native HTTP | Live Windows GET/HEAD/404/405/500 checks | Production server integrations |
| General Zig packages and C libraries | Existing language/ABI facilities | Per-library compatibility adapters and execution tests |
| `.sig` allocator prohibition | Allocating executable probe is accepted by current SDK | Compiler enforcement and a rebuilt, verified release |
