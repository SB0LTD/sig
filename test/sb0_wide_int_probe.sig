//! Native executable regression for aarch64-sb0 integers of 129...1024 bits (and the 128 bit `%`, `/`
//! forms that had no selection): `+%`, `-%`, `*%`, `/`, `%`, `@divFloor`, `@mod`, `<<`, `>>`, the six
//! comparisons, `&`, `|`, `^`, `~`, widening and narrowing casts, `@addWithOverflow`, `@subWithOverflow`,
//! `@mulWithOverflow` and `@shlWithOverflow`. The backend used to stop with `too big <op> <type>` (and
//! with a part-model error for 257...1024 bits), which is what the ZPM `numeric.sig`, `jsonb.sig` and
//! `exec.sig` need (u256/u512/u1024 decimal arithmetic, 128 bit `%`).
//!
//! Every type in `types` (signed and unsigned) is checked for every operation with edge operands (zero,
//! one, -1, min, max, powers of two and limb-boundary values) and pseudo-random operands of random bit
//! length. Expected values come from an independent reference in this file: schoolbook arithmetic on
//! little-endian `u32` limbs with a `u64` accumulator (long division one bit at a time), never a wide
//! integer operation. The operands and the results of the operations under test cross between typed
//! values and limbs only through their memory image (`std.mem.asBytes`), and all comparisons of results
//! compare images, so the code under test never judges itself. The same file runs as a host `test`
//! (published Sig 0.6.3, LLVM arithmetic on the same operations), which validates the reference.
//!
//! Also covered: operands that are constants or the same value on both sides, every consumer of the
//! overflow tuples (whole tuple through a `noinline` return, value only, flag only), a decimal digit
//! extraction loop on a u512 (10^k for k <= 150, `% 10`, `/ 10`) and a `[N]u1024` table read with by-value
//! loads at run-time indices.
//!
//! Built in ReleaseSmall only: the big-integer helpers (`__addei4`, ...) come from compiler_rt, and the
//! ReleaseSafe configuration of the other probes (`-fno-compiler-rt`) would need this file to export all
//! of them; `@intCast` in ReleaseSafe additionally has no selection above 64 bits.
//!
//! Build with -target aarch64-sb0 --script test/sb0_runner.ld and boot on QEMU virt. Success is the
//! runtime marker SB0-WIDE-PASS; the first mismatch of a (type, operation) prints
//! SB0-WIDE-FAIL <type> <op> and the PASS marker is then withheld.
const std = @import("std");
const builtin = @import("builtin");

const is_sb0 = builtin.cpu.arch == .aarch64;

pub const panic = if (is_sb0) std.debug.no_panic else std.debug.FullPanic(std.debug.defaultPanic);

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
        buf[i] = '0' + @as(u8, @intCast(v % 10));
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
            write("SB0-WIDE-FAIL mismatches=");
            writeDec(failed_cases);
            write("\n");
            park();
        }
        write("checked cases=");
        writeDec(checked_cases);
        write("\n");
        write("SB0-WIDE-PASS\n");
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
        write("SB0-WIDE-FAIL " ++ type_name ++ " " ++ op ++ "\n");
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

// ---- limb arithmetic of the reference (u32 limbs, u64 accumulators) -----------------------------
fn addLimbs(r: []u32, a: []const u32, b: []const u32) void {
    var carry: u64 = 0;
    for (r, 0..) |*out, i| {
        const sum = @as(u64, a[i]) + @as(u64, b[i]) + carry;
        out.* = @truncate(sum);
        carry = sum >> 32;
    }
}

fn subLimbs(r: []u32, a: []const u32, b: []const u32) void {
    var borrow: u64 = 0;
    for (r, 0..) |*out, i| {
        const diff = @as(u64, a[i]) -% @as(u64, b[i]) -% borrow;
        out.* = @truncate(diff);
        borrow = (diff >> 32) & 1;
    }
}

/// The low `r.len` limbs of `a * b`.
fn mulLimbs(r: []u32, a: []const u32, b: []const u32) void {
    @memset(r, 0);
    for (0..r.len) |i| {
        var carry: u64 = 0;
        var j: usize = 0;
        while (i + j < r.len) : (j += 1) {
            const cell = @as(u64, a[i]) * @as(u64, b[j]) + @as(u64, r[i + j]) + carry;
            r[i + j] = @truncate(cell);
            carry = cell >> 32;
        }
    }
}

