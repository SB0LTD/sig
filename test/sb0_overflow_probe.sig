//! Native executable regression for aarch64-sb0 `@addWithOverflow`, `@subWithOverflow`,
//! `@mulWithOverflow` and `@shlWithOverflow`.
//!
//! `@mulWithOverflow` and `@shlWithOverflow` had no instruction selection on this target
//! (`unimplemented mul_with_overflow`), signed `mul_safe` failed with `too big mul_safe iN`, and
//! the multi-limb add/sub-with-overflow of u96/u128/i128 returned through the caller's result buffer
//! overwrote a live operand register (the wrapped value of `1 + 0` was 0x1_0000_0000_0000_0001).
//!
//! Every width in `types` (signed and unsigned) is checked for every operation with edge operands
//! (zero, one, min, max, -1, half-width values, powers of two) and pseudo-random operands, against a
//! reference that uses only wrapping 32-bit limb arithmetic, comparisons and masks (no multiplication
//! builtin, no division, no shift builtin, no 128-bit multiply). Each pair is checked through
//! four consumers: the whole result tuple returned through a `noinline` function (the result buffer
//! path), the value only, the overflow bit only, and the same operand on both sides (`x op x`).
//! Constant operands and checked multiplication (`*` in ReleaseSafe) have their own checks. Vector operands are
//! not supported by this backend yet; `ci/test-sb0-native-backend.sh` checks that they are rejected with a diagnostic.
//!
//! In ReleaseSafe the build uses `-fno-compiler-rt`, so the probe exports the 65..128 bit multiply
//! helpers itself (backed by the same independent reference); ReleaseSmall links the real compiler_rt
//! helpers `__mulobi128`/`__umulobi128`, which makes that run the check of their implementation.
//!
//! Build with -target aarch64-sb0 --script test/sb0_runner.ld and boot on QEMU virt.
//! Success is the runtime marker SB0-OVF-PASS; every first mismatch of a (type, operation) prints
//! SB0-OVF-FAIL <type> <op> and the PASS marker is then withheld.
const std = @import("std");
const builtin = @import("builtin");
pub const panic = std.debug.no_panic;
comptime {
    if (builtin.mode == .safe) {
        @export(&testMemcpy, .{ .name = "memcpy" });
        @export(&testMemset, .{ .name = "memset" });
        @export(&testMulobi128, .{ .name = "__mulobi128" });
        @export(&testUmulobi128, .{ .name = "__umulobi128" });
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
fn testMulobi128(a: i128, b: i128, bits: c_uint, overflow: *c_int) callconv(.c) i128 {
    const r = refMul(true, @intCast(bits), @bitCast(a), @bitCast(b));
    overflow.* = @intFromBool(r.overflow);
    return @bitCast(r.value);
}
fn testUmulobi128(a: u128, b: u128, bits: c_uint, overflow: *c_int) callconv(.c) u128 {
    const r = refMul(false, @intCast(bits), a, b);
    overflow.* = @intFromBool(r.overflow);
    return r.value;
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
fn writeDec(value: u64) void {
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var v = value;
    while (true) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
        if (v == 0) break;
    }
    write(buf[i..]);
}
fn writeHex(value: u64) void {
    var i: u6 = 60;
    while (true) : (i -= 4) {
        const nibble: u8 = @intCast((value >> i) & 0xf);
        write(&[_]u8{if (nibble < 10) '0' + nibble else 'a' + nibble - 10});
        if (i == 0) break;
    }
}
fn writeHex128(value: u128) void {
    writeHex(@truncate(value >> 64));
    writeHex(@truncate(value));
}
fn park() noreturn {
    while (true) asm volatile ("wfe");
}

const Op = enum { add, sub, mul, shl };

// ---- reference ---------------------------------------------------------------------------------

const Ref = struct { value: u128, overflow: bool };

/// Bits 0..bits-1 set.
fn maskOf(bits: u16) u128 {
    if (bits >= 128) return ~@as(u128, 0);
    return (@as(u128, 1) << @intCast(bits)) -% 1;
}
/// The value wrapped to `bits` and extended to 128 bits according to the signedness.
fn extend(signed: bool, bits: u16, raw: u128) u128 {
    const mask = maskOf(bits);
    var v = raw & mask;
    if (signed and bits < 128 and (v & (mask ^ (mask >> 1))) != 0) v |= ~mask;
    return v;
}
fn isNegative(raw: u128) bool {
    return (raw >> 127) != 0;
}

/// 128 x 128 -> 256 bit unsigned product as eight 32-bit limbs (32 x 32 -> 64 bit products only).
fn mulWide(a: u128, b: u128) [8]u32 {
    var al: [4]u32 = undefined;
    var bl: [4]u32 = undefined;
    for (0..4) |i| {
        al[i] = @truncate(a >> @intCast(32 * i));
        bl[i] = @truncate(b >> @intCast(32 * i));
    }
    var r = [_]u32{0} ** 8;
    for (0..4) |i| {
        var carry: u64 = 0;
        for (0..4) |j| {
            const cur: u64 = @as(u64, r[i + j]) +% @as(u64, al[i]) *% @as(u64, bl[j]) +% carry;
            r[i + j] = @truncate(cur);
            carry = cur >> 32;
        }
        r[i + 4] = @truncate(carry);
    }
    return r;
}
fn limbs128(r: [8]u32, base: usize) u128 {
    var v: u128 = 0;
    for (0..4) |i| v |= @as(u128, r[base + i]) << @intCast(32 * i);
    return v;
}

/// `a` and `b` are the operands extended to 128 bits.
fn refMul(signed: bool, bits: u16, a: u128, b: u128) Ref {
    const negative = signed and (isNegative(a) != isNegative(b));
    const mag_a = if (signed and isNegative(a)) 0 -% a else a;
    const mag_b = if (signed and isNegative(b)) 0 -% b else b;
    const product = mulWide(mag_a, mag_b);
    const lo = limbs128(product, 0);
    const hi = limbs128(product, 4);
    const wrapped = if (negative) 0 -% lo else lo;
    var overflow = hi != 0;
    if (signed) {
        const limit: u128 = @as(u128, 1) << @intCast(bits - 1);
        if (negative) {
            if (lo > limit) overflow = true;
        } else if (lo >= limit) overflow = true;
    } else if (bits < 128 and (lo & ~maskOf(bits)) != 0) overflow = true;
    return .{ .value = extend(signed, bits, wrapped), .overflow = overflow };
}

fn refAdd(signed: bool, bits: u16, a: u128, b: u128) Ref {
    const sum = a +% b;
    const value = extend(signed, bits, sum);
    if (!signed) {
        if (bits == 128) return .{ .value = value, .overflow = sum < a };
        return .{ .value = value, .overflow = value != sum };
    }
    if (bits == 128) return .{ .value = value, .overflow = isNegative(a) == isNegative(b) and isNegative(sum) != isNegative(a) };
    return .{ .value = value, .overflow = value != sum };
}

fn refSub(signed: bool, bits: u16, a: u128, b: u128) Ref {
    const diff = a -% b;
    const value = extend(signed, bits, diff);
    if (!signed) return .{ .value = value, .overflow = a < b };
    if (bits == 128) return .{ .value = value, .overflow = isNegative(a) != isNegative(b) and isNegative(diff) != isNegative(a) };
    return .{ .value = value, .overflow = value != diff };
}

/// `a << amount` by repeated doubling. The overflow flag is set as soon as a doubling leaves the range
/// of the type, which is exactly when the mathematical result does not fit.
fn refShl(signed: bool, bits: u16, a: u128, amount: u8) Ref {
    var v = a;
    var overflow = false;
    var step: u8 = 0;
    while (step < amount) : (step += 1) {
        if (signed) {
            // Doubling fits iff -2^(bits-2) <= v < 2^(bits-2).
            const quarter: u128 = if (bits >= 2) @as(u128, 1) << @intCast(bits - 2) else 0;
            const v_negative = isNegative(v);
            if (bits < 2) {
                if (v != 0) overflow = true;
            } else if (v_negative) {
                if (v < 0 -% quarter) overflow = true;
            } else if (v >= quarter) overflow = true;
        } else if (v >= (@as(u128, 1) << @intCast(bits - 1))) {
            overflow = true;
        }
        v = extend(signed, bits, v +% v);
    }
    return .{ .value = extend(signed, bits, v), .overflow = overflow };
}

fn reference(comptime op: Op, signed: bool, bits: u16, a: u128, b: u128) Ref {
    return switch (op) {
        .add => refAdd(signed, bits, a, b),
        .sub => refSub(signed, bits, a, b),
        .mul => refMul(signed, bits, a, b),
        .shl => refShl(signed, bits, a, shiftAmount(bits, b)),
    };
}
/// The shift amount derived from the second operand: always below the bit width.
fn shiftAmount(bits: u16, raw: u128) u8 {
    return @as(u8, @truncate(raw)) % @as(u8, @intCast(bits));
}

// ---- operations under test ------------------------------------------------------------------------

fn Unsigned(comptime T: type) type {
    return @Int(.unsigned, @typeInfo(T).int.bits);
}
fn fromRaw(comptime T: type, raw: u128) T {
    return @bitCast(@as(Unsigned(T), @truncate(raw)));
}
fn widen(comptime T: type, v: T) u128 {
    // Sign- or zero-extended raw value as u128 (two's complement), for comparison only.
    const W = @Int(@typeInfo(T).int.signedness, 128);
    return @bitCast(@as(W, v));
}
fn amountOf(comptime T: type, b: T) std.math.Log2Int(T) {
    return @intCast(shiftAmount(@typeInfo(T).int.bits, widen(T, b)));
}

/// The whole result tuple, returned through the caller's result buffer.
noinline fn tuple(comptime T: type, comptime op: Op, a: T, b: T) struct { T, u1 } {
    return switch (op) {
        .add => @addWithOverflow(a, b),
        .sub => @subWithOverflow(a, b),
        .mul => @mulWithOverflow(a, b),
        .shl => @shlWithOverflow(a, amountOf(T, b)),
    };
}
noinline fn valueOnly(comptime T: type, comptime op: Op, a: T, b: T) T {
    return switch (op) {
        .add => @addWithOverflow(a, b)[0],
        .sub => @subWithOverflow(a, b)[0],
        .mul => @mulWithOverflow(a, b)[0],
        .shl => @shlWithOverflow(a, amountOf(T, b))[0],
    };
}
noinline fn flagOnly(comptime T: type, comptime op: Op, a: T, b: T) u1 {
    return switch (op) {
        .add => @addWithOverflow(a, b)[1],
        .sub => @subWithOverflow(a, b)[1],
        .mul => @mulWithOverflow(a, b)[1],
        .shl => @shlWithOverflow(a, amountOf(T, b))[1],
    };
}
/// Checked multiplication: with `ReleaseSafe` this is `mul_safe`, otherwise a plain `mul`.
noinline fn checkedMul(comptime T: type, a: T, b: T) T {
    return a * b;
}
/// One operand is a comptime-known constant.
noinline fn constRhs(comptime T: type, comptime op: Op, a: T) struct { T, u1 } {
    const c = comptime fromRaw(T, 3);
    return switch (op) {
        .add => @addWithOverflow(a, c),
        .sub => @subWithOverflow(a, c),
        .mul => @mulWithOverflow(a, c),
        .shl => @shlWithOverflow(a, amountOf(T, c)),
    };
}
noinline fn constLhs(comptime T: type, comptime op: Op, b: T) struct { T, u1 } {
    const c = comptime fromRaw(T, 5);
    return switch (op) {
        .add => @addWithOverflow(c, b),
        .sub => @subWithOverflow(c, b),
        .mul => @mulWithOverflow(c, b),
        .shl => @shlWithOverflow(c, amountOf(T, b)),
    };
}

// ---- driver ---------------------------------------------------------------------------------------

var rng_state: u64 = 0x9E3779B97F4A7C15;
fn nextRandom() u64 {
    rng_state ^= rng_state >> 12;
    rng_state ^= rng_state << 25;
    rng_state ^= rng_state >> 27;
    return rng_state *% 0x2545F4914F6CDD1D;
}

var checked_pairs: u32 = 0;
var failed_pairs: u32 = 0;
var group_failed: u32 = 0;

fn report(comptime T: type, comptime op: Op, consumer: []const u8, pair: u32, a: u128, b: u128, got: Ref, want: Ref) void {
    failed_pairs += 1;
    group_failed += 1;
    if (group_failed > 1) return; // only the first mismatch of a (type, operation) is listed
    write("SB0-OVF-FAIL ");
    write(@typeName(T));
    write(" ");
    write(@tagName(op));
    write(" ");
    write(consumer);
    write(" pair=");
    writeDec(pair);
    write(" a=0x");
    writeHex128(a);
    write(" b=0x");
    writeHex128(b);
    write(" overflow_got=");
    writeDec(@intFromBool(got.overflow));
    write(" overflow_want=");
    writeDec(@intFromBool(want.overflow));
    write(" got=0x");
    writeHex128(got.value);
    write(" want=0x");
    writeHex128(want.value);
    write("\n");
}

fn checkPair(comptime T: type, comptime op: Op, ra: u128, rb: u128, pair: u32) void {
    const info = @typeInfo(T).int;
    const signed = info.signedness == .signed;
    const a = fromRaw(T, ra);
    const b = fromRaw(T, rb);
    const wa = widen(T, a);
    const wb = widen(T, b);
    const want = reference(op, signed, info.bits, wa, wb);
    checked_pairs += 1;

    const t = tuple(T, op, a, b);
    const got: Ref = .{ .value = widen(T, t[0]), .overflow = t[1] != 0 };
    if (got.value != want.value or got.overflow != want.overflow) report(T, op, "tuple", pair, wa, wb, got, want);

    const v = valueOnly(T, op, a, b);
    if (widen(T, v) != want.value) report(T, op, "value", pair, wa, wb, .{ .value = widen(T, v), .overflow = want.overflow }, want);

    const f = flagOnly(T, op, a, b);
    if ((f != 0) != want.overflow) report(T, op, "flag", pair, wa, wb, .{ .value = want.value, .overflow = f != 0 }, want);

    // The same value on both sides.
    const want_same = reference(op, signed, info.bits, wa, wa);
    const s = tuple(T, op, a, a);
    const got_same: Ref = .{ .value = widen(T, s[0]), .overflow = s[1] != 0 };
    if (got_same.value != want_same.value or got_same.overflow != want_same.overflow)
        report(T, op, "same operand", pair, wa, wa, got_same, want_same);

    // Only pairs that do not overflow can be multiplied with `*` (an overflow would panic in ReleaseSafe).
    if (op == .mul and !want.overflow) {
        const m = checkedMul(T, a, b);
        if (widen(T, m) != want.value) report(T, op, "checked mul", pair, wa, wb, .{ .value = widen(T, m), .overflow = false }, want);
    }

    // A comptime-known operand on either side.
    const want_rhs = reference(op, signed, info.bits, wa, widen(T, comptime fromRaw(T, 3)));
    const cr = constRhs(T, op, a);
    const got_rhs: Ref = .{ .value = widen(T, cr[0]), .overflow = cr[1] != 0 };
    if (got_rhs.value != want_rhs.value or got_rhs.overflow != want_rhs.overflow)
        report(T, op, "const rhs", pair, wa, widen(T, comptime fromRaw(T, 3)), got_rhs, want_rhs);
    const want_lhs = reference(op, signed, info.bits, widen(T, comptime fromRaw(T, 5)), wb);
    const cl = constLhs(T, op, b);
    const got_lhs: Ref = .{ .value = widen(T, cl[0]), .overflow = cl[1] != 0 };
    if (got_lhs.value != want_lhs.value or got_lhs.overflow != want_lhs.overflow)
        report(T, op, "const lhs", pair, widen(T, comptime fromRaw(T, 5)), wb, got_lhs, want_lhs);
}

fn runGroup(comptime T: type, comptime op: Op) void {
    group_failed = 0;
    const bits = @typeInfo(T).int.bits;
    const top: u128 = @as(u128, 1) << @intCast(bits - 1);
    const half: u128 = @as(u128, 1) << @intCast(bits / 2);
    const raws = [_]u128{
        0,                1,                 2,    3,
        top,              top -% 1,          top +% 1,
        half,             half -% 1,         half +% 1,
        ~@as(u128, 0),    ~@as(u128, 0) - 1, // max unsigned / -1 / -2
        0x5555_5555_5555_5555_5555_5555_5555_5555,
        0xAAAA_AAAA_AAAA_AAAA_AAAA_AAAA_AAAA_AAAA,
    };
    var pair: u32 = 0;
    for (raws) |ra| for (raws) |rb| {
        checkPair(T, op, ra, rb, pair);
        pair += 1;
    };
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        const ra = (@as(u128, nextRandom()) << 64) | nextRandom();
        const rb = (@as(u128, nextRandom()) << 64) | nextRandom();
        checkPair(T, op, ra, rb, pair);
        pair += 1;
        // Half-width operands: far more non-overflowing cases for multiplication.
        checkPair(T, op, ra & (half -% 1), rb & (half -% 1), pair);
        pair += 1;
    }
}

const types = .{
    u1,   i1,   u2,   i2,   u7,   i7,   u8,   i8,   u9,   i9,   u16,  i16,
    u17,  i17,  u31,  i31,  u32,  i32,  u33,  i33,  u48,  i48,  u63,  i63,
    u64,  i64,  u65,  i65,  u100, i100, u127, i127, u128, i128,
};

export fn mainNative() callconv(.c) noreturn {
    const bytes: [*]u8 = @ptrCast(&__bss_start);
    const count = @intFromPtr(&__bss_end) - @intFromPtr(&__bss_start);
    for (0..count) |i| bytes[i] = 0;
    inline for (types) |T| {
        inline for (.{ Op.add, Op.sub, Op.mul, Op.shl }) |op| runGroup(T, op);
    }
    if (failed_pairs != 0) {
        write("SB0-OVF-FAIL mismatches=");
        writeDec(failed_pairs);
        write("\n");
        park();
    }
    write("checked pairs=");
    writeDec(checked_pairs);
    write("\n");
    write("SB0-OVF-PASS\n");
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
