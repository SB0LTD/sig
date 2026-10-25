//! Host tests of the big-integer helpers: every operation of `bigint.sig` is compared with the compiler's own
//! arithmetic on the same width for edge values and pseudo-random values, signed and unsigned.
const std = @import("std");
const testing = std.testing;
const bigint = @import("bigint.sig");

const Limbs = [16]u64;

fn Int(comptime signed: bool, comptime bits: u16) type {
    return @Int(if (signed) .signed else .unsigned, bits);
}

fn toLimbs(comptime T: type, v: T) Limbs {
    const info = @typeInfo(T).int;
    if (info.signedness == .signed) {
        const wide: i1024 = v;
        return @bitCast(wide);
    }
    const wide: u1024 = v;
    return @bitCast(wide);
}

fn fromLimbs(comptime T: type, limbs: Limbs) T {
    const info = @typeInfo(T).int;
    if (info.signedness == .signed) {
        const wide: i1024 = @bitCast(limbs);
        return @truncate(wide);
    }
    const wide: u1024 = @bitCast(limbs);
    return @truncate(wide);
}

/// The helper wrote the value `expected` including the extension of its top limb.
fn expectLimbs(comptime T: type, expected: T, actual: Limbs) !void {
    const bits = @typeInfo(T).int.bits;
    const n = (bits + 63) / 64;
    const want = toLimbs(T, expected);
    try testing.expectEqualSlices(u64, want[0..n], actual[0..n]);
}

fn random(comptime T: type, rng: std.Random, index: usize) T {
    const bits = @typeInfo(T).int.bits;
    const Unsigned = Int(false, bits);
    const edge: T = switch (index) {
        0 => 0,
        1 => 1,
        2 => std.math.maxInt(T),
        3 => std.math.minInt(T),
        4 => @bitCast(@as(Unsigned, std.math.maxInt(Unsigned))),
        5 => @bitCast(@as(Unsigned, 1) << (bits - 1)),
        6 => @bitCast(@as(Unsigned, 1) << @min(63, bits - 1)),
        7 => @bitCast(@as(Unsigned, 1) << @min(64, bits - 1)),
        8 => @bitCast((@as(Unsigned, 1) << @min(64, bits - 1)) - 1),
        else => {
            // random bits with a random number of significant bits
            const keep = rng.intRangeAtMost(u16, 1, bits);
            const raw = rng.int(Unsigned);
            const masked: Unsigned = if (keep == bits) raw else raw & ((@as(Unsigned, 1) << @intCast(keep)) - 1);
            return @bitCast(masked);
        },
    };
    return edge;
}

const widths = .{ 129, 192, 256, 320, 512, 768, 1024 };

test "add sub mul and or xor not" {
    var prng = std.Random.DefaultPrng.init(1);
    const rng = prng.random();
    inline for (widths) |bits| inline for (.{ false, true }) |signed| {
        const T = Int(signed, bits);
        for (0..80) |k| {
            const x = random(T, rng, k % 20);
            const y = random(T, rng, (k / 3) % 24);
            var a = toLimbs(T, x);
            var b = toLimbs(T, y);
            // garbage above the top limb and in the unused bits must not matter
            const n = (bits + 63) / 64;
            if (bits % 64 != 0) {
                a[n - 1] ^= @as(u64, 0xa5a5_a5a5_a5a5_a5a5) << @intCast(bits % 64);
                b[n - 1] ^= @as(u64, 0x5a5a_5a5a_5a5a_5a5a) << @intCast(bits % 64);
            }
            const s: u32 = @intFromBool(signed);
            var r: Limbs = @splat(0xdead_beef_dead_beef);
            bigint.__addei4(&r, &a, &b, bits, s);
            try expectLimbs(T, x +% y, r);
            bigint.__subei4(&r, &a, &b, bits, s);
            try expectLimbs(T, x -% y, r);
            bigint.__mulei4(&r, &a, &b, bits, s);
            try expectLimbs(T, x *% y, r);
            bigint.__andei4(&r, &a, &b, bits, s);
            try expectLimbs(T, x & y, r);
            bigint.__orei4(&r, &a, &b, bits, s);
            try expectLimbs(T, x | y, r);
            bigint.__xorei4(&r, &a, &b, bits, s);
            try expectLimbs(T, x ^ y, r);
            bigint.__notei4(&r, &a, bits, s);
            try expectLimbs(T, ~x, r);
        }
    };
}

test "shifts" {
    var prng = std.Random.DefaultPrng.init(2);
    const rng = prng.random();
    inline for (widths) |bits| inline for (.{ false, true }) |signed| {
        const T = Int(signed, bits);
        const Shift = std.math.Log2Int(Int(false, bits));
        for (0..60) |k| {
            const x = random(T, rng, k % 20);
            const amount = rng.intRangeLessThan(u32, 0, bits);
            const a = toLimbs(T, x);
            var r: Limbs = @splat(0xdead_beef_dead_beef);
            const s: u32 = @intFromBool(signed);
            bigint.__shlei4(&r, &a, amount, bits, s);
            try expectLimbs(T, x << @as(Shift, @intCast(amount)), r);
            if (signed) bigint.__ashrei4(&r, &a, amount, bits, s) else bigint.__lshrei4(&r, &a, amount, bits, s);
            try expectLimbs(T, x >> @as(Shift, @intCast(amount)), r);
        }
    };
}