fn compareUnsigned(a: []const u32, b: []const u32) i32 {
    var i = a.len;
    while (i > 0) {
        i -= 1;
        if (a[i] != b[i]) return if (a[i] < b[i]) -1 else 1;
    }
    return 0;
}

fn isZeroLimbs(a: []const u32) bool {
    for (a) |limb| if (limb != 0) return false;
    return true;
}

// ---- the reference for a type ------------------------------------------------------------------
/// Values of an integer type of `bits` bits as `n` canonical limbs: sign (or zero) extended, `n` large
/// enough for an exact product of two values.
fn Ref(comptime bits: u16, comptime signed: bool) type {
    return struct {
        const bit_count = bits;
        const n: usize = (2 * @as(usize, bits) + 31) / 32 + 2;
        /// Limbs needed by the magnitudes in the long division.
        const m: usize = (@as(usize, bits) + 31) / 32 + 1;
        const Limbs = [n]u32;

        fn extend(x_in: Limbs) Limbs {
            var x = x_in;
            const top = (bits - 1) / 32;
            const top_bit: u5 = @intCast((bits - 1) % 32);
            const negative = signed and ((x[top] >> top_bit) & 1) != 0;
            const keep: u32 = if (top_bit == 31) 0xffff_ffff else (@as(u32, 2) << top_bit) - 1;
            x[top] = (x[top] & keep) | (if (negative) ~keep else 0);
            var i = top + 1;
            while (i < n) : (i += 1) x[i] = if (negative) 0xffff_ffff else 0;
            return x;
        }

        fn isNegative(x: Limbs) bool {
            return signed and (x[n - 1] >> 31) != 0;
        }

        fn fits(x: Limbs) bool {
            return std.mem.eql(u32, &extend(x), &x);
        }

        fn add(a: Limbs, b: Limbs) Limbs {
            var r: Limbs = undefined;
            addLimbs(&r, &a, &b);
            return r;
        }

        fn sub(a: Limbs, b: Limbs) Limbs {
            var r: Limbs = undefined;
            subLimbs(&r, &a, &b);
            return r;
        }

        fn mul(a: Limbs, b: Limbs) Limbs {
            var r: Limbs = undefined;
            mulLimbs(&r, &a, &b);
            return r;
        }

        fn negate(a: Limbs) Limbs {
            const zero: Limbs = @splat(0);
            return sub(zero, a);
        }

        fn order(a: Limbs, b: Limbs) i32 {
            if (signed and isNegative(a) != isNegative(b)) return if (isNegative(a)) -1 else 1;
            return compareUnsigned(&a, &b);
        }

        fn shiftLeft(a: Limbs, amount: usize) Limbs {
            var r: Limbs = @splat(0);
            const limbs = amount / 32;
            const shift: u5 = @intCast(amount % 32);
            var i: usize = limbs;
            while (i < n) : (i += 1) {
                const src = i - limbs;
                var v: u32 = a[src] << shift;
                if (shift != 0 and src > 0) v |= a[src - 1] >> @intCast(32 - @as(u6, shift));
                r[i] = v;
            }
            return extend(r);
        }

        fn shiftRight(a: Limbs, amount: usize) Limbs {
            const fill: u32 = if (isNegative(a)) 0xffff_ffff else 0;
            var r: Limbs = undefined;
            const limbs = amount / 32;
            const shift: u5 = @intCast(amount % 32);
            for (0..n) |i| {
                const lo = if (i + limbs < n) a[i + limbs] else fill;
                const hi = if (i + limbs + 1 < n) a[i + limbs + 1] else fill;
                r[i] = if (shift == 0) lo else (lo >> shift) | (hi << @intCast(32 - @as(u6, shift)));
            }
            return r;
        }

        fn bit(a: []const u32, index: usize) u32 {
            return (a[index / 32] >> @intCast(index % 32)) & 1;
        }

        /// Magnitude long division, one bit at a time.
        fn divideMagnitudes(num: Limbs, den: Limbs) struct { q: Limbs, r: Limbs } {
            var q: Limbs = @splat(0);
            var r: Limbs = @splat(0);
            var i: usize = bits + 1;
            while (i > 0) {
                i -= 1;
                // r = (r << 1) | bit i of num, on the first m limbs
                var carry: u32 = bit(&num, i);
                for (0..m) |k| {
                    const next_carry = r[k] >> 31;
                    r[k] = (r[k] << 1) | carry;
                    carry = next_carry;
                }
                if (compareUnsigned(r[0..m], den[0..m]) >= 0) {
                    var d: [m]u32 = undefined;
                    subLimbs(&d, r[0..m], den[0..m]);
                    @memcpy(r[0..m], &d);
                    q[i / 32] |= @as(u32, 1) << @intCast(i % 32);
                }
            }
            return .{ .q = q, .r = r };
        }

        const Division = struct { trunc: Limbs, floor: Limbs, rem: Limbs, mod: Limbs };

        /// `b` must not be zero (and `a / b` must fit, which excludes min / -1).
        fn divide(a: Limbs, b: Limbs) Division {
            const a_negative = isNegative(a);
            const b_negative = isNegative(b);
            const mag = divideMagnitudes(if (a_negative) negate(a) else a, if (b_negative) negate(b) else b);
            const q_trunc = if (a_negative != b_negative) negate(mag.q) else mag.q;
            const one: Limbs = blk: {
                var o: Limbs = @splat(0);
                o[0] = 1;
                break :blk o;
            };
            const q_floor = if (a_negative != b_negative and !isZeroLimbs(&mag.r)) sub(q_trunc, one) else q_trunc;
            return .{
                .trunc = q_trunc,
                .floor = q_floor,
                .rem = sub(a, mul(q_trunc, b)),
                .mod = sub(a, mul(q_floor, b)),
            };
        }

        fn fromBytes(bytes: []const u8) Limbs {
            var x: Limbs = @splat(0);
            for (0..(bits + 7) / 8) |i| x[i / 4] |= @as(u32, bytes[i]) << @intCast(8 * (i % 4));
            return extend(x);
        }
    };
}

