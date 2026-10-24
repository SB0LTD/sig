const std = @import("std");
const builtin = @import("builtin");
const math = std.math;
const compiler_rt = @import("../compiler_rt.sig");
const symbol = compiler_rt.symbol;

comptime {
    symbol(&__mulosi4, "__mulosi4");
    symbol(&__mulodi4, "__mulodi4");
    symbol(&__muloti4, "__muloti4");
    symbol(&__mulobi128, "__mulobi128");
    symbol(&__umulobi128, "__umulobi128");
}

// mulo - multiplication overflow
// * return a*%b.
// * return if a*b overflows => 1 else => 0
// - muloXi4_genericSmall as default
// - muloXi4_genericFast for 2*bitsize <= usize

inline fn muloXi4_genericSmall(comptime ST: type, a: ST, b: ST, overflow: *c_int) ST {
    overflow.* = 0;
    const min = math.minInt(ST);
    const res: ST = if (ST == i128 and builtin.target.cpu.arch.isWasm()) res: {
        // Despite compiler-rt being built with `-fno-builtin`, LLVM still converts this function to
        // a call to `__muloti4` on WASM. This is an upstream bug: circumvent it by directly calling
        // the "lower-level" compiler-rt routine for this wrapping multiplication.
        break :res @import("mulXi3.sig").__multi3(a, b);
    } else a *% b;
    // Hacker's Delight section Overflow subsection Multiplication
    // case a=-2^{31}, b=-1 problem, because
    // on some machines a*b = -2^{31} with overflow
    // Then -2^{31}/-1 overflows and any result is possible.
    // => check with a<0 and b=-2^{31}
    if ((a < 0 and b == min) or (a != 0 and @divTrunc(res, a) != b))
        overflow.* = 1;
    return res;
}

inline fn muloXi4_genericFast(comptime ST: type, a: ST, b: ST, overflow: *c_int) ST {
    overflow.* = 0;
    const EST = switch (ST) {
        i32 => i64,
        i64 => i128,
        i128 => i256,
        else => unreachable,
    };
    const min = math.minInt(ST);
    const max = math.maxInt(ST);
    const res: EST = @as(EST, a) * @as(EST, b);
    //invariant: -2^{bitwidth(EST)} < res < 2^{bitwidth(EST)-1}
    if (res < min or max < res)
        overflow.* = 1;
    return @as(ST, @truncate(res));
}

pub fn __mulosi4(a: i32, b: i32, overflow: *c_int) callconv(.c) i32 {
    if (2 * @bitSizeOf(i32) <= @bitSizeOf(usize)) {
        return muloXi4_genericFast(i32, a, b, overflow);
    } else {
        return muloXi4_genericSmall(i32, a, b, overflow);
    }
}

pub fn __mulodi4(a: i64, b: i64, overflow: *c_int) callconv(.c) i64 {
    if (2 * @bitSizeOf(i64) <= @bitSizeOf(usize)) {
        return muloXi4_genericFast(i64, a, b, overflow);
    } else {
        return muloXi4_genericSmall(i64, a, b, overflow);
    }
}

pub fn __muloti4(a: i128, b: i128, overflow: *c_int) callconv(.c) i128 {
    if (2 * @bitSizeOf(i128) <= @bitSizeOf(usize)) {
        return muloXi4_genericFast(i128, a, b, overflow);
    } else {
        return muloXi4_genericSmall(i128, a, b, overflow);
    }
}

/// Full unsigned 128-bit product of `a` and `b` (low 128 bits), `overflow` is set if it does not fit.
/// Built from 64-bit limb products only: no division and no wider integer type.
inline fn umulo128(a: u128, b: u128, overflow: *bool) u128 {
    const a_lo: u64 = @truncate(a);
    const a_hi: u64 = @truncate(a >> 64);
    const b_lo: u64 = @truncate(b);
    const b_hi: u64 = @truncate(b >> 64);
    // a * b = a_lo*b_lo + (a_lo*b_hi + a_hi*b_lo) << 64 + a_hi*b_hi << 128
    var overflowed = a_hi != 0 and b_hi != 0;
    // 64 x 64 -> 128 bit products cannot wrap; the operators are explicit so that a safe build
    // of this file never routes back into this helper.
    const low_product: u128 = @as(u128, a_lo) *% b_lo;
    const cross_a: u128 = @as(u128, a_lo) *% b_hi;
    const cross_b: u128 = @as(u128, a_hi) *% b_lo;
    // Each cross product lands at bit 64, so it has to fit in 64 bits, and so does their sum.
    if ((cross_a >> 64) != 0 or (cross_b >> 64) != 0) overflowed = true;
    const cross_a_lo: u64 = @truncate(cross_a);
    const cross_b_lo: u64 = @truncate(cross_b);
    const cross_sum = cross_a_lo +% cross_b_lo;
    if (cross_sum < cross_a_lo) overflowed = true;
    const shifted: u128 = @as(u128, cross_sum) << 64;
    const result = low_product +% shifted;
    if (result < low_product) overflowed = true;
    overflow.* = overflowed;
    return result;
}

/// Unsigned multiplication of two `bits`-bit integers (65 <= bits <= 128) given zero-extended to
/// 128 bits. Returns the product wrapped to `bits` bits and sets `*overflow` to 1 if it does not fit.
pub fn __umulobi128(a: u128, b: u128, bits: c_uint, overflow: *c_int) callconv(.c) u128 {
    var overflowed: bool = undefined;
    const product = umulo128(a, b, &overflowed);
    if (bits >= 128) {
        overflow.* = @intFromBool(overflowed);
        return product;
    }
    const shift: u7 = @intCast(128 - bits);
    const wrapped = (product << shift) >> shift;
    overflow.* = @intFromBool(overflowed or wrapped != product);
    return wrapped;
}

/// Signed multiplication of two `bits`-bit integers (65 <= bits <= 128) given sign-extended to
/// 128 bits. Returns the product wrapped to `bits` bits (sign-extended) and sets `*overflow` to 1 if
/// it does not fit.
pub fn __mulobi128(a: i128, b: i128, bits: c_uint, overflow: *c_int) callconv(.c) i128 {
    const a_bits: u128 = @bitCast(a);
    const b_bits: u128 = @bitCast(b);
    const negative = (a < 0) != (b < 0);
    const a_magnitude: u128 = if (a < 0) 0 -% a_bits else a_bits;
    const b_magnitude: u128 = if (b < 0) 0 -% b_bits else b_bits;
    var overflowed: bool = undefined;
    const magnitude = umulo128(a_magnitude, b_magnitude, &overflowed);
    // The low 128 bits of the signed product, wrapped.
    const product: u128 = if (negative) 0 -% magnitude else magnitude;
    // The magnitude has to fit i128: below 2^127 (and up to 2^127 itself when the product is negative).
    const limit: u128 = @as(u128, 1) << 127;
    if (magnitude > limit or (magnitude == limit and !negative)) overflowed = true;
    if (bits >= 128) {
        overflow.* = @intFromBool(overflowed);
        return @bitCast(product);
    }
    const shift: u7 = @intCast(128 - bits);
    const wrapped: i128 = @as(i128, @bitCast(product << shift)) >> shift;
    overflow.* = @intFromBool(overflowed or @as(u128, @bitCast(wrapped)) != product);
    return wrapped;
}

test {
    _ = @import("mulobi128_test.sig");
    _ = @import("mulosi4_test.sig");
    _ = @import("mulodi4_test.sig");
    _ = @import("muloti4_test.sig");
}
