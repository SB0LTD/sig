//! Native executable regression for aarch64-sb0 saturating arithmetic on integers that are narrower than
//! a register: `+|`, `-|` and `<<|` of 2...31 and 33...63 bit integers (and the 32/64 bit controls).
//!
//! The backend used to stop with `too big add_sat u8`, `too big sub_sat u8` (ZPM's `parse_float`) and
//! `unimplemented shl_sat`; only 32 and 64 bit saturating add and subtract had a selection.
//!
//! For every type the operands are edge values (zero, one, minInt, maxInt and their neighbours, halves,
//! -1) in all pairs plus pseudo-random values. The expected value is computed on the exact result in an
//! `i128` and clamped to the range of the type, so the code under test never judges itself. The same file
//! runs as a host `test` (published Sig 0.6.3, LLVM arithmetic on the same operators), which validates the
//! reference. Operands reach the operators through `noinline` functions, so nothing is folded.
//!
//! Build with -target aarch64-sb0 --script test/sb0_runner.ld and boot on QEMU virt. Success is the runtime
//! marker SB0-SAT-PASS; the first mismatches print SB0-SAT-FAIL <type> <op> and withhold the PASS marker.
const std = @import("std");
const builtin = @import("builtin");
const is_sb0 = builtin.cpu.arch == .aarch64;
pub const panic = if (is_sb0) std.debug.no_panic else std.debug.FullPanic(std.debug.defaultPanic);
comptime {
    if (is_sb0 and builtin.mode == .safe) {
        @export(&testMemcpy, .{ .name = "memcpy" });
        @export(&testMemset, .{ .name = "memset" });
    }
}
fn testMemcpy(destination: [*]u8, source: [*]const u8, count: usize) callconv(.c) [*]u8 {
    const out: [*]volatile u8 = @ptrCast(destination);
    const input: [*]const volatile u8 = @ptrCast(source);
    var index: usize = 0;
    while (index < count) : (index += 1) out[index] = input[index];
    return destination;
}
fn testMemset(destination: [*]u8, value: c_int, count: usize) callconv(.c) [*]u8 {
    const out: [*]volatile u8 = @ptrCast(destination);
    var index: usize = 0;
    while (index < count) : (index += 1) out[index] = @truncate(@as(c_uint, @bitCast(value)));
    return destination;
}
// ---- platform ----------------------------------------------------------------------------------
fn write(bytes: []const u8) void {
    if (!is_sb0) return;
    const flags: *volatile u32 = @ptrFromInt(0x09000018);
    const data: *volatile u32 = @ptrFromInt(0x09000000);
    for (bytes) |byte| {
        while (flags.* & 32 != 0) {}
        data.* = byte;
    }
}
fn writeDec(value: u64) void {
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var v = value;
    while (true) {
        i -= 1;
        buf[i] = '0' + @as(u8, @truncate(v % 10));
        v /= 10;
        if (v == 0) break;
    }
    write(buf[i..]);
}
const platform = if (is_sb0) struct {
    extern var __bss_start: u8;
    extern var __bss_end: u8;
    fn park() noreturn {
        while (true) asm volatile ("wfe");
    }
    export fn mainNative() callconv(.c) noreturn {
        const bytes: [*]u8 = @ptrCast(&__bss_start);
        const count = @intFromPtr(&__bss_end) - @intFromPtr(&__bss_start);
        for (0..count) |i| bytes[i] = 0;
        runAll();
        if (failed_cases != 0) {
            write("SB0-SAT-FAIL mismatches=");
            writeDec(failed_cases);
            write("\n");
            park();
        }
        write("checked cases=");
        writeDec(checked_cases);
        write("\n");
        write("SB0-SAT-PASS\n");
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
} else struct {};
comptime {
    if (is_sb0) {
        _ = &platform.mainNative;
        _ = &platform._start;
    }
}
// ---- bookkeeping -------------------------------------------------------------------------------
var checked_cases: u32 = 0;
var failed_cases: u32 = 0;
fn pass() void {
    checked_cases += 1;
}
fn fail(comptime type_name: []const u8, comptime op: []const u8) void {
    failed_cases += 1;
    if (failed_cases <= 16) {
        write("SB0-SAT-FAIL " ++ type_name ++ " " ++ op ++ "\n");
    }
}
var rng_state: u64 = 0x9e37_79b9_7f4a_7c15;
fn nextRandom() u64 {
    // xorshift64*
    var x = rng_state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    rng_state = x;
    return x *% 0x2545_f491_4f6c_dd1d;
}
// ---- operations under test ---------------------------------------------------------------------
fn Ops(comptime T: type) type {
    return struct {
        noinline fn add(a: T, b: T) T {
            return a +| b;
        }
        noinline fn sub(a: T, b: T) T {
            return a -| b;
        }
        noinline fn shl(a: T, s: std.math.Log2Int(T)) T {
            return a <<| s;
        }
        /// Both operands flow into one result: `a +| a`, `a -| b -| a` (the same Value on both sides).
        noinline fn addSame(a: T) T {
            return a +| a;
        }
        /// A saturating result consumed by another saturating operation and by a comparison.
        noinline fn chain(a: T, b: T, c: T) T {
            return (a +| b) -| c;
        }
    };
}
/// The low bits of the 128 bit pattern as a T (two's complement for signed types).
fn fromBits(comptime T: type, bits: u128) T {
    const U = @Int(.unsigned, @typeInfo(T).int.bits);
    const low: U = @truncate(bits);
    return @bitCast(low);
}
// ---- reference ---------------------------------------------------------------------------------
fn clampTo(comptime T: type, exact: i128) T {
    const lo: i128 = std.math.minInt(T);
    const hi: i128 = std.math.maxInt(T);
    const r = if (exact < lo) lo else if (exact > hi) hi else exact;
    return fromBits(T, @bitCast(r));
}
fn refShl(comptime T: type, a: T, s: u7) T {
    // |a| < 2^63 and s < 64 keep the exact result within an i128 (u64 << 63 < 2^127).
    const exact: i128 = @as(i128, a) << @as(u7, s);
    return clampTo(T, exact);
}
fn edgeValues(comptime T: type, out: *[24]T) usize {
    const lo: i128 = std.math.minInt(T);
    const hi: i128 = std.math.maxInt(T);
    const candidates = [_]i128{ 0, 1, 2, 3, -1, -2, -3, hi, hi - 1, hi - 2, @divTrunc(hi, 2), @divTrunc(hi, 2) + 1, lo, lo + 1, lo + 2, @divTrunc(lo, 2), @divTrunc(lo, 2) - 1, hi - @divTrunc(hi, 3), 5, 100, 127, 128, 255, 256 };
    var n: usize = 0;
    for (candidates) |c| {
        if (c < lo or c > hi) continue;
        out[n] = fromBits(T, @bitCast(c));
        n += 1;
    }
    return n;
}
fn randomValue(comptime T: type) T {
    const r = nextRandom();
    // a random value of a random bit length, so that both small and large magnitudes occur
    const len: u6 = @truncate(nextRandom() >> 58);
    const shifted = r >> len;
    return fromBits(T, shifted);
}
// ---- checks ------------------------------------------------------------------------------------
fn checkPair(comptime T: type, a: T, b: T) void {
    const O = Ops(T);
    const name = @typeName(T);
    const exact_sum: i128 = @as(i128, a) + @as(i128, b);
    const exact_diff: i128 = @as(i128, a) - @as(i128, b);
    if (O.add(a, b) == clampTo(T, exact_sum)) pass() else fail(name, "add");
    if (O.sub(a, b) == clampTo(T, exact_diff)) pass() else fail(name, "sub");
    if (comptime @typeInfo(T).int.bits > 1) {
        // the shift amount: the low bits of b, always below the bit count
        const s: std.math.Log2Int(T) = @truncate(@as(@Int(.unsigned, @typeInfo(T).int.bits), @bitCast(b)));
        if (O.shl(a, s) == refShl(T, a, s)) pass() else fail(name, "shl");
    }
}
fn checkType(comptime T: type) void {
    const O = Ops(T);
    const name = @typeName(T);
    var edges: [24]T = undefined;
    const n = edgeValues(T, &edges);
    for (edges[0..n]) |a| {
        for (edges[0..n]) |b| checkPair(T, a, b);
        // same Value on both sides
        if (O.addSame(a) == clampTo(T, @as(i128, a) + @as(i128, a))) pass() else fail(name, "add_same");
    }
    // every shift amount for every edge value
    if (comptime @typeInfo(T).int.bits > 1) {
        const max_shift: usize = @typeInfo(T).int.bits - 1;
        for (edges[0..n]) |a| {
            var s: usize = 0;
            while (s <= max_shift) : (s += 1) {
                const amount: std.math.Log2Int(T) = @truncate(s);
                if (O.shl(a, amount) == refShl(T, a, amount)) pass() else fail(name, "shl_all");
            }
        }
    }
    var i: usize = 0;
    while (i < 96) : (i += 1) {
        const a = randomValue(T);
        const b = randomValue(T);
        const c = randomValue(T);
        checkPair(T, a, b);
        const want = clampTo(T, @as(i128, clampTo(T, @as(i128, a) + @as(i128, b))) - @as(i128, c));
        if (O.chain(a, b, c) == want) pass() else fail(name, "chain");
    }
}
fn runAll() void {
    // 2...31 bit, below the word size
    checkType(u2);
    checkType(i2);
    checkType(u3);
    checkType(i3);
    checkType(u7);
    checkType(i7);
    checkType(u8);
    checkType(i8);
    checkType(u9);
    checkType(i9);
    checkType(u15);
    checkType(i15);
    checkType(u16);
    checkType(i16);
    checkType(u17);
    checkType(i17);
    checkType(u24);
    checkType(i24);
    checkType(u31);
    checkType(i31);
    // 32 bit: the word size (control for add and subtract)
    checkType(u32);
    checkType(i32);
    // 33...63 bit, below the doubleword size
    checkType(u33);
    checkType(i33);
    checkType(u40);
    checkType(i40);
    checkType(u47);
    checkType(i47);
    checkType(u63);
    checkType(i63);
    // 64 bit
    checkType(u64);
    checkType(i64);
    checkType(u1);
    checkType(i1);
}
test "the reference agrees with the compiler's saturating arithmetic" {
    runAll();
    try std.testing.expectEqual(@as(u32, 0), failed_cases);
    try std.testing.expect(checked_cases > 10_000);
}
