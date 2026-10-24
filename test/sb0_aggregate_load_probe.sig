//! Native executable regression for aarch64-sb0 by-value element loads of aggregates that
//! have no register decomposition (`slice_elem_val`, `array_elem_val`, `ptr_elem_val`).
//!
//! Before the fix these element handlers called `Value.load` without the `memcpy` fallback
//! that AIR `.load` has, so any union above 8 bytes, an array above 16 bytes, a struct above
//! 16 bytes or a non-payload optional element failed with "load of aggregate too large for
//! register decomposition". The probe copies such elements out of slices (for-capture),
//! by-value arrays with a runtime index and many-item pointers, and checks the copy field by
//! field (tag, payload bytes, length), the first, middle and last element, that the source is
//! unchanged afterwards and that the guard words and neighbouring elements are intact.
//!
//! Build with -target aarch64-sb0 --script test/sb0_runner.ld and boot on QEMU virt.
//! Success is the runtime marker SB0-AGG-PASS; every mismatch prints SB0-AGG-FAIL <case>
//! and the PASS marker is then withheld.
const std = @import("std");
const builtin = @import("builtin");
pub const panic = std.debug.no_panic;
comptime {
    if (builtin.mode == .safe) {
        @export(&testMemcpy, .{ .name = "memcpy" });
        @export(&testMemset, .{ .name = "memset" });
    }
}
fn testMemcpy(destination: [*]u8, source: [*]const u8, count: usize) callconv(.c) [*]u8 {
    const out: [*]volatile u8 = @ptrCast(destination);
    const input: [*]const volatile u8 = @ptrCast(source);
    var index: usize = 0;
    while (index < count) : (index += 1) out[index] = input[index];
    // x2 is caller-clobbered: callers must not depend on it surviving the call.
    asm volatile ("mov x2, #0x1357" ::: .{ .x2 = true });
    return destination;
}
fn testMemset(destination: [*]u8, value: c_int, count: usize) callconv(.c) [*]u8 {
    const out: [*]volatile u8 = @ptrCast(destination);
    var index: usize = 0;
    while (index < count) : (index += 1) out[index] = @truncate(@as(c_uint, @bitCast(value)));
    asm volatile ("mov x2, #0x1357" ::: .{ .x2 = true });
    return destination;
}

extern var __bss_start: u8;
extern var __bss_end: u8;
fn write(bytes: []const u8) void {
    const flags: *volatile u32 = @ptrFromInt(0x09000018);
    const data: *volatile u32 = @ptrFromInt(0x09000000);
    for (bytes) |byte| {
        while (flags.* & 32 != 0) {}
        data.* = byte;
    }
}
fn park() noreturn {
    while (true) asm volatile ("wfe");
}
var failures: u32 = 0;
/// Report one mismatch and keep going, so a run lists every failing case.
noinline fn fail(type_name: []const u8, what: []const u8) void {
    failures += 1;
    write("SB0-AGG-FAIL ");
    write(type_name);
    write(" ");
    write(what);
    write("\n");
}

var index_cell: usize = 0;
/// An index the compiler cannot fold: the elements are selected at run time.
noinline fn rt(i: usize) usize {
    const p: *volatile usize = &index_cell;
    p.* = i;
    return p.*;
}

const Text = struct { bytes: [136]u8, len: usize };
const Cell = union(enum) { number: i64, text: Text, empty };
const Arr = [200]u8;
const Opt = ?Text;
const Big = struct { words: [19]u64, tail: u64 };
/// A bare union: tagged by the compiler in ReleaseSafe, untagged otherwise. The auto-layout form is only
/// used in ReleaseSafe: constructing an auto-layout bare union with an array payload in ReleaseSmall hangs
/// with the pristine compiler as well (independent of element loads), so the other modes use the extern
/// layout, which has the same size and no tag.
const Bare = if (builtin.mode == .safe)
    union { number: i64, bytes: [24]u8 }
else
    extern union { number: i64, bytes: [24]u8 };
const Small = union(enum) { a: u32, b: u64, c };
const Odd = [17]u8;

fn text(seed: usize) Text {
    var t: Text = .{ .bytes = undefined, .len = seed + 1 };
    for (&t.bytes, 0..) |*b, i| b.* = @truncate(i *% 7 +% seed *% 29 +% 3);
    return t;
}

fn make(comptime T: type, i: usize) T {
    switch (T) {
        Cell => return switch (i) {
            0 => .{ .number = -5 },
            1 => .{ .text = text(i) },
            else => .empty,
        },
        Arr => {
            var a: Arr = undefined;
            for (&a, 0..) |*b, k| b.* = @truncate(k *% 3 +% i *% 11 +% 1);
            return a;
        },
        Opt => return if (i == 1) null else text(i),
        Big => {
            var b: Big = undefined;
            for (&b.words, 0..) |*w, k| w.* = (@as(u64, i + 1) << 56) | k;
            b.tail = ~@as(u64, i);
            return b;
        },
        Bare => {
            var b: Bare = undefined;
            if (i == 1) {
                b = .{ .number = 99 };
            } else {
                b = .{ .bytes = undefined };
                for (&b.bytes) |*x| x.* = @truncate(i + 1);
            }
            return b;
        },
        Small => return switch (i) {
            0 => .{ .a = 0xA5A5_0001 },
            1 => .{ .b = 0x0123_4567_89AB_CDEF },
            else => .c,
        },
        Odd => {
            var a: Odd = undefined;
            for (&a, 0..) |*b, k| b.* = @truncate(k *% 5 +% i *% 13 +% 7);
            return a;
        },
        else => @compileError("no generator"),
    }
}