/// The canonical limbs of the value `v`, read from its memory image.
fn limbsOf(comptime R: type, comptime T: type, v: T) R.Limbs {
    var copy = v;
    return R.fromBytes(std.mem.asBytes(&copy));
}

/// The value with the canonical limbs `x`, written to memory as a full image of the type.
fn valueOf(comptime R: type, comptime T: type, x: R.Limbs) T {
    var image: [@sizeOf(T)]u8 = undefined;
    for (0..@sizeOf(T)) |i| image[i] = @truncate(x[i / 4] >> @intCast(8 * (i % 4)));
    const loaded: *align(1) const T = @ptrCast(&image);
    return loaded.*;
}

// ---- operands ----------------------------------------------------------------------------------
fn setBit(comptime R: type, x: *R.Limbs, index: usize) void {
    x[index / 32] |= @as(u32, 1) << @intCast(index % 32);
}

fn edgeOperand(comptime R: type, pattern: usize) R.Limbs {
    const bits = R.bit_count;
    var x: R.Limbs = @splat(0);
    switch (pattern) {
        0 => {},
        1 => x[0] = 1,
        2 => x = @splat(0xffff_ffff), // -1, or the maximum of an unsigned type
        3 => for (0..bits - 1) |i| setBit(R, &x, i), // maxInt of a signed type
        4 => setBit(R, &x, bits - 1), // minInt of a signed type, 2^(bits-1) unsigned
        5 => x[2] = 1, // 2^64
        6 => {
            x[0] = 0xffff_ffff; // 2^64 - 1
            x[1] = 0xffff_ffff;
        },
        7 => x[1] = 1, // 2^32
        8 => {
            x[1] = 0x8000_0000; // 2^63
        },
        9 => x[0] = 10,
        10 => for (0..bits / 2) |i| setBit(R, &x, i), // 2^(bits/2) - 1
        else => setBit(R, &x, bits / 2), // 2^(bits/2)
    }
    return R.extend(x);
}

fn randomOperand(comptime R: type) R.Limbs {
    const bits = R.bit_count;
    var x: R.Limbs = @splat(0);
    const length: usize = 1 + nextRandom() % bits;
    for (0..length) |i| {
        if (i % 64 == 0) {
            const word = nextRandom();
            for (0..64) |j| {
                if (i + j < length and (word >> @intCast(j)) & 1 != 0) setBit(R, &x, i + j);
            }
        }
    }
    var y = R.extend(x);
    // negative about half of the time for signed types
    if (nextRandom() & 1 != 0) y = R.extend(R.negate(y));
    return y;
}

