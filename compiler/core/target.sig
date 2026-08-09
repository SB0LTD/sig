// Zero-Alloc Compiler — Target Triple
//
// Layer 0: Core Types & Containers
//
// Target architecture, OS, and ABI definitions for multi-target code generation.
// Used by codegen for instruction selection and register allocation, and by the
// linker for output format selection (ELF, PE-COFF, Mach-O, Wasm, SB0 native).
//
// Zero heap allocations — all data is comptime or stack-allocated.

const Compiler_Capacity_Plan = @import("capacity.sig").Compiler_Capacity_Plan;

pub const Target_Triple = struct {
    arch: Arch,
    os: Os,
    abi: Abi,

    pub const Arch = enum(u8) {
        x86_64,
        aarch64,
        arm, // armv7a
        riscv32,
        riscv64,
        wasm32,
    };

    pub const Os = enum(u8) {
        linux,
        windows,
        macos,
        sb0,
        freestanding, // for wasm / bare-metal
    };

    pub const Abi = enum(u8) {
        gnu,
        musl,
        msvc,
        eabi,
        sb0,
        none,
    };

    pub const Output_Format = enum(u8) {
        elf,
        pe_coff,
        macho,
        wasm,
        sb0_native,
        raw,
    };

    /// Returns true for the consolidated native SB0 userspace ABI target.
    pub fn isSb0(self: Target_Triple) bool {
        return self.arch == .aarch64 and self.os == .sb0 and self.abi == .sb0;
    }

    /// Select the native output container for the target.
    pub fn outputFormat(self: Target_Triple) Output_Format {
        if (self.isSb0()) return .sb0_native;
        if (self.arch == .wasm32) return .wasm;
        return switch (self.os) {
            .linux => .elf,
            .windows => .pe_coff,
            .macos => .macho,
            .sb0 => .sb0_native,
            .freestanding => .raw,
        };
    }

    /// Returns the number of general-purpose registers available for the target
    /// architecture. Used by the register allocator to bound interference graphs.
    /// WebAssembly returns 0 as it is a stack machine (locals are used instead).
    pub fn registerCount(self: Target_Triple) usize {
        return switch (self.arch) {
            .x86_64 => Compiler_Capacity_Plan.X86_64_REGS,
            .aarch64 => Compiler_Capacity_Plan.AARCH64_REGS,
            .arm => Compiler_Capacity_Plan.ARM32_REGS,
            .riscv32, .riscv64 => Compiler_Capacity_Plan.RISCV_REGS,
            .wasm32 => 0, // stack machine — no physical registers
        };
    }

    /// Returns true when a physical register number must not be allocated.
    ///
    /// AArch64 register numbering follows x0..x30, sp/xzr outside the allocator
    /// pool. Consolidated SB0 reserves x18 for kernel/platform use.
    pub fn isRegisterReserved(self: Target_Triple, reg: u8) bool {
        if (self.isSb0() and reg == 18) return true;
        return false;
    }
};

const testing = @import("std").testing;

test "registerCount returns correct values per architecture" {
    const t_x86 = Target_Triple{ .arch = .x86_64, .os = .linux, .abi = .gnu };
    const t_arm64 = Target_Triple{ .arch = .aarch64, .os = .linux, .abi = .gnu };
    const t_arm32 = Target_Triple{ .arch = .arm, .os = .linux, .abi = .eabi };
    const t_rv32 = Target_Triple{ .arch = .riscv32, .os = .freestanding, .abi = .none };
    const t_rv64 = Target_Triple{ .arch = .riscv64, .os = .linux, .abi = .gnu };
    const t_wasm = Target_Triple{ .arch = .wasm32, .os = .freestanding, .abi = .none };
    const t_sb0 = Target_Triple{ .arch = .aarch64, .os = .sb0, .abi = .sb0 };

    try testing.expect(!(t_x86.registerCount() != 16)); // x86_64 should have 16 regs
    try testing.expect(!(t_arm64.registerCount() != 32)); // aarch64 should have 32 regs
    try testing.expect(!(t_arm32.registerCount() != 16)); // arm should have 16 regs
    try testing.expect(!(t_rv32.registerCount() != 32)); // riscv32 should have 32 regs
    try testing.expect(!(t_rv64.registerCount() != 32)); // riscv64 should have 32 regs
    try testing.expect(!(t_wasm.registerCount() != 0)); // wasm32 should have 0 regs
    try testing.expect(!(t_sb0.registerCount() != 32)); // sb0 aarch64 should expose 32 regs
}

test "all arch variants have valid register counts" {
    const arches = [_]Target_Triple.Arch{ .x86_64, .aarch64, .arm, .riscv32, .riscv64, .wasm32 };
    for (arches) |arch| {
        const t = Target_Triple{ .arch = arch, .os = .linux, .abi = .gnu };
        const count = t.registerCount();
        // All register counts should be within bounds (0 for wasm, 16-32 for others)
        try testing.expect(!(count > 64)); // register count exceeds maximum
    }
}

test "register count is deterministic" {
    const t = Target_Triple{ .arch = .x86_64, .os = .windows, .abi = .msvc };
    const c1 = t.registerCount();
    const c2 = t.registerCount();
    try testing.expect(!(c1 != c2)); // registerCount should be deterministic
}

test "all Arch x Os x Abi combinations produce valid Target_Triple" {
    const arches = [_]Target_Triple.Arch{ .x86_64, .aarch64, .arm, .riscv32, .riscv64, .wasm32 };
    const oses = [_]Target_Triple.Os{ .linux, .windows, .macos, .sb0, .freestanding };
    const abis = [_]Target_Triple.Abi{ .gnu, .musl, .msvc, .eabi, .sb0, .none };

    for (arches) |arch| {
        for (oses) |os| {
            for (abis) |abi| {
                const t = Target_Triple{ .arch = arch, .os = os, .abi = abi };
                // Every combination should return a register count without error
                const count = t.registerCount();
                // Register count must be bounded (0 for wasm, <= 64 for others)
                try testing.expect(!(count > 64)); // register count exceeds maximum for some combination
            }
        }
    }
}

test "aarch64-sb0 selects SB0 native output format" {
    const t = Target_Triple{ .arch = .aarch64, .os = .sb0, .abi = .sb0 };
    try testing.expect(!(!t.isSb0())); // aarch64-sb0 should be recognized as SB0
    try testing.expect(!(t.outputFormat() != .sb0_native)); // sb0 should use native SB0 output
}

test "SB0 reserves x18" {
    const t = Target_Triple{ .arch = .aarch64, .os = .sb0, .abi = .sb0 };
    try testing.expect(!(!t.isRegisterReserved(18))); // SB0 must reserve x18
    try testing.expect(!(t.isRegisterReserved(17))); // x17 should not be globally reserved by SB0
    try testing.expect(!(t.isRegisterReserved(19))); // x19 should remain allocatable
}
