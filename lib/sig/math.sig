//! Pure Sig Math — zero-dependency mathematical functions.
//!
//! Replaces std.math for freestanding modules. Uses compiler builtins
//! (@sqrt, @exp, @log, @sin, @cos) where available, provides pure
//! implementations for everything else.
//!
//! All functions are comptime-evaluable and freestanding.

// ══════════════════════════════════════════════════════════════════════════════
// IEEE 754 Classification
// ══════════════════════════════════════════════════════════════════════════════

pub fn isFinite(x: f32) bool {
    const bits: u32 = @bitCast(x);
    return (bits & 0x7F800000) != 0x7F800000;
}

pub fn isFiniteF64(x: f64) bool {
    const bits: u64 = @bitCast(x);
    return (bits & 0x7FF0000000000000) != 0x7FF0000000000000;
}

pub fn isNan(x: f32) bool {
    const bits: u32 = @bitCast(x);
    return (bits & 0x7F800000) == 0x7F800000 and (bits & 0x007FFFFF) != 0;
}

pub fn isNanF64(x: f64) bool {
    const bits: u64 = @bitCast(x);
    return (bits & 0x7FF0000000000000) == 0x7FF0000000000000 and (bits & 0x000FFFFFFFFFFFFF) != 0;
}

pub fn isInf(x: f32) bool {
    const bits: u32 = @bitCast(x);
    return (bits & 0x7FFFFFFF) == 0x7F800000;
}

// ══════════════════════════════════════════════════════════════════════════════
// Transcendentals (compiler builtins)
// ══════════════════════════════════════════════════════════════════════════════

pub fn sqrt(x: f32) f32 {
    return @sqrt(x);
}

pub fn sqrtF64(x: f64) f64 {
    return @sqrt(x);
}

pub fn exp(x: f32) f32 {
    return @exp(x);
}

pub fn expF64(x: f64) f64 {
    return @exp(x);
}

pub fn log(x: f32) f32 {
    return @log(x);
}

pub fn logF64(x: f64) f64 {
    return @log(x);
}

pub fn sin(x: f32) f32 {
    return @sin(x);
}

pub fn cos(x: f32) f32 {
    return @cos(x);
}

/// tanh(x) = (exp(2x) - 1) / (exp(2x) + 1)
/// Clamped for large |x| to avoid overflow.
pub fn tanh(x: f32) f32 {
    if (x > 10.0) return 1.0;
    if (x < -10.0) return -1.0;
    const e2x = @exp(2.0 * x);
    return (e2x - 1.0) / (e2x + 1.0);
}

/// pow(base, exponent) = exp(exponent * log(base))
/// Handles special cases: base=0, negative base with integer exp.
pub fn pow(base: f32, exponent: f32) f32 {
    if (exponent == 0.0) return 1.0;
    if (base == 0.0) return 0.0;
    if (base == 1.0) return 1.0;
    if (base > 0.0) return @exp(exponent * @log(base));
    // Negative base: only valid for integer exponents
    const int_exp: i32 = @intFromFloat(exponent);
    const is_integer = @as(f32, @floatFromInt(int_exp)) == exponent;
    if (!is_integer) return 0.0 / @as(f32, 0.0); // NaN
    const magnitude = @exp(exponent * @log(-base));
    return if (@rem(int_exp, 2) != 0) -magnitude else magnitude;
}

// ══════════════════════════════════════════════════════════════════════════════
// Absolute Value
// ══════════════════════════════════════════════════════════════════════════════

pub fn absF32(x: f32) f32 {
    return @abs(x);
}

pub fn absF64(x: f64) f64 {
    return @abs(x);
}

pub fn absInt(comptime T: type, x: T) T {
    return if (x < 0) -x else x;
}

// ══════════════════════════════════════════════════════════════════════════════
// Integer Utilities
// ══════════════════════════════════════════════════════════════════════════════

/// Maximum value for an integer type.
pub fn maxInt(comptime T: type) T {
    const info = @typeInfo(T).int;
    if (info.signedness == .signed) {
        return (1 << (info.bits - 1)) - 1;
    } else {
        return ~@as(T, 0);
    }
}

/// Minimum value for an integer type.
pub fn minInt(comptime T: type) T {
    const info = @typeInfo(T).int;
    if (info.signedness == .signed) {
        return -maxInt(T) - 1;
    } else {
        return 0;
    }
}

/// Rotate left.
pub fn rotl(comptime T: type, x: T, comptime r: comptime_int) T {
    const bits = @typeInfo(T).int.bits;
    return (x << r) | (x >> (bits - r));
}

/// Rotate left for u64.
pub fn rotlU64(x: u64, r: u6) u64 {
    return (x << r) | (x >> (@as(u6, 64) - r));
}

/// Rotate left for u32.
pub fn rotlU32(x: u32, r: u5) u32 {
    return (x << r) | (x >> (@as(u5, 32) - r));
}

// ══════════════════════════════════════════════════════════════════════════════
// Clamping and Min/Max
// ══════════════════════════════════════════════════════════════════════════════

pub fn min(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return if (a < b) a else b;
}

pub fn max(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return if (a > b) a else b;
}

pub fn clamp(val: anytype, lower: @TypeOf(val), upper: @TypeOf(val)) @TypeOf(val) {
    return max(lower, min(val, upper));
}

// ══════════════════════════════════════════════════════════════════════════════
// Float Conversion
// ══════════════════════════════════════════════════════════════════════════════

pub fn floatFromInt(comptime T: type, val: anytype) T {
    return @floatFromInt(val);
}

pub fn intFromFloat(comptime T: type, val: anytype) T {
    return @intFromFloat(val);
}

// ══════════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════════

test "isFinite" {
    if (!isFinite(1.0)) return error.TestUnexpectedResult;
    if (!isFinite(-1.0e30)) return error.TestUnexpectedResult;
    if (isFinite(0.0 / @as(f32, 0.0))) return error.TestUnexpectedResult; // NaN
}

test "isNan" {
    if (isNan(1.0)) return error.TestUnexpectedResult;
    if (!isNan(0.0 / @as(f32, 0.0))) return error.TestUnexpectedResult;
}

test "sqrt" {
    if (@abs(sqrt(4.0) - 2.0) > 0.0001) return error.TestUnexpectedResult;
    if (@abs(sqrt(9.0) - 3.0) > 0.0001) return error.TestUnexpectedResult;
}

test "tanh bounds" {
    if (@abs(tanh(0.0)) > 0.0001) return error.TestUnexpectedResult;
    if (@abs(tanh(100.0) - 1.0) > 0.0001) return error.TestUnexpectedResult;
    if (@abs(tanh(-100.0) + 1.0) > 0.0001) return error.TestUnexpectedResult;
}

test "maxInt" {
    if (maxInt(u8) != 255) return error.TestUnexpectedResult;
    if (maxInt(u16) != 65535) return error.TestUnexpectedResult;
    if (maxInt(i8) != 127) return error.TestUnexpectedResult;
}