/// Field-by-field comparison; `i` is the index `want` was built from. Padding bytes of the
/// tagged shapes are not defined by `make`, so only the fields that were written are compared.
fn same(comptime T: type, got: *const T, want: *const T, i: usize) bool {
    switch (T) {
        Cell => switch (want.*) {
            .number => |n| return got.* == .number and got.number == n,
            .text => |t| return got.* == .text and got.text.len == t.len and std.mem.eql(u8, &got.text.bytes, &t.bytes),
            .empty => return got.* == .empty,
        },
        Opt => {
            if (want.*) |t| {
                const g = got.* orelse return false;
                return g.len == t.len and std.mem.eql(u8, &g.bytes, &t.bytes);
            }
            return got.* == null;
        },
        Small => switch (want.*) {
            .a => |v| return got.* == .a and got.a == v,
            .b => |v| return got.* == .b and got.b == v,
            .c => return got.* == .c,
        },
        Arr, Odd => return std.mem.eql(u8, got, want),
        Big => return std.mem.eql(u64, &got.words, &want.words) and got.tail == want.tail,
        Bare => {
            if (i == 1) return got.number == 99;
            return std.mem.eql(u8, &got.bytes, &want.bytes);
        },
        else => @compileError("no comparison"),
    }
}
fn Guarded(comptime T: type) type {
    return struct { pre: u64, items: [3]T, post: u64 };
}
const guard_pre: u64 = 0x1122_3344_5566_7788;
const guard_post: u64 = 0x99AA_BBCC_DDEE_FF00;

/// AIR slice_elem_val: for-capture over a slice.
noinline fn copyCapture(comptime T: type, src: []const T, dst: []T) void {
    for (src, 0..) |item, index| dst[index] = item;
}
/// AIR array_elem_val: by-value array parameter indexed at run time.
noinline fn pickArray(comptime T: type, arr: [3]T, i: usize, out: *T) void {
    out.* = arr[i];
}
/// AIR ptr_elem_val: many-item pointer indexed at run time.
noinline fn pickPtr(comptime T: type, p: [*]const T, i: usize, out: *T) void {
    out.* = p[i];
}

fn runCase(comptime T: type, comptime name: []const u8) void {
    var src: [3]T = undefined;
    for (&src, 0..) |*s, i| s.* = make(T, i);
    var g: Guarded(T) = .{ .pre = guard_pre, .items = undefined, .post = guard_post };
    for (&g.items) |*it| it.* = make(T, 2);

    // slice_elem_val: every element of a for-capture.
    copyCapture(T, &src, &g.items);
    for (0..3) |i| {
        const want = make(T, i);
        if (!same(T, &g.items[i], &want, i)) fail(name, "capture");
    }
    if (g.pre != guard_pre or g.post != guard_post) fail(name, "capture guard");

    // array_elem_val and ptr_elem_val at index 0, a middle index and len - 1.
    const indexes = [3]usize{ 0, 1, 2 };
    const sentinel = make(T, 2);
    for (indexes) |raw| {
        const i = rt(raw);
        const want = make(T, raw);
        var out: Guarded(T) = .{ .pre = guard_pre, .items = undefined, .post = guard_post };
        out.items[0] = sentinel;
        out.items[1] = sentinel;
        out.items[2] = sentinel;

        pickArray(T, src, i, &out.items[1]);
        if (!same(T, &out.items[1], &want, raw)) fail(name, "array");
        if (!same(T, &out.items[0], &sentinel, 2) or !same(T, &out.items[2], &sentinel, 2)) fail(name, "array neighbours");
        if (out.pre != guard_pre or out.post != guard_post) fail(name, "array guard");

        out.items[1] = sentinel;
        pickPtr(T, &src, i, &out.items[1]);
        if (!same(T, &out.items[1], &want, raw)) fail(name, "ptr");
        if (!same(T, &out.items[0], &sentinel, 2) or !same(T, &out.items[2], &sentinel, 2)) fail(name, "ptr neighbours");
        if (out.pre != guard_pre or out.post != guard_post) fail(name, "ptr guard");
    }

    // The source is untouched, and the destination is distinct storage.
    for (0..3) |i| {
        const want = make(T, i);
        if (!same(T, &src[i], &want, i)) fail(name, "source changed");
    }
    if (@intFromPtr(&g.items) == @intFromPtr(&src)) fail(name, "aliased");
}
export fn mainNative() callconv(.c) noreturn {
    const bytes: [*]u8 = @ptrCast(&__bss_start);
    const count = @intFromPtr(&__bss_end) - @intFromPtr(&__bss_start);
    for (0..count) |i| bytes[i] = 0;
    runCase(Cell, "Cell");
    runCase(Arr, "[200]u8");
    runCase(Odd, "[17]u8");
    runCase(Opt, "?Text");
    runCase(Big, "Big160");
    runCase(Bare, "Bare");
    runCase(Small, "Small");
    if (failures == 0) write("SB0-AGG-PASS\n");
    park();
}
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ movz x0, #0x4100, lsl #16
        \\ mov sp, x0
        \\ movz x1, #0x30, lsl #16
        \\ msr cpacr_el1, x1
        \\ isb
        \\ bl %[main]
        \\ b .
        :
        : [main] "S" (&mainNative),
        : .{ .memory = true });
}
