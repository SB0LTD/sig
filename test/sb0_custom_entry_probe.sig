const builtin = @import("builtin");

comptime {
    if (!builtin.target.isSb0()) @compileError("custom entry probe requires SB0");
    if (builtin.target.ofmt != .raw) @compileError("SB0 must emit native raw bytes");
}

pub export fn _image_start() callconv(.naked) noreturn {
    asm volatile (
        \\1:
        \\  wfe
        \\  b 1b
    );
}
