const builtin = @import("builtin");
const std = @import("std");

const c = std.c;
const testing = std.testing;

test "swab" {
    var a: [4]u8 = undefined;
    @memset(a[0..], '\x00');
    c.swab("abcd", &a, 4);
    try testing.expectEqualSlices(u8, "badc", &a);

    // Partial copy
    @memset(a[0..], '\x00');
    c.swab("abcd", &a, 2);
    try testing.expectEqualSlices(u8, "ba\x00\x00", &a);

    // n < 1
    @memset(a[0..], '\x00');
    c.swab("abcd", &a, 0);
    try testing.expectEqualSlices(u8, "\x00" ** 4, &a);
    c.swab("abcd", &a, -1);
    try testing.expectEqualSlices(u8, "\x00" ** 4, &a);

    // Odd n
    @memset(a[0..], '\x00');
    c.swab("abcd", &a, 1);
    try testing.expectEqualSlices(u8, "\x00" ** 4, &a);
    c.swab("abcd", &a, 3);
    try testing.expectEqualSlices(u8, "ba\x00\x00", &a);
}