const edge_patterns = 12;
const edge_pairs = edge_patterns * 8;
const random_pairs = 64;
const total_pairs = edge_pairs + random_pairs;
/// The long division is slow; it runs for the edge pairs and a part of the random ones.
const division_pairs = edge_pairs + 24;

fn operands(comptime R: type, pair: usize) [2]R.Limbs {
    if (pair < edge_pairs) return .{ edgeOperand(R, pair % edge_patterns), edgeOperand(R, pair / edge_patterns) };
    return .{ randomOperand(R), randomOperand(R) };
}

// ---- operations under test ---------------------------------------------------------------------
fn Ops(comptime T: type) type {
    const bits = @typeInfo(T).int.bits;
    return struct {
        const Shift = std.math.Log2Int(@Int(.unsigned, bits));
        const Tuple = struct { T, u1 };
        noinline fn add(a: T, b: T) T {
            return a +% b;
        }
        noinline fn sub(a: T, b: T) T {
            return a -% b;
        }
        noinline fn mul(a: T, b: T) T {
            return a *% b;
        }
        noinline fn divTrunc(a: T, b: T) T {
            return @divTrunc(a, b);
        }
        noinline fn divFloor(a: T, b: T) T {
            return @divFloor(a, b);
        }
        noinline fn rem(a: T, b: T) T {
            return @rem(a, b);
        }
        noinline fn mod(a: T, b: T) T {
            return @mod(a, b);
        }
        noinline fn bitAnd(a: T, b: T) T {
            return a & b;
        }
        noinline fn bitOr(a: T, b: T) T {
            return a | b;
        }
        noinline fn bitXor(a: T, b: T) T {
            return a ^ b;
        }
        noinline fn bitNot(a: T) T {
            return ~a;
        }
        noinline fn shl(a: T, k: Shift) T {
            return a << k;
        }
        noinline fn shr(a: T, k: Shift) T {
            return a >> k;
        }
        noinline fn lt(a: T, b: T) bool {
            return a < b;
        }
        noinline fn lte(a: T, b: T) bool {
            return a <= b;
        }
        noinline fn eq(a: T, b: T) bool {
            return a == b;
        }
        noinline fn gte(a: T, b: T) bool {
            return a >= b;
        }
        noinline fn gt(a: T, b: T) bool {
            return a > b;
        }
        noinline fn neq(a: T, b: T) bool {
            return a != b;
        }
        noinline fn addo(a: T, b: T) Tuple {
            return @addWithOverflow(a, b);
        }
        noinline fn subo(a: T, b: T) Tuple {
            return @subWithOverflow(a, b);
        }
        noinline fn mulo(a: T, b: T) Tuple {
            return @mulWithOverflow(a, b);
        }
        noinline fn shlo(a: T, k: Shift) Tuple {
            return @shlWithOverflow(a, k);
        }
        noinline fn addoValue(a: T, b: T) T {
            return @addWithOverflow(a, b)[0];
        }
        noinline fn addoFlag(a: T, b: T) u1 {
            return @addWithOverflow(a, b)[1];
        }
        noinline fn suboValue(a: T, b: T) T {
            return @subWithOverflow(a, b)[0];
        }
        noinline fn suboFlag(a: T, b: T) u1 {
            return @subWithOverflow(a, b)[1];
        }
        noinline fn muloValue(a: T, b: T) T {
            return @mulWithOverflow(a, b)[0];
        }
        noinline fn muloFlag(a: T, b: T) u1 {
            return @mulWithOverflow(a, b)[1];
        }
        noinline fn shloFlag(a: T, k: Shift) u1 {
            return @shlWithOverflow(a, k)[1];
        }
        // constants on either side, and the same value on both sides
        noinline fn addConst(a: T) T {
            return a +% 12345;
        }
        noinline fn subConst(a: T) T {
            return 7 -% a;
        }
        noinline fn mulConst(a: T) T {
            return a *% 1000003;
        }
        noinline fn divConst(a: T) T {
            return @divTrunc(a, 10);
        }
        noinline fn remConst(a: T) T {
            return @rem(a, 10);
        }
        noinline fn ltConst(a: T) bool {
            return a < 12345;
        }
        noinline fn addSelf(a: T) T {
            return a +% a;
        }
        noinline fn mulSelf(a: T) T {
            return a *% a;
        }
        noinline fn subSelf(a: T) T {
            return a -% a;
        }
        noinline fn eqSelf(a: T) bool {
            return a == a;
        }
    };
}

