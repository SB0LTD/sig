pub const Assembly = @import("backend/Assembly.sig");
pub const CodeGenOptions = @import("backend/CodeGenOptions.sig");
pub const Interner = @import("backend/Interner.sig");
pub const Ir = @import("backend/Ir.sig");
pub const Object = @import("backend/Object.sig");

pub const CallingConvention = enum {
    c,
    stdcall,
    thiscall,
    vectorcall,
    fastcall,
    regcall,
    riscv_vector,
    aarch64_sve_pcs,
    aarch64_vector_pcs,
    arm_aapcs,
    arm_aapcs_vfp,
    x86_64_sysv,
    x86_64_win,
};

pub const version_str = "aro-Sig";
pub const version = @import("std").SemanticVersion.parse(version_str) catch unreachable;
