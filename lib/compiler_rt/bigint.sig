//! Width-generic big-integer helpers for backends without inline lowerings of integers wider than 128
//! bits (the aarch64 backend lowers `add`, `sub`, `mul`, bitwise operations, shifts, division, comparison,
//! integer casts and the `*_with_overflow` operations of 129..1024 bit integers to calls of these functions).
//!
//! Operands and results are `bits`-bit integers stored as `(bits + 63) / 64` little-endian `u64` limbs in
//! caller-owned memory (the stack slots of the compiler's values). Only those limbs are read and written;
//! the padding that the ABI size of such a type may add is never touched. The bits of the top limb above
//! `bits` are ignored on input and written as the sign extension (`signed != 0`) or zero extension of the
//! value on output. There is no allocator and no recursion; scratch space is a fixed `[16]u64` on the stack,
//! which bounds `bits` to 1024.
//!
//! Division reuses the Knuth algorithm D of `udivmodei4.sig` (through a 32 bit limb view of these buffers).
const std = @import("std");
const builtin = @import("builtin");
const compiler_rt = @import("../compiler_rt.sig");
const udivmod = @import("udivmodei4.sig").divmod;
const symbol = compiler_rt.symbol;

comptime {
    symbol(&__addei4, "__addei4");
    symbol(&__subei4, "__subei4");
    symbol(&__mulei4, "__mulei4");
    symbol(&__andei4, "__andei4");
    symbol(&__orei4, "__orei4");
    symbol(&__xorei4, "__xorei4");
    symbol(&__notei4, "__notei4");
    symbol(&__shlei4, "__shlei4");
    symbol(&__lshrei4, "__lshrei4");
    symbol(&__ashrei4, "__ashrei4");
    symbol(&__cmpei4, "__cmpei4");
    symbol(&__divtruncei4, "__divtruncei4");
    symbol(&__divfloorei4, "__divfloorei4");
    symbol(&__remei4, "__remei4");
    symbol(&__floormodei4, "__floormodei4");
    symbol(&__resizeei4, "__resizeei4");
    symbol(&__resize128ei4, "__resize128ei4");
    symbol(&__uaddoei4, "__uaddoei4");
    symbol(&__addoei4, "__addoei4");
    symbol(&__usuboei4, "__usuboei4");
    symbol(&__suboei4, "__suboei4");
    symbol(&__umuloei4, "__umuloei4");
    symbol(&__muloei4, "__muloei4");
}

comptime {
    if (builtin.cpu.arch.endian() != .little) @compileError("bigint.sig: the 32 bit limb view of the division requires little endian");
}

/// The largest supported integer is 1024 bits.
const max_limbs = 16;
const Limbs = [max_limbs]u64;

inline fn limbCount(bits: u32) usize {
    return (@as(usize, bits) + 63) / 64;
}

/// The number of bits of the top limb that belong to the integer (1...64).
inline fn topBits(bits: u32) u32 {
    return bits - 64 * @as(u32, @intCast(limbCount(bits) - 1));
}

/// Replace the bits of the top limb above `bits` with the sign extension (or zeros) of the integer.
fn extendTop(x: *Limbs, bits: u32, signed: bool) void {
    const top = topBits(bits);
    if (top == 64) return;
    const n = limbCount(bits);
    const shift: u6 = @intCast(64 - top);
    if (signed) {
        x[n - 1] = @bitCast(@as(i64, @bitCast(x[n - 1] << shift)) >> shift);
    } else {
        x[n - 1] = (x[n - 1] << shift) >> shift;
    }
}

/// Read `bits` bits from `p`; the top limb is extended from bit `bits - 1`.
fn read(out: *Limbs, p: [*]const u64, bits: u32, signed: bool) void {
    const n = limbCount(bits);
    for (0..n) |i| out[i] = p[i];
    extendTop(out, bits, signed);
}

/// Write `x` (already holding the wrapped value in its low `bits` bits) to `p`.
fn write(p: [*]u64, x: *Limbs, bits: u32, signed: bool) void {
    extendTop(x, bits, signed);
    const n = limbCount(bits);
    for (0..n) |i| p[i] = x[i];
}

