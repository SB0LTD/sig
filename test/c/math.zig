const builtin = @import("builtin");
const std = @import("std");

const c = std.c;
const math = std.math;
const testing = std.testing;

fn testModf(comptime T: type) !void {
    const f = switch (T) {
        f32 => c.modff,
        f64 => c.modf,
        c_longdouble => c.modfl,
        else => unreachable,
    };

    var int: T = undefined;
    const iptr = &int;
    const eps_val: comptime_float = @max(1e-6, math.floatEps(T));

    const normal_frac = f(@as(T, 1234.567), iptr);
    // Account for precision error
    const expected = 1234.567 - @as(T, 1234);
    try testing.expectApproxEqAbs(expected, normal_frac, eps_val);
    try testing.expectApproxEqRel(@as(T, 1234.0), iptr.*, eps_val);

    // When `x` is a NaN, NaN is returned and `*iptr` is set to NaN
    const nan_frac = f(math.nan(T), iptr);
    try testing.expect(math.isNan(nan_frac));
    try testing.expect(math.isNan(iptr.*));

    // When `x` is positive infinity, +0 is returned and `*iptr` is set to
    // positive infinity
    const pos_zero_frac = f(math.inf(T), iptr);
    try testing.expect(math.isPositiveZero(pos_zero_frac));
    try testing.expect(math.isPositiveInf(iptr.*));

    // When `x` is negative infinity, -0 is returned and `*iptr` is set to
    // negative infinity
    const neg_zero_frac = f(-math.inf(T), iptr);
    try testing.expect(math.isNegativeZero(neg_zero_frac));
    try testing.expect(math.isNegativeInf(iptr.*));

    // Return -0 when `x` is a negative integer
    const nz_frac = f(@as(T, -1000.0), iptr);
    try testing.expect(math.isNegativeZero(nz_frac));
    try testing.expectEqual(@as(T, -1000.0), iptr.*);

    // Return +0 when `x` is a positive integer
    const pz_frac = f(@as(T, 1000.0), iptr);
    try testing.expect(math.isPositiveZero(pz_frac));
    try testing.expectEqual(@as(T, 1000.0), iptr.*);
}

test "modf" {
    try testModf(f32);
    try testModf(f64);
    try testModf(c_longdouble);
}

fn testRint(comptime T: type) !void {
    const f = switch (T) {
        f32 => c.rintf,
        f64 => c.rint,
        else => @compileError("rint not implemented for" ++ @typeName(T)),
    };

    // Positive numbers round correctly
    try testing.expectEqual(@as(T, 42.0), f(42.2));
    try testing.expectEqual(@as(T, 42.0), f(41.8));

    // Negative numbers round correctly
    try testing.expectEqual(@as(T, -6.0), f(-5.9));
    try testing.expectEqual(@as(T, -6.0), f(-6.1));

    // No rounding needed test
    try testing.expectEqual(@as(T, 5.0), f(5.0));
    try testing.expectEqual(@as(T, -10.0), f(-10.0));
    try testing.expectEqual(@as(T, 0.0), f(0.0));

    // Very large numbers return unchanged
    const large: T = 9007199254740992.0; // 2^53
    try testing.expectEqual(large, f(large));
    try testing.expectEqual(-large, f(-large));

    // Small positive numbers round to zero
    const pos_result = f(0.3);
    try testing.expect(math.isPositiveZero(pos_result));

    // Small negative numbers round to negative zero
    const neg_result = f(-0.3);
    try testing.expect(math.isNegativeZero(neg_result));

    // Exact half rounds to nearest even (banker's rounding)
    try testing.expectEqual(@as(T, 2.0), f(2.5));
    try testing.expectEqual(@as(T, 4.0), f(3.5));
}

test "rint" {
    try testRint(f32);
    try testRint(f64);
}
