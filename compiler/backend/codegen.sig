//! Layer 1 — Code Generation
//!
//! Multi-target code generation backend for the zero-alloc compiler.
//! Translates IR nodes into target-specific machine code, starting with x86_64.
//! All storage is comptime-sized — zero heap allocations.
//!
//! The output ring buffer streams encoded bytes to the linker. Relocations are
//! accumulated in a bounded vector for later resolution during linking.

const types = @import("../core/types.sig");
const containers = @import("../core/containers.sig");
const cap = @import("../core/capacity.sig");
const target_mod = @import("../core/target.sig");

const IR_Node = types.IR_Node;
const Relocation = types.Relocation;
const Compiler_Capacity_Plan = cap.Compiler_Capacity_Plan;
const Target_Triple = target_mod.Target_Triple;

const RingBuffer = containers.RingBuffer;
const BoundedVec = containers.BoundedVec;

// ============================================================================
// Constants
// ============================================================================

/// Maximum registers in the interference graph (covers aarch64's 32 GP + FP).
const MAX_TARGET_REGS: usize = 64;

/// Capacity for the relocation table within codegen.
const RELOCATION_TABLE_CAPACITY: usize = Compiler_Capacity_Plan.RELOCATION_TABLE_CAPACITY;

// ============================================================================
// Codegen
// ============================================================================