inline fn isNegative(x: *const Limbs, n: usize) bool {
    return (x[n - 1] >> 63) != 0;
}

fn isZero(x: *const Limbs, n: usize) bool {
    for (0..n) |i| if (x[i] != 0) return false;
    return true;
}

/// `x = -x` over `n` limbs.
fn negate(x: *Limbs, n: usize) void {
    var carry: u64 = 1;
    for (0..n) |i| {
        const v = ~x[i] +% carry;
        carry = @intFromBool(v < carry);
        x[i] = v;
    }
}

/// `r = a + b` over `n` limbs; returns the carry out of the top limb.
fn addLimbs(r: *Limbs, a: *const Limbs, b: *const Limbs, n: usize) u64 {
    var carry: u64 = 0;
    for (0..n) |i| {
        const s1 = a[i] +% b[i];
        const c1: u64 = @intFromBool(s1 < a[i]);
        const s2 = s1 +% carry;
        const c2: u64 = @intFromBool(s2 < s1);
        r[i] = s2;
        carry = c1 + c2;
    }
    return carry;
}

/// `r = a - b` over `n` limbs; returns the borrow out of the top limb.
fn subLimbs(r: *Limbs, a: *const Limbs, b: *const Limbs, n: usize) u64 {
    var borrow: u64 = 0;
    for (0..n) |i| {
        const d1 = a[i] -% b[i];
        const b1: u64 = @intFromBool(a[i] < b[i]);
        const d2 = d1 -% borrow;
        const b2: u64 = @intFromBool(d1 < borrow);
        r[i] = d2;
        borrow = b1 + b2;
    }
    return borrow;
}

const Wide = struct { lo: u64, hi: u64 };

/// The 128 bit product of two 64 bit values, built from 32 bit partial products.
inline fn mul64(a: u64, b: u64) Wide {
    const mask: u64 = 0xffff_ffff;
    const a0 = a & mask;
    const a1 = a >> 32;
    const b0 = b & mask;
    const b1 = b >> 32;
    const p00 = a0 * b0;
    const p01 = a0 * b1;
    const p10 = a1 * b0;
    const p11 = a1 * b1;
    const mid = (p00 >> 32) + (p01 & mask) + (p10 & mask);
    return .{
        .lo = (mid << 32) | (p00 & mask),
        .hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32),
    };
}

/// `r = (a * b) mod 2^(64 * n)`.
fn mulLow(r: *Limbs, a: *const Limbs, b: *const Limbs, n: usize) void {
    for (0..n) |i| r[i] = 0;
    for (0..n) |i| {
        var carry: u64 = 0;
        var j: usize = 0;
        while (i + j < n) : (j += 1) {
            const p = mul64(a[i], b[j]);
            var s = r[i + j] +% p.lo;
            var c: u64 = @intFromBool(s < p.lo);
            s +%= carry;
            c += @intFromBool(s < carry);
            r[i + j] = s;
            carry = p.hi +% c;
        }
    }
}

/// `prod = a * b` over `2 * n` limbs.
fn mulFull(prod: *[2 * max_limbs]u64, a: *const Limbs, b: *const Limbs, n: usize) void {
    for (0..2 * n) |i| prod[i] = 0;
    for (0..n) |i| {
        var carry: u64 = 0;
        for (0..n) |j| {
            const p = mul64(a[i], b[j]);
            var s = prod[i + j] +% p.lo;
            var c: u64 = @intFromBool(s < p.lo);
            s +%= carry;
            c += @intFromBool(s < carry);
            prod[i + j] = s;
            carry = p.hi +% c;
        }
        prod[i + n] = carry;
    }
}

// ---------------------------------------------------------------------------------------------------------
// Wrapping arithmetic and bitwise operations: `(res, a, b, bits, signed)`.

pub fn __addei4(res: [*]u64, a: [*]const u64, b: [*]const u64, bits: u32, signed: u32) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    var x: Limbs = undefined;
    var y: Limbs = undefined;
    var r: Limbs = undefined;
    const n = limbCount(bits);
    for (0..n) |i| {
        x[i] = a[i];
        y[i] = b[i];
    }
    _ = addLimbs(&r, &x, &y, n);
    write(res, &r, bits, signed != 0);
}