fn sameImage(comptime R: type, comptime T: type, got: T, want: R.Limbs) bool {
    return std.mem.eql(u32, &limbsOf(R, T, got), &R.extend(want));
}

fn sameBool(got: bool, want: bool) bool {
    return got == want;
}

/// Runs every operation on `total_pairs` pairs of operands of `T`.
fn runType(comptime T: type) void {
    const info = @typeInfo(T).int;
    const bits = info.bits;
    const signed = info.signedness == .signed;
    const R = Ref(bits, signed);
    const O = Ops(T);
    const name = @typeName(T);
    var op_failed = [_]bool{false} ** 48;
    var pair: usize = 0;
    while (pair < total_pairs) : (pair += 1) {
        const pair_operands = operands(R, pair);
        const xa = pair_operands[0];
        const xb = pair_operands[1];
        const a = valueOf(R, T, xa);
        const b = valueOf(R, T, xb);
        const amount: usize = if (pair < edge_pairs) (pair * 7) % bits else nextRandom() % bits;
        const k: O.Shift = @intCast(amount);
        var index: usize = 0;

        // wrapping arithmetic
        check(R, T, name, "add", &op_failed, &index, sameImage(R, T, O.add(a, b), R.add(xa, xb)));
        check(R, T, name, "sub", &op_failed, &index, sameImage(R, T, O.sub(a, b), R.sub(xa, xb)));
        check(R, T, name, "mul", &op_failed, &index, sameImage(R, T, O.mul(a, b), R.mul(xa, xb)));
        // bitwise
        var and_want = xa;
        var or_want = xa;
        var xor_want = xa;
        var not_want = xa;
        for (0..R.n) |i| {
            and_want[i] = xa[i] & xb[i];
            or_want[i] = xa[i] | xb[i];
            xor_want[i] = xa[i] ^ xb[i];
            not_want[i] = ~xa[i];
        }
        check(R, T, name, "bit_and", &op_failed, &index, sameImage(R, T, O.bitAnd(a, b), and_want));
        check(R, T, name, "bit_or", &op_failed, &index, sameImage(R, T, O.bitOr(a, b), or_want));
        check(R, T, name, "xor", &op_failed, &index, sameImage(R, T, O.bitXor(a, b), xor_want));
        check(R, T, name, "not", &op_failed, &index, sameImage(R, T, O.bitNot(a), not_want));
        // shifts
        check(R, T, name, "shl", &op_failed, &index, sameImage(R, T, O.shl(a, k), R.shiftLeft(xa, amount)));
        check(R, T, name, "shr", &op_failed, &index, sameImage(R, T, O.shr(a, k), R.shiftRight(xa, amount)));
        // comparisons
        const ord = R.order(xa, xb);
        check(R, T, name, "cmp_lt", &op_failed, &index, sameBool(O.lt(a, b), ord < 0));
        check(R, T, name, "cmp_lte", &op_failed, &index, sameBool(O.lte(a, b), ord <= 0));
        check(R, T, name, "cmp_eq", &op_failed, &index, sameBool(O.eq(a, b), ord == 0));
        check(R, T, name, "cmp_gte", &op_failed, &index, sameBool(O.gte(a, b), ord >= 0));
        check(R, T, name, "cmp_gt", &op_failed, &index, sameBool(O.gt(a, b), ord > 0));
        check(R, T, name, "cmp_neq", &op_failed, &index, sameBool(O.neq(a, b), ord != 0));
        // overflow
        const exact_sum = R.add(xa, xb);
        const exact_diff = R.sub(xa, xb);
        const exact_prod = R.mul(xa, xb);
        const shifted_back = R.shiftRight(R.shiftLeft(xa, amount), amount);
        const sum_tuple = O.addo(a, b);
        const diff_tuple = O.subo(a, b);
        const prod_tuple = O.mulo(a, b);
        const shl_tuple = O.shlo(a, k);
        check(R, T, name, "add_with_overflow", &op_failed, &index, sameImage(R, T, sum_tuple[0], exact_sum) and sum_tuple[1] == @intFromBool(!R.fits(exact_sum)));
        check(R, T, name, "sub_with_overflow", &op_failed, &index, sameImage(R, T, diff_tuple[0], exact_diff) and diff_tuple[1] == @intFromBool(!R.fits(exact_diff)));
        check(R, T, name, "mul_with_overflow", &op_failed, &index, sameImage(R, T, prod_tuple[0], exact_prod) and prod_tuple[1] == @intFromBool(!R.fits(exact_prod)));
        check(R, T, name, "shl_with_overflow", &op_failed, &index, sameImage(R, T, shl_tuple[0], R.shiftLeft(xa, amount)) and
            shl_tuple[1] == @intFromBool(!std.mem.eql(u32, &shifted_back, &xa)));
        check(R, T, name, "overflow_value_only", &op_failed, &index, sameImage(R, T, O.addoValue(a, b), exact_sum) and
            sameImage(R, T, O.suboValue(a, b), exact_diff) and sameImage(R, T, O.muloValue(a, b), exact_prod));
        check(R, T, name, "overflow_flag_only", &op_failed, &index, O.addoFlag(a, b) == @intFromBool(!R.fits(exact_sum)) and
            O.suboFlag(a, b) == @intFromBool(!R.fits(exact_diff)) and O.muloFlag(a, b) == @intFromBool(!R.fits(exact_prod)) and
            O.shloFlag(a, k) == @intFromBool(!std.mem.eql(u32, &shifted_back, &xa)));
        // constants and the same value on both sides
        var small: R.Limbs = @splat(0);
        small[0] = 12345;
        var seven: R.Limbs = @splat(0);
        seven[0] = 7;
        var million: R.Limbs = @splat(0);
        million[0] = 1000003;
        var ten: R.Limbs = @splat(0);
        ten[0] = 10;
        const by_ten = R.divide(xa, ten);
        check(R, T, name, "const_operands", &op_failed, &index, sameImage(R, T, O.addConst(a), R.add(xa, small)) and
            sameImage(R, T, O.subConst(a), R.sub(seven, xa)) and sameImage(R, T, O.mulConst(a), R.mul(xa, million)) and
            sameImage(R, T, O.divConst(a), by_ten.trunc) and sameImage(R, T, O.remConst(a), by_ten.rem) and
            sameBool(O.ltConst(a), R.order(xa, small) < 0));
        check(R, T, name, "same_operand", &op_failed, &index, sameImage(R, T, O.addSelf(a), R.add(xa, xa)) and
            sameImage(R, T, O.mulSelf(a), R.mul(xa, xa)) and sameImage(R, T, O.subSelf(a), R.sub(xa, xa)) and O.eqSelf(a));
        // division
        if (pair < division_pairs and !isZeroLimbs(&xb)) {
            var minus_one: R.Limbs = @splat(0xffff_ffff);
            minus_one = R.extend(minus_one);
            const min_value = edgeOperand(R, 4);
            const overflows = signed and std.mem.eql(u32, &xa, &min_value) and std.mem.eql(u32, &xb, &minus_one);
            if (!overflows) {
                const d = R.divide(xa, xb);
                check(R, T, name, "div_trunc", &op_failed, &index, sameImage(R, T, O.divTrunc(a, b), d.trunc));
                check(R, T, name, "div_floor", &op_failed, &index, sameImage(R, T, O.divFloor(a, b), d.floor));
                check(R, T, name, "rem", &op_failed, &index, sameImage(R, T, O.rem(a, b), d.rem));
                if (!R.isNegative(xb)) check(R, T, name, "mod", &op_failed, &index, sameImage(R, T, O.mod(a, b), d.mod));
            }
        }
    }
}

