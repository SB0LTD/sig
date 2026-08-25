const A = extern struct {
    field: c_int,
};

extern fn issue529(?*A) void;

comptime {
    if (builtin.sig_backend != .stage2_spirv) {
        _ = @import("conflicting_externs/b.sig");
    }
}

const builtin = @import("builtin");

test "call extern function defined with conflicting type" {
    if (builtin.sig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.sig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.sig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.sig_backend == .stage2_riscv64) return error.SkipZigTest;

    @import("conflicting_externs/a.sig").issue529(null);
    issue529(null);
}