pub fn __subei4(res: [*]u64, a: [*]const u64, b: [*]const u64, bits: u32, signed: u32) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    var x: Limbs = undefined;
    var y: Limbs = undefined;
    var r: Limbs = undefined;
    const n = limbCount(bits);
    for (0..n) |i| {
        x[i] = a[i];
        y[i] = b[i];
    }
    _ = subLimbs(&r, &x, &y, n);
    write(res, &r, bits, signed != 0);
}

pub fn __mulei4(res: [*]u64, a: [*]const u64, b: [*]const u64, bits: u32, signed: u32) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    var x: Limbs = undefined;
    var y: Limbs = undefined;
    var r: Limbs = undefined;
    const n = limbCount(bits);
    for (0..n) |i| {
        x[i] = a[i];
        y[i] = b[i];
    }
    mulLow(&r, &x, &y, n);
    write(res, &r, bits, signed != 0);
}

pub fn __andei4(res: [*]u64, a: [*]const u64, b: [*]const u64, bits: u32, signed: u32) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    var r: Limbs = undefined;
    for (0..limbCount(bits)) |i| r[i] = a[i] & b[i];
    write(res, &r, bits, signed != 0);
}

pub fn __orei4(res: [*]u64, a: [*]const u64, b: [*]const u64, bits: u32, signed: u32) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    var r: Limbs = undefined;
    for (0..limbCount(bits)) |i| r[i] = a[i] | b[i];
    write(res, &r, bits, signed != 0);
}

pub fn __xorei4(res: [*]u64, a: [*]const u64, b: [*]const u64, bits: u32, signed: u32) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    var r: Limbs = undefined;
    for (0..limbCount(bits)) |i| r[i] = a[i] ^ b[i];
    write(res, &r, bits, signed != 0);
}

pub fn __notei4(res: [*]u64, a: [*]const u64, bits: u32, signed: u32) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    var r: Limbs = undefined;
    for (0..limbCount(bits)) |i| r[i] = ~a[i];
    write(res, &r, bits, signed != 0);
}

// ---------------------------------------------------------------------------------------------------------
// Shifts: `(res, a, amount, bits, signed)`. An amount of at least `bits` is illegal behavior; the result
// is then all zeros (all sign bits for an arithmetic shift of a negative value).

pub fn __shlei4(res: [*]u64, a: [*]const u64, amount: u32, bits: u32, signed: u32) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    var x: Limbs = undefined;
    var r: Limbs = undefined;
    const n = limbCount(bits);
    for (0..n) |i| x[i] = a[i];
    if (amount >= bits) {
        for (0..n) |i| r[i] = 0;
    } else {
        const limb_shift: usize = amount / 64;
        const bit_shift: u32 = amount % 64;
        var i = n;
        while (i > 0) {
            i -= 1;
            var v: u64 = 0;
            if (i >= limb_shift) {
                const src = i - limb_shift;
                if (bit_shift == 0) {
                    v = x[src];
                } else {
                    const left: u6 = @intCast(bit_shift);
                    const right: u6 = @intCast(64 - bit_shift);
                    v = x[src] << left;
                    if (src >= 1) v |= x[src - 1] >> right;
                }
            }
            r[i] = v;
        }
    }
    write(res, &r, bits, signed != 0);
}

fn shiftRight(res: [*]u64, a: [*]const u64, amount: u32, bits: u32, signed: bool) void {
    var x: Limbs = undefined;
    var r: Limbs = undefined;
    read(&x, a, bits, signed);
    const n = limbCount(bits);
    const fill: u64 = if (signed and isNegative(&x, n)) ~@as(u64, 0) else 0;
    if (amount >= bits) {
        for (0..n) |i| r[i] = fill;
    } else {
        const limb_shift: usize = amount / 64;
        const bit_shift: u32 = amount % 64;
        for (0..n) |i| {
            const src = i + limb_shift;
            const lo = if (src < n) x[src] else fill;
            const hi = if (src + 1 < n) x[src + 1] else fill;
            r[i] = if (bit_shift == 0) lo else blk: {
                const right: u6 = @intCast(bit_shift);
                const left: u6 = @intCast(64 - bit_shift);
                break :blk (lo >> right) | (hi << left);
            };
        }
    }
    write(res, &r, bits, signed);
}

