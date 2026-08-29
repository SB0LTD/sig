// Zero-Alloc Compiler — Linker Core
//
// Layer 1: Compiler Phases (Backend)
//
// Fixed-capacity linker with streaming relocation processing.
// Manages sections, relocations, and external symbols using comptime-sized
// data structures. When the relocation table is full, `streamingFlush()`
// clears it so the caller can continue adding relocations in passes.
//
// Zero heap allocations — all storage is stack or comptime-sized.

const types = @import("../core/types.sig");
const containers = @import("../core/containers.sig");
const cap = @import("../core/capacity.sig");
const target_mod = @import("../core/target.sig");

const Relocation = types.Relocation;
const Compiler_Capacity_Plan = cap.Compiler_Capacity_Plan;
const Target_Triple = target_mod.Target_Triple;
const BoundedVec = containers.BoundedVec;
const Fixed_Hash_Map = containers.Fixed_Hash_Map;

pub const SB0_NATIVE_MAGIC = [_]u8{ 'S', 'B', '0', 'X' };
pub const SB0_NATIVE_FORMAT_VERSION: u8 = 1;
pub const SB0_NATIVE_ABI_VERSION: u16 = 1;
pub const SB0_NATIVE_HEADER_SIZE: usize = 64;
pub const SB0_NATIVE_SEGMENT_SIZE: usize = 40;
pub const SB0_NATIVE_MAX_SEGMENTS: usize = 8;

/// Native SB0 kernel container. This is an artifact kind of `aarch64-sb0`,
/// not a second target ABI. The emitter writes this container directly into
/// caller-provided storage; no foreign object or executable format exists at
/// any point in the zero-allocation pipeline.
pub const SB0_KERNEL_MAGIC = [_]u8{ 'S', 'B', '0', 'K' };
pub const SB0_KERNEL_FORMAT_VERSION: u16 = 1;
pub const SB0_KERNEL_HEADER_SIZE: usize = 64;
pub const SB0_KERNEL_BOOT_ABI_VERSION: u16 = 1;
pub const SB0_KERNEL_FLAG_FIXED_LAYOUT: u32 = 1;

// ============================================================================
// Section_Entry
// ============================================================================

/// Describes a section in the linked output (e.g. .text, .data, .rodata).
pub const Section_Entry = struct {
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    offset: u64 = 0,
    size: u64 = 0,
    alignment: u32 = 1,
    flags: u32 = 0, // SHF_ALLOC, SHF_WRITE, SHF_EXECINSTR
};

// ============================================================================
// External_Symbol
// ============================================================================

/// An external symbol tracked by the linker for cross-file reference resolution.
pub const External_Symbol = struct {
    name_hash: u64,
    section_index: u32,
    offset: u64,
    size: u64,
    is_defined: bool = false,
};

// ============================================================================
// Linker
// ============================================================================