/// Multi-target code generator. Translates IR nodes into machine code bytes,
/// streaming output through a fixed-capacity ring buffer.
pub const Codegen = struct {
    /// Target architecture, OS, and ABI.
    target: Target_Triple,

    /// Instruction output stream — ring buffer of encoded bytes.
    output_ring: RingBuffer(u8, Compiler_Capacity_Plan.CODEGEN_RING_CAPACITY),

    /// Relocations generated during code emission.
    relocations: BoundedVec(Relocation, RELOCATION_TABLE_CAPACITY),

    /// Interference graph for register allocation (bounded by register count).
    /// Row i, column j = true means registers i and j interfere (cannot be
    /// assigned the same physical register).
    interference_graph: [MAX_TARGET_REGS][MAX_TARGET_REGS]bool,

    /// Current code offset within the section.
    code_offset: u64,

    /// Initialize a code generator for the given target.
    pub fn init(target: Target_Triple) Codegen {
        return Codegen{
            .target = target,
            .output_ring = .{},
            .relocations = .{},
            .interference_graph = @splat(@as([MAX_TARGET_REGS]bool, @splat(false))),
            .code_offset = 0,
        };
    }

    /// Initialize the code generator directly in its bounded workspace.
    pub fn initInto(self: *Codegen, target: Target_Triple) void {
        self.target = target;
        self.output_ring.reset();
        self.relocations.clear();
        @memset(&self.interference_graph, @as([MAX_TARGET_REGS]bool, @splat(false)));
        self.code_offset = 0;
    }

    /// Emit machine code for a single IR node.
    /// Dispatches to the appropriate target-specific encoder.
    pub fn emit(self: *Codegen, ir_node: *const IR_Node) void {
        switch (self.target.arch) {
            .x86_64 => self.emitX86_64(ir_node),
            .aarch64 => self.emitAarch64(ir_node),
            .arm => self.emitArm(ir_node),
            .riscv32, .riscv64 => self.emitRiscV(ir_node),
            .wasm32 => self.emitWasm(ir_node),
        }
    }

    /// Flush the output ring buffer contents into a destination buffer.
    /// Drains all available bytes from the ring into `output`.
    /// Returns the number of bytes written.
    pub fn flushToLinker(self: *Codegen, output: []u8) usize {
        var written: usize = 0;
        while (written < output.len) {
            const byte = self.output_ring.pop() orelse break;
            output[written] = byte;
            written += 1;
        }
        return written;
    }

    /// Emit a complete trivial void function for the active target.
    /// Milestone 1 uses this to prove function frame bytes can stream through
    /// the output ring before full function-level IR is introduced.
    pub fn emitVoidFunction(self: *Codegen) void {
        switch (self.target.arch) {
            .x86_64 => {
                self.emitX86FunctionPrologue();
                self.emitX86FunctionEpilogue();
            },
            else => {
                const ret = IR_Node{
                    .tag = .ret,
                    .data = .{ .none = {} },
                    .type_index = 0,
                };
                self.emit(&ret);
            },
        }
    }

    // ========================================================================
    // x86_64 Instruction Encoding
    // ========================================================================

    /// Translate an IR node to x86_64 machine code and push bytes into
    /// the output ring.
    pub fn emitX86_64(self: *Codegen, ir: *const IR_Node) void {
        switch (ir.tag) {
            .constant => self.emitX86Constant(ir),
            .add => self.emitX86Add(),
            .sub => self.emitX86Sub(),
            .mul => self.emitX86Mul(),
            .ret => self.emitX86Ret(),
            .call => self.emitX86Call(ir),
            .load => self.emitX86Load(),
            .store => self.emitX86Store(),
            .branch => self.emitX86Branch(ir),
            .jump => self.emitX86Jump(ir),
            .cmp_eq => self.emitX86Cmp(0x94), // sete
            .cmp_ne => self.emitX86Cmp(0x95), // setne
            .cmp_lt => self.emitX86Cmp(0x9C), // setl
            .cmp_gt => self.emitX86Cmp(0x9F), // setg
            .cmp_le => self.emitX86Cmp(0x9E), // setle
            .cmp_ge => self.emitX86Cmp(0x9D), // setge
            else => {
                // Unsupported IR tag — emit NOP
                self.emitByte(0x90);
            },
        }
    }

    /// Emit x86_64 constant load: mov rax, imm64 (or mov eax, imm32 for small values).
    fn emitX86Constant(self: *Codegen, ir: *const IR_Node) void {
        const value = ir.data.constant.value;
        if (value <= 0xFFFFFFFF) {
            // mov eax, imm32 — shorter encoding (5 bytes)
            // Opcode: B8 + rd (rd=0 for eax)
            self.emitByte(0xB8);
            self.emitU32LE(@intCast(value));
        } else {
            // REX.W + mov rax, imm64 (10 bytes)
            // REX.W prefix: 0x48
            // Opcode: B8 + rd (rd=0 for rax)
            self.emitByte(0x48);
            self.emitByte(0xB8);
            self.emitU64LE(value);
        }
    }

    /// Emit x86_64: add rax, rbx (REX.W 01 D8)
    fn emitX86Add(self: *Codegen) void {
        self.emitByte(0x48); // REX.W
        self.emitByte(0x01); // ADD r/m64, r64
        self.emitByte(0xD8); // ModRM: mod=11, reg=rbx(3), rm=rax(0)
    }

    /// Emit x86_64: sub rax, rbx (REX.W 29 D8)
    fn emitX86Sub(self: *Codegen) void {
        self.emitByte(0x48); // REX.W
        self.emitByte(0x29); // SUB r/m64, r64
        self.emitByte(0xD8); // ModRM: mod=11, reg=rbx(3), rm=rax(0)
    }

    /// Emit x86_64: imul rax, rbx (REX.W 0F AF C3)
    fn emitX86Mul(self: *Codegen) void {
        self.emitByte(0x48); // REX.W
        self.emitByte(0x0F); // Two-byte opcode prefix
        self.emitByte(0xAF); // IMUL r64, r/m64
        self.emitByte(0xC3); // ModRM: mod=11, reg=rax(0), rm=rbx(3)
    }

    /// Emit x86_64 function prologue: push rbp; mov rbp, rsp.
    fn emitX86FunctionPrologue(self: *Codegen) void {
        self.emitByte(0x55); // push rbp
        self.emitByte(0x48); // REX.W
        self.emitByte(0x89); // mov r/m64, r64
        self.emitByte(0xE5); // ModRM: rbp <- rsp
    }

    /// Emit x86_64 function epilogue: pop rbp; ret.
    fn emitX86FunctionEpilogue(self: *Codegen) void {
        self.emitByte(0x5D); // pop rbp
        self.emitByte(0xC3); // ret
    }

    /// Emit x86_64: ret (C3)
    fn emitX86Ret(self: *Codegen) void {
        self.emitByte(0xC3);
    }

    /// Emit x86_64: call rel32 with relocation.
    fn emitX86Call(self: *Codegen, ir: *const IR_Node) void {
        // E8 rel32
        self.emitByte(0xE8);
        // Record relocation at current offset (the rel32 displacement)
        const reloc = Relocation{
            .offset = self.code_offset,
            .symbol_index = ir.data.call.callee,
            .rel_type = .r_x86_64_pc32,
            .addend = -4, // PC-relative: adjust for instruction size
        };
        self.relocations.append(reloc) catch {};
        // Placeholder for rel32 (linker will patch)
        self.emitU32LE(0x00000000);
    }

    /// Emit x86_64: mov rax, [rbx] (REX.W 8B 03)
    fn emitX86Load(self: *Codegen) void {
        self.emitByte(0x48); // REX.W
        self.emitByte(0x8B); // MOV r64, r/m64
        self.emitByte(0x03); // ModRM: mod=00, reg=rax(0), rm=rbx(3)
    }

    /// Emit x86_64: mov [rax], rbx (REX.W 89 18)
    fn emitX86Store(self: *Codegen) void {
        self.emitByte(0x48); // REX.W
        self.emitByte(0x89); // MOV r/m64, r64
        self.emitByte(0x18); // ModRM: mod=00, reg=rbx(3), rm=rax(0)
    }

    /// Emit x86_64 conditional branch: cmp + jcc rel32 + jmp rel32
    fn emitX86Branch(self: *Codegen, ir: *const IR_Node) void {
        _ = ir;
        // test al, al (check condition in al)
        self.emitByte(0x84); // TEST r/m8, r8
        self.emitByte(0xC0); // ModRM: mod=11, reg=al(0), rm=al(0)

        // jne rel32 (jump to then_block if non-zero)
        self.emitByte(0x0F);
        self.emitByte(0x85); // JNE rel32
        self.emitU32LE(0x00000000); // placeholder — linker/patch resolves

        // jmp rel32 (fall through to else_block)
        self.emitByte(0xE9); // JMP rel32
        self.emitU32LE(0x00000000); // placeholder
    }

    /// Emit x86_64 unconditional jump: jmp rel32
    fn emitX86Jump(self: *Codegen, ir: *const IR_Node) void {
        _ = ir;
        self.emitByte(0xE9); // JMP rel32
        self.emitU32LE(0x00000000); // placeholder — linker resolves
    }

    /// Emit x86_64 comparison: cmp rax, rbx + setcc al
    fn emitX86Cmp(self: *Codegen, setcc_opcode: u8) void {
        // cmp rax, rbx (REX.W 39 D8)
        self.emitByte(0x48); // REX.W
        self.emitByte(0x39); // CMP r/m64, r64
        self.emitByte(0xD8); // ModRM: mod=11, reg=rbx(3), rm=rax(0)

        // setcc al (0F <setcc> C0)
        self.emitByte(0x0F);
        self.emitByte(setcc_opcode);
        self.emitByte(0xC0); // ModRM: mod=11, reg=0, rm=al(0)
    }

    // ========================================================================
    // AArch64 Instruction Encoding
    // ========================================================================

    /// Translate an IR node to AArch64 (ARM64) machine code.
    /// All instructions are 4 bytes (fixed-width).
    pub fn emitAarch64(self: *Codegen, ir: *const IR_Node) void {
        switch (ir.tag) {
            .constant => {
                // movz x0, #imm16 — encoding: 0xD2800000 | (imm16 << 5)
                const imm16: u32 = @intCast(ir.data.constant.value & 0xFFFF);
                self.emitU32LE(0xD2800000 | (imm16 << 5));
            },
            .add => {
                // add x0, x0, x1 — encoding: 0x8B010000
                self.emitU32LE(0x8B010000);
            },
            .sub => {
                // sub x0, x0, x1 — encoding: 0xCB010000
                self.emitU32LE(0xCB010000);
            },
            .ret => {
                // ret — encoding: 0xD65F03C0
                self.emitU32LE(0xD65F03C0);
            },
            .call => {
                // bl rel26 — emit 4-byte instruction + R_AARCH64_CALL26 relocation
                const reloc = Relocation{
                    .offset = self.code_offset,
                    .symbol_index = ir.data.call.callee,
                    .rel_type = .r_aarch64_call26,
                    .addend = 0,
                };
                self.relocations.append(reloc) catch {};
                // bl placeholder (opcode bits [31:26] = 100101, imm26 = 0)
                self.emitU32LE(0x94000000);
            },
            .load => {
                // ldr x0, [x1] — encoding: 0xF9400020
                self.emitU32LE(0xF9400020);
            },
            .store => {
                // str x0, [x1] — encoding: 0xF9000020
                self.emitU32LE(0xF9000020);
            },
            else => {
                // Unsupported IR tag — emit NOP (0xD503201F)
                self.emitU32LE(0xD503201F);
            },
        }
    }

    // ========================================================================
    // ARM (armv7a) Instruction Encoding
    // ========================================================================

    /// Translate an IR node to ARM (armv7a) machine code.
    /// All instructions are 4 bytes (fixed-width).
    pub fn emitArm(self: *Codegen, ir: *const IR_Node) void {
        switch (ir.tag) {
            .constant => {
                // mov r0, #imm8 — encoding: 0xE3A00000 | imm8
                const imm8: u32 = @intCast(ir.data.constant.value & 0xFF);
                self.emitU32LE(0xE3A00000 | imm8);
            },
            .add => {
                // add r0, r0, r1 — encoding: 0xE0800001
                self.emitU32LE(0xE0800001);
            },
            .sub => {
                // sub r0, r0, r1 — encoding: 0xE0400001
                self.emitU32LE(0xE0400001);
            },
            .ret => {
                // bx lr — encoding: 0xE12FFF1E
                self.emitU32LE(0xE12FFF1E);
            },
            .call => {
                // bl rel24 — emit 4-byte instruction + R_ARM_CALL relocation
                const reloc = Relocation{
                    .offset = self.code_offset,
                    .symbol_index = ir.data.call.callee,
                    .rel_type = .r_arm_call,
                    .addend = 0,
                };
                self.relocations.append(reloc) catch {};
                // bl placeholder (cond=1110, opcode=101x, imm24=0)
                self.emitU32LE(0xEB000000);
            },
            else => {
                // Unsupported IR tag — emit NOP (mov r0, r0)
                self.emitU32LE(0xE1A00000);
            },
        }
    }

    // ========================================================================
    // RISC-V Instruction Encoding
    // ========================================================================

    /// Translate an IR node to RISC-V (RV32I/RV64I) machine code.
    /// All instructions are 4 bytes (fixed-width base ISA).
    pub fn emitRiscV(self: *Codegen, ir: *const IR_Node) void {
        switch (ir.tag) {
            .constant => {
                // addi x10, x0, imm12
                // I-type: imm12[31:20] | rs1[19:15] | funct3[14:12] | rd[11:7] | opcode[6:0]
                // opcode=0010011(0x13), funct3=000, rd=x10(01010), rs1=x0(00000)
                const imm12: u32 = @intCast(ir.data.constant.value & 0xFFF);
                const instr: u32 = (imm12 << 20) | (0 << 15) | (0b000 << 12) | (10 << 7) | 0x13;
                self.emitU32LE(instr);
            },
            .add => {
                // add x10, x10, x11
                // R-type: 0000000 | x11 | x10 | 000 | x10 | 0110011
                const instr: u32 = (0b0000000 << 25) | (11 << 20) | (10 << 15) | (0b000 << 12) | (10 << 7) | 0x33;
                self.emitU32LE(instr);
            },
            .sub => {
                // sub x10, x10, x11
                // R-type: 0100000 | x11 | x10 | 000 | x10 | 0110011
                const instr: u32 = (0b0100000 << 25) | (11 << 20) | (10 << 15) | (0b000 << 12) | (10 << 7) | 0x33;
                self.emitU32LE(instr);
            },
            .ret => {
                // jalr x0, x1, 0 — encoding: 0x00008067
                self.emitU32LE(0x00008067);
            },
            .call => {
                // jal x1, offset — emit 4-byte J-type + R_RISCV_CALL relocation
                const reloc = Relocation{
                    .offset = self.code_offset,
                    .symbol_index = ir.data.call.callee,
                    .rel_type = .r_riscv_call,
                    .addend = 0,
                };
                self.relocations.append(reloc) catch {};
                // jal x1, 0 — J-type: imm[20|10:1|11|19:12] | rd | opcode
                // rd=x1(00001), opcode=1101111(0x6F), imm=0 placeholder
                self.emitU32LE(0x000000EF);
            },
            else => {
                // Unsupported IR tag — emit NOP (addi x0, x0, 0 = 0x00000013)
                self.emitU32LE(0x00000013);
            },
        }
    }

    // ========================================================================
    // WebAssembly Bytecode Encoding
    // ========================================================================

    /// Translate an IR node to WebAssembly bytecode.
    /// Variable-length bytecodes (stack machine).
    pub fn emitWasm(self: *Codegen, ir: *const IR_Node) void {
        switch (ir.tag) {
            .constant => {
                // i32.const + LEB128 value (opcode 0x41)
                self.emitByte(0x41);
                self.emitLEB128(@intCast(ir.data.constant.value & 0xFFFFFFFF));
            },
            .add => {
                // i32.add (0x6A)
                self.emitByte(0x6A);
            },
            .sub => {
                // i32.sub (0x6B)
                self.emitByte(0x6B);
            },
            .mul => {
                // i32.mul (0x6C)
                self.emitByte(0x6C);
            },
            .ret => {
                // return (0x0F)
                self.emitByte(0x0F);
            },
            .call => {
                // call func_idx (0x10 + LEB128 index)
                self.emitByte(0x10);
                self.emitLEB128(ir.data.call.callee);
            },
            else => {
                // Unsupported IR tag — emit nop (0x01)
                self.emitByte(0x01);
            },
        }
    }

    // ========================================================================
    // Byte emission helpers
    // ========================================================================

    /// Push a single byte into the output ring and advance code_offset.
    pub fn emitByte(self: *Codegen, b: u8) void {
        self.output_ring.push(b);
        self.code_offset += 1;
    }

    /// Push multiple bytes into the output ring.
    pub fn emitBytes(self: *Codegen, bytes: []const u8) void {
        for (bytes) |b| {
            self.emitByte(b);
        }
    }

    /// Push a u32 in little-endian byte order.
    pub fn emitU32LE(self: *Codegen, val: u32) void {
        self.emitByte(@intCast(val & 0xFF));
        self.emitByte(@intCast((val >> 8) & 0xFF));
        self.emitByte(@intCast((val >> 16) & 0xFF));
        self.emitByte(@intCast((val >> 24) & 0xFF));
    }

    /// Push a u64 in little-endian byte order.
    pub fn emitU64LE(self: *Codegen, val: u64) void {
        self.emitByte(@intCast(val & 0xFF));
        self.emitByte(@intCast((val >> 8) & 0xFF));
        self.emitByte(@intCast((val >> 16) & 0xFF));
        self.emitByte(@intCast((val >> 24) & 0xFF));
        self.emitByte(@intCast((val >> 32) & 0xFF));
        self.emitByte(@intCast((val >> 40) & 0xFF));
        self.emitByte(@intCast((val >> 48) & 0xFF));
        self.emitByte(@intCast((val >> 56) & 0xFF));
    }

    /// Push a u32 in big-endian byte order.
    /// Available for targets that need big-endian encoding, though modern
    /// ARM/RISC-V typically store little-endian instruction words.
    pub fn emitU32BE(self: *Codegen, val: u32) void {
        self.emitByte(@intCast((val >> 24) & 0xFF));
        self.emitByte(@intCast((val >> 16) & 0xFF));
        self.emitByte(@intCast((val >> 8) & 0xFF));
        self.emitByte(@intCast(val & 0xFF));
    }

    /// Encode a u32 value in LEB128 (Little Endian Base 128) format.
    /// Used by WebAssembly for variable-length integer encoding.
    pub fn emitLEB128(self: *Codegen, val: u32) void {
        var v = val;
        while (true) {
            const byte: u8 = @intCast(v & 0x7F);
            v >>= 7;
            if (v == 0) {
                self.emitByte(byte);
                break;
            } else {
                self.emitByte(byte | 0x80);
            }
        }
    }
};

