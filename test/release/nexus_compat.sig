const std = @import("std");

export fn nexusArrayRepeatProbe() u8 {
    const values: [8]u8 = [_]u8{ 0x53, 0x42 } ** 4;
    return values[7];
}

test "Nexus-style fixed array repetition" {
    const values: [8]u8 = [_]u8{ 0x53, 0x42 } ** 4;
    try std.testing.expectEqualSlices(u8, "SBSBSBSB", &values);
}