/// Fixed-capacity linker for the zero-alloc compiler pipeline.
/// Processes relocations in streaming passes — when the relocation table
/// fills up, the caller invokes `streamingFlush()` to clear it and continue.
pub const Linker = struct {
    target: Target_Triple,
    relocations: BoundedVec(Relocation, Compiler_Capacity_Plan.RELOCATION_TABLE_CAPACITY),
    sections: BoundedVec(Section_Entry, Compiler_Capacity_Plan.SECTION_MERGE_CAPACITY),
    externals: Fixed_Hash_Map(
        u64,
        External_Symbol,
        Compiler_Capacity_Plan.EXTERNAL_SYMBOL_BUCKETS,
        Compiler_Capacity_Plan.EXTERNAL_SYMBOL_INDEX_CAPACITY,
    ),
    output_offset: u64 = 0,

    /// Initialize a new Linker for the given target.
    pub fn init(target: Target_Triple) Linker {
        return Linker{
            .target = target,
            .relocations = .{},
            .sections = .{},
            .externals = .{},
            .output_offset = 0,
        };
    }

    /// Initialize linker state directly in caller-owned fixed storage.
    pub fn initInto(self: *Linker, target: Target_Triple) void {
        self.target = target;
        self.relocations.clear();
        self.sections.clear();
        self.externals.clear();
        self.output_offset = 0;
    }

    /// Add a section to the linker's section merge table.
    pub fn addSection(self: *Linker, entry: Section_Entry) void {
        self.sections.append(entry) catch {
            // Section table full — in a streaming linker this should not happen
            // for well-formed inputs (SECTION_MERGE_CAPACITY = 1024).
            // If it does, the oldest section is implicitly complete.
            return;
        };
    }

    /// Add a relocation entry to the relocation table.
    pub fn addRelocation(self: *Linker, reloc: Relocation) void {
        self.relocations.append(reloc) catch {
            // Table full — caller should have called streamingFlush() before this.
            // As a safety measure, flush and retry.
            self.streamingFlush();
            self.relocations.append(reloc) catch {
                return;
            };
        };
    }

    /// Register an external symbol for cross-file reference resolution.
    pub fn addExternalSymbol(self: *Linker, sym: External_Symbol) void {
        self.externals.put(sym.name_hash, sym);
    }

    /// Resolve relocations against known external symbols.
    /// For each relocation where the target symbol is defined, computes the
    /// final address and patches the code buffer at the relocation offset.
    /// Removes resolved relocations from the table. Returns the count resolved.
    pub fn resolveRelocations(self: *Linker, code: []u8) usize {
        var resolved_count: usize = 0;
        var write_idx: usize = 0;
        const total = self.relocations.len();

        var read_idx: usize = 0;
        while (read_idx < total) : (read_idx += 1) {
            const reloc = self.relocations.get(read_idx);
            const sym_hash: u64 = @intCast(reloc.symbol_index);

            // Look up the symbol in the externals table
            if (self.externals.get(sym_hash)) |sym| {
                if (sym.is_defined) {
                    // Compute final address: section offset + symbol offset + addend
                    const final_addr = sym.offset +% @as(u64, @bitCast(reloc.addend));

                    // Patch the code buffer at the relocation offset
                    if (reloc.offset < code.len) {
                        self.patchCode(code, reloc.offset, final_addr, reloc.rel_type);
                    }

                    resolved_count += 1;
                    // Don't keep this relocation (it's resolved)
                    continue;
                }
            }

            // Unresolved — keep it in the table (compact in-place)
            if (write_idx != read_idx) {
                self.relocations.set(write_idx, reloc);
            }
            write_idx += 1;
        }

        // Update the size to reflect only unresolved relocations
        self.relocations.size = write_idx;

        return resolved_count;
    }

    /// Clear the relocation buffer. Used when capacity is full — the caller
    /// must flush partial results (e.g. write out resolved sections) before
    /// continuing to add more relocations.
    pub fn streamingFlush(self: *Linker) void {
        self.relocations.clear();
    }

    /// Returns the number of sections currently in the merge table.
    pub fn sectionCount(self: *const Linker) usize {
        return self.sections.len();
    }

    /// Returns the number of relocations currently pending.
    pub fn relocationCount(self: *const Linker) usize {
        return self.relocations.len();
    }

    // ── Output Format Emitters ──

    /// Emit an executable image for the linker's target output format.
    /// `main_code` is the compiled body for a trivial entry function.
    pub fn emitExecutable(self: *Linker, output: []u8, main_code: []const u8) usize {
        return switch (self.target.outputFormat()) {
            .elf => self.emitElfExecutable(output, main_code),
            .pe_coff => self.emitPeCoffExecutable(output, main_code),
            .sb0_native => self.emitSb0NativeExecutable(output, main_code),
            .macho => self.emitMachOExecutable(output, main_code),
            .wasm => self.emitWasm(output),
            .raw => self.emitRaw(output, main_code),
        };
    }

    /// Emit an ELF binary into the output buffer.
    /// Writes: ELF header (0x7f454c46 magic), program headers, section headers,
    /// and section content. Returns bytes written.
    pub fn emitElf(self: *Linker, output: []u8) usize {
        const default_main = [_]u8{0xC3};
        return self.emitElfExecutable(output, default_main[0..]);
    }

    /// Emit a runnable ELF64 executable with one RX PT_LOAD segment.
    ///
    /// Layout:
    ///   ELF header (64), program header (56), _start stub, main bytes.
    /// The _start stub calls main and exits via Linux exit_group(0).
    ///
    /// Supported architectures: x86_64 (EM_X86_64) and aarch64 (EM_AARCH64).
    /// Both host arches emit the same ELF container and differ only in the
    /// e_machine field and the fixed-length `_start` stub instructions, so a
    /// single host can cross-emit either Linux target deterministically.
    pub fn emitElfExecutable(self: *Linker, output: []u8, main_code: []const u8) usize {
        const e_machine: u16 = switch (self.target.arch) {
            .x86_64 => 0x3E, // EM_X86_64
            .aarch64 => 0xB7, // EM_AARCH64
            else => return 0,
        };
        if (main_code.len == 0) return 0;

        const elf_header_size: usize = 64;
        const ph_header_size: usize = 56;
        const text_offset: usize = elf_header_size + ph_header_size;
        // x86_64 stub is 14 bytes; aarch64 stub is 4 fixed-width instructions (16 bytes).
        const start_stub_len: usize = switch (self.target.arch) {
            .aarch64 => 16,
            else => 14,
        };
        const image_size: usize = text_offset + start_stub_len + main_code.len;
        const base_vaddr: u64 = 0x400000;
        if (output.len < image_size) return 0;

        self.zeroBuffer(output);

        var pos: usize = 0;

        // e_ident
        output[pos] = 0x7f;
        output[pos + 1] = 'E';
        output[pos + 2] = 'L';
        output[pos + 3] = 'F';
        pos += 4;
        output[pos] = 2; // EI_CLASS: ELFCLASS64
        pos += 1;
        output[pos] = 1; // EI_DATA: little-endian
        pos += 1;
        output[pos] = 1; // EI_VERSION
        pos += 1;
        output[pos] = 0; // EI_OSABI
        pos += 1;
        pos = 16;

        self.writeU16LE(output[pos..], 2);
        pos += 2; // e_type: ET_EXEC
        self.writeU16LE(output[pos..], e_machine);
        pos += 2; // e_machine: EM_X86_64 / EM_AARCH64
        self.writeU32LE(output[pos..], 1);
        pos += 4; // e_version
        self.writeU64LE(output[pos..], base_vaddr + @as(u64, @intCast(text_offset)));
        pos += 8; // e_entry
        self.writeU64LE(output[pos..], elf_header_size);
        pos += 8; // e_phoff
        self.writeU64LE(output[pos..], 0);
        pos += 8; // e_shoff
        self.writeU32LE(output[pos..], 0);
        pos += 4; // e_flags
        self.writeU16LE(output[pos..], elf_header_size);
        pos += 2; // e_ehsize
        self.writeU16LE(output[pos..], ph_header_size);
        pos += 2; // e_phentsize
        self.writeU16LE(output[pos..], 1);
        pos += 2; // e_phnum
        self.writeU16LE(output[pos..], 0);
        pos += 2; // e_shentsize
        self.writeU16LE(output[pos..], 0);
        pos += 2; // e_shnum
        self.writeU16LE(output[pos..], 0);
        pos += 2; // e_shstrndx

        // PT_LOAD program header.
        self.writeU32LE(output[pos..], 1);
        pos += 4; // p_type: PT_LOAD
        self.writeU32LE(output[pos..], 0x5);
        pos += 4; // p_flags: PF_R | PF_X
        self.writeU64LE(output[pos..], 0);
        pos += 8; // p_offset
        self.writeU64LE(output[pos..], base_vaddr);
        pos += 8; // p_vaddr
        self.writeU64LE(output[pos..], base_vaddr);
        pos += 8; // p_paddr
        self.writeU64LE(output[pos..], @intCast(image_size));
        pos += 8; // p_filesz
        self.writeU64LE(output[pos..], @intCast(image_size));
        pos += 8; // p_memsz
        self.writeU64LE(output[pos..], 0x1000);
        pos += 8; // p_align

        pos = text_offset;
        switch (self.target.arch) {
            .aarch64 => {
                // AArch64 Linux `_start` stub (4 instructions, little-endian).
                // main sits immediately after the 16-byte stub.
                //   bl   main            ; branch-and-link to main (offset +16 = imm26 4)
                //   mov  x0, #0          ; status = 0
                //   mov  x8, #94         ; __NR_exit_group
                //   svc  #0
                const bl_imm26: u32 = @intCast((start_stub_len - 0) >> 2);
                self.writeU32LE(output[pos..], 0x94000000 | (bl_imm26 & 0x03FFFFFF));
                pos += 4;
                self.writeU32LE(output[pos..], 0xD2800000); // movz x0, #0
                pos += 4;
                self.writeU32LE(output[pos..], 0xD2800BC8); // movz x8, #94 (exit_group)
                pos += 4;
                self.writeU32LE(output[pos..], 0xD4000001); // svc #0
                pos += 4;
            },
            else => {
                // x86_64 Linux `_start` stub (14 bytes).
                // call main
                output[pos] = 0xE8;
                self.writeU32LE(output[pos + 1 ..], @intCast(start_stub_len - 5));
                pos += 5;
                // xor edi, edi
                output[pos] = 0x31;
                output[pos + 1] = 0xFF;
                pos += 2;
                // mov eax, 231 ; exit_group
                output[pos] = 0xB8;
                self.writeU32LE(output[pos + 1 ..], 231);
                pos += 5;
                // syscall
                output[pos] = 0x0F;
                output[pos + 1] = 0x05;
                pos += 2;
            },
        }

        self.copyBytes(output[pos..], main_code);
        return image_size;
    }

    /// Emit a PE/COFF executable header into the output buffer.
    /// Writes: DOS stub (MZ magic 0x4d5a), PE signature, COFF header,
    /// and optional header. Returns bytes written.
    pub fn emitPeCoff(self: *Linker, output: []u8) usize {
        const default_main = [_]u8{0xC3};
        return self.emitPeCoffExecutable(output, default_main[0..]);
    }

    /// Emit a PE32+ executable with one .text section and an ExitProcess import.
    ///
    /// Supported architectures: x86_64 (Machine 0x8664) and aarch64
    /// (Machine 0xAA64). The PE container, optional header, import table and
    /// IAT are identical across both; only the COFF `Machine` field and the
    /// fixed-length entry stub differ, so a single host cross-emits either
    /// Windows target deterministically.
    pub fn emitPeCoffExecutable(self: *Linker, output: []u8, main_code: []const u8) usize {
        const machine: u16 = switch (self.target.arch) {
            .x86_64 => 0x8664, // IMAGE_FILE_MACHINE_AMD64
            .aarch64 => 0xAA64, // IMAGE_FILE_MACHINE_ARM64
            else => return 0,
        };
        if (main_code.len == 0) return 0;

        const pe_offset: usize = 0x80;
        const optional_header_size: usize = 0xF0;
        const section_alignment: usize = 0x1000;
        const file_alignment: usize = 0x200;
        const headers_size: usize = 0x200;
        const text_rva: usize = 0x1000;
        const text_raw: usize = headers_size;
        // x86_64 entry stub is 13 bytes; aarch64 is 5 fixed-width instructions (20 bytes).
        const entry_stub_len: usize = switch (self.target.arch) {
            .aarch64 => 20,
            else => 13,
        };
        const code_len: usize = entry_stub_len + main_code.len;
        const import_desc_off: usize = alignForward(code_len, 8);
        const null_desc_off: usize = import_desc_off + 20;
        const int_off: usize = null_desc_off + 20;
        const iat_off: usize = int_off + 16;
        const dll_name = "KERNEL32.dll";
        const dll_name_off: usize = iat_off + 16;
        const hint_name_off: usize = alignForward(dll_name_off + dll_name.len + 1, 2);
        const hint_name = "ExitProcess";
        const text_virtual_size: usize = hint_name_off + 2 + hint_name.len + 1;
        const text_raw_size: usize = alignForward(text_virtual_size, file_alignment);
        const image_size: usize = alignForward(text_rva + text_virtual_size, section_alignment);
        const total_size: usize = text_raw + text_raw_size;
        if (output.len < total_size) return 0;

        self.zeroBuffer(output);

        var pos: usize = 0;
        output[pos] = 0x4D;
        output[pos + 1] = 0x5A;
        self.writeU32LE(output[0x3C..], @intCast(pe_offset));

        pos = pe_offset;
        output[pos] = 'P';
        output[pos + 1] = 'E';
        output[pos + 2] = 0;
        output[pos + 3] = 0;
        pos += 4;

        self.writeU16LE(output[pos..], machine);
        pos += 2; // Machine: AMD64 / ARM64
        self.writeU16LE(output[pos..], 1);
        pos += 2; // NumberOfSections
        self.writeU32LE(output[pos..], 0);
        pos += 4; // TimeDateStamp
        self.writeU32LE(output[pos..], 0);
        pos += 4; // PointerToSymbolTable
        self.writeU32LE(output[pos..], 0);
        pos += 4; // NumberOfSymbols
        self.writeU16LE(output[pos..], optional_header_size);
        pos += 2; // SizeOfOptionalHeader
        self.writeU16LE(output[pos..], 0x22);
        pos += 2; // IMAGE_FILE_EXECUTABLE_IMAGE | IMAGE_FILE_LARGE_ADDRESS_AWARE

        const opt_pos = pos;
        self.writeU16LE(output[pos..], 0x20B);
        pos += 2; // PE32+
        output[pos] = 0;
        output[pos + 1] = 0;
        pos += 2; // linker version
        self.writeU32LE(output[pos..], @intCast(text_raw_size));
        pos += 4; // SizeOfCode
        self.writeU32LE(output[pos..], 0);
        pos += 4; // SizeOfInitializedData
        self.writeU32LE(output[pos..], 0);
        pos += 4; // SizeOfUninitializedData
        self.writeU32LE(output[pos..], @intCast(text_rva));
        pos += 4; // AddressOfEntryPoint
        self.writeU32LE(output[pos..], @intCast(text_rva));
        pos += 4; // BaseOfCode
        self.writeU64LE(output[pos..], 0x140000000);
        pos += 8; // ImageBase
        self.writeU32LE(output[pos..], @intCast(section_alignment));
        pos += 4;
        self.writeU32LE(output[pos..], @intCast(file_alignment));
        pos += 4;
        self.writeU16LE(output[pos..], 6);
        pos += 2; // MajorOperatingSystemVersion
        self.writeU16LE(output[pos..], 0);
        pos += 2;
        self.writeU16LE(output[pos..], 0);
        pos += 2; // MajorImageVersion
        self.writeU16LE(output[pos..], 0);
        pos += 2;
        self.writeU16LE(output[pos..], 6);
        pos += 2; // MajorSubsystemVersion
        self.writeU16LE(output[pos..], 0);
        pos += 2;
        self.writeU32LE(output[pos..], 0);
        pos += 4; // Win32VersionValue
        self.writeU32LE(output[pos..], @intCast(image_size));
        pos += 4; // SizeOfImage
        self.writeU32LE(output[pos..], headers_size);
        pos += 4; // SizeOfHeaders
        self.writeU32LE(output[pos..], 0);
        pos += 4; // CheckSum
        self.writeU16LE(output[pos..], 3);
        pos += 2; // IMAGE_SUBSYSTEM_WINDOWS_CUI
        self.writeU16LE(output[pos..], 0x8160);
        pos += 2; // DllCharacteristics
        self.writeU64LE(output[pos..], 1024 * 1024);
        pos += 8; // SizeOfStackReserve
        self.writeU64LE(output[pos..], 4096);
        pos += 8; // SizeOfStackCommit
        self.writeU64LE(output[pos..], 1024 * 1024);
        pos += 8; // SizeOfHeapReserve
        self.writeU64LE(output[pos..], 4096);
        pos += 8; // SizeOfHeapCommit
        self.writeU32LE(output[pos..], 0);
        pos += 4; // LoaderFlags
        self.writeU32LE(output[pos..], 16);
        pos += 4; // NumberOfRvaAndSizes

        const import_rva: u32 = @intCast(text_rva + import_desc_off);
        const import_size: u32 = 40;
        const iat_rva: u32 = @intCast(text_rva + iat_off);
        self.writeU32LE(output[opt_pos + 120 ..], import_rva);
        self.writeU32LE(output[opt_pos + 124 ..], import_size);
        self.writeU32LE(output[opt_pos + 208 ..], iat_rva);
        self.writeU32LE(output[opt_pos + 212 ..], 16);

        pos = opt_pos + optional_header_size;
        output[pos] = '.';
        output[pos + 1] = 't';
        output[pos + 2] = 'e';
        output[pos + 3] = 'x';
        output[pos + 4] = 't';
        pos += 8;
        self.writeU32LE(output[pos..], @intCast(text_virtual_size));
        pos += 4; // VirtualSize
        self.writeU32LE(output[pos..], @intCast(text_rva));
        pos += 4; // VirtualAddress
        self.writeU32LE(output[pos..], @intCast(text_raw_size));
        pos += 4; // SizeOfRawData
        self.writeU32LE(output[pos..], @intCast(text_raw));
        pos += 4; // PointerToRawData
        self.writeU32LE(output[pos..], 0);
        pos += 4; // PointerToRelocations
        self.writeU32LE(output[pos..], 0);
        pos += 4; // PointerToLinenumbers
        self.writeU16LE(output[pos..], 0);
        pos += 2; // NumberOfRelocations
        self.writeU16LE(output[pos..], 0);
        pos += 2; // NumberOfLinenumbers
        self.writeU32LE(output[pos..], 0x60000020);
        pos += 4; // code | execute | read

        const code_start = text_raw;
        const main_offset = entry_stub_len;
        switch (self.target.arch) {
            .aarch64 => {
                // AArch64 Windows entry stub (5 instructions, 20 bytes).
                //   bl   main                     ; call user main (main sits after the stub)
                //   movz w0, #0                   ; exit code 0
                //   adrp x16, page(IAT ExitProcess)
                //   ldr  x16, [x16, #lo12(IAT)]   ; load imported ExitProcess address
                //   blr  x16                      ; ExitProcess(0)
                const entry_rva: usize = text_rva; // AddressOfEntryPoint
                const iat_entry_rva: usize = text_rva + iat_off;

                // insn0: bl main (main is at entry_stub_len bytes past the branch)
                const bl_imm26: u32 = @intCast(main_offset >> 2);
                self.writeU32LE(output[code_start..], 0x94000000 | (bl_imm26 & 0x03FFFFFF));

                // insn1: movz w0, #0
                self.writeU32LE(output[code_start + 4 ..], 0x52800000);

                // insn2: adrp x16, page(IAT)
                const adrp_pc: usize = entry_rva + 8; // rva of the adrp instruction
                const page_delta: i64 = @as(i64, @intCast(iat_entry_rva & ~@as(usize, 0xFFF))) -
                    @as(i64, @intCast(adrp_pc & ~@as(usize, 0xFFF)));
                const pages: i64 = @divTrunc(page_delta, 0x1000);
                const imm21: u32 = @intCast(@as(i64, pages) & 0x1FFFFF);
                const immlo: u32 = imm21 & 0x3;
                const immhi: u32 = (imm21 >> 2) & 0x7FFFF;
                const adrp: u32 = 0x90000000 | (immlo << 29) | (immhi << 5) | 16;
                self.writeU32LE(output[code_start + 8 ..], adrp);

                // insn3: ldr x16, [x16, #lo12(IAT)]  (unsigned offset, scaled by 8)
                const lo12: u32 = @intCast(iat_entry_rva & 0xFFF);
                const ldr: u32 = 0xF9400000 | ((lo12 >> 3) << 10) | (16 << 5) | 16;
                self.writeU32LE(output[code_start + 12 ..], ldr);

                // insn4: blr x16
                self.writeU32LE(output[code_start + 16 ..], 0xD63F0200);
            },
            else => {
                // x86_64 Windows entry stub (13 bytes).
                output[code_start] = 0xE8;
                self.writeU32LE(output[code_start + 1 ..], @intCast(main_offset - 5));
                output[code_start + 5] = 0x31;
                output[code_start + 6] = 0xC9; // xor ecx, ecx
                output[code_start + 7] = 0xFF;
                output[code_start + 8] = 0x15; // call qword ptr [rip+disp32]
                self.writeU32LE(output[code_start + 9 ..], @intCast((text_rva + iat_off) - (text_rva + entry_stub_len)));
            },
        }
        self.copyBytes(output[code_start + main_offset ..], main_code);

        const section_base = text_raw;
        const import_desc = section_base + import_desc_off;
        const int_rva: u32 = @intCast(text_rva + int_off);
        const dll_name_rva: u32 = @intCast(text_rva + dll_name_off);
        const hint_name_rva: u32 = @intCast(text_rva + hint_name_off);
        self.writeU32LE(output[import_desc..], int_rva);
        self.writeU32LE(output[import_desc + 12 ..], dll_name_rva);
        self.writeU32LE(output[import_desc + 16 ..], iat_rva);
        self.writeU64LE(output[section_base + int_off ..], hint_name_rva);
        self.writeU64LE(output[section_base + iat_off ..], hint_name_rva);
        self.copyBytes(output[section_base + dll_name_off ..], dll_name);
        output[section_base + dll_name_off + dll_name.len] = 0;
        self.writeU16LE(output[section_base + hint_name_off ..], 0);
        self.copyBytes(output[section_base + hint_name_off + 2 ..], hint_name);
        output[section_base + hint_name_off + 2 + hint_name.len] = 0;

        return total_size;
    }

    /// Emit a Mach-O executable using a trivial default `main` (single `ret`).
    /// Retained for callers/tests that only need a valid runnable container.
    pub fn emitMachO(self: *Linker, output: []u8) usize {
        // x86_64 `ret` = 0xC3; aarch64 `ret` = 0xD65F03C0.
        return switch (self.target.arch) {
            .aarch64 => self.emitMachOExecutable(output, &[_]u8{ 0xC0, 0x03, 0x5F, 0xD6 }),
            else => self.emitMachOExecutable(output, &[_]u8{0xC3}),
        };
    }

    /// Emit a runnable Mach-O 64-bit executable (MH_EXECUTE) with a real
    /// __PAGEZERO + __TEXT segment layout and an LC_UNIXTHREAD entry.
    ///
    /// Supported architectures: x86_64 (CPU_TYPE_X86_64) and aarch64
    /// (CPU_TYPE_ARM64). The container is static and dyld-free: the kernel sets
    /// the initial thread register state from LC_UNIXTHREAD and jumps straight
    /// to the entry stub, which calls `main` then issues the platform `exit`
    /// syscall directly. A single host cross-emits either macOS target.
    ///
    /// Layout:
    ///   mach_header_64 (32)
    ///   LC_SEGMENT_64 __PAGEZERO (72)
    ///   LC_SEGMENT_64 __TEXT + 1 section __text (152)
    ///   LC_UNIXTHREAD (arch-sized thread state)
    ///   entry stub + main bytes (the __text section content)
    pub fn emitMachOExecutable(self: *Linker, output: []u8, main_code: []const u8) usize {
        const cputype: u32 = switch (self.target.arch) {
            .x86_64 => 0x01000007, // CPU_TYPE_X86_64
            .aarch64 => 0x0100000C, // CPU_TYPE_ARM64 (CPU_ARCH_ABI64 | CPU_TYPE_ARM)
            else => return 0,
        };
        if (main_code.len == 0) return 0;

        const header_size: usize = 32;
        const seg_cmd_size: usize = 72; // LC_SEGMENT_64 base (no sections)
        const section_size: usize = 80; // section_64
        const pagezero_size: usize = seg_cmd_size;
        const text_seg_size: usize = seg_cmd_size + section_size;

        // LC_UNIXTHREAD carries the full thread state; layout differs per arch.
        //   x86_64: flavor x86_THREAD_STATE64 (4), count 42 -> 168 state bytes
        //   arm64 : flavor ARM_THREAD_STATE64 (6), count 68 -> 272 state bytes
        const thread_state_words: usize = switch (self.target.arch) {
            .aarch64 => 68,
            else => 42,
        };
        const unixthread_size: usize = 16 + thread_state_words * 4; // cmd,cmdsize,flavor,count + state
        const size_of_cmds: usize = pagezero_size + text_seg_size + unixthread_size;
        const ncmds: u32 = 3;

        // Entry stub sits at the start of __text; main follows immediately.
        const entry_stub_len: usize = switch (self.target.arch) {
            .aarch64 => 16, // bl main; movz x0,#0; movz x16,#1; svc #0x80
            else => 15, // call main; xor edi,edi; mov eax,0x2000001; syscall
        };

        const text_file_off: usize = header_size + size_of_cmds;
        const text_size: usize = entry_stub_len + main_code.len;
        const total_size: usize = text_file_off + text_size;
        if (output.len < total_size) return 0;

        const pagezero_vmsize: u64 = 0x1_0000_0000;
        const text_vmaddr: u64 = pagezero_vmsize; // __TEXT maps right after __PAGEZERO
        const entry_vaddr: u64 = text_vmaddr + @as(u64, @intCast(text_file_off));

        self.zeroBuffer(output[0..total_size]);
        var pos: usize = 0;

        // ── mach_header_64 ──
        self.writeU32LE(output[pos..], 0xFEEDFACF);
        pos += 4; // magic MH_MAGIC_64
        self.writeU32LE(output[pos..], cputype);
        pos += 4;
        self.writeU32LE(output[pos..], 0x03);
        pos += 4; // cpusubtype: *_ALL
        self.writeU32LE(output[pos..], 2);
        pos += 4; // filetype: MH_EXECUTE
        self.writeU32LE(output[pos..], ncmds);
        pos += 4;
        self.writeU32LE(output[pos..], @intCast(size_of_cmds));
        pos += 4;
        self.writeU32LE(output[pos..], 0x1);
        pos += 4; // flags: MH_NOUNDEFS
        self.writeU32LE(output[pos..], 0);
        pos += 4; // reserved

        // ── LC_SEGMENT_64: __PAGEZERO ──
        self.writeU32LE(output[pos..], 0x19);
        pos += 4; // cmd: LC_SEGMENT_64
        self.writeU32LE(output[pos..], @intCast(pagezero_size));
        pos += 4; // cmdsize
        self.writeSegName(output[pos..], "__PAGEZERO");
        pos += 16;
        self.writeU64LE(output[pos..], 0);
        pos += 8; // vmaddr
        self.writeU64LE(output[pos..], pagezero_vmsize);
        pos += 8; // vmsize
        self.writeU64LE(output[pos..], 0);
        pos += 8; // fileoff
        self.writeU64LE(output[pos..], 0);
        pos += 8; // filesize
        self.writeU32LE(output[pos..], 0);
        pos += 4; // maxprot: VM_PROT_NONE
        self.writeU32LE(output[pos..], 0);
        pos += 4; // initprot: VM_PROT_NONE
        self.writeU32LE(output[pos..], 0);
        pos += 4; // nsects
        self.writeU32LE(output[pos..], 0);
        pos += 4; // flags

        // ── LC_SEGMENT_64: __TEXT (covers the header + code) ──
        self.writeU32LE(output[pos..], 0x19);
        pos += 4; // cmd: LC_SEGMENT_64
        self.writeU32LE(output[pos..], @intCast(text_seg_size));
        pos += 4; // cmdsize (base + 1 section)
        self.writeSegName(output[pos..], "__TEXT");
        pos += 16;
        self.writeU64LE(output[pos..], text_vmaddr);
        pos += 8; // vmaddr
        self.writeU64LE(output[pos..], @intCast(alignForward(total_size, 0x1000)));
        pos += 8; // vmsize (page-rounded)
        self.writeU64LE(output[pos..], 0);
        pos += 8; // fileoff (segment starts at 0, includes header)
        self.writeU64LE(output[pos..], @intCast(total_size));
        pos += 8; // filesize
        self.writeU32LE(output[pos..], 0x5);
        pos += 4; // maxprot: READ|EXECUTE
        self.writeU32LE(output[pos..], 0x5);
        pos += 4; // initprot: READ|EXECUTE
        self.writeU32LE(output[pos..], 1);
        pos += 4; // nsects
        self.writeU32LE(output[pos..], 0);
        pos += 4; // flags

        // section_64: __text
        self.writeSegName(output[pos..], "__text");
        pos += 16; // sectname
        self.writeSegName(output[pos..], "__TEXT");
        pos += 16; // segname
        self.writeU64LE(output[pos..], entry_vaddr);
        pos += 8; // addr
        self.writeU64LE(output[pos..], @intCast(text_size));
        pos += 8; // size
        self.writeU32LE(output[pos..], @intCast(text_file_off));
        pos += 4; // offset
        self.writeU32LE(output[pos..], 2);
        pos += 4; // align (2^2 = 4)
        self.writeU32LE(output[pos..], 0);
        pos += 4; // reloff
        self.writeU32LE(output[pos..], 0);
        pos += 4; // nreloc
        self.writeU32LE(output[pos..], 0x80000400);
        pos += 4; // flags: S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS
        self.writeU32LE(output[pos..], 0);
        pos += 4; // reserved1
        self.writeU32LE(output[pos..], 0);
        pos += 4; // reserved2
        self.writeU32LE(output[pos..], 0);
        pos += 4; // reserved3

        // ── LC_UNIXTHREAD: initial register state, PC = entry ──
        self.writeU32LE(output[pos..], 0x5);
        pos += 4; // cmd: LC_UNIXTHREAD
        self.writeU32LE(output[pos..], @intCast(unixthread_size));
        pos += 4; // cmdsize
        switch (self.target.arch) {
            .aarch64 => {
                self.writeU32LE(output[pos..], 6);
                pos += 4; // flavor: ARM_THREAD_STATE64
                self.writeU32LE(output[pos..], 68);
                pos += 4; // count
                // state: x0..x28 (29), fp(x29), lr(x30), sp, pc, cpsr, pad => 68 words.
                // pc is at word index 32 (after 32 x-regs incl. fp/lr, then sp).
                const pc_word_index: usize = 32;
                self.writeU64LE(output[pos + pc_word_index * 4 ..], entry_vaddr);
                pos += 68 * 4;
            },
            else => {
                self.writeU32LE(output[pos..], 4);
                pos += 4; // flavor: x86_THREAD_STATE64
                self.writeU32LE(output[pos..], 42);
                pos += 4; // count
                // x86_THREAD_STATE64 layout (u64 registers): rax,rbx,rcx,rdx,rdi,
                // rsi,rbp,rsp,r8..r15 (16 regs), then rip. rip is the 17th u64,
                // i.e. word index 32.
                const rip_word_index: usize = 32;
                self.writeU64LE(output[pos + rip_word_index * 4 ..], entry_vaddr);
                pos += 42 * 4;
            },
        }

        // ── __text content: entry stub + main ──
        const code_start = text_file_off;
        switch (self.target.arch) {
            .aarch64 => {
                // bl main; movz x0,#0; movz x16,#1 (SYS_exit); svc #0x80
                const bl_imm26: u32 = @intCast(entry_stub_len >> 2);
                self.writeU32LE(output[code_start..], 0x94000000 | (bl_imm26 & 0x03FFFFFF));
                self.writeU32LE(output[code_start + 4 ..], 0xD2800000); // movz x0, #0
                self.writeU32LE(output[code_start + 8 ..], 0xD2800030); // movz x16, #1
                self.writeU32LE(output[code_start + 12 ..], 0xD4001001); // svc #0x80
            },
            else => {
                // call main; xor edi,edi; mov eax,0x2000001 (SYS_exit); syscall
                var c = code_start;
                output[c] = 0xE8;
                self.writeU32LE(output[c + 1 ..], @intCast(entry_stub_len - 5));
                c += 5;
                output[c] = 0x31;
                output[c + 1] = 0xFF; // xor edi, edi
                c += 2;
                output[c] = 0xB8;
                self.writeU32LE(output[c + 1 ..], 0x2000001); // mov eax, SYS_exit
                c += 5;
                output[c] = 0x0F;
                output[c + 1] = 0x05; // syscall
            },
        }
        self.copyBytes(output[code_start + entry_stub_len ..], main_code);

        return total_size;
    }

    /// Emit a WebAssembly module header into the output buffer.
    /// Writes: magic (0x00 0x61 0x73 0x6D), version, and type section placeholder.
    /// Returns bytes written.
    pub fn emitWasm(self: *Linker, output: []u8) usize {
        _ = self;
        var pos: usize = 0;
        if (pos + 8 > output.len) return 0;
        // Wasm magic: \0asm
        output[pos] = 0x00;
        output[pos + 1] = 0x61;
        output[pos + 2] = 0x73;
        output[pos + 3] = 0x6D;
        pos += 4;
        // Version: 1
        output[pos] = 0x01;
        output[pos + 1] = 0x00;
        output[pos + 2] = 0x00;
        output[pos + 3] = 0x00;
        pos += 4;
        return pos;
    }

    /// Emit the consolidated SB0 native image header.
    ///
    /// The format keeps the bounded SB0X loader shape: a fixed 64-byte header
    /// followed by fixed 40-byte segment descriptors. Version 1 is the compiler
    /// side of the consolidated ABI; classic SB0S v0 and Nexus v1 remain inputs
    /// to the final loader contract.
    pub fn emitSb0Native(self: *Linker, output: []u8) usize {
        const default_main = [_]u8{ 0xC0, 0x03, 0x5F, 0xD6 };
        return self.emitSb0NativeExecutable(output, default_main[0..]);
    }

    /// Emit a consolidated SB0 native executable image with one RX text segment.
    pub fn emitSb0NativeExecutable(self: *Linker, output: []u8, main_code: []const u8) usize {
        if (!self.target.isSb0()) return 0;
        if (main_code.len == 0) return 0;
        const metadata_size: usize = SB0_NATIVE_HEADER_SIZE + SB0_NATIVE_SEGMENT_SIZE;
        const total_size: usize = metadata_size + main_code.len;
        if (output.len < total_size) return 0;

        self.zeroBuffer(output);
        var pos: usize = 0;

        // Header: 64 bytes.
        output[pos] = SB0_NATIVE_MAGIC[0];
        output[pos + 1] = SB0_NATIVE_MAGIC[1];
        output[pos + 2] = SB0_NATIVE_MAGIC[2];
        output[pos + 3] = SB0_NATIVE_MAGIC[3];
        pos += 4;
        output[pos] = SB0_NATIVE_FORMAT_VERSION;
        pos += 1;
        output[pos] = 0; // flags
        pos += 1;
        self.writeU16LE(output[pos..], SB0_NATIVE_ABI_VERSION);
        pos += 2;
        self.writeU64LE(output[pos..], 0); // entry_offset within segment 0
        pos += 8;
        self.writeU16LE(output[pos..], 1); // one RX text segment for the first compiler gate
        pos += 2;
        self.writeU16LE(output[pos..], 0); // reserved header field
        pos += 2;
        self.writeU32LE(output[pos..], 0); // tls_template_offset
        pos += 4;
        self.writeU32LE(output[pos..], 0); // tls_template_size
        pos += 4;
        self.writeU32LE(output[pos..], 0); // tls_bss_size
        pos += 4;
        self.writeU64LE(output[pos..], @intCast(alignForward(total_size, 4096)));
        pos += 8;
        self.writeU64LE(output[pos..], 64 * 1024); // default stack_size
        pos += 8;
        var reserved: usize = 0;
        while (reserved < 16) : (reserved += 1) {
            output[pos] = 0;
            pos += 1;
        }

        // Segment 0: RX text segment descriptor, 40 bytes.
        self.writeU64LE(output[pos..], metadata_size);
        pos += 8; // file_offset
        self.writeU64LE(output[pos..], 0);
        pos += 8; // vaddr_offset
        self.writeU64LE(output[pos..], @intCast(main_code.len));
        pos += 8; // file_size
        self.writeU64LE(output[pos..], @intCast(alignForward(main_code.len, 4096)));
        pos += 8; // mem_size
        self.writeU32LE(output[pos..], 0b101);
        pos += 4; // readable + executable
        self.writeU32LE(output[pos..], 0);
        pos += 4; // segment padding

        self.copyBytes(output[pos..], main_code);
        return total_size;
    }

    /// Emit a native SB0 kernel image directly from already-relocated AArch64
    /// code. Kernel and application images share the `aarch64-sb0` register
    /// and calling convention; `SB0K` identifies the privileged artifact.
    ///
    /// Header layout (64 bytes):
    ///   0x00 magic `SB0K`
    ///   0x04 format version (u16)
    ///   0x06 header bytes (u16)
    ///   0x08 boot ABI version (u16)
    ///   0x0a ABI revision (u16)
    ///   0x0c flags (u32)
    ///   0x10 entry offset (u64)
    ///   0x18 total image bytes (u64)
    ///   0x20 relocation offset (u64; zero means none)
    ///   0x28 relocation count (u32)
    ///   0x2c relocation entry bytes (u32)
    ///   0x30 build identity (u64)
    ///   0x38 preferred physical base (u64; zero means loader-selected)
    pub fn emitSb0Kernel(
        self: *Linker,
        output: []u8,
        reset_code: []const u8,
        build_identity: u64,
        preferred_physical_base: u64,
    ) usize {
        if (!self.target.isSb0()) return 0;
        if (reset_code.len == 0) return 0;

        const total_size = SB0_KERNEL_HEADER_SIZE + reset_code.len;
        if (output.len < total_size) return 0;

        self.zeroBuffer(output[0..total_size]);
        output[0] = SB0_KERNEL_MAGIC[0];
        output[1] = SB0_KERNEL_MAGIC[1];
        output[2] = SB0_KERNEL_MAGIC[2];
        output[3] = SB0_KERNEL_MAGIC[3];
        self.writeU16LE(output[4..], SB0_KERNEL_FORMAT_VERSION);
        self.writeU16LE(output[6..], @intCast(SB0_KERNEL_HEADER_SIZE));
        self.writeU16LE(output[8..], SB0_KERNEL_BOOT_ABI_VERSION);
        self.writeU16LE(output[10..], 0);
        self.writeU32LE(output[12..], SB0_KERNEL_FLAG_FIXED_LAYOUT);
        self.writeU64LE(output[16..], SB0_KERNEL_HEADER_SIZE);
        self.writeU64LE(output[24..], @intCast(total_size));
        self.writeU64LE(output[32..], 0);
        self.writeU32LE(output[40..], 0);
        self.writeU32LE(output[44..], 0);
        self.writeU64LE(output[48..], build_identity);
        self.writeU64LE(output[56..], preferred_physical_base);
        self.copyBytes(output[SB0_KERNEL_HEADER_SIZE..total_size], reset_code);
        return total_size;
    }

    /// Emit raw machine code for freestanding targets.
    pub fn emitRaw(self: *Linker, output: []u8, main_code: []const u8) usize {
        _ = self;
        if (output.len < main_code.len) return 0;
        var i: usize = 0;
        while (i < main_code.len) : (i += 1) {
            output[i] = main_code[i];
        }
        return main_code.len;
    }

    // ── Diagnostic Emission ──

    /// Emit diagnostics for all unresolved relocations.
    /// For each relocation whose symbol is not defined, records a diagnostic
    /// naming the symbol index and the referencing offset.
    /// Returns the number of unresolved symbols found.
    pub fn emitUnresolvedDiagnostics(self: *Linker, diag_buf: []u8) usize {
        var pos: usize = 0;
        var unresolved_count: usize = 0;
        const total = self.relocations.len();
        var i: usize = 0;
        while (i < total) : (i += 1) {
            const reloc = self.relocations.get(i);
            const sym_hash: u64 = @intCast(reloc.symbol_index);
            var is_resolved = false;
            if (self.externals.get(sym_hash)) |sym| {
                if (sym.is_defined) is_resolved = true;
            }
            if (!is_resolved) {
                unresolved_count += 1;
                // Format: "unresolved symbol at offset <offset>\n"
                const msg = "unresolved symbol at offset ";
                if (pos + msg.len + 20 <= diag_buf.len) {
                    for (msg) |c| {
                        diag_buf[pos] = c;
                        pos += 1;
                    }
                    pos += writeU64Decimal(diag_buf[pos..], reloc.offset);
                    diag_buf[pos] = '\n';
                    pos += 1;
                }
            }
        }
        return unresolved_count;
    }

    // ── Internal helpers ──

    /// Write a u16 in little-endian format to the buffer.
    fn writeU16LE(self: *const Linker, buf: []u8, val: u16) void {
        _ = self;
        buf[0] = @truncate(val);
        buf[1] = @truncate(val >> 8);
    }

    /// Write a u32 in little-endian format to the buffer.
    fn writeU32LE(self: *const Linker, buf: []u8, val: u32) void {
        _ = self;
        buf[0] = @truncate(val);
        buf[1] = @truncate(val >> 8);
        buf[2] = @truncate(val >> 16);
        buf[3] = @truncate(val >> 24);
    }

    /// Write a u64 in little-endian format to the buffer.
    fn writeU64LE(self: *const Linker, buf: []u8, val: u64) void {
        _ = self;
        buf[0] = @truncate(val);
        buf[1] = @truncate(val >> 8);
        buf[2] = @truncate(val >> 16);
        buf[3] = @truncate(val >> 24);
        buf[4] = @truncate(val >> 32);
        buf[5] = @truncate(val >> 40);
        buf[6] = @truncate(val >> 48);
        buf[7] = @truncate(val >> 56);
    }

    /// Write a Mach-O 16-byte fixed segment/section name field, zero-padded.
    /// Names longer than 16 bytes are truncated; the field is not required to
    /// be NUL-terminated when it uses the full 16 bytes.
    fn writeSegName(self: *const Linker, buf: []u8, name: []const u8) void {
        _ = self;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            buf[i] = if (i < name.len) name[i] else 0;
        }
    }

    /// Zero the full destination buffer before writing a deterministic image.
    fn zeroBuffer(self: *const Linker, buf: []u8) void {
        _ = self;
        for (buf) |*b| {
            b.* = 0;
        }
    }

    /// Copy bytes into a destination slice. Caller must ensure it fits.
    fn copyBytes(self: *const Linker, dst: []u8, src: []const u8) void {
        _ = self;
        var i: usize = 0;
        while (i < src.len) : (i += 1) {
            dst[i] = src[i];
        }
    }

    /// Round `value` up to the next multiple of `alignment`.
    fn alignForward(value: usize, alignment: usize) usize {
        return (value + alignment - 1) & ~(alignment - 1);
    }

    /// Write a u64 as decimal digits into the buffer. Returns the number of bytes written.
    fn writeU64Decimal(buf: []u8, value: u64) usize {
        if (value == 0) {
            buf[0] = '0';
            return 1;
        }
        var tmp: [20]u8 = undefined;
        var n = value;
        var count: usize = 0;
        while (n > 0) : (count += 1) {
            tmp[count] = @intCast((n % 10) + '0');
            n /= 10;
        }
        var i: usize = 0;
        while (i < count) : (i += 1) {
            buf[i] = tmp[count - 1 - i];
        }
        return count;
    }

    /// Patch code bytes at the given offset with the computed address.
    /// The patch format depends on the relocation type.
    fn patchCode(self: *const Linker, code: []u8, offset: u64, addr: u64, rel_type: Relocation.Rel_Type) void {
        _ = self;
        const off: usize = @intCast(offset);

        switch (rel_type) {
            // 32-bit relative relocations (x86_64 PC-relative)
            .r_x86_64_pc32, .r_x86_64_plt32, .r_x86_64_32, .r_x86_64_32s, .r_x86_64_gotpcrel => {
                if (off + 4 <= code.len) {
                    const val: u32 = @truncate(addr);
                    code[off] = @truncate(val);
                    code[off + 1] = @truncate(val >> 8);
                    code[off + 2] = @truncate(val >> 16);
                    code[off + 3] = @truncate(val >> 24);
                }
            },
            // 64-bit absolute relocation
            .r_x86_64_64 => {
                if (off + 8 <= code.len) {
                    const val: u64 = addr;
                    code[off] = @truncate(val);
                    code[off + 1] = @truncate(val >> 8);
                    code[off + 2] = @truncate(val >> 16);
                    code[off + 3] = @truncate(val >> 24);
                    code[off + 4] = @truncate(val >> 32);
                    code[off + 5] = @truncate(val >> 40);
                    code[off + 6] = @truncate(val >> 48);
                    code[off + 7] = @truncate(val >> 56);
                }
            },
            // AArch64 — 26-bit call offset (4-byte aligned)
            .r_aarch64_call26 => {
                if (off + 4 <= code.len) {
                    const val: u32 = @truncate(addr >> 2);
                    const imm26 = val & 0x03FFFFFF;
                    // Patch lower 26 bits of the instruction
                    var insn: u32 = @as(u32, code[off]) |
                        (@as(u32, code[off + 1]) << 8) |
                        (@as(u32, code[off + 2]) << 16) |
                        (@as(u32, code[off + 3]) << 24);
                    insn = (insn & 0xFC000000) | imm26;
                    code[off] = @truncate(insn);
                    code[off + 1] = @truncate(insn >> 8);
                    code[off + 2] = @truncate(insn >> 16);
                    code[off + 3] = @truncate(insn >> 24);
                }
            },
            // AArch64 page-relative
            .r_aarch64_adr_prel_pg_hi21, .r_aarch64_add_abs_lo12_nc, .r_aarch64_ldst64_abs_lo12_nc => {
                if (off + 4 <= code.len) {
                    const val: u32 = @truncate(addr);
                    code[off] = @truncate(val);
                    code[off + 1] = @truncate(val >> 8);
                    code[off + 2] = @truncate(val >> 16);
                    code[off + 3] = @truncate(val >> 24);
                }
            },
            // ARM 32-bit relocations
            .r_arm_call, .r_arm_movw_abs_nc, .r_arm_movt_abs, .r_arm_prel31 => {
                if (off + 4 <= code.len) {
                    const val: u32 = @truncate(addr);
                    code[off] = @truncate(val);
                    code[off + 1] = @truncate(val >> 8);
                    code[off + 2] = @truncate(val >> 16);
                    code[off + 3] = @truncate(val >> 24);
                }
            },
            // RISC-V 32-bit relocations
            .r_riscv_call, .r_riscv_hi20, .r_riscv_lo12_i, .r_riscv_lo12_s, .r_riscv_pcrel_hi20 => {
                if (off + 4 <= code.len) {
                    const val: u32 = @truncate(addr);
                    code[off] = @truncate(val);
                    code[off + 1] = @truncate(val >> 8);
                    code[off + 2] = @truncate(val >> 16);
                    code[off + 3] = @truncate(val >> 24);
                }
            },
            // WebAssembly — index-based relocations (32-bit)
            .r_wasm_function_index, .r_wasm_table_index, .r_wasm_memory_addr, .r_wasm_global_index => {
                if (off + 4 <= code.len) {
                    const val: u32 = @truncate(addr);
                    code[off] = @truncate(val);
                    code[off + 1] = @truncate(val >> 8);
                    code[off + 2] = @truncate(val >> 16);
                    code[off + 3] = @truncate(val >> 24);
                }
            },
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = @import("std").testing;

test "Linker init creates empty state" {
    const target = Target_Triple{ .arch = .x86_64, .os = .linux, .abi = .gnu };
    const linker = Linker.init(target);
    try testing.expect(!(linker.sectionCount() != 0)); // new linker should have 0 sections
    try testing.expect(!(linker.relocationCount() != 0)); // new linker should have 0 relocations
    try testing.expect(!(linker.output_offset != 0)); // new linker should have output_offset = 0
}

test "addSection increments section count" {
    const target = Target_Triple{ .arch = .x86_64, .os = .linux, .abi = .gnu };
    var linker = Linker.init(target);
    var entry = Section_Entry{};
    entry.name[0] = '.';
    entry.name[1] = 't';
    entry.name[2] = 'e';
    entry.name[3] = 'x';
    entry.name[4] = 't';
    entry.name_len = 5;
    entry.size = 1024;
    entry.alignment = 16;
    linker.addSection(entry);
    try testing.expect(!(linker.sectionCount() != 1)); // expected 1 section after addSection
}

test "addRelocation increments relocation count" {
    const target = Target_Triple{ .arch = .x86_64, .os = .linux, .abi = .gnu };
    var linker = Linker.init(target);
    const reloc = Relocation{
        .offset = 0x10,
        .symbol_index = 1,
        .rel_type = .r_x86_64_pc32,
        .addend = 0,
    };
    linker.addRelocation(reloc);
    try testing.expect(!(linker.relocationCount() != 1)); // expected 1 relocation after addRelocation
}

test "streamingFlush clears relocation table" {
    const target = Target_Triple{ .arch = .x86_64, .os = .linux, .abi = .gnu };
    var linker = Linker.init(target);
    const reloc = Relocation{
        .offset = 0x10,
        .symbol_index = 1,
        .rel_type = .r_x86_64_pc32,
        .addend = 0,
    };
    linker.addRelocation(reloc);
    linker.addRelocation(reloc);
    try testing.expect(!(linker.relocationCount() != 2)); // expected 2 relocations
    linker.streamingFlush();
    try testing.expect(!(linker.relocationCount() != 0)); // expected 0 relocations after flush
}

test "resolveRelocations patches defined symbols" {
    const target = Target_Triple{ .arch = .x86_64, .os = .linux, .abi = .gnu };
    var linker = Linker.init(target);

    // Register a defined external symbol with hash = 42
    const sym = External_Symbol{
        .name_hash = 42,
        .section_index = 0,
        .offset = 0x1000,
        .size = 16,
        .is_defined = true,
    };
    linker.addExternalSymbol(sym);

    // Add a relocation referencing symbol_index 42 at offset 0
    const reloc = Relocation{
        .offset = 0,
        .symbol_index = 42,
        .rel_type = .r_x86_64_pc32,
        .addend = 0,
    };
    linker.addRelocation(reloc);

    // Code buffer to be patched
    var code = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    const resolved = linker.resolveRelocations(&code);

    try testing.expect(!(resolved != 1)); // expected 1 resolved relocation
    try testing.expect(!(linker.relocationCount() != 0)); // resolved relocations should be removed

    // Verify code was patched with address 0x1000 (little-endian 32-bit)
    try testing.expect(!(code[0] != 0x00)); // byte 0 should be 0x00
    try testing.expect(!(code[1] != 0x10)); // byte 1 should be 0x10
    try testing.expect(!(code[2] != 0x00)); // byte 2 should be 0x00
    try testing.expect(!(code[3] != 0x00)); // byte 3 should be 0x00
}

test "resolveRelocations keeps unresolved relocations" {
    const target = Target_Triple{ .arch = .x86_64, .os = .linux, .abi = .gnu };
    var linker = Linker.init(target);

    // Add a relocation with no corresponding external symbol
    const reloc = Relocation{
        .offset = 0x10,
        .symbol_index = 99,
        .rel_type = .r_x86_64_64,
        .addend = 0,
    };
    linker.addRelocation(reloc);

    var code = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    const resolved = linker.resolveRelocations(&code);

    try testing.expect(!(resolved != 0)); // no symbols defined — nothing should resolve
    try testing.expect(!(linker.relocationCount() != 1)); // unresolved relocation should remain
}

test "resolveRelocations with undefined symbol keeps relocation" {
    const target = Target_Triple{ .arch = .x86_64, .os = .linux, .abi = .gnu };
    var linker = Linker.init(target);

    // Register an undefined external symbol
    const sym = External_Symbol{
        .name_hash = 7,
        .section_index = 0,
        .offset = 0,
        .size = 0,
        .is_defined = false,
    };
    linker.addExternalSymbol(sym);

    const reloc = Relocation{
        .offset = 0,
        .symbol_index = 7,
        .rel_type = .r_x86_64_pc32,
        .addend = 0,
    };
    linker.addRelocation(reloc);

    var code = [_]u8{ 0, 0, 0, 0 };
    const resolved = linker.resolveRelocations(&code);

    try testing.expect(!(resolved != 0)); // undefined symbol should not resolve
    try testing.expect(!(linker.relocationCount() != 1)); // relocation for undefined sym should remain
}

test "addExternalSymbol allows lookup via externals" {
    const target = Target_Triple{ .arch = .aarch64, .os = .macos, .abi = .none };
    var linker = Linker.init(target);

    const sym = External_Symbol{
        .name_hash = 123,
        .section_index = 1,
        .offset = 0x2000,
        .size = 32,
        .is_defined = true,
    };
    linker.addExternalSymbol(sym);

    try testing.expect(!(linker.externals.get(123) == null)); // should find symbol with hash 123
    const found = linker.externals.get(123).?;
    try testing.expect(!(found.offset != 0x2000)); // symbol offset should be 0x2000
    try testing.expect(!(!found.is_defined)); // symbol should be defined
}

test "resolveRelocations applies addend correctly" {
    const target = Target_Triple{ .arch = .x86_64, .os = .linux, .abi = .gnu };
    var linker = Linker.init(target);

    const sym = External_Symbol{
        .name_hash = 10,
        .section_index = 0,
        .offset = 0x100,
        .size = 8,
        .is_defined = true,
    };
    linker.addExternalSymbol(sym);

    // Relocation with addend of 4
    const reloc = Relocation{
        .offset = 0,
        .symbol_index = 10,
        .rel_type = .r_x86_64_pc32,
        .addend = 4,
    };
    linker.addRelocation(reloc);

    var code = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    const resolved = linker.resolveRelocations(&code);

    try testing.expect(!(resolved != 1)); // expected 1 resolved
    // Final address = 0x100 + 4 = 0x104
    try testing.expect(!(code[0] != 0x04)); // byte 0 should be 0x04
    try testing.expect(!(code[1] != 0x01)); // byte 1 should be 0x01
    try testing.expect(!(code[2] != 0x00)); // byte 2 should be 0x00
    try testing.expect(!(code[3] != 0x00)); // byte 3 should be 0x00
}

test "multiple sections accumulate correctly" {
    const target = Target_Triple{ .arch = .x86_64, .os = .windows, .abi = .msvc };
    var linker = Linker.init(target);

    var text_section = Section_Entry{};
    text_section.name[0] = '.';
    text_section.name[1] = 't';
    text_section.name_len = 2;
    text_section.size = 512;
    text_section.alignment = 16;
    text_section.flags = 0x6; // SHF_ALLOC | SHF_EXECINSTR

    var data_section = Section_Entry{};
    data_section.name[0] = '.';
    data_section.name[1] = 'd';
    data_section.name_len = 2;
    data_section.size = 256;
    data_section.alignment = 8;
    data_section.flags = 0x3; // SHF_ALLOC | SHF_WRITE

    linker.addSection(text_section);
    linker.addSection(data_section);

    try testing.expect(!(linker.sectionCount() != 2)); // expected 2 sections
}

test "emitElf produces ELF magic" {
    const target = Target_Triple{ .arch = .x86_64, .os = .linux, .abi = .gnu };
    var linker = Linker.init(target);
    // ELF64 header + program header + entry stub + one-byte main = 135 bytes.
    var buf: [256]u8 = undefined;
    const written = linker.emitElf(&buf);
    try testing.expect(!(written < 64)); // ELF header should be at least 64 bytes
    if (buf[0] != 0x7f or buf[1] != 'E' or buf[2] != 'L' or buf[3] != 'F')
        return error.TestUnexpectedResult; // ELF magic incorrect
}

test "emitPeCoff produces MZ magic" {
    const target = Target_Triple{ .arch = .x86_64, .os = .windows, .abi = .msvc };
    var linker = Linker.init(target);
    // PE32+ headers and the aligned .text/import section require 1024 bytes.
    var buf: [1024]u8 = undefined;
    const written = linker.emitPeCoff(&buf);
    try testing.expect(!(written < 68)); // PE header should be at least 68 bytes
    try testing.expect(!(buf[0] != 0x4D or buf[1] != 0x5A)); // MZ magic incorrect
}

test "emitMachO produces Mach-O magic" {
    const target = Target_Triple{ .arch = .aarch64, .os = .macos, .abi = .none };
    var linker = Linker.init(target);
    var buf: [1024]u8 = undefined;
    const written = linker.emitMachO(&buf);
    try testing.expect(!(written < 32)); // Mach-O header should be at least 32 bytes
    // 0xFEEDFACF in little-endian
    if (buf[0] != 0xCF or buf[1] != 0xFA or buf[2] != 0xED or buf[3] != 0xFE)
        return error.TestUnexpectedResult; // Mach-O magic incorrect
}

test "emitWasm produces Wasm magic" {
    const target = Target_Triple{ .arch = .wasm32, .os = .freestanding, .abi = .none };
    var linker = Linker.init(target);
    var buf: [16]u8 = undefined;
    const written = linker.emitWasm(&buf);
    try testing.expect(!(written != 8)); // Wasm header should be 8 bytes
    if (buf[0] != 0x00 or buf[1] != 0x61 or buf[2] != 0x73 or buf[3] != 0x6D)
        return error.TestUnexpectedResult; // Wasm magic incorrect
}

test "emitSb0Native produces consolidated SB0 magic and fixed metadata sizes" {
    const target = Target_Triple{ .arch = .aarch64, .os = .sb0, .abi = .sb0 };
    var linker = Linker.init(target);
    var buf: [256]u8 = undefined;
    const written = linker.emitSb0Native(&buf);
    const default_main_size: usize = 4;
    if (written != SB0_NATIVE_HEADER_SIZE + SB0_NATIVE_SEGMENT_SIZE + default_main_size)
        return error.TestUnexpectedResult; // SB0 image size mismatch
    if (buf[0] != 'S' or buf[1] != 'B' or buf[2] != '0' or buf[3] != 'X')
        return error.TestUnexpectedResult; // SB0 magic incorrect
    if (buf[4] != SB0_NATIVE_FORMAT_VERSION)
        return error.TestUnexpectedResult; // SB0 format version mismatch
    if (buf[6] != @as(u8, @truncate(SB0_NATIVE_ABI_VERSION)))
        return error.TestUnexpectedResult; // SB0 ABI version low byte mismatch
    if (buf[16] != 1 or buf[17] != 0)
        return error.TestUnexpectedResult; // SB0 should emit one initial segment
}

test "emitSb0Native rejects non-SB0 target" {
    const target = Target_Triple{ .arch = .aarch64, .os = .linux, .abi = .gnu };
    var linker = Linker.init(target);
    var buf: [256]u8 = undefined;
    const written = linker.emitSb0Native(&buf);
    try testing.expect(!(written != 0)); // non-SB0 targets should not emit SB0 native image
}

test "emitSb0Kernel writes the direct native kernel container" {
    const target = Target_Triple{ .arch = .aarch64, .os = .sb0, .abi = .sb0 };
    var linker = Linker.init(target);
    const reset_code = [_]u8{
        0x5f, 0x20, 0x03, 0xd5, // wfe
        0xff, 0xff, 0xff, 0x17, // b .
    };
    var buf: [128]u8 = undefined;
    const written = linker.emitSb0Kernel(
        &buf,
        &reset_code,
        0x0102_0304_0506_0708,
        0x0000_0000_8000_0000,
    );

    try testing.expect(!(written != SB0_KERNEL_HEADER_SIZE + reset_code.len));
    if (buf[0] != 'S' or buf[1] != 'B' or buf[2] != '0' or buf[3] != 'K')
        return error.TestUnexpectedResult;
    try testing.expect(!(buf[4] != 1 or buf[5] != 0));
    try testing.expect(!(buf[6] != 64 or buf[7] != 0));
    try testing.expect(!(buf[8] != 1 or buf[9] != 0));
    try testing.expect(!(buf[12] != 1));
    try testing.expect(!(buf[16] != 64));
    try testing.expect(!(buf[24] != @as(u8, @intCast(written))));
    try testing.expect(!(buf[48] != 0x08 or buf[55] != 0x01));
    try testing.expect(!(buf[59] != 0x80));
    for (reset_code, 0..) |byte, i| {
        try testing.expect(!(buf[SB0_KERNEL_HEADER_SIZE + i] != byte));
    }
}

test "emitSb0Kernel rejects every non-SB0 target" {
    var linker = Linker.init(.{ .arch = .aarch64, .os = .freestanding, .abi = .none });
    const reset_code = [_]u8{ 0x5f, 0x20, 0x03, 0xd5 };
    var buf: [128]u8 = undefined;
    try testing.expect(!(linker.emitSb0Kernel(&buf, &reset_code, 0, 0) != 0));
}

test "SB0 kernel header cannot identify as a foreign container" {
    var linker = Linker.init(.{ .arch = .aarch64, .os = .sb0, .abi = .sb0 });
    const reset_code = [_]u8{ 0x5f, 0x20, 0x03, 0xd5 };
    var buf: [128]u8 = undefined;
    const written = linker.emitSb0Kernel(&buf, &reset_code, 0, 0);
    try testing.expect(!(written == 0));

    // Foreign executable magics are rejected at the artifact boundary.
    try testing.expect(!(buf[0] == 0x7f and buf[1] == 'E' and buf[2] == 'L' and buf[3] == 'F'));
    try testing.expect(!(buf[0] == 'M' and buf[1] == 'Z'));
    try testing.expect(!(buf[0] == 0xcf and buf[1] == 0xfa and buf[2] == 0xed and buf[3] == 0xfe));
}

// ============================================================================
// Property 15: Linker output format correctness
// **Validates: Requirements 6.3, 6.4, 7.2**
// ============================================================================

test "linker output format - ELF magic is 0x7f454c46" {
    var linker = Linker.init(.{ .arch = .x86_64, .os = .linux, .abi = .gnu });
    var buf: [256]u8 = undefined;
    const n = linker.emitElf(&buf);
    try testing.expect(!(n < 4)); // ELF too short
    if (buf[0] != 0x7f or buf[1] != 0x45 or buf[2] != 0x4C or buf[3] != 0x46)
        return error.TestUnexpectedResult; // ELF magic wrong
}

test "linker output format - PE magic is 0x4d5a" {
    var linker = Linker.init(.{ .arch = .x86_64, .os = .windows, .abi = .msvc });
    var buf: [1024]u8 = undefined;
    const n = linker.emitPeCoff(&buf);
    try testing.expect(!(n < 2)); // PE too short
    try testing.expect(!(buf[0] != 0x4D or buf[1] != 0x5A)); // PE magic wrong
}

test "linker output format - Wasm magic is 0x0061736d" {
    var linker = Linker.init(.{ .arch = .wasm32, .os = .freestanding, .abi = .none });
    var buf: [16]u8 = undefined;
    const n = linker.emitWasm(&buf);
    try testing.expect(!(n < 4)); // Wasm too short
    if (buf[0] != 0x00 or buf[1] != 0x61 or buf[2] != 0x73 or buf[3] != 0x6D)
        return error.TestUnexpectedResult; // Wasm magic wrong
}

test "linker output format - SB0 native magic is SB0X" {
    var linker = Linker.init(.{ .arch = .aarch64, .os = .sb0, .abi = .sb0 });
    var buf: [256]u8 = undefined;
    const n = linker.emitSb0Native(&buf);
    try testing.expect(!(n < 4)); // SB0 native image too short
    if (buf[0] != 'S' or buf[1] != 'B' or buf[2] != '0' or buf[3] != 'X')
        return error.TestUnexpectedResult; // SB0 native magic wrong
}

// ============================================================================
// Property 16: Unresolved symbol diagnostics
// **Validates: Requirements 6.5**
// ============================================================================

test "unresolved symbol diagnostics - reports unresolved" {
    var linker = Linker.init(.{ .arch = .x86_64, .os = .linux, .abi = .gnu });
    const reloc = Relocation{ .offset = 0x42, .symbol_index = 99, .rel_type = .r_x86_64_pc32, .addend = 0 };
    linker.addRelocation(reloc);
    var diag_buf: [256]u8 = undefined;
    const count = linker.emitUnresolvedDiagnostics(&diag_buf);
    try testing.expect(!(count != 1)); // should report 1 unresolved symbol
}

test "unresolved symbol diagnostics - no report for defined symbols" {
    var linker = Linker.init(.{ .arch = .x86_64, .os = .linux, .abi = .gnu });
    linker.addExternalSymbol(.{ .name_hash = 5, .section_index = 0, .offset = 0x100, .size = 8, .is_defined = true });
    const reloc = Relocation{ .offset = 0, .symbol_index = 5, .rel_type = .r_x86_64_pc32, .addend = 0 };
    linker.addRelocation(reloc);
    var diag_buf: [256]u8 = undefined;
    const count = linker.emitUnresolvedDiagnostics(&diag_buf);
    try testing.expect(!(count != 0)); // defined symbol should not be reported as unresolved
}

// ============================================================================
// Property 17: Multi-unit section merge
// **Validates: Requirements 6.6**
// ============================================================================

test "multi-unit section merge - sections accumulate" {
    var linker = Linker.init(.{ .arch = .x86_64, .os = .linux, .abi = .gnu });
    var s1 = Section_Entry{};
    s1.size = 100;
    s1.name_len = 1;
    s1.name[0] = 'a';
    var s2 = Section_Entry{};
    s2.size = 200;
    s2.name_len = 1;
    s2.name[0] = 'b';
    var s3 = Section_Entry{};
    s3.size = 300;
    s3.name_len = 1;
    s3.name[0] = 'c';
    linker.addSection(s1);
    linker.addSection(s2);
    linker.addSection(s3);
    try testing.expect(!(linker.sectionCount() != 3)); // expected 3 sections
}

test "multi-unit section merge - relocations from multiple units" {
    var linker = Linker.init(.{ .arch = .aarch64, .os = .linux, .abi = .gnu });
    // Simulate two compilation units adding relocations
    const r1 = Relocation{ .offset = 0x10, .symbol_index = 1, .rel_type = .r_aarch64_call26, .addend = 0 };
    const r2 = Relocation{ .offset = 0x20, .symbol_index = 2, .rel_type = .r_aarch64_call26, .addend = 0 };
    linker.addRelocation(r1);
    linker.addRelocation(r2);
    try testing.expect(!(linker.relocationCount() != 2)); // expected 2 relocations from 2 units
}

// ============================================================================
// Cross-OS multi-target executable emission
//
// Validates that a single host can emit runnable images for every sls-shipped
// target: x86_64 + aarch64 for Linux (ELF), Windows (PE/COFF) and macOS
// (Mach-O). aarch64-sb0 (SB0X/SB0K) is covered by the SB0 tests above.
// ============================================================================

test "ELF aarch64 - EM_AARCH64 machine and aarch64 _start stub" {
    var linker = Linker.init(.{ .arch = .aarch64, .os = .linux, .abi = .gnu });
    // aarch64 main body: a single `ret` (0xD65F03C0).
    const main_code = [_]u8{ 0xC0, 0x03, 0x5F, 0xD6 };
    var buf: [512]u8 = undefined;
    const n = linker.emitElfExecutable(&buf, &main_code);
    try testing.expect(!(n == 0)); // aarch64 ELF should emit

    // ELF magic.
    if (buf[0] != 0x7f or buf[1] != 'E' or buf[2] != 'L' or buf[3] != 'F')
        return error.TestUnexpectedResult;
    // e_machine at offset 18 == EM_AARCH64 (0xB7).
    try testing.expect(!(buf[18] != 0xB7 or buf[19] != 0x00));

    // _start stub begins right after ELF header (64) + program header (56) = 120.
    const stub_off: usize = 120;
    // First instruction: bl main => 0x94000004 (imm26 = 16/4 = 4), little-endian.
    try testing.expect(!(buf[stub_off + 0] != 0x04));
    try testing.expect(!(buf[stub_off + 1] != 0x00));
    try testing.expect(!(buf[stub_off + 2] != 0x00));
    try testing.expect(!(buf[stub_off + 3] != 0x94));
    // svc #0 as the last stub instruction: 0xD4000001.
    try testing.expect(!(buf[stub_off + 12] != 0x01));
    try testing.expect(!(buf[stub_off + 15] != 0xD4));
    // main body copied immediately after the 16-byte stub.
    try testing.expect(!(buf[stub_off + 16] != 0xC0));
    try testing.expect(!(buf[stub_off + 19] != 0xD6));
}

test "ELF x86_64 still emits EM_X86_64" {
    var linker = Linker.init(.{ .arch = .x86_64, .os = .linux, .abi = .gnu });
    var buf: [256]u8 = undefined;
    const n = linker.emitElf(&buf);
    try testing.expect(!(n == 0));
    try testing.expect(!(buf[18] != 0x3E or buf[19] != 0x00)); // EM_X86_64
}

test "ELF rejects unsupported arch" {
    var linker = Linker.init(.{ .arch = .riscv64, .os = .linux, .abi = .gnu });
    const main_code = [_]u8{ 0x67, 0x80, 0x00, 0x00 };
    var buf: [256]u8 = undefined;
    try testing.expect(!(linker.emitElfExecutable(&buf, &main_code) != 0));
}

test "PE aarch64 - ARM64 machine field and aarch64 entry stub" {
    var linker = Linker.init(.{ .arch = .aarch64, .os = .windows, .abi = .msvc });
    const main_code = [_]u8{ 0xC0, 0x03, 0x5F, 0xD6 }; // ret
    var buf: [2048]u8 = undefined;
    const n = linker.emitPeCoffExecutable(&buf, &main_code);
    try testing.expect(!(n == 0)); // aarch64 PE should emit

    // MZ magic.
    try testing.expect(!(buf[0] != 0x4D or buf[1] != 0x5A));
    // PE signature at 0x80.
    try testing.expect(!(buf[0x80] != 'P' or buf[0x81] != 'E'));
    // Machine field right after PE\0\0 (offset 0x84) == IMAGE_FILE_MACHINE_ARM64 (0xAA64).
    try testing.expect(!(buf[0x84] != 0x64 or buf[0x85] != 0xAA));

    // Entry stub begins at file offset headers_size (0x200); first insn is `bl main`.
    const code_off: usize = 0x200;
    // bl main => imm26 = 20/4 = 5 => 0x94000005.
    try testing.expect(!(buf[code_off + 0] != 0x05));
    try testing.expect(!(buf[code_off + 3] != 0x94));
    // blr x16 as the final stub instruction: 0xD63F0200.
    try testing.expect(!(buf[code_off + 16] != 0x00));
    try testing.expect(!(buf[code_off + 19] != 0xD6));
}

test "PE x86_64 still emits AMD64 machine field" {
    var linker = Linker.init(.{ .arch = .x86_64, .os = .windows, .abi = .msvc });
    var buf: [1024]u8 = undefined;
    const n = linker.emitPeCoff(&buf);
    try testing.expect(!(n == 0));
    try testing.expect(!(buf[0x84] != 0x64 or buf[0x85] != 0x86)); // 0x8664 AMD64
}

test "PE rejects unsupported arch" {
    var linker = Linker.init(.{ .arch = .arm, .os = .windows, .abi = .msvc });
    const main_code = [_]u8{ 0x1E, 0xFF, 0x2F, 0xE1 };
    var buf: [1024]u8 = undefined;
    try testing.expect(!(linker.emitPeCoffExecutable(&buf, &main_code) != 0));
}

test "MachO x86_64 - runnable executable with LC_UNIXTHREAD" {
    var linker = Linker.init(.{ .arch = .x86_64, .os = .macos, .abi = .none });
    const main_code = [_]u8{0xC3}; // ret
    var buf: [1024]u8 = undefined;
    const n = linker.emitMachOExecutable(&buf, &main_code);
    try testing.expect(!(n == 0)); // x86_64 Mach-O should emit

    // MH_MAGIC_64 = 0xFEEDFACF (little-endian).
    if (buf[0] != 0xCF or buf[1] != 0xFA or buf[2] != 0xED or buf[3] != 0xFE)
        return error.TestUnexpectedResult;
    // cputype at offset 4 == CPU_TYPE_X86_64 (0x01000007).
    try testing.expect(!(buf[4] != 0x07 or buf[5] != 0x00 or buf[6] != 0x00 or buf[7] != 0x01));
    // filetype at offset 12 == MH_EXECUTE (2).
    try testing.expect(!(buf[12] != 0x02 or buf[13] != 0x00));
    // ncmds at offset 16 == 3.
    try testing.expect(!(buf[16] != 0x03));
    // First load command is LC_SEGMENT_64 (0x19) at offset 32.
    try testing.expect(!(buf[32] != 0x19));
}

test "MachO aarch64 - ARM64 cputype and runnable executable" {
    var linker = Linker.init(.{ .arch = .aarch64, .os = .macos, .abi = .none });
    const main_code = [_]u8{ 0xC0, 0x03, 0x5F, 0xD6 }; // ret
    var buf: [1024]u8 = undefined;
    const n = linker.emitMachOExecutable(&buf, &main_code);
    try testing.expect(!(n == 0)); // aarch64 Mach-O should emit

    if (buf[0] != 0xCF or buf[1] != 0xFA or buf[2] != 0xED or buf[3] != 0xFE)
        return error.TestUnexpectedResult;
    // cputype == CPU_TYPE_ARM64 (0x0100000C).
    try testing.expect(!(buf[4] != 0x0C or buf[5] != 0x00 or buf[6] != 0x00 or buf[7] != 0x01));
    try testing.expect(!(buf[12] != 0x02 or buf[13] != 0x00)); // MH_EXECUTE
    try testing.expect(!(buf[16] != 0x03)); // ncmds
}

test "MachO rejects unsupported arch" {
    var linker = Linker.init(.{ .arch = .riscv64, .os = .macos, .abi = .none });
    const main_code = [_]u8{ 0x67, 0x80, 0x00, 0x00 };
    var buf: [1024]u8 = undefined;
    try testing.expect(!(linker.emitMachOExecutable(&buf, &main_code) != 0));
}

test "emitExecutable dispatches to real Mach-O for macOS targets" {
    var linker = Linker.init(.{ .arch = .aarch64, .os = .macos, .abi = .none });
    const main_code = [_]u8{ 0xC0, 0x03, 0x5F, 0xD6 };
    var buf: [1024]u8 = undefined;
    const n = linker.emitExecutable(&buf, &main_code);
    // A real executable is much larger than the old 32-byte header stub.
    try testing.expect(!(n < 400)); // dispatched emitter must produce full image
    if (buf[0] != 0xCF or buf[1] != 0xFA or buf[2] != 0xED or buf[3] != 0xFE)
        return error.TestUnexpectedResult;
}

test "all sls host targets emit non-empty runnable images from one host" {
    const Case = struct { arch: Target_Triple.Arch, os: Target_Triple.Os, abi: Target_Triple.Abi };
    const cases = [_]Case{
        .{ .arch = .x86_64, .os = .linux, .abi = .gnu },
        .{ .arch = .aarch64, .os = .linux, .abi = .gnu },
        .{ .arch = .x86_64, .os = .windows, .abi = .msvc },
        .{ .arch = .aarch64, .os = .windows, .abi = .msvc },
        .{ .arch = .x86_64, .os = .macos, .abi = .none },
        .{ .arch = .aarch64, .os = .macos, .abi = .none },
        .{ .arch = .aarch64, .os = .sb0, .abi = .sb0 },
    };
    for (cases) |c| {
        var linker = Linker.init(.{ .arch = c.arch, .os = c.os, .abi = c.abi });
        // aarch64 main body ends in ret; x86_64 uses its ret.
        const aarch64_ret = [_]u8{ 0xC0, 0x03, 0x5F, 0xD6 };
        const x86_ret = [_]u8{0xC3};
        const main_code: []const u8 = if (c.arch == .aarch64) aarch64_ret[0..] else x86_ret[0..];
        var buf: [2048]u8 = undefined;
        const n = linker.emitExecutable(&buf, main_code);
        try testing.expect(!(n == 0)); // every supported host target must emit a runnable image
    }
}