/// Logical shift right of an unsigned integer.
pub fn __lshrei4(res: [*]u64, a: [*]const u64, amount: u32, bits: u32, signed: u32) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    _ = signed;
    shiftRight(res, a, amount, bits, false);
}

/// Arithmetic shift right of a signed integer.
pub fn __ashrei4(res: [*]u64, a: [*]const u64, amount: u32, bits: u32, signed: u32) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    _ = signed;
    shiftRight(res, a, amount, bits, true);
}

// ---------------------------------------------------------------------------------------------------------
// Comparison: `(a, b, bits, signed, op) -> 0 or 1`; `op` is a `std.math.CompareOperator` (lt, lte, eq, gte, gt, neq).

pub fn __cmpei4(a: [*]const u64, b: [*]const u64, bits: u32, signed: u32, op: u32) callconv(.c) u32 {
    @setRuntimeSafety(compiler_rt.test_safety);
    var x: Limbs = undefined;
    var y: Limbs = undefined;
    read(&x, a, bits, signed != 0);
    read(&y, b, bits, signed != 0);
    const n = limbCount(bits);
    // -1 (less), 0 (equal) or 1 (greater)
    var order: i32 = 0;
    var i = n;
    while (i > 0) {
        i -= 1;
        if (x[i] == y[i]) continue;
        const less = if (signed != 0 and i == n - 1)
            @as(i64, @bitCast(x[i])) < @as(i64, @bitCast(y[i]))
        else
            x[i] < y[i];
        order = if (less) -1 else 1;
        break;
    }
    const result = switch (op) {
        0 => order < 0,
        1 => order <= 0,
        2 => order == 0,
        3 => order >= 0,
        4 => order > 0,
        else => order != 0,
    };
    return @intFromBool(result);
}

// ---------------------------------------------------------------------------------------------------------
// Division: `(res, a, b, bits, signed)`. Division by zero is illegal behavior and yields 0.

const DivKind = enum { trunc, floor, rem, mod };

fn divide(res: [*]u64, a: [*]const u64, b: [*]const u64, bits: u32, signed_arg: u32, kind: DivKind) void {
    const signed = signed_arg != 0;
    var x: Limbs = undefined;
    var y: Limbs = undefined;
    read(&x, a, bits, signed);
    read(&y, b, bits, signed);
    const n = limbCount(bits);
    var out: Limbs = undefined;
    for (0..n) |i| out[i] = 0;
    if (isZero(&y, n)) {
        write(res, &out, bits, signed);
        return;
    }
    const a_negative = signed and isNegative(&x, n);
    const b_negative = signed and isNegative(&y, n);
    // Divide the magnitudes; the signs are applied afterwards.
    var x_mag = x;
    var y_mag = y;
    if (a_negative) negate(&x_mag, n);
    if (b_negative) negate(&y_mag, n);
    var q: Limbs = undefined;
    var r: Limbs = undefined;
    const u32_len = 2 * n;
    const q32: []u32 = @as([*]u32, @ptrCast(&q))[0..u32_len];
    const r32: []u32 = @as([*]u32, @ptrCast(&r))[0..u32_len];
    const x32: []const u32 = @as([*]const u32, @ptrCast(&x_mag))[0..u32_len];
    const y32: []const u32 = @as([*]const u32, @ptrCast(&y_mag))[0..u32_len];
    udivmod(q32, r32, x32, y32) catch {};
    const signs_differ = a_negative != b_negative;
    switch (kind) {
        .trunc => {
            out = q;
            if (signs_differ) negate(&out, n);
        },
        .floor => {
            out = q;
            if (signs_differ) {
                negate(&out, n);
                // The truncated quotient rounds towards zero; step down when there is a remainder.
                if (!isZero(&r, n)) {
                    var one: Limbs = undefined;
                    for (0..n) |i| one[i] = 0;
                    one[0] = 1;
                    _ = subLimbs(&out, &out, &one, n);
                }
            }
        },
        .rem => {
            out = r;
            if (a_negative) negate(&out, n);
        },
        .mod => {
            out = r;
            if (a_negative) negate(&out, n);
            // The result takes the sign of the divisor.
            if (signs_differ and !isZero(&out, n)) _ = addLimbs(&out, &out, &y, n);
        },
    }
    write(res, &out, bits, signed);
}

