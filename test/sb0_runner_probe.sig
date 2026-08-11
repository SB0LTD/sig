const builtin = @import("builtin");

comptime {
    if (!builtin.target.isSb0()) @compileError("runner probe requires aarch64-sb0");
}

/// QEMU's `virt` PL011 is used only as the observable device boundary for the
/// native runner gate. The image has no host ABI, libc, allocator, startup
/// object, or foreign executable wrapper.
pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\  mov x9, #0x09000000
        \\  mov w10, #'S'
        \\  strb w10, [x9]
        \\  mov w10, #'B'
        \\  strb w10, [x9]
        \\  mov w10, #'0'
        \\  strb w10, [x9]
        \\  mov w10, #'-'
        \\  strb w10, [x9]
        \\  mov w10, #'R'
        \\  strb w10, [x9]
        \\  mov w10, #'U'
        \\  strb w10, [x9]
        \\  mov w10, #'N'
        \\  strb w10, [x9]
        \\  mov w10, #'N'
        \\  strb w10, [x9]
        \\  mov w10, #'E'
        \\  strb w10, [x9]
        \\  mov w10, #'R'
        \\  strb w10, [x9]
        \\  mov w10, #'-'
        \\  strb w10, [x9]
        \\  mov w10, #'P'
        \\  strb w10, [x9]
        \\  mov w10, #'A'
        \\  strb w10, [x9]
        \\  mov w10, #'S'
        \\  strb w10, [x9]
        \\  mov w10, #'S'
        \\  strb w10, [x9]
        \\  mov w10, #10
        \\  strb w10, [x9]
        \\1:
        \\  wfe
        \\  b 1b
    );
}
