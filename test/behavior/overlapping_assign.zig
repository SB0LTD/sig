const std = @import("std");
const expectEqualSlices = std.testing.expectEqualSlices;

test "assignment to overlapping memory" {
    try theTest();
    try comptime theTest();
}

fn theTest() !void {
    var a1: [3]usize = .{ 0, 1, 2 };
    a1[1..3].* = a1[0..2].*;
    try expectEqualSlices(usize, &.{ 0, 0, 1 }, &a1);

    var a2: [3]usize = .{ 0, 1, 2 };
    a2[0..2].* = a2[1..3].*;
    try expectEqualSlices(usize, &.{ 1, 2, 2 }, &a2);

    var a3: [16]u8 = .{
        0, 1, 2,  3,  4,  5,  6,  7,
        8, 9, 10, 11, 12, 13, 14, 15,
    };
    a3[1..16].* = a3[0..15].*;
    try expectEqualSlices(u8, &.{
        0, 0, 1, 2,  3,  4,  5,  6,
        7, 8, 9, 10, 11, 12, 13, 14,
    }, &a3);

    var a4: [16]u8 = .{
        0, 1, 2,  3,  4,  5,  6,  7,
        8, 9, 10, 11, 12, 13, 14, 15,
    };
    a4[0..15].* = a4[1..16].*;
    try expectEqualSlices(u8, &.{
        1, 2,  3,  4,  5,  6,  7,  8,
        9, 10, 11, 12, 13, 14, 15, 15,
    }, &a4);
}
