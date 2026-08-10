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
        self.* = Linker{
            .target = target,
            .relocations = .{},
            .sections = .{},
            .externals = .{},
            .output_offset = 0,
        };
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
            .macho => self.emitMachO(output),
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
    pub fn emitElfExecutable(self: *Linker, output: []u8, main_code: []const u8) usize {
        if (self.target.arch != .x86_64) return 0;
        if (main_code.len == 0) return 0;

        const elf_header_size: usize = 64;
        const ph_header_size: usize = 56;
        const text_offset: usize = elf_header_size + ph_header_size;
        const start_stub_len: usize = 14;
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
        self.writeU16LE(output[pos..], 0x3E);
        pos += 2; // e_machine: EM_X86_64
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
    pub fn emitPeCoffExecutable(self: *Linker, output: []u8, main_code: []const u8) usize {
        if (self.target.arch != .x86_64) return 0;
        if (main_code.len == 0) return 0;

        const pe_offset: usize = 0x80;
        const optional_header_size: usize = 0xF0;
        const section_alignment: usize = 0x1000;
        const file_alignment: usize = 0x200;
        const headers_size: usize = 0x200;
        const text_rva: usize = 0x1000;
        const text_raw: usize = headers_size;
        const entry_stub_len: usize = 13;
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

        self.writeU16LE(output[pos..], 0x8664);
        pos += 2; // Machine: AMD64
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
        output[code_start] = 0xE8;
        self.writeU32LE(output[code_start + 1 ..], @intCast(main_offset - 5));
        output[code_start + 5] = 0x31;
        output[code_start + 6] = 0xC9; // xor ecx, ecx
        output[code_start + 7] = 0xFF;
        output[code_start + 8] = 0x15; // call qword ptr [rip+disp32]
        self.writeU32LE(output[code_start + 9 ..], @intCast((text_rva + iat_off) - (text_rva + entry_stub_len)));
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

    /// Emit a Mach-O binary header into the output buffer.
    /// Writes: magic (0xfeedfacf for 64-bit), header, and load commands.
    /// Returns bytes written.
    pub fn emitMachO(self: *Linker, output: []u8) usize {
        var pos: usize = 0;
        if (pos + 32 > output.len) return 0;
        // Magic: 0xfeedfacf (64-bit)
        self.writeU32LE(output[pos..], 0xFEEDFACF);
        pos += 4;
        // CPU type
        const cputype: u32 = switch (self.target.arch) {
            .x86_64 => 0x01000007, // CPU_TYPE_X86_64
            .aarch64 => 0x0100000C, // CPU_TYPE_ARM64
            .arm => 0x0000000C, // CPU_TYPE_ARM
            else => 0,
        };
        self.writeU32LE(output[pos..], cputype);
        pos += 4;
        // CPU subtype
        self.writeU32LE(output[pos..], 0x03);
        pos += 4; // CPU_SUBTYPE_ALL
        // File type: MH_EXECUTE = 2
        self.writeU32LE(output[pos..], 2);
        pos += 4;
        // Number of load commands (placeholder)
        self.writeU32LE(output[pos..], 0);
        pos += 4;
        // Size of load commands
        self.writeU32LE(output[pos..], 0);
        pos += 4;
        // Flags
        self.writeU32LE(output[pos..], 0);
        pos += 4;
        // Reserved (64-bit)
        self.writeU32LE(output[pos..], 0);
        pos += 4;
        return pos;
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
    var buf: [64]u8 = undefined;
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