test "compare" {
    var prng = std.Random.DefaultPrng.init(3);
    const rng = prng.random();
    inline for (widths) |bits| inline for (.{ false, true }) |signed| {
        const T = Int(signed, bits);
        for (0..80) |k| {
            const x = random(T, rng, k % 20);
            const y = if (k % 5 == 0) x else random(T, rng, (k / 3) % 24);
            var a = toLimbs(T, x);
            const b = toLimbs(T, y);
            if (bits % 64 != 0) a[(bits + 63) / 64 - 1] ^= @as(u64, 0xff) << @intCast(bits % 64);
            const s: u32 = @intFromBool(signed);
            try testing.expectEqual(@intFromBool(x < y), bigint.__cmpei4(&a, &b, bits, s, 0));
            try testing.expectEqual(@intFromBool(x <= y), bigint.__cmpei4(&a, &b, bits, s, 1));
            try testing.expectEqual(@intFromBool(x == y), bigint.__cmpei4(&a, &b, bits, s, 2));
            try testing.expectEqual(@intFromBool(x >= y), bigint.__cmpei4(&a, &b, bits, s, 3));
            try testing.expectEqual(@intFromBool(x > y), bigint.__cmpei4(&a, &b, bits, s, 4));
            try testing.expectEqual(@intFromBool(x != y), bigint.__cmpei4(&a, &b, bits, s, 5));
        }
    };
}

test "division" {
    var prng = std.Random.DefaultPrng.init(4);
    const rng = prng.random();
    inline for (widths) |bits| inline for (.{ false, true }) |signed| {
        const T = Int(signed, bits);
        for (0..60) |k| {
            const x = random(T, rng, k % 20);
            var y = random(T, rng, (k / 3) % 24);
            // small divisors are the common case (digit extraction)
            if (k % 4 == 0) y = @intCast(rng.intRangeAtMost(u8, 1, 200));
            if (y == 0) y = 3;
            if (signed and x == std.math.minInt(T) and y == -1) y = 7;
            const a = toLimbs(T, x);
            const b = toLimbs(T, y);
            var r: Limbs = @splat(0xdead_beef_dead_beef);
            const s: u32 = @intFromBool(signed);
            bigint.__divtruncei4(&r, &a, &b, bits, s);
            try expectLimbs(T, @divTrunc(x, y), r);
            bigint.__divfloorei4(&r, &a, &b, bits, s);
            try expectLimbs(T, @divFloor(x, y), r);
            bigint.__remei4(&r, &a, &b, bits, s);
            try expectLimbs(T, @rem(x, y), r);
            if (!signed or y > 0) {
                bigint.__floormodei4(&r, &a, &b, bits, s);
                try expectLimbs(T, @mod(x, y), r);
            }
        }
    };
}

test "resize" {
    var prng = std.Random.DefaultPrng.init(5);
    const rng = prng.random();
    inline for (.{ 129, 192, 256, 512, 1024 }) |dst_bits| inline for (.{ 33, 64, 100, 128, 129, 192, 300, 512 }) |src_bits| inline for (.{ false, true }) |signed| {
        const Dst = Int(signed, dst_bits);
        const Src = Int(signed, src_bits);
        for (0..30) |k| {
            const x = random(Src, rng, k % 20);
            const a = toLimbs(Src, x);
            const s: u32 = @intFromBool(signed);
            var r: Limbs = @splat(0xdead_beef_dead_beef);
            if (dst_bits >= src_bits) {
                const want: Dst = x;
                bigint.__resizeei4(&r, dst_bits, s, &a, src_bits, s);
                try expectLimbs(Dst, want, r);
                if (src_bits <= 128) {
                    r = @splat(0xdead_beef_dead_beef);
                    bigint.__resize128ei4(&r, dst_bits, s, a[0], a[1], src_bits, s);
                    try expectLimbs(Dst, want, r);
                }
            }
            if (dst_bits < src_bits) {
                const want: Dst = @truncate(x);
                bigint.__resizeei4(&r, dst_bits, s, &a, src_bits, s);
                try expectLimbs(Dst, want, r);
            }
        }
    };
}

test "overflow" {
    var prng = std.Random.DefaultPrng.init(6);
    const rng = prng.random();
    inline for (widths) |bits| inline for (.{ false, true }) |signed| {
        const T = Int(signed, bits);
        for (0..120) |k| {
            const x = random(T, rng, k % 20);
            const y = random(T, rng, (k / 3) % 24);
            var a = toLimbs(T, x);
            const b = toLimbs(T, y);
            if (bits % 64 != 0) a[(bits + 63) / 64 - 1] ^= @as(u64, 0xff) << @intCast(bits % 64);
            var r: Limbs = @splat(0xdead_beef_dead_beef);
            var flag: c_int = 7;
            const add = @addWithOverflow(x, y);
            if (signed) bigint.__addoei4(&r, &a, &b, bits, &flag) else bigint.__uaddoei4(&r, &a, &b, bits, &flag);
            try expectLimbs(T, add[0], r);
            try testing.expectEqual(@as(c_int, add[1]), flag);
            const sub = @subWithOverflow(x, y);
            if (signed) bigint.__suboei4(&r, &a, &b, bits, &flag) else bigint.__usuboei4(&r, &a, &b, bits, &flag);
            try expectLimbs(T, sub[0], r);
            try testing.expectEqual(@as(c_int, sub[1]), flag);
            const mul = @mulWithOverflow(x, y);
            if (signed) bigint.__muloei4(&r, &a, &b, bits, &flag) else bigint.__umuloei4(&r, &a, &b, bits, &flag);
            try expectLimbs(T, mul[0], r);
            try testing.expectEqual(@as(c_int, mul[1]), flag);
        }
    };
}
