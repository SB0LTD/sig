const builtin = @import("builtin");
const std = @import("std");

const c = std.c;
const fmt = std.fmt;
const math = std.math;
const testing = std.testing;

test "abs" {
    if (builtin.target.cpu.arch.isMIPS64()) return error.SkipZigTest; // TODO

    const val: c_int = -10;
    try testing.expectEqual(10, c.abs(val));
}

test "labs" {
    if (builtin.target.cpu.arch.isMIPS64() and @sizeOf(usize) == 4) return error.SkipZigTest; // TODO

    const val: c_long = -10;
    try testing.expectEqual(10, c.labs(val));
}

test "llabs" {
    const val: c_longlong = -10;
    try testing.expectEqual(10, c.llabs(val));
}

test "div" {
    if (builtin.target.cpu.arch.isLoongArch()) return error.SkipZigTest; // TODO
    if (builtin.target.cpu.arch.isMIPS64()) return error.SkipZigTest; // TODO
    if (builtin.target.cpu.arch.isPowerPC()) return error.SkipZigTest; // TODO
    if (builtin.target.cpu.arch == .s390x) return error.SkipZigTest; // TODO

    const expected: c.div_t = .{ .quot = 5, .rem = 5 };
    try testing.expectEqual(expected, c.div(55, 10));
}

test "ldiv" {
    if (builtin.target.cpu.arch.isMIPS64() and @sizeOf(usize) == 4) return error.SkipZigTest; // TODO
    if (builtin.target.cpu.arch.isPowerPC32()) return error.SkipZigTest; // TODO
    if (builtin.target.cpu.arch == .s390x) return error.SkipZigTest; // TODO

    const expected: c.ldiv_t = .{ .quot = -6, .rem = 2 };
    try testing.expectEqual(expected, c.ldiv(38, -6));
}

test "lldiv" {
    if (builtin.target.cpu.arch.isPowerPC32()) return error.SkipZigTest; // TODO
    if (builtin.target.cpu.arch == .s390x) return error.SkipZigTest; // TODO

    const expected: c.lldiv_t = .{ .quot = 1, .rem = 2 };
    try testing.expectEqual(expected, c.lldiv(5, 3));
}

test "atoi" {
    try testing.expectEqual(0, c.atoi(@ptrCast("stop42true")));
    try testing.expectEqual(42, c.atoi(@ptrCast("42true")));
    try testing.expectEqual(-1, c.atoi(@ptrCast("-01")));
    try testing.expectEqual(1, c.atoi(@ptrCast("+001")));
    try testing.expectEqual(100, c.atoi(@ptrCast("            100")));
    try testing.expectEqual(500, c.atoi(@ptrCast("000000000000500")));
    try testing.expectEqual(1111, c.atoi(@ptrCast("0000000000001111_0000")));
    try testing.expectEqual(0, c.atoi(@ptrCast("0xAA")));
    try testing.expectEqual(700, c.atoi(@ptrCast("700B")));
    try testing.expectEqual(32453, c.atoi(@ptrCast("+32453more")));
    try testing.expectEqual(math.maxInt(c_int), c.atoi(@ptrCast(fmt.comptimePrint("{d}", .{math.maxInt(c_int)}))));
    try testing.expectEqual(math.minInt(c_int), c.atoi(@ptrCast(fmt.comptimePrint("{d}", .{math.minInt(c_int)}))));
}

test "atol" {
    try testing.expectEqual(0, c.atol(@ptrCast("stop42true")));
    try testing.expectEqual(42, c.atol(@ptrCast("42true")));
    try testing.expectEqual(-1, c.atol(@ptrCast("-01")));
    try testing.expectEqual(1, c.atol(@ptrCast("+001")));
    try testing.expectEqual(100, c.atol(@ptrCast("            100")));
    try testing.expectEqual(500, c.atol(@ptrCast("000000000000500")));
    try testing.expectEqual(1111, c.atol(@ptrCast("0000000000001111_0000")));
    try testing.expectEqual(0, c.atol(@ptrCast("0xAA")));
    try testing.expectEqual(700, c.atol(@ptrCast("700B")));
    try testing.expectEqual(32453, c.atol(@ptrCast("+32453more")));
    try testing.expectEqual(math.maxInt(c_long), c.atol(@ptrCast(fmt.comptimePrint("{d}", .{math.maxInt(c_long)}))));
    try testing.expectEqual(math.minInt(c_long), c.atol(@ptrCast(fmt.comptimePrint("{d}", .{math.minInt(c_long)}))));
}

test "atoll" {
    try testing.expectEqual(0, c.atoll(@ptrCast("stop42true")));
    try testing.expectEqual(42, c.atoll(@ptrCast("42true")));
    try testing.expectEqual(-1, c.atoll(@ptrCast("-01")));
    try testing.expectEqual(1, c.atoll(@ptrCast("+001")));
    try testing.expectEqual(100, c.atoll(@ptrCast("            100")));
    try testing.expectEqual(500, c.atoll(@ptrCast("000000000000500")));
    try testing.expectEqual(1111, c.atoll(@ptrCast("0000000000001111_0000")));
    try testing.expectEqual(0, c.atoll(@ptrCast("0xAA")));
    try testing.expectEqual(700, c.atoll(@ptrCast("700B")));
    try testing.expectEqual(32453, c.atoll(@ptrCast("   +32453more")));
    try testing.expectEqual(math.maxInt(c_longlong), c.atoll(@ptrCast(fmt.comptimePrint("{d}", .{math.maxInt(c_longlong)}))));
    try testing.expectEqual(math.minInt(c_longlong), c.atoll(@ptrCast(fmt.comptimePrint("{d}", .{math.minInt(c_longlong)}))));
}

test "bsearch" {
    const Comparison = struct {
        pub fn compare(a: *const anyopaque, b: *const anyopaque) callconv(.c) c_int {
            const a_u16: *const u16 = @ptrCast(@alignCast(a));
            const b_u16: *const u16 = @ptrCast(@alignCast(b));

            return switch (math.order(a_u16.*, b_u16.*)) {
                .gt => 1,
                .eq => 0,
                .lt => -1,
            };
        }
    };

    const items: []const u16 = &.{ 0, 5, 7, 9, 10, 200, 512, 768 };

    try testing.expectEqual(@as(?*anyopaque, null), c.bsearch(&@as(u16, 2000), items.ptr, items.len, @sizeOf(u16), Comparison.compare));

    for (items) |*value| {
        try testing.expectEqual(@as(*const anyopaque, value), c.bsearch(value, items.ptr, items.len, @sizeOf(u16), Comparison.compare));
    }
}

test {
    _ = @import("stdlib/drand48.zig");
}
