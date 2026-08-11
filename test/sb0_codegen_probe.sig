const builtin = @import("builtin");
const std = @import("std");

comptime {
    if (builtin.target.cpu.arch != .aarch64) @compileError("SB0 must be AArch64");
    if (builtin.target.os.tag != .sb0) @compileError("SB0 OS identity was lost");
    if (builtin.target.abi != .sb0) @compileError("SB0 ABI identity was lost");
    if (builtin.target.ofmt != .raw) @compileError("SB0 must emit native raw bytes");
    if (!builtin.target.cpu.has(.aarch64, .reserve_x18)) @compileError("SB0 must reserve x18");
    if (!builtin.target.isSb0()) @compileError("SB0 target predicate failed");
}

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\1:
        \\  wfe
        \\  b 1b
    );
}

test "host parser sees the same SB0 contract" {
    const query = try std.Target.Query.parse(.{ .arch_os_abi = "aarch64-sb0" });
    const target = try std.zig.system.resolveTargetQuery(std.testing.io, query);
    try std.testing.expect(target.isSb0());
}