/// Count one check and report the first failure of each operation of a type once.
fn check(
    comptime R: type,
    comptime T: type,
    comptime name: []const u8,
    comptime op: []const u8,
    op_failed: *[48]bool,
    index: *usize,
    ok: bool,
) void {
    _ = R;
    _ = T;
    const slot = index.*;
    index.* += 1;
    if (ok) {
        pass();
        return;
    }
    if (!op_failed[slot]) {
        op_failed[slot] = true;
        fail(name, op);
    } else {
        failed_cases += 1;
    }
}

// ---- casts -------------------------------------------------------------------------------------
fn castFrom(comptime Dst: type, comptime Src: type) void {
    const src_info = @typeInfo(Src).int;
    const dst_info = @typeInfo(Dst).int;
    const SR = Ref(src_info.bits, src_info.signedness == .signed);
    const DR = Ref(dst_info.bits, dst_info.signedness == .signed);
    const Cast = struct {
        noinline fn widen(x: Src) Dst {
            return x;
        }
        noinline fn narrow(x: Dst) Src {
            return @intCast(x);
        }
        noinline fn truncate(x: Dst) Src {
            return @truncate(x);
        }
    };
    var pair: usize = 0;
    while (pair < 96) : (pair += 1) {
        const xs = if (pair < 12) edgeOperand(SR, pair % edge_patterns) else randomOperand(SR);
        const s = valueOf(SR, Src, xs);
        // the same number in the destination type
        var xd: DR.Limbs = @splat(0);
        const fill: u32 = if (SR.isNegative(xs)) 0xffff_ffff else 0;
        for (0..DR.n) |i| xd[i] = if (i < SR.n) xs[i] else fill;
        xd = DR.extend(xd);
        const wide = Cast.widen(s);
        if (std.mem.eql(u32, &limbsOf(DR, Dst, wide), &xd)) pass() else fail(@typeName(Dst) ++ "<-" ++ @typeName(Src), "int_cast_widen");
        const back = Cast.narrow(wide);
        if (std.mem.eql(u32, &limbsOf(SR, Src, back), &xs)) pass() else fail(@typeName(Dst) ++ "->" ++ @typeName(Src), "int_cast_narrow");
        // truncation of an arbitrary destination value keeps the low bits
        const xr = randomOperand(DR);
        var low: SR.Limbs = @splat(0);
        for (0..SR.n) |i| low[i] = if (i < DR.n) xr[i] else 0;
        low = SR.extend(low);
        const truncated = Cast.truncate(valueOf(DR, Dst, xr));
        if (std.mem.eql(u32, &limbsOf(SR, Src, truncated), &low)) pass() else fail(@typeName(Dst) ++ "->" ++ @typeName(Src), "trunc");
    }
}

