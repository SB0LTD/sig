const std = @import("std");

test "native build runner isolates nested compiler caches" {
    const repeated = [_]u8{0x53, 0x42} ** 2;
    try std.testing.expectEqualSlices(u8, "SBSB", &repeated);
}
