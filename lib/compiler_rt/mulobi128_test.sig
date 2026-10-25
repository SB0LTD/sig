const mulo = @import("mulo.sig");
const testing = @import("std").testing;

fn testUnsigned(a: u128, b: u128, bits: c_uint, expected: u128, expected_overflow: c_int) !void {
    var overflow: c_int = undefined;
    const x = mulo.__umulobi128(a, b, bits, &overflow);
    try testing.expectEqual(expected_overflow, overflow);
    try testing.expectEqual(expected, x);
}

fn testSigned(a: i128, b: i128, bits: c_uint, expected: i128, expected_overflow: c_int) !void {
    var overflow: c_int = undefined;
    const x = mulo.__mulobi128(a, b, bits, &overflow);
    try testing.expectEqual(expected_overflow, overflow);
    try testing.expectEqual(expected, x);
}

test "umulobi128" {
    try testUnsigned(0, 0, 128, 0, 0);
    try testUnsigned(1, 1, 65, 1, 0);
    try testUnsigned(1 << 64, 1, 65, 1 << 64, 0);
    // 2^64 * 2^64 = 2^128 does not fit 128 bits; the wrapped value is 0.
    try testUnsigned(1 << 64, 1 << 64, 128, 0, 1);
    try testUnsigned(1 << 64, 1 << 63, 128, 1 << 127, 0);
    // Fits 128 bits but not 100 bits.
    try testUnsigned(1 << 64, 1 << 63, 100, 0, 1);
    try testUnsigned(1 << 64, 1 << 35, 100, 1 << 99, 0);
    try testUnsigned(1 << 64, 1 << 36, 100, 0, 1);
    try testUnsigned(std.math.maxInt(u128), 2, 128, std.math.maxInt(u128) - 1, 1);
    try testUnsigned(std.math.maxInt(u128), 1, 128, std.math.maxInt(u128), 0);
    try testUnsigned(std.math.maxInt(u64), std.math.maxInt(u64), 128, @as(u128, std.math.maxInt(u64)) * std.math.maxInt(u64), 0);
    // The cross terms alone fit 64 bits each but their sum carries out.
    try testUnsigned((@as(u128, 1) << 127) + 1, 2, 128, 2, 1);
    try testUnsigned((@as(u128, 3) << 64) + 5, (@as(u128, 3) << 64) + 7, 128, (@as(u128, 36) << 64) + 35, 1);
}

test "mulobi128" {
    try testSigned(0, 0, 128, 0, 0);
    try testSigned(-1, 1, 65, -1, 0);
    try testSigned(-1, -1, 128, 1, 0);
    try testSigned(std.math.minInt(i128), -1, 128, std.math.minInt(i128), 1);
    try testSigned(-1, std.math.minInt(i128), 128, std.math.minInt(i128), 1);
    try testSigned(std.math.minInt(i128), 1, 128, std.math.minInt(i128), 0);
    try testSigned(std.math.maxInt(i128), 2, 128, -2, 1);
    try testSigned(std.math.maxInt(i128), 1, 128, std.math.maxInt(i128), 0);
    try testSigned(std.math.minInt(i128), 2, 128, 0, 1);
    try testSigned(1 << 64, 1 << 62, 128, 1 << 126, 0);
    try testSigned(1 << 64, 1 << 63, 128, std.math.minInt(i128), 1);
    try testSigned(-(1 << 64), 1 << 63, 128, std.math.minInt(i128), 0);
    // Fits 128 bits but not 100 bits (signed range -2^99 .. 2^99 - 1).
    try testSigned(1 << 64, 1 << 35, 100, std.math.minInt(i128) >> 28, 1);
    try testSigned(1 << 64, 1 << 34, 100, 1 << 98, 0);
    try testSigned(-(1 << 64), 1 << 35, 100, -(1 << 99), 0);
    try testSigned(-(1 << 64), 1 << 36, 100, 0, 1);
}

const std = @import("std");