pub fn __divtruncei4(res: [*]u64, a: [*]const u64, b: [*]const u64, bits: u32, signed: u32) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    divide(res, a, b, bits, signed, .trunc);
}

pub fn __divfloorei4(res: [*]u64, a: [*]const u64, b: [*]const u64, bits: u32, signed: u32) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    divide(res, a, b, bits, signed, .floor);
}

pub fn __remei4(res: [*]u64, a: [*]const u64, b: [*]const u64, bits: u32, signed: u32) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    divide(res, a, b, bits, signed, .rem);
}

pub fn __floormodei4(res: [*]u64, a: [*]const u64, b: [*]const u64, bits: u32, signed: u32) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    divide(res, a, b, bits, signed, .mod);
}

// ---------------------------------------------------------------------------------------------------------
// Resizing (`@intCast`, `@truncate`): the value of the source (already extended from `src_bits`) is
// extended or cut to `dst_bits`.

fn resize(res: [*]u64, dst_bits: u32, dst_signed: bool, src: *const Limbs, src_bits: u32, src_signed: bool) void {
    const ns = limbCount(src_bits);
    const nd = limbCount(dst_bits);
    const fill: u64 = if (src_signed and isNegative(src, ns)) ~@as(u64, 0) else 0;
    var x: Limbs = undefined;
    for (0..nd) |i| x[i] = if (i < ns) src[i] else fill;
    write(res, &x, dst_bits, dst_signed);
}

/// `(res, dst_bits, dst_signed, src, src_bits, src_signed)` for a source in memory.
pub fn __resizeei4(res: [*]u64, dst_bits: u32, dst_signed: u32, src: [*]const u64, src_bits: u32, src_signed: u32) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    var x: Limbs = undefined;
    read(&x, src, src_bits, src_signed != 0);
    resize(res, dst_bits, dst_signed != 0, &x, src_bits, src_signed != 0);
}

/// `(res, dst_bits, dst_signed, lo, hi, src_bits, src_signed)` for a source of at most 128 bits held in two
/// registers (`hi` is ignored for at most 64 bits).
pub fn __resize128ei4(res: [*]u64, dst_bits: u32, dst_signed: u32, lo: u64, hi: u64, src_bits: u32, src_signed: u32) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    var x: Limbs = undefined;
    x[0] = lo;
    x[1] = hi;
    extendTop(&x, src_bits, src_signed != 0);
    resize(res, dst_bits, dst_signed != 0, &x, src_bits, src_signed != 0);
}

// ---------------------------------------------------------------------------------------------------------
// Operations with an overflow flag: `(res, a, b, bits, flag)`. `*flag` is set to 1 if the mathematical
// result does not fit `bits` bits; `res` always receives the wrapped result.

/// Whether bits `bits` and up of the top limb of `x` (an unextended `bits`-bit result) are set.
fn hasBitsAbove(x: *const Limbs, bits: u32) bool {
    const top = topBits(bits);
    if (top == 64) return false;
    const shift: u6 = @intCast(top);
    return (x[limbCount(bits) - 1] >> shift) != 0;
}

/// The bit `bits - 1` of the unextended `bits`-bit integer `x`.
fn signBit(x: *const Limbs, bits: u32) bool {
    const shift: u6 = @intCast(topBits(bits) - 1);
    return ((x[limbCount(bits) - 1] >> shift) & 1) != 0;
}

pub fn __uaddoei4(res: [*]u64, a: [*]const u64, b: [*]const u64, bits: u32, flag: *c_int) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    var x: Limbs = undefined;
    var y: Limbs = undefined;
    var r: Limbs = undefined;
    read(&x, a, bits, false);
    read(&y, b, bits, false);
    const carry = addLimbs(&r, &x, &y, limbCount(bits));
    flag.* = @intFromBool(carry != 0 or hasBitsAbove(&r, bits));
    write(res, &r, bits, false);
}