/// `@truncate` and `@intCast` between two wide types.
fn castWide(comptime Dst: type, comptime Src: type) void {
    const src_info = @typeInfo(Src).int;
    const dst_info = @typeInfo(Dst).int;
    const SR = Ref(src_info.bits, src_info.signedness == .signed);
    const DR = Ref(dst_info.bits, dst_info.signedness == .signed);
    const Cast = struct {
        noinline fn truncate(x: Src) Dst {
            return @truncate(x);
        }
    };
    var pair: usize = 0;
    while (pair < 64) : (pair += 1) {
        const xs = if (pair < 12) edgeOperand(SR, pair % edge_patterns) else randomOperand(SR);
        var low: DR.Limbs = @splat(0);
        for (0..DR.n) |i| low[i] = if (i < SR.n) xs[i] else 0;
        low = DR.extend(low);
        const got = Cast.truncate(valueOf(SR, Src, xs));
        if (std.mem.eql(u32, &limbsOf(DR, Dst, got), &low)) pass() else fail(@typeName(Src) ++ "->" ++ @typeName(Dst), "trunc");
    }
}

// ---- 128 bit remainder and division --------------------------------------------------------------
fn run128(comptime T: type) void {
    const info = @typeInfo(T).int;
    const signed = info.signedness == .signed;
    const R = Ref(info.bits, signed);
    const O = Ops(T);
    const name = @typeName(T);
    var op_failed = [_]bool{false} ** 48;
    var pair: usize = 0;
    while (pair < total_pairs) : (pair += 1) {
        const pair_operands = operands(R, pair);
        const xa = pair_operands[0];
        const xb = pair_operands[1];
        if (isZeroLimbs(&xb)) continue;
        const minus_one = R.extend(@as(R.Limbs, @splat(0xffff_ffff)));
        if (signed and std.mem.eql(u32, &xa, &edgeOperand(R, 4)) and std.mem.eql(u32, &xb, &minus_one)) continue;
        const a = valueOf(R, T, xa);
        const b = valueOf(R, T, xb);
        const d = R.divide(xa, xb);
        var index: usize = 0;
        check(R, T, name, "div_trunc", &op_failed, &index, sameImage(R, T, O.divTrunc(a, b), d.trunc));
        check(R, T, name, "div_floor", &op_failed, &index, sameImage(R, T, O.divFloor(a, b), d.floor));
        check(R, T, name, "rem", &op_failed, &index, sameImage(R, T, O.rem(a, b), d.rem));
        if (!R.isNegative(xb)) check(R, T, name, "mod", &op_failed, &index, sameImage(R, T, O.mod(a, b), d.mod));
    }
}