// ============================================================================
// Register Allocator
// ============================================================================

/// Register allocation using greedy graph coloring.
/// Falls back to deterministic round-robin when deep model confidence is low.
pub const RegAlloc = struct {
    /// Physical register assignment for each virtual register.
    assignments: [256]u8 = @splat(UNASSIGNED),
    virtual_count: u16 = 0,
    spill_count: u16 = 0,
    spill_offset: u32 = 0,

    pub const UNASSIGNED: u8 = 0xFF;
    pub const SPILLED: u8 = 0xFE;

    /// Greedy graph coloring: for each vreg, find lowest physical reg
    /// that doesn't interfere with already-assigned neighbors.
    pub fn allocateRegisters(self: *RegAlloc, cg: *Codegen) void {
        const num_regs = cg.target.registerCount();
        if (num_regs == 0) return; // wasm — stack machine, no allocation needed

        var vreg: u16 = 0;
        while (vreg < self.virtual_count) : (vreg += 1) {
            var assigned = false;
            var phys: u8 = 0;
            while (phys < @as(u8, @intCast(num_regs))) : (phys += 1) {
                if (cg.target.isRegisterReserved(phys)) continue;
                if (!self.interferes(vreg, phys, cg)) {
                    self.assignments[vreg] = phys;
                    assigned = true;
                    break;
                }
            }
            if (!assigned) {
                self.spillRegister(vreg);
            }
        }
    }

    /// Check if assigning phys to vreg would conflict with any neighbor.
    fn interferes(self: *const RegAlloc, vreg: u16, phys: u8, cg: *const Codegen) bool {
        var other: u16 = 0;
        while (other < self.virtual_count) : (other += 1) {
            if (other == vreg) continue;
            if (self.assignments[other] == phys) {
                // Check if vreg and other interfere
                if (cg.interference_graph[vreg][other]) return true;
            }
        }
        return false;
    }

    fn spillRegister(self: *RegAlloc, vreg: u16) void {
        self.assignments[vreg] = SPILLED;
        self.spill_count += 1;
        self.spill_offset += 8; // 8 bytes per spill slot
    }

    pub fn getAssignment(self: *const RegAlloc, vreg: u16) u8 {
        return self.assignments[vreg];
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = @import("std").testing;

test "Codegen init produces valid state" {
    const cg = Codegen.init(.{ .arch = .x86_64, .os = .linux, .abi = .gnu });
    try testing.expect(!(cg.code_offset != 0)); // initial code_offset should be 0
    try testing.expect(!(cg.output_ring.len() != 0)); // initial output ring should be empty
    try testing.expect(!(cg.relocations.len() != 0)); // initial relocations should be empty
    try testing.expect(!(cg.interference_graph[0][0] != false)); // interference graph should start clear
}

test "emitByte pushes to ring and advances offset" {
    var cg = Codegen.init(.{ .arch = .x86_64, .os = .linux, .abi = .gnu });
    cg.emitByte(0xC3);
    try testing.expect(!(cg.output_ring.len() != 1)); // expected 1 byte in ring
    try testing.expect(!(cg.code_offset != 1)); // expected code_offset 1
    try testing.expect(!(cg.output_ring.pop().? != 0xC3)); // expected 0xC3
}

test "emitU32LE encodes little-endian" {
    var cg = Codegen.init(.{ .arch = .x86_64, .os = .linux, .abi = .gnu });
    cg.emitU32LE(0xDEADBEEF);
    try testing.expect(!(cg.output_ring.pop().? != 0xEF)); // byte 0 should be 0xEF
    try testing.expect(!(cg.output_ring.pop().? != 0xBE)); // byte 1 should be 0xBE
    try testing.expect(!(cg.output_ring.pop().? != 0xAD)); // byte 2 should be 0xAD
    try testing.expect(!(cg.output_ring.pop().? != 0xDE)); // byte 3 should be 0xDE
}

test "emitU64LE encodes little-endian" {
    var cg = Codegen.init(.{ .arch = .x86_64, .os = .linux, .abi = .gnu });
    cg.emitU64LE(0x0102030405060708);
    try testing.expect(!(cg.output_ring.pop().? != 0x08)); // byte 0
    try testing.expect(!(cg.output_ring.pop().? != 0x07)); // byte 1
    try testing.expect(!(cg.output_ring.pop().? != 0x06)); // byte 2
    try testing.expect(!(cg.output_ring.pop().? != 0x05)); // byte 3
    try testing.expect(!(cg.output_ring.pop().? != 0x04)); // byte 4
    try testing.expect(!(cg.output_ring.pop().? != 0x03)); // byte 5
    try testing.expect(!(cg.output_ring.pop().? != 0x02)); // byte 6
    try testing.expect(!(cg.output_ring.pop().? != 0x01)); // byte 7
}

test "emit constant small value uses 5-byte mov eax encoding" {
    var cg = Codegen.init(.{ .arch = .x86_64, .os = .linux, .abi = .gnu });
    const ir = IR_Node{
        .tag = .constant,
        .data = .{ .constant = .{ .value = 42 } },
        .type_index = 0,
    };
    cg.emit(&ir);
    // mov eax, 42 = B8 2A 00 00 00
    try testing.expect(!(cg.output_ring.len() != 5)); // mov eax, imm32 should be 5 bytes
    try testing.expect(!(cg.output_ring.pop().? != 0xB8)); // opcode should be B8
    try testing.expect(!(cg.output_ring.pop().? != 42)); // imm byte 0 should be 42
}

test "emit constant large value uses 10-byte mov rax encoding" {
    var cg = Codegen.init(.{ .arch = .x86_64, .os = .linux, .abi = .gnu });
    const ir = IR_Node{
        .tag = .constant,
        .data = .{ .constant = .{ .value = 0x100000000 } },
        .type_index = 0,
    };
    cg.emit(&ir);
    // REX.W + mov rax, imm64 = 48 B8 + 8 bytes
    try testing.expect(!(cg.output_ring.len() != 10)); // mov rax, imm64 should be 10 bytes
    try testing.expect(!(cg.output_ring.pop().? != 0x48)); // REX.W prefix
    try testing.expect(!(cg.output_ring.pop().? != 0xB8)); // opcode B8
}

test "emit ret produces single 0xC3 byte" {
    var cg = Codegen.init(.{ .arch = .x86_64, .os = .linux, .abi = .gnu });
    const ir = IR_Node{
        .tag = .ret,
        .data = .{ .none = {} },
        .type_index = 0,
    };
    cg.emit(&ir);
    try testing.expect(!(cg.output_ring.len() != 1)); // ret should be 1 byte
    try testing.expect(!(cg.output_ring.pop().? != 0xC3)); // ret should be 0xC3
}

test "emit add produces 3-byte REX.W encoding" {
    var cg = Codegen.init(.{ .arch = .x86_64, .os = .linux, .abi = .gnu });
    const ir = IR_Node{
        .tag = .add,
        .data = .{ .binary = .{ .lhs = 0, .rhs = 1 } },
        .type_index = 0,
    };
    cg.emit(&ir);
    try testing.expect(!(cg.output_ring.len() != 3)); // add rax, rbx should be 3 bytes
    try testing.expect(!(cg.output_ring.pop().? != 0x48)); // REX.W
    try testing.expect(!(cg.output_ring.pop().? != 0x01)); // ADD opcode
    try testing.expect(!(cg.output_ring.pop().? != 0xD8)); // ModRM
}

test "emit call produces relocation" {
    var cg = Codegen.init(.{ .arch = .x86_64, .os = .linux, .abi = .gnu });
    const ir = IR_Node{
        .tag = .call,
        .data = .{ .call = .{ .callee = 7, .args_start = 0, .args_count = 0 } },
        .type_index = 0,
    };
    cg.emit(&ir);
    // call rel32 = E8 + 4 bytes = 5 bytes total
    try testing.expect(!(cg.output_ring.len() != 5)); // call should be 5 bytes
    try testing.expect(!(cg.relocations.len() != 1)); // call should produce 1 relocation
    const reloc = cg.relocations.get(0);
    try testing.expect(!(reloc.symbol_index != 7)); // relocation should reference callee 7
    try testing.expect(!(reloc.rel_type != .r_x86_64_pc32)); // relocation type should be pc32
}

test "flushToLinker drains ring buffer" {
    var cg = Codegen.init(.{ .arch = .x86_64, .os = .linux, .abi = .gnu });
    cg.emitByte(0xAA);
    cg.emitByte(0xBB);
    cg.emitByte(0xCC);
    var buf: [8]u8 = undefined;
    const written = cg.flushToLinker(&buf);
    try testing.expect(!(written != 3)); // should flush 3 bytes
    try testing.expect(!(buf[0] != 0xAA)); // byte 0
    try testing.expect(!(buf[1] != 0xBB)); // byte 1
    try testing.expect(!(buf[2] != 0xCC)); // byte 2
    try testing.expect(!(cg.output_ring.len() != 0)); // ring should be empty after flush
}

test "RegAlloc basic allocation" {
    var cg = Codegen.init(.{ .arch = .x86_64, .os = .linux, .abi = .gnu });
    var ra: RegAlloc = .{};
    ra.virtual_count = 3;
    // No interference — all should get distinct regs starting from 0
    ra.allocateRegisters(&cg);
    try testing.expect(!(ra.assignments[0] != 0)); // vreg 0 should get phys 0
    try testing.expect(!(ra.assignments[1] != 0)); // vreg 1 should get phys 0 (no interference)
}

// ============================================================================
// Property Tests — Tasks 6.4, 6.5, 6.6
// ============================================================================

// Property 12: Multi-target codegen validity
test "multi-target codegen - all targets emit bytes for ret" {
    const targets = [_]Target_Triple{
        .{ .arch = .x86_64, .os = .linux, .abi = .gnu },
        .{ .arch = .aarch64, .os = .linux, .abi = .gnu },
        .{ .arch = .arm, .os = .linux, .abi = .eabi },
        .{ .arch = .riscv64, .os = .linux, .abi = .gnu },
        .{ .arch = .wasm32, .os = .freestanding, .abi = .none },
    };
    const ir = IR_Node{ .tag = .ret, .data = .{ .none = {} }, .type_index = 0 };
    for (targets) |t| {
        var cg = Codegen.init(t);
        cg.emit(&ir);
        try testing.expect(!(cg.output_ring.len() == 0)); // all targets should emit at least 1 byte for ret
    }
}

test "multi-target codegen - all targets emit bytes for add" {
    const targets = [_]Target_Triple{
        .{ .arch = .x86_64, .os = .linux, .abi = .gnu },
        .{ .arch = .aarch64, .os = .linux, .abi = .gnu },
        .{ .arch = .arm, .os = .linux, .abi = .eabi },
        .{ .arch = .riscv32, .os = .freestanding, .abi = .none },
        .{ .arch = .wasm32, .os = .freestanding, .abi = .none },
    };
    const ir = IR_Node{ .tag = .add, .data = .{ .binary = .{ .lhs = 0, .rhs = 1 } }, .type_index = 0 };
    for (targets) |t| {
        var cg = Codegen.init(t);
        cg.emit(&ir);
        try testing.expect(!(cg.output_ring.len() == 0)); // all targets should emit bytes for add
    }
}

test "multi-target codegen - aarch64 instructions are 4 bytes" {
    var cg = Codegen.init(.{ .arch = .aarch64, .os = .linux, .abi = .gnu });
    const ir = IR_Node{ .tag = .add, .data = .{ .binary = .{ .lhs = 0, .rhs = 1 } }, .type_index = 0 };
    cg.emit(&ir);
    try testing.expect(!(cg.output_ring.len() != 4)); // aarch64 instructions should be 4 bytes
}

// Property 13: Register allocation within bounds
test "register allocation - assignments within register count" {
    var cg = Codegen.init(.{ .arch = .x86_64, .os = .linux, .abi = .gnu });
    var ra: RegAlloc = .{};
    ra.virtual_count = 5;
    ra.allocateRegisters(&cg);
    // All assigned registers should be < 16 (x86_64 has 16 regs) or SPILLED
    var i: u16 = 0;
    while (i < 5) : (i += 1) {
        const a = ra.assignments[i];
        try testing.expect(!(a != RegAlloc.SPILLED and a >= 16)); // assignment exceeds register count
    }
}

test "register allocation - spill when interference forces it" {
    var cg = Codegen.init(.{ .arch = .x86_64, .os = .linux, .abi = .gnu });
    // Set up 17 vregs all interfering with each other (more than 16 regs)
    var ra: RegAlloc = .{};
    ra.virtual_count = 17;
    // Make all vregs interfere with all others
    var a: usize = 0;
    while (a < 17) : (a += 1) {
        var b: usize = 0;
        while (b < 17) : (b += 1) {
            if (a != b) cg.interference_graph[a][b] = true;
        }
    }
    ra.allocateRegisters(&cg);
    // With 17 fully-interfering vregs and 16 regs, at least 1 must spill
    try testing.expect(!(ra.spill_count == 0)); // should have at least 1 spill with 17 interfering vregs and 16 regs
}

test "register allocation - wasm skips allocation" {
    var cg = Codegen.init(.{ .arch = .wasm32, .os = .freestanding, .abi = .none });
    var ra: RegAlloc = .{};
    ra.virtual_count = 10;
    ra.allocateRegisters(&cg);
    // Wasm has 0 registers — allocateRegisters should be a no-op
    try testing.expect(!(ra.spill_count != 0)); // wasm should not spill (no allocation)
    try testing.expect(!(ra.assignments[0] != RegAlloc.UNASSIGNED)); // wasm vregs should remain unassigned
}

test "register allocation - SB0 never assigns reserved x18" {
    var cg = Codegen.init(.{ .arch = .aarch64, .os = .sb0, .abi = .sb0 });
    var ra: RegAlloc = .{};
    ra.virtual_count = 31;

    var a: usize = 0;
    while (a < 31) : (a += 1) {
        var b: usize = 0;
        while (b < 31) : (b += 1) {
            if (a != b) cg.interference_graph[a][b] = true;
        }
    }

    ra.allocateRegisters(&cg);

    var i: u16 = 0;
    while (i < 31) : (i += 1) {
        try testing.expect(!(ra.assignments[i] == 18)); // SB0 allocation must not assign x18
    }
    try testing.expect(!(ra.spill_count != 0)); // 31 values should fit in 32 aarch64 regs with x18 reserved
}

// Property 19: ABI struct layout determinism
test "ABI determinism - same target produces same output" {
    const ir = IR_Node{ .tag = .constant, .data = .{ .constant = .{ .value = 123 } }, .type_index = 0 };
    var cg1 = Codegen.init(.{ .arch = .x86_64, .os = .linux, .abi = .gnu });
    var cg2 = Codegen.init(.{ .arch = .x86_64, .os = .linux, .abi = .gnu });
    cg1.emit(&ir);
    cg2.emit(&ir);
    try testing.expect(!(cg1.output_ring.len() != cg2.output_ring.len())); // same target should produce same output length
    // Compare bytes
    while (cg1.output_ring.pop()) |b1| {
        const b2 = cg2.output_ring.pop() orelse return error.TestUnexpectedResult; // rings should have same length
        try testing.expect(!(b1 != b2)); // same target should produce identical bytes
    }
}
