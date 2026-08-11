const std = @import("std");

test "aarch64-sb0 target identity is native and reserves x18" {
    const query = try std.Target.Query.parse(.{
        .arch_os_abi = "aarch64-sb0",
        .cpu_features = "baseline-reserve_x18",
    });
    const target = try std.zig.system.resolveTargetQuery(std.testing.io, query);

    try std.testing.expectEqual(std.Target.Cpu.Arch.aarch64, target.cpu.arch);
    try std.testing.expectEqual(std.Target.Os.Tag.sb0, target.os.tag);
    try std.testing.expectEqual(std.Target.Abi.sb0, target.abi);
    try std.testing.expectEqual(std.Target.ObjectFormat.raw, target.ofmt);
    try std.testing.expect(target.dynamic_linker.get() == null);
    try std.testing.expect(target.cpu.has(.aarch64, .reserve_x18));
    try std.testing.expect(target.isSb0());
}

test "explicit aarch64-sb0-sb0 identity resolves" {
    const query = try std.Target.Query.parse(.{
        .arch_os_abi = "aarch64-sb0-sb0",
    });
    const target = try std.zig.system.resolveTargetQuery(std.testing.io, query);
    try std.testing.expect(target.isSb0());
}