pub fn __addoei4(res: [*]u64, a: [*]const u64, b: [*]const u64, bits: u32, flag: *c_int) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    var x: Limbs = undefined;
    var y: Limbs = undefined;
    var r: Limbs = undefined;
    read(&x, a, bits, true);
    read(&y, b, bits, true);
    const n = limbCount(bits);
    _ = addLimbs(&r, &x, &y, n);
    const a_sign = isNegative(&x, n);
    flag.* = @intFromBool(a_sign == isNegative(&y, n) and signBit(&r, bits) != a_sign);
    write(res, &r, bits, true);
}

pub fn __usuboei4(res: [*]u64, a: [*]const u64, b: [*]const u64, bits: u32, flag: *c_int) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    var x: Limbs = undefined;
    var y: Limbs = undefined;
    var r: Limbs = undefined;
    read(&x, a, bits, false);
    read(&y, b, bits, false);
    const borrow = subLimbs(&r, &x, &y, limbCount(bits));
    flag.* = @intFromBool(borrow != 0);
    write(res, &r, bits, false);
}

pub fn __suboei4(res: [*]u64, a: [*]const u64, b: [*]const u64, bits: u32, flag: *c_int) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    var x: Limbs = undefined;
    var y: Limbs = undefined;
    var r: Limbs = undefined;
    read(&x, a, bits, true);
    read(&y, b, bits, true);
    const n = limbCount(bits);
    _ = subLimbs(&r, &x, &y, n);
    const a_sign = isNegative(&x, n);
    flag.* = @intFromBool(a_sign != isNegative(&y, n) and signBit(&r, bits) != a_sign);
    write(res, &r, bits, true);
}

pub fn __umuloei4(res: [*]u64, a: [*]const u64, b: [*]const u64, bits: u32, flag: *c_int) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    var x: Limbs = undefined;
    var y: Limbs = undefined;
    var prod: [2 * max_limbs]u64 = undefined;
    read(&x, a, bits, false);
    read(&y, b, bits, false);
    const n = limbCount(bits);
    mulFull(&prod, &x, &y, n);
    var overflowed = false;
    for (n..2 * n) |i| {
        if (prod[i] != 0) overflowed = true;
    }
    var r: Limbs = undefined;
    for (0..n) |i| r[i] = prod[i];
    if (hasBitsAbove(&r, bits)) overflowed = true;
    flag.* = @intFromBool(overflowed);
    write(res, &r, bits, false);
}

pub fn __muloei4(res: [*]u64, a: [*]const u64, b: [*]const u64, bits: u32, flag: *c_int) callconv(.c) void {
    @setRuntimeSafety(compiler_rt.test_safety);
    var x: Limbs = undefined;
    var y: Limbs = undefined;
    read(&x, a, bits, true);
    read(&y, b, bits, true);
    const n = limbCount(bits);
    // The wrapped result is the low half of the product of the two's complement values.
    var wrapped: Limbs = undefined;
    mulLow(&wrapped, &x, &y, n);
    // The mathematical product from the magnitudes: it fits iff it is below 2^(bits - 1), or equal to it
    // when the product is negative.
    const a_negative = isNegative(&x, n);
    const b_negative = isNegative(&y, n);
    if (a_negative) negate(&x, n);
    if (b_negative) negate(&y, n);
    var prod: [2 * max_limbs]u64 = undefined;
    mulFull(&prod, &x, &y, n);
    var overflowed = false;
    for (n..2 * n) |i| {
        if (prod[i] != 0) overflowed = true;
    }
    // Compare the low half with the limit 2^(bits - 1).
    const limit_limb = (bits - 1) / 64;
    const limit_bit: u6 = @intCast((bits - 1) % 64);
    var order: i32 = 0; // magnitude versus the limit
    var i = n;
    while (i > 0) {
        i -= 1;
        const limit: u64 = if (i == limit_limb) @as(u64, 1) << limit_bit else 0;
        if (prod[i] == limit) continue;
        order = if (prod[i] < limit) -1 else 1;
        break;
    }
    const negative_result = a_negative != b_negative;
    if (order > 0 or (order == 0 and !negative_result)) overflowed = true;
    flag.* = @intFromBool(overflowed);
    write(res, &wrapped, bits, true);
}

test {
    _ = @import("bigint_test.sig");
}
