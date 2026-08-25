//! CodeGen tests for the x86_64 backend.

test {
    const builtin = @import("builtin");
    if (builtin.sig_backend != .stage2_x86_64) return error.SkipZigTest;
    // MachO linker does not support executables this big.
    if (builtin.object_format == .macho) return error.SkipZigTest;
    _ = @import("x86_64/access.sig");
    _ = @import("x86_64/binary.sig");
    _ = @import("x86_64/cast.sig");
    _ = @import("x86_64/unary.sig");
}
