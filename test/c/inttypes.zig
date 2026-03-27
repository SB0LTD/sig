const builtin = @import("builtin");
const std = @import("std");

const c = std.c;
const testing = std.testing;

test "imaxabs" {
    const val: c.intmax_t = -10;
    try testing.expectEqual(10, c.imaxabs(val));
}

test "imaxdiv" {
    const expected: c.imaxdiv_t = .{ .quot = 9, .rem = 0 };
    try testing.expectEqual(expected, c.imaxdiv(9, 1));
}