// ---- the shapes of the pin: decimal digit extraction and a table of u1024 -----------------------
noinline fn digitCount(value: u512, digits: *[160]u8) usize {
    var x = value;
    var count: usize = 0;
    while (x != 0) {
        digits[count] = @intCast(x % 10);
        x /= 10;
        count += 1;
    }
    return count;
}

fn powerOfTen(comptime R: type, k: usize) R.Limbs {
    var x: R.Limbs = @splat(0);
    x[0] = 1;
    var ten: R.Limbs = @splat(0);
    ten[0] = 10;
    for (0..k) |_| x = R.mul(x, ten);
    return x;
}

fn runDecimal() void {
    const R = Ref(512, false);
    var k: usize = 0;
    while (k <= 150) : (k += 1) {
        const value = valueOf(R, u512, powerOfTen(R, k));
        var digits: [160]u8 = undefined;
        const count = digitCount(value, &digits);
        var ok = count == k + 1 and digits[k] == 1;
        for (0..k) |i| {
            if (digits[i] != 0) ok = false;
        }
        if (ok) pass() else fail("u512", "decimal_digits");
    }
    // a number with all different digits: 123456789 repeated
    var x: R.Limbs = @splat(0);
    var ten: R.Limbs = @splat(0);
    ten[0] = 10;
    var expected: [90]u8 = undefined;
    for (0..90) |i| {
        // the most significant digit first
        const digit: u32 = @intCast(1 + i % 9);
        var d: R.Limbs = @splat(0);
        d[0] = digit;
        x = R.add(R.mul(x, ten), d);
        expected[89 - i] = @intCast(digit);
    }
    var digits: [160]u8 = undefined;
    const count = digitCount(valueOf(R, u512, x), &digits);
    if (count == 90 and std.mem.eql(u8, digits[0..90], &expected)) pass() else fail("u512", "decimal_mixed_digits");
}

const table_len = 24;
const wide_table: [table_len]u1024 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [table_len]u1024 = undefined;
    var v: u1024 = 1;
    for (&t) |*entry| {
        entry.* = v;
        v *= 10;
    }
    break :blk t;
};
var table_index: usize = 0;

noinline fn tableValue(index: usize) u1024 {
    return wide_table[index];
}

fn runTable() void {
    const R = Ref(1024, false);
    const volatile_index: *volatile usize = &table_index;
    var i: usize = 0;
    while (i < table_len) : (i += 1) {
        volatile_index.* = table_len - 1 - i;
        const idx = volatile_index.*;
        const loaded = wide_table[idx];
        const via_call = tableValue(idx);
        const want = powerOfTen(R, idx);
        if (sameImage(R, u1024, loaded, want) and sameImage(R, u1024, via_call, want)) pass() else fail("u1024", "table_load");
        // an element used in arithmetic right after the load
        const doubled = loaded +% wide_table[(idx + 1) % table_len];
        if (sameImage(R, u1024, doubled, R.add(want, powerOfTen(R, (idx + 1) % table_len)))) pass() else fail("u1024", "table_add");
    }
}

// ---- driver --------------------------------------------------------------------------------------
const types = .{ u129, u192, i192, u256, i256, u320, u512, i512, u1024, i1024 };

fn runAll() void {
    inline for (types) |T| runType(T);
    run128(u128);
    run128(i128);
    // widening from and narrowing to small types
    castFrom(u192, u32);
    castFrom(u256, u64);
    castFrom(u512, u64);
    castFrom(u512, u128);
    castFrom(u1024, u32);
    castFrom(u1024, u128);
    castFrom(u129, u64);
    castFrom(i192, i32);
    castFrom(i256, i64);
    castFrom(i512, i64);
    castFrom(i512, i128);
    castFrom(i1024, i32);
    castFrom(i1024, i128);
    castFrom(i129, i64);
    // between wide types of different limb counts
    castWide(u192, u512);
    castWide(u129, u256);
    castWide(u320, u1024);
    castWide(i192, i512);
    castWide(i129, i256);
    castWide(i320, i1024);
    runDecimal();
    runTable();
}

test "the reference agrees with the compiler's integer arithmetic" {
    runAll();
    try std.testing.expectEqual(@as(u32, 0), failed_cases);
    try std.testing.expect(checked_cases > 10_000);
}
