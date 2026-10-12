pub const Atom = @import("Elf/Atom.sig");

base: link.File,
zig_object: ?*ZigObject,
rpath_table: std.array_hash_map.String(void),
image_base: u64,
z_nodelete: bool,
z_notext: bool,
z_defs: bool,
z_origin: bool,
z_nocopyreloc: bool,
z_now: bool,
z_relro: bool,
/// TODO make this non optional and resolve the default in open()
z_common_page_size: ?u64,
/// TODO make this non optional and resolve the default in open()
z_max_page_size: ?u64,
soname: ?[]const u8,
entry_name: ?[]const u8,

ptr_width: PtrWidth,

/// A list of all input files.
/// First index is a special "null file". Order is otherwise not observed.
files: std.MultiArrayList(File.Entry) = .{},
/// Long-lived list of all file descriptors.
/// We store them globally rather than per actual File so that we can re-use
/// one file handle per every object file within an archive.
file_handles: std.ArrayList(File.Handle) = .empty,
zig_object_index: ?File.Index = null,
linker_defined_index: ?File.Index = null,
objects: std.ArrayList(File.Index) = .empty,
shared_objects: std.array_hash_map.String(File.Index) = .empty,

/// List of all output sections and their associated metadata.
sections: std.MultiArrayList(Section) = .{},
/// File offset into the shdr table.
shdr_table_offset: ?u64 = null,

/// Stored in native-endian format, depending on target endianness needs to be bswapped on read/write.
/// Same order as in the file.
phdrs: ProgramHeaderList = .empty,

/// Special program headers.
phdr_indexes: ProgramHeaderIndexes = .{},
section_indexes: SectionIndexes = .{},

page_size: u32,
default_sym_version: elf.Versym,

/// .shstrtab buffer
shstrtab: std.ArrayList(u8) = .empty,
/// .symtab buffer
symtab: std.ArrayList(elf.Elf64.Sym) = .empty,
/// .strtab buffer
strtab: std.ArrayList(u8) = .empty,
/// Dynamic symbol table. Only populated and emitted when linking dynamically.
dynsym: DynsymSection = .{},
/// .dynstrtab buffer
dynstrtab: std.ArrayList(u8) = .empty,
/// Version symbol table. Only populated and emitted when linking dynamically.
versym: std.ArrayList(elf.Versym) = .empty,
/// .verneed section
verneed: VerneedSection = .{},
/// .got section
got: GotSection = .{},
/// .rela.dyn section
rela_dyn: std.ArrayList(elf.Elf64.Rela) = .empty,
/// .dynamic section
dynamic: DynamicSection = .{},
/// .hash section
hash: HashSection = .{},
/// .gnu.hash section
gnu_hash: GnuHashSection = .{},
/// .plt section
plt: PltSection = .{},
/// .got.plt section
got_plt: GotPltSection = .{},
/// .plt.got section
plt_got: PltGotSection = .{},
/// .copyrel section
copy_rel: CopyRelSection = .{},
/// .rela.plt section
rela_plt: std.ArrayList(elf.Elf64.Rela) = .empty,
/// SHT_GROUP sections
/// Applies only to a relocatable.
group_sections: std.ArrayList(GroupSection) = .empty,

resolver: SymbolResolver = .{},

has_text_reloc: bool = false,
num_ifunc_dynrelocs: usize = 0,

/// List of range extension thunks.
thunks: std.ArrayList(Thunk) = .empty,

/// List of output merge sections with deduped contents.
merge_sections: std.ArrayList(Merge.Section) = .empty,
comment_merge_section_index: ?Merge.Section.Index = null,

/// `--verbose-link` output.
/// Initialized on creation, appended to as inputs are added, printed during `flush`.
dump_argv_list: std.ArrayList([]const u8),

const SectionIndexes = struct {
    copy_rel: ?u32 = null,
    dynamic: ?u32 = null,
    dynstrtab: ?u32 = null,
    dynsymtab: ?u32 = null,
    eh_frame: ?u32 = null,
    eh_frame_rela: ?u32 = null,
    eh_frame_hdr: ?u32 = null,
    hash: ?u32 = null,
    gnu_hash: ?u32 = null,
    got: ?u32 = null,
    got_plt: ?u32 = null,
    interp: ?u32 = null,
    plt: ?u32 = null,
    plt_got: ?u32 = null,
    rela_dyn: ?u32 = null,
    rela_plt: ?u32 = null,
    versym: ?u32 = null,
    verneed: ?u32 = null,

    shstrtab: ?u32 = null,
    strtab: ?u32 = null,
    symtab: ?u32 = null,
};

const ProgramHeaderList = std.ArrayList(elf.Elf64.Phdr);

const OptionalProgramHeaderIndex = enum(u16) {
    none = std.math.maxInt(u16),
    _,

    fn unwrap(i: OptionalProgramHeaderIndex) ?ProgramHeaderIndex {
        if (i == .none) return null;
        return @fromBackingInt(@intCast(@backingInt(i)));
    }

    fn int(i: OptionalProgramHeaderIndex) ?u16 {
        if (i == .none) return null;
        return @backingInt(i);
    }
};

const ProgramHeaderIndex = enum(u16) {
    _,

    fn toOptional(i: ProgramHeaderIndex) OptionalProgramHeaderIndex {
        const result: OptionalProgramHeaderIndex = @fromBackingInt(@intCast(@backingInt(i)));
        assert(result != .none);
        return result;
    }

    fn int(i: ProgramHeaderIndex) u16 {
        return @backingInt(i);
    }
};

const ProgramHeaderIndexes = struct {
    /// PT.PHDR
    table: OptionalProgramHeaderIndex = .none,
    /// PT.LOAD for PHDR table
    /// We add this special load segment to ensure the EHDR and PHDR table are always
    /// loaded into memory.
    table_load: OptionalProgramHeaderIndex = .none,
    /// PT.INTERP
    interp: OptionalProgramHeaderIndex = .none,
    /// PT.DYNAMIC
    dynamic: OptionalProgramHeaderIndex = .none,
    /// PT.GNU_EH_FRAME
    gnu_eh_frame: OptionalProgramHeaderIndex = .none,
    /// PT.GNU_STACK
    gnu_stack: OptionalProgramHeaderIndex = .none,
    /// PT.TLS
    /// TODO I think ELF permits multiple TLS segments but for now, assume one per file.
    tls: OptionalProgramHeaderIndex = .none,
};

/// When allocating, the ideal_capacity is calculated by
/// actual_capacity + (actual_capacity / ideal_factor)
const ideal_factor = 3;

/// In order for a slice of bytes to be considered eligible to keep metadata pointing at
/// it as a possible place to put new symbols, it must have enough room for this many bytes
/// (plus extra for reserved capacity).
const minimum_atom_size = 64;
pub const min_text_capacity = padToIdeal(minimum_atom_size);

pub const PtrWidth = enum { p32, p64 };

pub fn createEmpty(
    arena: Allocator,
    comp: *Compilation,
    emit: Path,
    options: link.File.OpenOptions,
) !*Elf {
    const target = &comp.root_mod.resolved_target.result;
    assert(target.ofmt == .elf);

    const use_llvm = comp.config.use_llvm;
    const opt_zcu = comp.zcu;
    const output_mode = comp.config.output_mode;
    const link_mode = comp.config.link_mode;
    const optimize_mode = comp.root_mod.optimize_mode;
    const is_native_os = comp.root_mod.resolved_target.is_native_os;
    const ptr_width: PtrWidth = switch (target.ptrBitWidth()) {
        0...32 => .p32,
        33...64 => .p64,
        else => return error.UnsupportedELFArchitecture,
    };

    // This is the max page size that the target system can run with, aka the ABI page size. Not to
    // be confused with the common page size, which is the page size that's used in practice on most
    // systems.
    const page_size: u32 = switch (target.cpu.arch) {
        .bpfel,
        .bpfeb,
        .sparc64,
        => 0x100000,
        .aarch64,
        .aarch64_be,
        .amdgcn,
        .hexagon,
        .mips,
        .mipsel,
        .mips64,
        .mips64el,
        .powerpc,
        .powerpcle,
        .powerpc64,
        .powerpc64le,
        .sparc,
        => 0x10000,
        .loongarch32,
        .loongarch64,
        => 0x4000,
        .arc,
        .m68k,
        => 0x2000,
        .msp430,
        => 0x4,
        .avr,
        => 0x1,
        else => 0x1000,
    };

    const is_dyn_lib = output_mode == .Lib and link_mode == .dynamic;
    const default_sym_version: elf.Versym = if (is_dyn_lib or comp.config.rdynamic) .GLOBAL else .LOCAL;

    var rpath_table: std.array_hash_map.String(void) = .empty;
    try rpath_table.entries.resize(arena, options.rpath_list.len);
    @memcpy(rpath_table.entries.items(.key), options.rpath_list);
    try rpath_table.reIndex(arena);

    const self = try arena.create(Elf);
    self.* = .{
        .base = .{
            .tag = .elf,
            .comp = comp,
            .emit = emit,
            .gc_sections = options.gc_sections orelse (optimize_mode != .debug and output_mode != .Obj),
            .print_gc_sections = options.print_gc_sections,
            .stack_size = options.stack_size orelse 16777216,
            .allow_shlib_undefined = options.allow_shlib_undefined orelse !is_native_os,
            .file = null,
            .build_id = options.build_id,
        },
        .zig_object = null,
        .rpath_table = rpath_table,
        .ptr_width = ptr_width,
        .page_size = page_size,
        .default_sym_version = default_sym_version,

        .entry_name = switch (options.entry) {
            .disabled => null,
            .default => if (output_mode != .Exe) null else defaultEntrySymbolName(target.cpu.arch),
            .enabled => defaultEntrySymbolName(target.cpu.arch),
            .named => |name| name,
        },

        .image_base = b: {
            if (is_dyn_lib) break :b 0;
            if (output_mode == .Exe and (comp.config.pie or target.os.tag == .haiku)) break :b 0;
            break :b options.image_base orelse switch (ptr_width) {
                .p32 => 0x10000,
                .p64 => 0x1000000,
            };
        },

        .z_nodelete = options.z_nodelete,
        .z_notext = options.z_notext,
        .z_defs = options.z_defs,
        .z_origin = options.z_origin,
        .z_nocopyreloc = options.z_nocopyreloc,
        .z_now = options.z_now,
        .z_relro = options.z_relro,
        .z_common_page_size = options.z_common_page_size,
        .z_max_page_size = options.z_max_page_size,
        .soname = options.soname,
        .dump_argv_list = .empty,
    };
    errdefer self.base.destroy();

    // --verbose-link
    if (comp.verbose_link) try dumpArgvInit(self, arena);

    const is_obj = output_mode == .Obj;
    const is_obj_or_ar = is_obj or (output_mode == .Lib and link_mode == .static);

    const io = comp.io;

    // What path should this ELF linker code output to?
    const sub_path = emit.sub_path;
    self.base.file = try emit.root_dir.handle.createFile(io, sub_path, .{
        .truncate = true,
        .read = true,
        .permissions = link.File.determinePermissions(output_mode, link_mode),
    });

    const gpa = comp.gpa;

    // Append null file at index 0
    try self.files.append(gpa, .null);
    // Append null byte to string tables
    try self.shstrtab.append(gpa, 0);
    try self.strtab.append(gpa, 0);
    // There must always be a null shdr in index 0
    _ = try self.addSection(.{});
    // Append null symbol in output symtab
    try self.symtab.append(gpa, null_sym);

    if (!is_obj_or_ar) {
        try self.dynstrtab.append(gpa, 0);

        // Initialize PT.PHDR program header
        const p_align: u16 = switch (self.ptr_width) {
            .p32 => @alignOf(elf.Elf32.Phdr),
            .p64 => @alignOf(elf.Elf64.Phdr),
        };
        const ehsize: u64 = switch (self.ptr_width) {
            .p32 => @sizeOf(elf.Elf32.Ehdr),
            .p64 => @sizeOf(elf.Elf64.Ehdr),
        };
        const phsize: u64 = switch (self.ptr_width) {
            .p32 => @sizeOf(elf.Elf32.Phdr),
            .p64 => @sizeOf(elf.Elf64.Phdr),
        };
        const max_nphdrs = comptime getMaxNumberOfPhdrs();
        const reserved: u64 = mem.alignForward(u64, padToIdeal(max_nphdrs * phsize), self.page_size);
        self.phdr_indexes.table = (try self.addPhdr(.{
            .type = .PHDR,
            .flags = .{ .R = true },
            .@"align" = p_align,
            .addr = self.image_base + ehsize,
            .offset = ehsize,
            .filesz = reserved,
            .memsz = reserved,
        })).toOptional();
        self.phdr_indexes.table_load = (try self.addPhdr(.{
            .type = .LOAD,
            .flags = .{ .R = true },
            .@"align" = self.page_size,
            .addr = self.image_base,
            .offset = 0,
            .filesz = reserved + ehsize,
            .memsz = reserved + ehsize,
        })).toOptional();
    }

    if (opt_zcu) |zcu| {
        if (!use_llvm) {
            const index: File.Index = @intCast(try self.files.addOne(gpa));
            self.files.set(index, .zig_object);
            self.zig_object_index = index;
            const zig_object = try arena.create(ZigObject);
            self.zig_object = zig_object;
            zig_object.* = .{
                .index = index,
                .basename = try std.fmt.allocPrint(arena, "{s}.o", .{
                    fs.path.stem(zcu.main_mod.root_src_path),
                }),
            };
            try zig_object.init(self, .{
                .symbol_count_hint = options.symbol_count_hint,
                .program_code_size_hint = options.program_code_size_hint,
            });
        }
    }

    return self;
}

pub fn open(
    arena: Allocator,
    comp: *Compilation,
    emit: Path,
    options: link.File.OpenOptions,
) !*Elf {
    // TODO: restore saved linker state, don't truncate the file, and
    // participate in incremental compilation.
    return createEmpty(arena, comp, emit, options);
}

pub fn deinit(self: *Elf) void {
    const comp = self.base.comp;
    const gpa = comp.gpa;
    const io = comp.io;

    for (self.file_handles.items) |fh| {
        fh.close(io);
    }
    self.file_handles.deinit(gpa);

    for (self.files.items(.tags), self.files.items(.data)) |tag, *data| switch (tag) {
        .null, .zig_object => {},
        .linker_defined => data.linker_defined.deinit(gpa),
        .object => data.object.deinit(gpa),
        .shared_object => data.shared_object.deinit(gpa),
    };
    if (self.zig_object) |zig_object| {
        zig_object.deinit(gpa);
    }
    self.files.deinit(gpa);
    self.objects.deinit(gpa);
    self.shared_objects.deinit(gpa);

    for (self.sections.items(.atom_list_2), self.sections.items(.atom_list), self.sections.items(.free_list)) |*atom_list, *atoms, *free_list| {
        atom_list.deinit(gpa);
        atoms.deinit(gpa);
        free_list.deinit(gpa);
    }
    self.sections.deinit(gpa);
    self.phdrs.deinit(gpa);
    self.shstrtab.deinit(gpa);
    self.symtab.deinit(gpa);
    self.strtab.deinit(gpa);
    self.resolver.deinit(gpa);

    for (self.thunks.items) |*th| {
        th.deinit(gpa);
    }
    self.thunks.deinit(gpa);
    for (self.merge_sections.items) |*sect| {
        sect.deinit(gpa);
    }
    self.merge_sections.deinit(gpa);

    self.got.deinit(gpa);
    self.plt.deinit(gpa);
    self.plt_got.deinit(gpa);
    self.dynsym.deinit(gpa);
    self.dynstrtab.deinit(gpa);
    self.dynamic.deinit(gpa);
    self.hash.deinit(gpa);
    self.versym.deinit(gpa);
    self.verneed.deinit(gpa);
    self.copy_rel.deinit(gpa);
    self.rela_dyn.deinit(gpa);
    self.rela_plt.deinit(gpa);
    self.group_sections.deinit(gpa);
    self.dump_argv_list.deinit(gpa);
}

pub fn getNavVAddr(self: *Elf, pt: Zcu.PerThread, nav_index: InternPool.Nav.Index, reloc_info: link.File.RelocInfo) !u64 {
    return self.zigObjectPtr().?.getNavVAddr(self, pt, nav_index, reloc_info);
}

pub fn lowerUav(
    self: *Elf,
    pt: Zcu.PerThread,
    uav: InternPool.Index,
    explicit_alignment: InternPool.Alignment,
) !link.File.SymbolId {
    return self.zigObjectPtr().?.lowerUav(self, pt, uav, explicit_alignment);
}

pub fn getUavVAddr(self: *Elf, uav: InternPool.Index, reloc_info: link.File.RelocInfo) !u64 {
    return self.zigObjectPtr().?.getUavVAddr(self, uav, reloc_info);
}

/// Returns end pos of collision, if any.
fn detectAllocCollision(self: *Elf, start: u64, size: u64) !?u64 {
    const comp = self.base.comp;
    const io = comp.io;
    const small_ptr = self.ptr_width == .p32;
    const ehdr_size: u64 = if (small_ptr) @sizeOf(elf.Elf32.Ehdr) else @sizeOf(elf.Elf64.Ehdr);
    if (start < ehdr_size)
        return ehdr_size;

    var at_end = true;
    const end = start + padToIdeal(size);

    if (self.shdr_table_offset) |off| {
        const shdr_size: u64 = if (small_ptr) @sizeOf(elf.Elf32.Shdr) else @sizeOf(elf.Elf64.Shdr);
        const tight_size = self.sections.items(.shdr).len * shdr_size;
        const increased_size = padToIdeal(tight_size);
        const test_end = off +| increased_size;
        if (start < test_end) {
            if (end > off) return test_end;
            if (test_end < std.math.maxInt(u64)) at_end = false;
        }
    }

    for (self.sections.items(.shdr)) |shdr| {
        if (shdr.type == .NOBITS) continue;
        const increased_size = padToIdeal(shdr.size);
        const test_end = shdr.offset +| increased_size;
        if (start < test_end) {
            if (end > shdr.offset) return test_end;
            if (test_end < std.math.maxInt(u64)) at_end = false;
        }
    }

    for (self.phdrs.items) |phdr| {
        if (phdr.type != .LOAD) continue;
        const increased_size = padToIdeal(phdr.filesz);
        const test_end = phdr.offset +| increased_size;
        if (start < test_end) {
            if (end > phdr.offset) return test_end;
            if (test_end < std.math.maxInt(u64)) at_end = false;
        }
    }

    if (at_end) try self.base.file.?.setLength(io, end);
    return null;
}

pub fn allocatedSize(self: *Elf, start: u64) u64 {
    if (start == 0) return 0;
    var min_pos: u64 = std.math.maxInt(u64);
    if (self.shdr_table_offset) |off| {
        if (off > start and off < min_pos) min_pos = off;
    }
    for (self.sections.items(.shdr)) |section| {
        if (section.offset <= start) continue;
        if (section.offset < min_pos) min_pos = section.offset;
    }
    for (self.phdrs.items) |phdr| {
        if (phdr.offset <= start) continue;
        if (phdr.offset < min_pos) min_pos = phdr.offset;
    }
    return min_pos - start;
}

pub fn findFreeSpace(self: *Elf, object_size: u64, min_alignment: u64) !u64 {
    var start: u64 = 0;
    while (try self.detectAllocCollision(start, object_size)) |item_end| {
        start = mem.alignForward(u64, item_end, min_alignment);
    }
    return start;
}

pub fn growSection(self: *Elf, shdr_index: u32, needed_size: u64, min_alignment: u64) !void {
    const comp = self.base.comp;
    const io = comp.io;
    const shdr = &self.sections.items(.shdr)[shdr_index];

    if (shdr.type != .NOBITS) {
        const allocated_size = self.allocatedSize(shdr.offset);
        log.debug("allocated size {x} of '{s}', needed size {x}", .{
            allocated_size,
            self.getShString(shdr.name),
            needed_size,
        });

        if (needed_size > allocated_size) {
            const existing_size = shdr.size;
            shdr.size = 0;
            // Must move the entire section.
            const new_offset = try self.findFreeSpace(needed_size, min_alignment);

            log.debug("moving '{s}' from 0x{x} to 0x{x}", .{
                self.getShString(shdr.name),
                shdr.offset,
                new_offset,
            });

            try self.base.copyRangeAll(shdr.offset, new_offset, existing_size);

            shdr.offset = new_offset;
        } else if (shdr.offset + allocated_size == std.math.maxInt(u64)) {
            try self.base.file.?.setLength(io, shdr.offset + needed_size);
        }
    }

    shdr.size = needed_size;
    self.markDirty(shdr_index);
}

fn markDirty(self: *Elf, shdr_index: u32) void {
    if (self.zigObjectPtr()) |zo| {
        for ([_]?Symbol.Index{
            zo.debug_info_index,
            zo.debug_abbrev_index,
            zo.debug_aranges_index,
            zo.debug_str_index,
            zo.debug_line_index,
            zo.debug_line_str_index,
            zo.debug_loclists_index,
            zo.debug_rnglists_index,
        }, [_]*bool{
            &zo.debug_info_section_dirty,
            &zo.debug_abbrev_section_dirty,
            &zo.debug_aranges_section_dirty,
            &zo.debug_str_section_dirty,
            &zo.debug_line_section_dirty,
            &zo.debug_line_str_section_dirty,
            &zo.debug_loclists_section_dirty,
            &zo.debug_rnglists_section_dirty,
        }) |maybe_sym_index, dirty| {
            const sym_index = maybe_sym_index orelse continue;
            if (zo.symbol(sym_index).atom(self).?.output_section_index == shdr_index) {
                dirty.* = true;
                break;
            }
        }
    }
}

const AllocateChunkResult = struct {
    value: u64,
    placement: Ref,
};

pub fn allocateChunk(self: *Elf, args: struct {
    size: u64,
    shndx: u32,
    alignment: Atom.Alignment,
    requires_padding: bool = true,
}) !AllocateChunkResult {
    const slice = self.sections.slice();
    const shdr = &slice.items(.shdr)[args.shndx];
    const free_list = &slice.items(.free_list)[args.shndx];
    const last_atom_ref = &slice.items(.last_atom)[args.shndx];
    const new_atom_ideal_capacity = if (args.requires_padding) padToIdeal(args.size) else args.size;

    // First we look for an appropriately sized free list node.
    // The list is unordered. We'll just take the first thing that works.
    const res: AllocateChunkResult = blk: {
        var i: usize = if (self.base.child_pid == null) 0 else free_list.items.len;
        while (i < free_list.items.len) {
            const big_atom_ref = free_list.items[i];
            const big_atom = self.atom(big_atom_ref).?;
            // We now have a pointer to a live atom that has too much capacity.
            // Is it enough that we could fit this new atom?
            const cap = big_atom.capacity(self);
            const ideal_capacity = if (args.requires_padding) padToIdeal(cap) else cap;
            const ideal_capacity_end_vaddr = std.math.add(u64, @intCast(big_atom.value), ideal_capacity) catch ideal_capacity;
            const capacity_end_vaddr = @as(u64, @intCast(big_atom.value)) + cap;
            const new_start_vaddr_unaligned = capacity_end_vaddr - new_atom_ideal_capacity;
            const new_start_vaddr = args.alignment.backward(new_start_vaddr_unaligned);
            if (new_start_vaddr < ideal_capacity_end_vaddr) {
                // Additional bookkeeping here to notice if this free list node
                // should be deleted because the block that it points to has grown to take up
                // more of the extra capacity.
                if (!big_atom.freeListEligible(self)) {
                    _ = free_list.swapRemove(i);
                } else {
                    i += 1;
                }
                continue;
            }
            // At this point we know that we will place the new block here. But the
            // remaining question is whether there is still yet enough capacity left
            // over for there to still be a free list node.
            const remaining_capacity = new_start_vaddr - ideal_capacity_end_vaddr;
            const keep_free_list_node = remaining_capacity >= min_text_capacity;

            if (!keep_free_list_node) {
                _ = free_list.swapRemove(i);
            }
            break :blk .{ .value = new_start_vaddr, .placement = big_atom_ref };
        } else if (self.atom(last_atom_ref.*)) |last_atom| {
            const ideal_capacity = if (args.requires_padding) padToIdeal(last_atom.size) else last_atom.size;
            const ideal_capacity_end_vaddr = @as(u64, @intCast(last_atom.value)) + ideal_capacity;
            const new_start_vaddr = args.alignment.forward(ideal_capacity_end_vaddr);
            break :blk .{ .value = new_start_vaddr, .placement = last_atom.ref() };
        } else {
            break :blk .{ .value = 0, .placement = .{} };
        }
    };

    const expand_section = if (self.atom(res.placement)) |placement_atom|
        placement_atom.nextAtom(self) == null
    else
        true;
    if (expand_section) {
        const needed_size = res.value + args.size;
        try self.growSection(args.shndx, needed_size, args.alignment.toByteUnits().?);
    }

    log.debug("allocated chunk (size({x}),align({x})) in {s} at 0x{x} (file(0x{x}))", .{
        args.size,
        args.alignment.toByteUnits().?,
        self.getShString(shdr.name),
        shdr.addr + res.value,
        shdr.offset + res.value,
    });
    log.debug("  placement {f}, {s}", .{
        res.placement,
        if (self.atom(res.placement)) |atom_ptr| atom_ptr.name(self) else "",
    });

    return res;
}

pub fn loadInput(self: *Elf, input: link.Input) !void {
    const comp = self.base.comp;
    const gpa = comp.gpa;
    const io = comp.io;
    const diags = &comp.link_diags;
    const target = self.getTarget();
    const debug_fmt_strip = comp.config.debug_format == .strip;
    const default_sym_version = self.default_sym_version;

    if (comp.verbose_link) {
        comp.mutex.lockUncancelable(io); // protect comp.arena
        defer comp.mutex.unlock(io);

        const argv = &self.dump_argv_list;
        switch (input) {
            .res => unreachable,
            .dso_exact => |dso_exact| try argv.appendSlice(gpa, &.{ "-l", dso_exact.name }),
            .object, .archive => |obj| try argv.append(gpa, try obj.path.toString(comp.arena)),
            .dso => |dso| try argv.append(gpa, try dso.path.toString(comp.arena)),
        }
    }

    switch (input) {
        .res => unreachable,
        .dso_exact => @panic("TODO"),
        .object => |obj| try parseObject(self, obj),
        .archive => |obj| if (self.base.isStaticLib()) {
            // Ignore static library inputs when generating a static library.
        } else {
            try parseArchive(gpa, io, diags, &self.file_handles, &self.files, target, debug_fmt_strip, default_sym_version, &self.objects, obj);
        },
        .dso => |dso| try parseDso(gpa, io, diags, dso, &self.shared_objects, &self.files, target),
    }
}

pub fn flush(self: *Elf, arena: Allocator, tid: Zcu.PerThread.Id, prog_node: std.Progress.Node) link.Error!void {
    const tracy = trace(@src());
    defer tracy.end();

    const comp = self.base.comp;
    const io = comp.io;
    const diags = &comp.link_diags;

    if (comp.verbose_link) try Compilation.dumpArgv(io, self.dump_argv_list.items);

    const sub_prog_node = prog_node.start("ELF Flush", 0);
    defer sub_prog_node.end();

    return flushInner(self, arena, tid) catch |err| switch (err) {
        error.OutOfMemory, error.AlreadyReported => |e| return e,
        else => |e| return diags.fail("ELF flush failed: {t}", .{e}),
    };
}

fn flushInner(self: *Elf, arena: Allocator, tid: Zcu.PerThread.Id) !void {
    _ = arena;

    const comp = self.base.comp;
    const gpa = comp.gpa;
    const diags = &comp.link_diags;

    if (self.zigObjectPtr()) |zig_object| try zig_object.flush(self, tid);

    switch (comp.config.output_mode) {
        .Obj => return relocatable.flushObject(self, comp),
        .Lib => switch (comp.config.link_mode) {
            .dynamic => {},
            .static => return relocatable.flushStaticLib(self, comp),
        },
        .Exe => {},
    }

    if (diags.hasErrors()) return error.AlreadyReported;

    // If we haven't already, create a linker-generated input file comprising of
    // linker-defined synthetic symbols only such as `_DYNAMIC`, etc.
    if (self.linker_defined_index == null) {
        const index: File.Index = @intCast(try self.files.addOne(gpa));
        self.files.set(index, .{ .linker_defined = .{ .index = index } });
        self.linker_defined_index = index;
        const object = self.linkerDefinedPtr().?;
        try object.init(gpa);
        try object.initSymbols(self);
    }

    // Now, we are ready to resolve the symbols across all input files.
    // We will first resolve the files in the ZigObject, next in the parsed
    // input Object files.
    // Any qualifing unresolved symbol will be upgraded to an absolute, weak
    // symbol for potential resolution at load-time.
    try self.resolveSymbols();
    self.markEhFrameAtomsDead();
    try self.resolveMergeSections();

    for (self.objects.items) |index| {
        try self.file(index).?.object.convertCommonSymbols(self);
    }
    self.markImportsExports();

    if (self.base.gc_sections) {
        try gc.gcAtoms(self);
    }

    self.checkDuplicates() catch |err| switch (err) {
        error.HasDuplicates => return error.AlreadyReported,
        else => |e| return e,
    };

    try self.addCommentString();
    try self.finalizeMergeSections();
    try self.initOutputSections();
    if (self.linkerDefinedPtr()) |obj| {
        try obj.initStartStopSymbols(self);
    }
    self.claimUnresolved();

    // Scan and create missing synthetic entries such as GOT indirection.
    try self.scanRelocs();

    // Generate and emit synthetic sections.
    try self.initSyntheticSections();
    try self.initSpecialPhdrs();
    try sortShdrs(
        gpa,
        &self.section_indexes,
        &self.sections,
        self.shstrtab.items,
        self.merge_sections.items,
        self.group_sections.items,
        self.zigObjectPtr(),
        self.files,
    );

    try self.setDynamicSection(self.rpath_table.keys());
    self.sortDynamicSymtab();
    try self.setHashSections();
    try self.setVersionSymtab();

    try self.sortInitFini();
    try self.updateMergeSectionSizes();
    try self.updateSectionSizes();

    try self.addLoadPhdrs();
    try self.allocatePhdrTable();
    try self.allocateAllocSections();
    try sortPhdrs(gpa, &self.phdrs, &self.phdr_indexes, self.sections.items(.phndx));
    try self.allocateNonAllocSections();
    self.allocateSpecialPhdrs();
    if (self.linkerDefinedPtr()) |obj| {
        obj.allocateSymbols(self);
    }

    // Dump the state for easy debugging.
    // State can be dumped via `--debug-log link_state`.
    if (build_options.enable_logging) {
        state_log.debug("{f}", .{self.dumpState()});
    }

    // Beyond this point, everything has been allocated a virtual address and we can resolve
    // the relocations, and commit objects to file.
    for (self.objects.items) |index| {
        self.file(index).?.object.dirty = false;
    }
    // TODO: would state tracking be more appropriate here? perhaps even custom relocation type?
    self.rela_dyn.clearRetainingCapacity();
    self.rela_plt.clearRetainingCapacity();

    if (self.zigObjectPtr()) |zo| {
        var undefs: std.array_hash_map.Auto(SymbolResolver.Index, std.array_list.Managed(Ref)) = .empty;
        defer {
            for (undefs.values()) |*refs| refs.deinit();
            undefs.deinit(gpa);
        }

        var has_reloc_errors = false;
        for (zo.atoms_indexes.items) |atom_index| {
            const atom_ptr = zo.atom(atom_index) orelse continue;
            if (!atom_ptr.alive) continue;
            const out_shndx = atom_ptr.output_section_index;
            const shdr = &self.sections.items(.shdr)[out_shndx];
            if (shdr.type == .NOBITS) continue;
            const code = try zo.codeAlloc(self, atom_index);
            defer gpa.free(code);
            const file_offset = atom_ptr.offset(self);
            (if (!shdr.flags.shf.ALLOC)
                atom_ptr.resolveRelocsNonAlloc(self, code, &undefs)
            else
                atom_ptr.resolveRelocsAlloc(self, code)) catch |err| switch (err) {
                error.RelocFailure, error.RelaxFailure => has_reloc_errors = true,
                error.UnsupportedCpuArch => {
                    try self.reportUnsupportedCpuArch();
                    return error.AlreadyReported;
                },
                else => |e| return e,
            };
            try self.pwriteAll(code, file_offset);
        }

        try self.reportUndefinedSymbols(&undefs);

        if (has_reloc_errors) return error.AlreadyReported;
    }

    try self.writePhdrTable();
    try self.writeShdrTable();
    try self.writeAtoms();
    try self.writeMergeSections();

    self.writeSyntheticSections() catch |err| switch (err) {
        error.RelocFailure => return error.AlreadyReported,
        error.UnsupportedCpuArch => {
            try self.reportUnsupportedCpuArch();
            return error.AlreadyReported;
        },
        else => |e| return e,
    };

    if (self.base.isExe() and self.linkerDefinedPtr().?.entry_index == null) {
        log.debug("flushing. no_entry_point_found = true", .{});
        diags.flags.no_entry_point_found = true;
    } else {
        log.debug("flushing. no_entry_point_found = false", .{});
        diags.flags.no_entry_point_found = false;
        try self.writeElfHeader();
    }

    if (diags.hasErrors()) return error.AlreadyReported;
}

fn dumpArgvInit(self: *Elf, arena: Allocator) !void {
    const comp = self.base.comp;
    const gpa = comp.gpa;
    const target = self.getTarget();
    const full_out_path = try self.base.emit.root_dir.join(arena, &[_][]const u8{self.base.emit.sub_path});

    const argv = &self.dump_argv_list;

    try argv.append(gpa, "zig");

    if (self.base.isStaticLib()) {
        try argv.append(gpa, "ar");
    } else {
        try argv.append(gpa, "ld");
    }

    if (self.base.isObject()) {
        try argv.append(gpa, "-r");
    }

    try argv.append(gpa, "-o");
    try argv.append(gpa, full_out_path);

    if (!self.base.isRelocatable()) {
        if (!self.base.isStatic()) {
            if (target.dynamic_linker.get()) |path| {
                try argv.appendSlice(gpa, &.{ "-dynamic-linker", try arena.dupe(u8, path) });
            }
        }

        if (self.base.isDynLib()) {
            if (self.soname) |name| {
                try argv.append(gpa, "-soname");
                try argv.append(gpa, name);
            }
        }

        if (self.entry_name) |name| {
            try argv.appendSlice(gpa, &.{ "--entry", name });
        }

        for (self.rpath_table.keys()) |rpath| {
            try argv.appendSlice(gpa, &.{ "-rpath", rpath });
        }

        try argv.appendSlice(gpa, &.{
            "-z",
            try std.fmt.allocPrint(arena, "stack-size={d}", .{self.base.stack_size}),
        });

        try argv.append(gpa, try std.fmt.allocPrint(arena, "--image-base={d}", .{self.image_base}));

        if (self.base.gc_sections) {
            try argv.append(gpa, "--gc-sections");
        }

        if (self.base.print_gc_sections) {
            try argv.append(gpa, "--print-gc-sections");
        }

        if (comp.link_eh_frame_hdr) {
            try argv.append(gpa, "--eh-frame-hdr");
        }

        if (comp.config.rdynamic) {
            try argv.append(gpa, "--export-dynamic");
        }

        if (self.z_notext) {
            try argv.append(gpa, "-z");
            try argv.append(gpa, "notext");
        }

        if (self.z_nocopyreloc) {
            try argv.append(gpa, "-z");
            try argv.append(gpa, "nocopyreloc");
        }

        if (self.z_now) {
            try argv.append(gpa, "-z");
            try argv.append(gpa, "now");
        }

        if (self.base.isStatic()) {
            try argv.append(gpa, "-static");
        } else if (self.isEffectivelyDynLib()) {
            try argv.append(gpa, "-shared");
        }

        if (comp.config.pie and self.base.isExe()) {
            try argv.append(gpa, "-pie");
        }

        if (comp.config.debug_format == .strip) {
            try argv.append(gpa, "-s");
        }

        if (comp.config.link_libc) {
            if (self.base.comp.libc_installation) |lci| {
                try argv.append(gpa, "-L");
                try argv.append(gpa, lci.crt_dir.?);
            }
        }
    }
}

fn parseObject(self: *Elf, obj: link.Input.Object) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const comp = self.base.comp;
    const io = comp.io;
    const gpa = comp.gpa;
    const diags = &comp.link_diags;
    const target = &comp.root_mod.resolved_target.result;
    const debug_fmt_strip = comp.config.debug_format == .strip;
    const default_sym_version = self.default_sym_version;
    const file_handles = &self.file_handles;

    const handle = obj.file;
    const fh = try addFileHandle(gpa, file_handles, handle);

    const index: File.Index = @intCast(try self.files.addOne(gpa));
    self.files.set(index, .{ .object = .{
        .path = .{
            .root_dir = obj.path.root_dir,
            .sub_path = try gpa.dupe(u8, obj.path.sub_path),
        },
        .file_handle = fh,
        .index = index,
    } });
    try self.objects.append(gpa, index);

    const object = self.file(index).?.object;
    try object.parseCommon(gpa, io, diags, obj.path, handle, target);
    if (!self.base.isStaticLib()) {
        try object.parse(gpa, io, diags, obj.path, handle, target, debug_fmt_strip, default_sym_version);
    }
}

fn parseArchive(
    gpa: Allocator,
    io: Io,
    diags: *Diags,
    file_handles: *std.ArrayList(File.Handle),
    files: *std.MultiArrayList(File.Entry),
    target: *const std.Target,
    debug_fmt_strip: bool,
    default_sym_version: elf.Versym,
    objects: *std.ArrayList(File.Index),
    obj: link.Input.Object,
) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const fh = try addFileHandle(gpa, file_handles, obj.file);
    var archive = try Archive.parse(gpa, io, diags, file_handles, obj.path, fh);
    defer archive.deinit(gpa);

    for (archive.objects) |extracted| {
        const index: File.Index = @intCast(try files.addOne(gpa));
        files.set(index, .{ .object = extracted });
        const object = &files.items(.data)[index].object;
        object.index = index;
        object.alive = obj.must_link;
        try object.parseCommon(gpa, io, diags, obj.path, obj.file, target);
        try object.parse(gpa, io, diags, obj.path, obj.file, target, debug_fmt_strip, default_sym_version);
        try objects.append(gpa, index);
    }
}

fn parseDso(
    gpa: Allocator,
    io: Io,
    diags: *Diags,
    dso: link.Input.Dso,
    shared_objects: *std.array_hash_map.String(File.Index),
    files: *std.MultiArrayList(File.Entry),
    target: *const std.Target,
) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const handle = dso.file;

    const stat = Stat.fromFs(try handle.stat(io));
    var header = try SharedObject.parseHeader(gpa, io, diags, dso.path, handle, stat, target);
    defer header.deinit(gpa);

    const soname = header.soname() orelse dso.path.basename();

    const gop = try shared_objects.getOrPut(gpa, soname);
    if (gop.found_existing) return;
    errdefer _ = shared_objects.pop();

    const index: File.Index = @intCast(try files.addOne(gpa));
    errdefer _ = files.pop();

    gop.value_ptr.* = index;

    var parsed = try SharedObject.parse(gpa, io, &header, handle);
    errdefer parsed.deinit(gpa);

    const duped_path: Path = .{
        .root_dir = dso.path.root_dir,
        .sub_path = try gpa.dupe(u8, dso.path.sub_path),
    };
    errdefer gpa.free(duped_path.sub_path);

    files.set(index, .{
        .shared_object = .{
            .parsed = parsed,
            .path = duped_path,
            .index = index,
            .needed = dso.needed,
            .alive = dso.needed,
            .aliases = null,
            .symbols = .empty,
            .symbols_extra = .empty,
            .symbols_resolver = .empty,
            .output_symtab_ctx = .{},
        },
    });
    const so = fileLookup(files.*, index, null).?.shared_object;

    // TODO: save this work for later
    const nsyms = parsed.symbols.len;
    try so.symbols.ensureTotalCapacityPrecise(gpa, nsyms);
    try so.symbols_extra.ensureTotalCapacityPrecise(gpa, nsyms * @typeInfo(Symbol.Extra).@"struct".field_names.len);
    try so.symbols_resolver.ensureTotalCapacityPrecise(gpa, nsyms);
    so.symbols_resolver.appendNTimesAssumeCapacity(0, nsyms);

    for (parsed.symtab, parsed.symbols, parsed.versyms, 0..) |esym, sym, versym, i| {
        const out_sym_index = so.addSymbolAssumeCapacity();
        const out_sym = &so.symbols.items[out_sym_index];
        out_sym.value = @intCast(esym.value);
        out_sym.name_offset = sym.mangled_name;
        out_sym.ref = .{ .index = 0, .file = 0 };
        out_sym.esym_index = @intCast(i);
        out_sym.version_index = versym;
        out_sym.extra_index = so.addSymbolExtraAssumeCapacity(.{});
    }
}

/// When resolving symbols, we approach the problem similarly to `mold`.
/// 1. Resolve symbols across all objects (including those preemptively extracted archives).
/// 2. Resolve symbols across all shared objects.
/// 3. Mark live objects (see `Elf.markLive`)
/// 4. Reset state of all resolved globals since we will redo this bit on the pruned set.
/// 5. Remove references to dead objects/shared objects
/// 6. Re-run symbol resolution on pruned objects and shared objects sets.
pub fn resolveSymbols(self: *Elf) !void {
    // This function mutates `shared_objects`.
    const shared_objects = &self.shared_objects;

    // Resolve symbols in the ZigObject. For now, we assume that it's always live.
    if (self.zigObjectPtr()) |zo| try zo.asFile().resolveSymbols(self);
    // Resolve symbols on the set of all objects and shared objects (even if some are unneeded).
    for (self.objects.items) |index| try self.file(index).?.resolveSymbols(self);
    for (shared_objects.values()) |index| try self.file(index).?.resolveSymbols(self);
    if (self.linkerDefinedPtr()) |obj| try obj.asFile().resolveSymbols(self);

    // Mark live objects.
    self.markLive();

    // Reset state of all globals after marking live objects.
    self.resolver.reset();

    // Prune dead objects and shared objects.
    var i: usize = 0;
    while (i < self.objects.items.len) {
        const index = self.objects.items[i];
        if (!self.file(index).?.isAlive()) {
            _ = self.objects.orderedRemove(i);
        } else i += 1;
    }
    // TODO This loop has 2 major flaws:
    // 1. It is O(N^2) which is never allowed in the codebase.
    // 2. It mutates shared_objects, which is a non-starter for incremental compilation.
    i = 0;
    while (i < shared_objects.values().len) {
        const index = shared_objects.values()[i];
        if (!self.file(index).?.isAlive()) {
            _ = shared_objects.orderedRemoveAt(i);
        } else i += 1;
    }

    {
        // Dedup groups.
        var table = std.StringHashMap(Ref).init(self.base.comp.gpa);
        defer table.deinit();

        for (self.objects.items) |index| {
            try self.file(index).?.object.resolveGroups(self, &table);
        }

        for (self.objects.items) |index| {
            self.file(index).?.object.markGroupsDead(self);
        }
    }

    // Re-resolve the symbols.
    if (self.zigObjectPtr()) |zo| try zo.asFile().resolveSymbols(self);
    for (self.objects.items) |index| try self.file(index).?.resolveSymbols(self);
    for (shared_objects.values()) |index| try self.file(index).?.resolveSymbols(self);
    if (self.linkerDefinedPtr()) |obj| try obj.asFile().resolveSymbols(self);
}

/// Traverses all objects and shared objects marking any object referenced by
/// a live object/shared object as alive itself.
/// This routine will prune unneeded objects extracted from archives and
/// unneeded shared objects.
fn markLive(self: *Elf) void {
    const shared_objects = self.shared_objects.values();
    if (self.zigObjectPtr()) |zig_object| zig_object.asFile().markLive(self);
    for (self.objects.items) |index| {
        const file_ptr = self.file(index).?;
        if (file_ptr.isAlive()) file_ptr.markLive(self);
    }
    for (shared_objects) |index| {
        const file_ptr = self.file(index).?;
        if (file_ptr.isAlive()) file_ptr.markLive(self);
    }
}

pub fn markEhFrameAtomsDead(self: *Elf) void {
    for (self.objects.items) |index| {
        const file_ptr = self.file(index).?;
        if (!file_ptr.isAlive()) continue;
        file_ptr.object.markEhFrameAtomsDead(self);
    }
}

fn markImportsExports(self: *Elf) void {
    const shared_objects = self.shared_objects.values();
    if (self.zigObjectPtr()) |zo| {
        zo.markImportsExports(self);
    }
    for (self.objects.items) |index| {
        self.file(index).?.object.markImportsExports(self);
    }
    if (!self.isEffectivelyDynLib()) {
        for (shared_objects) |index| {
            self.file(index).?.shared_object.markImportExports(self);
        }
    }
}

fn claimUnresolved(self: *Elf) void {
    if (self.zigObjectPtr()) |zig_object| {
        zig_object.claimUnresolved(self);
    }
    for (self.objects.items) |index| {
        self.file(index).?.object.claimUnresolved(self);
    }
}

/// In scanRelocs we will go over all live atoms and scan their relocs.
/// This will help us work out what synthetics to emit, GOT indirection, etc.
/// This is also the point where we will report undefined symbols for any
/// alloc sections.
fn scanRelocs(self: *Elf) !void {
    const gpa = self.base.comp.gpa;
    const shared_objects = self.shared_objects.values();

    var undefs: std.array_hash_map.Auto(SymbolResolver.Index, std.array_list.Managed(Ref)) = .empty;
    defer {
        for (undefs.values()) |*refs| refs.deinit();
        undefs.deinit(gpa);
    }

    var has_reloc_errors = false;
    if (self.zigObjectPtr()) |zo| {
        zo.asFile().scanRelocs(self, &undefs) catch |err| switch (err) {
            error.RelaxFailure => unreachable,
            error.UnsupportedCpuArch => {
                try self.reportUnsupportedCpuArch();
                return error.AlreadyReported;
            },
            error.RelocFailure => has_reloc_errors = true,
            else => |e| return e,
        };
    }
    for (self.objects.items) |index| {
        self.file(index).?.scanRelocs(self, &undefs) catch |err| switch (err) {
            error.RelaxFailure => unreachable,
            error.UnsupportedCpuArch => {
                try self.reportUnsupportedCpuArch();
                return error.AlreadyReported;
            },
            error.RelocFailure => has_reloc_errors = true,
            else => |e| return e,
        };
    }

    try self.reportUndefinedSymbols(&undefs);

    if (has_reloc_errors) return error.AlreadyReported;

    if (self.zigObjectPtr()) |zo| {
        try zo.asFile().createSymbolIndirection(self);
    }
    for (self.objects.items) |index| {
        try self.file(index).?.createSymbolIndirection(self);
    }
    for (shared_objects) |index| {
        try self.file(index).?.createSymbolIndirection(self);
    }
    if (self.linkerDefinedPtr()) |obj| {
        try obj.asFile().createSymbolIndirection(self);
    }
    if (self.got.flags.needs_tlsld) {
        log.debug("program needs TLSLD", .{});
        try self.got.addTlsLdSymbol(self);
    }
}

pub fn initOutputSection(self: *Elf, args: struct {
    name: [:0]const u8,
    flags: u64,
    type: u32,
}) error{OutOfMemory}!u32 {
    const args_flags: elf.SHF = @bitCast(@as(elf.Word, @truncate(args.flags)));
    const args_type: elf.SHT = @enumFromInt(args.type);
    const name = blk: {
        if (self.base.isRelocatable()) break :blk args.name;
        if (args_flags.MERGE) break :blk args.name;
        const name_prefixes: []const [:0]const u8 = &.{
            ".text",          ".data.rel.ro", ".data",        ".rodata", ".bss.rel.ro", ".bss",
            ".preinit_array", ".init_array",  ".fini_array",  ".tbss",   ".tdata",      ".gcc_except_table",
            ".ctors",         ".dtors",       ".gnu.warning",
        };
        inline for (name_prefixes) |prefix| {
            if (mem.eql(u8, args.name, prefix) or mem.startsWith(u8, args.name, prefix ++ ".")) {
                break :blk prefix;
            }
        }
        break :blk args.name;
    };
    const @"type" = tt: {
        if (self.getTarget().cpu.arch == .x86_64 and args_type == elf.SHT.X86_64_UNWIND)
            break :tt elf.SHT.PROGBITS;
        switch (args_type) {
            .NULL => unreachable,
            .PROGBITS => {
                if (mem.eql(u8, args.name, ".preinit_array") or mem.startsWith(u8, args.name, ".preinit_array."))
                    break :tt elf.SHT.PREINIT_ARRAY;
                if (mem.eql(u8, args.name, ".init_array") or mem.startsWith(u8, args.name, ".init_array."))
                    break :tt elf.SHT.INIT_ARRAY;
                if (mem.eql(u8, args.name, ".fini_array") or mem.startsWith(u8, args.name, ".fini_array."))
                    break :tt elf.SHT.FINI_ARRAY;
                break :tt args_type;
            },
            else => break :tt args_type,
        }
    };
    const flags = blk: {
        var flags = args_flags;
        if (!self.base.isRelocatable()) {
            flags.COMPRESSED = false;
            flags.GROUP = false;
            flags.OS.GNU.RETAIN = false;
        }
        switch (@"type") {
            .INIT_ARRAY, .FINI_ARRAY => flags.WRITE = true,
            else => {},
        }
        break :blk flags;
    };
    const out_shndx = self.sectionByName(name) orelse try self.addSection(.{
        .type = @intFromEnum(@"type"),
        .flags = @as(elf.Word, @bitCast(flags)),
        .name = try self.insertShString(name),
    });
    return out_shndx;
}

pub fn writeShdrTable(self: *Elf) !void {
    const gpa = self.base.comp.gpa;
    const target_endian = self.getTarget().cpu.arch.endian();
    const foreign_endian = target_endian != builtin.cpu.arch.endian();
    const shsize: u64 = switch (self.ptr_width) {
        .p32 => @sizeOf(elf.Elf32.Shdr),
        .p64 => @sizeOf(elf.Elf64.Shdr),
    };
    const shalign: u16 = switch (self.ptr_width) {
        .p32 => @alignOf(elf.Elf32.Shdr),
        .p64 => @alignOf(elf.Elf64.Shdr),
    };

    const shoff = self.shdr_table_offset orelse 0;
    const needed_size = self.sections.items(.shdr).len * shsize;

    if (needed_size > self.allocatedSize(shoff)) {
        self.shdr_table_offset = null;
        self.shdr_table_offset = try self.findFreeSpace(needed_size, shalign);
    }

    log.debug("writing section headers from 0x{x} to 0x{x}", .{
        self.shdr_table_offset.?,
        self.shdr_table_offset.? + needed_size,
    });

    switch (self.ptr_width) {
        .p32 => {
            const buf = try gpa.alloc(elf.Elf32.Shdr, self.sections.items(.shdr).len);
            defer gpa.free(buf);

            for (buf, 0..) |*shdr, i| {
                assert(self.sections.items(.shdr)[i].offset != math.maxInt(u64));
                shdr.* = shdrTo32(self.sections.items(.shdr)[i]);
                if (foreign_endian) {
                    mem.byteSwapAllFields(elf.Elf32.Shdr, shdr);
                }
            }
            try self.pwriteAll(@ptrCast(buf), self.shdr_table_offset.?);
        },
        .p64 => {
            const buf = try gpa.alloc(elf.Elf64.Shdr, self.sections.items(.shdr).len);
            defer gpa.free(buf);

            for (buf, 0..) |*shdr, i| {
                assert(self.sections.items(.shdr)[i].offset != math.maxInt(u64));
                shdr.* = self.sections.items(.shdr)[i];
                if (foreign_endian) {
                    mem.byteSwapAllFields(elf.Elf64.Shdr, shdr);
                }
            }
            try self.pwriteAll(@ptrCast(buf), self.shdr_table_offset.?);
        },
    }
}

fn writePhdrTable(self: *Elf) !void {
    const gpa = self.base.comp.gpa;
    const target_endian = self.getTarget().cpu.arch.endian();
    const foreign_endian = target_endian != builtin.cpu.arch.endian();
    const phdr_table = &self.phdrs.items[self.phdr_indexes.table.int().?];

    log.debug("writing program headers from 0x{x} to 0x{x}", .{
        phdr_table.offset,
        phdr_table.offset + phdr_table.filesz,
    });

    switch (self.ptr_width) {
        .p32 => {
            const buf = try gpa.alloc(elf.Elf32.Phdr, self.phdrs.items.len);
            defer gpa.free(buf);

            for (buf, 0..) |*phdr, i| {
                phdr.* = phdrTo32(self.phdrs.items[i]);
                if (foreign_endian) {
                    mem.byteSwapAllFields(elf.Elf32.Phdr, phdr);
                }
            }
            try self.pwriteAll(@ptrCast(buf), phdr_table.offset);
        },
        .p64 => {
            const buf = try gpa.alloc(elf.Elf64.Phdr, self.phdrs.items.len);
            defer gpa.free(buf);

            for (buf, 0..) |*phdr, i| {
                phdr.* = self.phdrs.items[i];
                if (foreign_endian) {
                    mem.byteSwapAllFields(elf.Elf64.Phdr, phdr);
                }
            }
            try self.pwriteAll(@ptrCast(buf), phdr_table.offset);
        },
    }
}

pub fn writeElfHeader(self: *Elf) !void {
    const diags = &self.base.comp.link_diags;
    if (diags.hasErrors()) return; // We had errors, so skip flushing to render the output unusable

    const comp = self.base.comp;
    var hdr_buf: [@sizeOf(elf.Elf64.Ehdr)]u8 = undefined;

    var index: usize = 0;
    hdr_buf[0..4].* = elf.MAGIC.*;
    index += 4;

    hdr_buf[index] = switch (self.ptr_width) {
        .p32 => @intFromEnum(elf.CLASS.@"32"),
        .p64 => @intFromEnum(elf.CLASS.@"64"),
    };
    index += 1;

    const target = self.getTarget();
    const endian = target.cpu.arch.endian();
    hdr_buf[index] = switch (endian) {
        .little => @intFromEnum(elf.DATA.@"2LSB"),
        .big => @intFromEnum(elf.DATA.@"2MSB"),
    };
    index += 1;

    hdr_buf[index] = 1; // ELF version
    index += 1;

    hdr_buf[index] = @backingInt(@as(elf.OSABI, switch (target.cpu.arch) {
        .amdgcn => switch (target.os.tag) {
            .amdhsa => .AMDGPU_HSA,
            .amdpal => .AMDGPU_PAL,
            .mesa3d => .AMDGPU_MESA3D,
            else => .NONE,
        },
        .msp430 => .STANDALONE,
        else => switch (target.os.tag) {
            .freebsd, .ps4 => .FREEBSD,
            .hermit => .STANDALONE,
            .illumos => .SOLARIS,
            .openbsd => .OPENBSD,
            else => .NONE,
        },
    }));
    index += 1;

    // ABI Version, possibly used by glibc but not by static executables
    // padding
    @memset(hdr_buf[index..][0..8], 0);
    index += 8;

    assert(index == 16);

    const output_mode = comp.config.output_mode;
    const link_mode = comp.config.link_mode;
    const elf_type: elf.ET = switch (output_mode) {
        .Exe => if (comp.config.pie or target.os.tag == .haiku) .DYN else .EXEC,
        .Obj => .REL,
        .Lib => switch (link_mode) {
            .static => @as(elf.ET, .REL),
            .dynamic => .DYN,
        },
    };
    mem.writeInt(u16, hdr_buf[index..][0..2], @backingInt(elf_type), endian);
    index += 2;

    const machine = target.toElfMachine();
    mem.writeInt(u16, hdr_buf[index..][0..2], @backingInt(machine), endian);
    index += 2;

    // ELF Version, again
    mem.writeInt(u32, hdr_buf[index..][0..4], 1, endian);
    index += 4;

    const e_entry: u64 = if (self.linkerDefinedPtr()) |obj| blk: {
        const entry_sym = obj.entrySymbol(self) orelse break :blk 0;
        break :blk @intCast(entry_sym.address(.{}, self));
    } else 0;
    const phdr_table_offset = if (self.phdr_indexes.table.int()) |phndx| self.phdrs.items[phndx].offset else 0;
    switch (self.ptr_width) {
        .p32 => {
            mem.writeInt(u32, hdr_buf[index..][0..4], @intCast(e_entry), endian);
            index += 4;

            // e_phoff
            mem.writeInt(u32, hdr_buf[index..][0..4], @intCast(phdr_table_offset), endian);
            index += 4;

            // e_shoff
            mem.writeInt(u32, hdr_buf[index..][0..4], @intCast(self.shdr_table_offset.?), endian);
            index += 4;
        },
        .p64 => {
            // e_entry
            mem.writeInt(u64, hdr_buf[index..][0..8], e_entry, endian);
            index += 8;

            // e_phoff
            mem.writeInt(u64, hdr_buf[index..][0..8], phdr_table_offset, endian);
            index += 8;

            // e_shoff
            mem.writeInt(u64, hdr_buf[index..][0..8], self.shdr_table_offset.?, endian);
            index += 8;
        },
    }

    const e_flags = 0;
    mem.writeInt(u32, hdr_buf[index..][0..4], e_flags, endian);
    index += 4;

    const e_ehsize: u16 = switch (self.ptr_width) {
        .p32 => @sizeOf(elf.Elf32.Ehdr),
        .p64 => @sizeOf(elf.Elf64.Ehdr),
    };
    mem.writeInt(u16, hdr_buf[index..][0..2], e_ehsize, endian);
    index += 2;

    const e_phentsize: u16 = switch (self.ptr_width) {
        .p32 => @sizeOf(elf.Elf32.Phdr),
        .p64 => @sizeOf(elf.Elf64.Phdr),
    };
    mem.writeInt(u16, hdr_buf[index..][0..2], e_phentsize, endian);
    index += 2;

    const e_phnum = @as(u16, @intCast(self.phdrs.items.len));
    mem.writeInt(u16, hdr_buf[index..][0..2], e_phnum, endian);
    index += 2;

    const e_shentsize: u16 = switch (self.ptr_width) {
        .p32 => @sizeOf(elf.Elf32.Shdr),
        .p64 => @sizeOf(elf.Elf64.Shdr),
    };
    mem.writeInt(u16, hdr_buf[index..][0..2], e_shentsize, endian);
    index += 2;

    const e_shnum: u16 = @intCast(self.sections.items(.shdr).len);
    mem.writeInt(u16, hdr_buf[index..][0..2], e_shnum, endian);
    index += 2;

    mem.writeInt(u16, hdr_buf[index..][0..2], @intCast(self.section_indexes.shstrtab.?), endian);
    index += 2;

    assert(index == e_ehsize);

    try self.pwriteAll(hdr_buf[0..index], 0);
}

pub fn freeNav(self: *Elf, nav: InternPool.Nav.Index) void {
    return self.zigObjectPtr().?.freeNav(self, nav);
}

pub fn updateFunc(
    self: *Elf,
    pt: Zcu.PerThread,
    func_index: InternPool.Index,
    mir: *const codegen.AnyMir,
) link.Error!void {
    return self.zigObjectPtr().?.updateFunc(self, pt, func_index, mir);
}

pub fn updateNav(
    self: *Elf,
    pt: Zcu.PerThread,
    nav: InternPool.Nav.Index,
) link.Error!void {
    return self.zigObjectPtr().?.updateNav(self, pt, nav);
}

pub fn updateContainerType(
    self: *Elf,
    pt: Zcu.PerThread,
    ty: InternPool.Index,
    success: bool,
) link.Error!void {
    try self.zigObjectPtr().?.updateContainerType(pt, ty, success);
}

pub fn updateExports(
    self: *Elf,
    pt: Zcu.PerThread,
    export_indices: []const Zcu.Export.Index,
) link.Error!void {
    return self.zigObjectPtr().?.updateExports(self, pt, export_indices);
}

pub fn updateLineNumber(self: *Elf, pt: Zcu.PerThread, inst: InternPool.TrackedInst.Index, line: u32) link.Error!void {
    return self.zigObjectPtr().?.updateLineNumber(pt, inst, line);
}

fn checkDuplicates(self: *Elf) !void {
    const gpa = self.base.comp.gpa;

    var dupes: std.array_hash_map.Auto(SymbolResolver.Index, std.ArrayList(File.Index)) = .empty;
    defer {
        for (dupes.values()) |*list| {
            list.deinit(gpa);
        }
        dupes.deinit(gpa);
    }

    if (self.zigObjectPtr()) |zig_object| {
        try zig_object.checkDuplicates(&dupes, self);
    }
    for (self.objects.items) |index| {
        try self.file(index).?.object.checkDuplicates(&dupes, self);
    }

    try self.reportDuplicates(dupes);
}

pub fn addCommentString(self: *Elf) !void {
    const gpa = self.base.comp.gpa;
    if (self.comment_merge_section_index != null) return;
    const msec_index = try self.getOrCreateMergeSection(
        ".comment",
        @as(elf.Word, @bitCast(elf.SHF{ .MERGE = true, .STRINGS = true })),
        @intFromEnum(elf.SHT.PROGBITS),
    );
    const msec = self.mergeSection(msec_index);
    const res = try msec.insertZ(gpa, "zig " ++ builtin.zig_version_string);
    if (res.found_existing) return;
    const msub_index = try msec.addMergeSubsection(gpa);
    const msub = msec.mergeSubsection(msub_index);
    msub.merge_section_index = msec_index;
    msub.string_index = res.key.pos;
    msub.alignment = .@"1";
    msub.size = res.key.len;
    msub.entsize = 1;
    msub.alive = true;
    res.sub.* = msub_index;
    self.comment_merge_section_index = msec_index;
}

pub fn resolveMergeSections(self: *Elf) !void {
    const tracy = trace(@src());
    defer tracy.end();

    var has_errors = false;
    for (self.objects.items) |index| {
        const object = self.file(index).?.object;
        if (!object.alive) continue;
        if (!object.dirty) continue;
        object.initInputMergeSections(self) catch |err| switch (err) {
            error.AlreadyReported => has_errors = true,
            else => |e| return e,
        };
    }

    if (has_errors) return error.AlreadyReported;

    for (self.objects.items) |index| {
        const object = self.file(index).?.object;
        if (!object.alive) continue;
        if (!object.dirty) continue;
        try object.initOutputMergeSections(self);
    }

    for (self.objects.items) |index| {
        const object = self.file(index).?.object;
        if (!object.alive) continue;
        if (!object.dirty) continue;
        object.resolveMergeSubsections(self) catch |err| switch (err) {
            error.AlreadyReported => has_errors = true,
            else => |e| return e,
        };
    }

    if (has_errors) return error.AlreadyReported;
}

pub fn finalizeMergeSections(self: *Elf) !void {
    for (self.merge_sections.items) |*msec| {
        try msec.finalize(self.base.comp.gpa);
    }
}

pub fn updateMergeSectionSizes(self: *Elf) !void {
    for (self.merge_sections.items) |*msec| {
        msec.updateSize();
    }
    for (self.merge_sections.items) |*msec| {
        const shdr = &self.sections.items(.shdr)[msec.output_section_index];
        const offset = msec.alignment.forward(shdr.size);
        const padding = offset - shdr.size;
        msec.value = @intCast(offset);
        shdr.size += padding + msec.size;
        shdr.addralign = @max(shdr.addralign, msec.alignment.toByteUnits() orelse 1);
        shdr.entsize = if (shdr.entsize == 0) msec.entsize else @min(shdr.entsize, msec.entsize);
    }
}

pub fn writeMergeSections(self: *Elf) !void {
    const gpa = self.base.comp.gpa;
    var buffer = std.array_list.Managed(u8).init(gpa);
    defer buffer.deinit();

    for (self.merge_sections.items) |*msec| {
        const shdr = self.sections.items(.shdr)[msec.output_section_index];
        const fileoff = try self.cast(usize, msec.value + shdr.offset);
        const size = try self.cast(usize, msec.size);
        try buffer.ensureTotalCapacity(size);
        buffer.appendNTimesAssumeCapacity(0, size);

        for (msec.finalized_subsections.items) |msub_index| {
            const msub = msec.mergeSubsection(msub_index);
            assert(msub.alive);
            const string = msub.getString(self);
            const off = try self.cast(usize, msub.value);
            @memcpy(buffer.items[off..][0..string.len], string);
        }

        try self.pwriteAll(buffer.items, fileoff);
        buffer.clearRetainingCapacity();
    }
}

fn initOutputSections(self: *Elf) !void {
    for (self.objects.items) |index| {
        try self.file(index).?.object.initOutputSections(self);
    }
    for (self.merge_sections.items) |*msec| {
        if (msec.finalized_subsections.items.len == 0) continue;
        try msec.initOutputSection(self);
    }
}

fn initSyntheticSections(self: *Elf) !void {
    const comp = self.base.comp;
    const target = self.getTarget();
    const ptr_size = self.ptrWidthBytes();

    const is_exe_or_dyn_lib = switch (comp.config.output_mode) {
        .Exe => true,
        .Lib => comp.config.link_mode == .dynamic,
        .Obj => false,
    };
    const have_dynamic_linker = comp.config.link_mode == .dynamic and is_exe_or_dyn_lib;

    const needs_eh_frame = blk: {
        if (self.zigObjectPtr()) |zo|
            if (zo.eh_frame_index != null) break :blk true;
        break :blk for (self.objects.items) |index| {
            if (self.file(index).?.object.cies.items.len > 0) break true;
        } else false;
    };

    if (needs_eh_frame) {
        if (self.section_indexes.eh_frame == null) {
            self.section_indexes.eh_frame = self.sectionByName(".eh_frame") orelse try self.addSection(.{
                .name = try self.insertShString(".eh_frame"),
                .type = shtInt(if (target.cpu.arch == .x86_64)
                    .X86_64_UNWIND
                else
                    .PROGBITS),
                .flags = shfInt(.{ .ALLOC = true }),
                .addralign = ptr_size,
            });
        }
        if (comp.link_eh_frame_hdr and self.section_indexes.eh_frame_hdr == null) {
            self.section_indexes.eh_frame_hdr = try self.addSection(.{
                .name = try self.insertShString(".eh_frame_hdr"),
                .type = shtInt(.PROGBITS),
                .flags = shfInt(.{ .ALLOC = true }),
                .addralign = 4,
            });
        }
    }

    if (self.got.entries.items.len > 0 and self.section_indexes.got == null) {
        self.section_indexes.got = try self.addSection(.{
            .name = try self.insertShString(".got"),
            .type = shtInt(.PROGBITS),
            .flags = shfInt(.{ .ALLOC = true, .WRITE = true }),
            .addralign = ptr_size,
        });
    }

    if (have_dynamic_linker) {
        if (self.section_indexes.got_plt == null) {
            self.section_indexes.got_plt = try self.addSection(.{
                .name = try self.insertShString(".got.plt"),
                .type = shtInt(.PROGBITS),
                .flags = shfInt(.{ .ALLOC = true, .WRITE = true }),
                .addralign = @alignOf(u64),
            });
        }
    } else {
        assert(self.plt.symbols.items.len == 0);
    }

    const needs_rela_dyn = blk: {
        if (self.got.flags.needs_rela or self.got.flags.needs_tlsld or self.copy_rel.symbols.items.len > 0)
            break :blk true;
        if (self.zigObjectPtr()) |zig_object| {
            if (zig_object.num_dynrelocs > 0) break :blk true;
        }
        for (self.objects.items) |index| {
            if (self.file(index).?.object.num_dynrelocs > 0) break :blk true;
        }
        break :blk false;
    };
    if (needs_rela_dyn and self.section_indexes.rela_dyn == null) {
        self.section_indexes.rela_dyn = try self.addSection(.{
            .name = try self.insertShString(".rela.dyn"),
            .type = shtInt(.RELA),
            .flags = shfInt(.{ .ALLOC = true }),
            .addralign = @alignOf(elf.Elf64.Rela),
            .entsize = @sizeOf(elf.Elf64.Rela),
        });
    }

    if (self.plt.symbols.items.len > 0) {
        if (self.section_indexes.plt == null) {
            self.section_indexes.plt = try self.addSection(.{
                .name = try self.insertShString(".plt"),
                .type = shtInt(.PROGBITS),
                .flags = shfInt(.{ .ALLOC = true, .EXECINSTR = true }),
                .addralign = 16,
            });
        }
        if (self.section_indexes.rela_plt == null) {
            self.section_indexes.rela_plt = try self.addSection(.{
                .name = try self.insertShString(".rela.plt"),
                .type = shtInt(.RELA),
                .flags = shfInt(.{ .ALLOC = true }),
                .addralign = @alignOf(elf.Elf64.Rela),
                .entsize = @sizeOf(elf.Elf64.Rela),
            });
        }
    }

    if (self.plt_got.symbols.items.len > 0 and self.section_indexes.plt_got == null) {
        self.section_indexes.plt_got = try self.addSection(.{
            .name = try self.insertShString(".plt.got"),
            .type = shtInt(.PROGBITS),
            .flags = shfInt(.{ .ALLOC = true, .EXECINSTR = true }),
            .addralign = 16,
        });
    }

    if (self.copy_rel.symbols.items.len > 0 and self.section_indexes.copy_rel == null) {
        self.section_indexes.copy_rel = try self.addSection(.{
            .name = try self.insertShString(".copyrel"),
            .type = shtInt(.NOBITS),
            .flags = shfInt(.{ .ALLOC = true, .WRITE = true }),
        });
    }

    if (needs_interp: {
        if (comp.config.link_mode == .static) break :needs_interp false;
        if (target.dynamic_linker.get() == null) break :needs_interp false;
        break :needs_interp switch (comp.config.output_mode) {
            .Exe => true,
            .Lib => comp.root_mod.resolved_target.is_explicit_dynamic_linker,
            .Obj => false,
        };
    } and self.section_indexes.interp == null) {
        self.section_indexes.interp = try self.addSection(.{
            .name = try self.insertShString(".interp"),
            .type = shtInt(.PROGBITS),
            .flags = shfInt(.{ .ALLOC = true }),
            .addralign = 1,
        });
    }

    if (have_dynamic_linker or comp.config.pie or self.isEffectivelyDynLib()) {
        if (self.section_indexes.dynstrtab == null) {
            self.section_indexes.dynstrtab = try self.addSection(.{
                .name = try self.insertShString(".dynstr"),
                .flags = shfInt(.{ .ALLOC = true }),
                .type = shtInt(.STRTAB),
                .entsize = 1,
                .addralign = 1,
            });
        }
        if (self.section_indexes.dynamic == null) {
            self.section_indexes.dynamic = try self.addSection(.{
                .name = try self.insertShString(".dynamic"),
                .flags = shfInt(.{ .ALLOC = true, .WRITE = true }),
                .type = shtInt(.DYNAMIC),
                .entsize = @sizeOf(elf.Elf64.Dyn),
                .addralign = @alignOf(elf.Elf64.Dyn),
            });
        }
        if (self.section_indexes.dynsymtab == null) {
            self.section_indexes.dynsymtab = try self.addSection(.{
                .name = try self.insertShString(".dynsym"),
                .flags = shfInt(.{ .ALLOC = true }),
                .type = shtInt(.DYNSYM),
                .addralign = @alignOf(elf.Elf64.Sym),
                .entsize = @sizeOf(elf.Elf64.Sym),
                .info = 1,
            });
        }
        if (self.section_indexes.hash == null) {
            self.section_indexes.hash = try self.addSection(.{
                .name = try self.insertShString(".hash"),
                .flags = shfInt(.{ .ALLOC = true }),
                .type = shtInt(.HASH),
                .addralign = 4,
                .entsize = 4,
            });
        }
        if (self.section_indexes.gnu_hash == null) {
            self.section_indexes.gnu_hash = try self.addSection(.{
                .name = try self.insertShString(".gnu.hash"),
                .flags = shfInt(.{ .ALLOC = true }),
                .type = shtInt(.GNU_HASH),
                .addralign = 8,
            });
        }

        const needs_versions = for (self.dynsym.entries.items) |entry| {
            const sym = self.symbol(entry.ref).?;
            if (sym.flags.import and sym.version_index.VERSION > elf.Versym.GLOBAL.VERSION) break true;
        } else false;
        if (needs_versions) {
            if (self.section_indexes.versym == null) {
                self.section_indexes.versym = try self.addSection(.{
                    .name = try self.insertShString(".gnu.version"),
                    .flags = shfInt(.{ .ALLOC = true }),
                    .type = shtInt(.GNU_VERSYM),
                    .addralign = @alignOf(elf.Versym),
                    .entsize = @sizeOf(elf.Versym),
                });
            }
            if (self.section_indexes.verneed == null) {
                self.section_indexes.verneed = try self.addSection(.{
                    .name = try self.insertShString(".gnu.version_r"),
                    .flags = shfInt(.{ .ALLOC = true }),
                    .type = shtInt(.GNU_VERNEED),
                    .addralign = @alignOf(elf.Elf64.Verneed),
                });
            }
        }
    }

    try self.initSymtab();
    try self.initShStrtab();
}

pub fn initSymtab(self: *Elf) !void {
    const small_ptr = switch (self.ptr_width) {
        .p32 => true,
        .p64 => false,
    };
    if (self.section_indexes.symtab == null) {
        self.section_indexes.symtab = try self.addSection(.{
            .name = try self.insertShString(".symtab"),
            .type = shtInt(.SYMTAB),
            .addralign = if (small_ptr) @alignOf(elf.Elf32.Sym) else @alignOf(elf.Elf64.Sym),
            .entsize = if (small_ptr) @sizeOf(elf.Elf32.Sym) else @sizeOf(elf.Elf64.Sym),
        });
    }
    if (self.section_indexes.strtab == null) {
        self.section_indexes.strtab = try self.addSection(.{
            .name = try self.insertShString(".strtab"),
            .type = shtInt(.STRTAB),
            .entsize = 1,
            .addralign = 1,
        });
    }
}

pub fn initShStrtab(self: *Elf) !void {
    if (self.section_indexes.shstrtab == null) {
        self.section_indexes.shstrtab = try self.addSection(.{
            .name = try self.insertShString(".shstrtab"),
            .type = shtInt(.STRTAB),
            .entsize = 1,
            .addralign = 1,
        });
    }
}

fn initSpecialPhdrs(self: *Elf) !void {
    comptime assert(max_number_of_special_phdrs == 5);

    if (self.section_indexes.interp != null and self.phdr_indexes.interp == .none) {
        self.phdr_indexes.interp = (try self.addPhdr(.{
            .type = .INTERP,
            .flags = .{ .R = true },
            .@"align" = 1,
        })).toOptional();
    }
    if (self.section_indexes.dynamic != null and self.phdr_indexes.dynamic == .none) {
        self.phdr_indexes.dynamic = (try self.addPhdr(.{
            .type = .DYNAMIC,
            .flags = .{ .R = true, .W = true },
        })).toOptional();
    }
    if (self.section_indexes.eh_frame_hdr != null and self.phdr_indexes.gnu_eh_frame == .none) {
        self.phdr_indexes.gnu_eh_frame = (try self.addPhdr(.{
            .type = .GNU_EH_FRAME,
            .flags = .{ .R = true },
        })).toOptional();
    }
    if (self.phdr_indexes.gnu_stack == .none) {
        self.phdr_indexes.gnu_stack = (try self.addPhdr(.{
            .type = .GNU_STACK,
            .flags = .{ .W = true, .R = true },
            .memsz = self.base.stack_size,
            .@"align" = 1,
        })).toOptional();
    }

    const has_tls = for (self.sections.items(.shdr)) |shdr| {
        if (shdr.flags.shf.TLS) break true;
    } else false;
    if (has_tls and self.phdr_indexes.tls == .none) {
        self.phdr_indexes.tls = (try self.addPhdr(.{
            .type = .TLS,
            .flags = .{ .R = true },
            .@"align" = 1,
        })).toOptional();
    }
}

/// We need to sort constructors/destuctors in the following sections:
/// * .init_array
/// * .fini_array
/// * .preinit_array
/// * .ctors
/// * .dtors
/// The prority of inclusion is defined as part of the input section's name. For example, .init_array.10000.
/// If no priority value has been specified,
/// * for .init_array, .fini_array and .preinit_array, we automatically assign that section max value of maxInt(i32)
///   and push it to the back of the queue,
/// * for .ctors and .dtors, we automatically assign that section min value of -1
///   and push it to the front of the queue,
/// crtbegin and ctrend are assigned minInt(i32) and maxInt(i32) respectively.
/// Ties are broken by the file prority which corresponds to the inclusion of input sections in this output section
/// we are about to sort.
fn sortInitFini(self: *Elf) !void {
    const gpa = self.base.comp.gpa;
    const slice = self.sections.slice();

    const Entry = struct {
        priority: i32,
        atom_ref: Ref,

        pub fn lessThan(ctx: *Elf, lhs: @This(), rhs: @This()) bool {
            if (lhs.priority == rhs.priority) {
                return ctx.atom(lhs.atom_ref).?.priority(ctx) < ctx.atom(rhs.atom_ref).?.priority(ctx);
            }
            return lhs.priority < rhs.priority;
        }
    };

    for (slice.items(.shdr), slice.items(.atom_list_2)) |shdr, *atom_list| {
        if (!shdr.flags.shf.ALLOC) continue;
        if (atom_list.atoms.keys().len == 0) continue;

        var is_init_fini = false;
        var is_ctor_dtor = false;
        switch (shdr.type) {
            .PREINIT_ARRAY,
            .INIT_ARRAY,
            .FINI_ARRAY,
            => is_init_fini = true,
            else => {
                const name = self.getShString(shdr.name);
                is_ctor_dtor = mem.find(u8, name, ".ctors") != null or mem.find(u8, name, ".dtors") != null;
            },
        }
        if (!is_init_fini and !is_ctor_dtor) continue;

        var entries = std.array_list.Managed(Entry).init(gpa);
        try entries.ensureTotalCapacityPrecise(atom_list.atoms.keys().len);
        defer entries.deinit();

        for (atom_list.atoms.keys()) |ref| {
            const atom_ptr = self.atom(ref).?;
            const object = atom_ptr.file(self).?.object;
            const priority = blk: {
                if (is_ctor_dtor) {
                    const basename = object.path.basename();
                    if (mem.eql(u8, basename, "crtbegin.o")) break :blk std.math.minInt(i32);
                    if (mem.eql(u8, basename, "crtend.o")) break :blk std.math.maxInt(i32);
                }
                const default: i32 = if (is_ctor_dtor) -1 else std.math.maxInt(i32);
                const name = atom_ptr.name(self);
                var it = mem.splitBackwardsScalar(u8, name, '.');
                const priority = std.fmt.parseUnsigned(u16, it.first(), 10) catch default;
                break :blk priority;
            };
            entries.appendAssumeCapacity(.{ .priority = priority, .atom_ref = ref });
        }

        mem.sort(Entry, entries.items, self, Entry.lessThan);

        atom_list.atoms.clearRetainingCapacity();
        for (entries.items) |entry| {
            _ = atom_list.atoms.getOrPutAssumeCapacity(entry.atom_ref);
        }
    }
}

fn setDynamicSection(self: *Elf, rpaths: []const []const u8) !void {
    if (self.section_indexes.dynamic == null) return;

    const shared_objects = self.shared_objects.values();

    for (shared_objects) |index| {
        const shared_object = self.file(index).?.shared_object;
        if (!shared_object.alive) continue;
        try self.dynamic.addNeeded(shared_object, self);
    }

    if (self.isEffectivelyDynLib()) {
        if (self.soname) |soname| {
            try self.dynamic.setSoname(soname, self);
        }
    }

    try self.dynamic.setRpath(rpaths, self);
}

fn sortDynamicSymtab(self: *Elf) void {
    if (self.section_indexes.gnu_hash == null) return;
    self.dynsym.sort(self);
}

fn setVersionSymtab(self: *Elf) !void {
    const gpa = self.base.comp.gpa;
    if (self.section_indexes.versym == null) return;
    try self.versym.resize(gpa, self.dynsym.count());
    self.versym.items[0] = .LOCAL;
    for (self.dynsym.entries.items, 1..) |entry, i| {
        const sym = self.symbol(entry.ref).?;
        self.versym.items[i] = sym.version_index;
    }

    if (self.section_indexes.verneed) |shndx| {
        try self.verneed.generate(self);
        const shdr = &self.sections.items(.shdr)[shndx];
        shdr.info = @as(u32, @intCast(self.verneed.verneed.items.len));
    }
}

fn setHashSections(self: *Elf) !void {
    if (self.section_indexes.hash != null) {
        try self.hash.generate(self);
    }
    if (self.section_indexes.gnu_hash != null) {
        try self.gnu_hash.calcSize(self);
    }
}

fn phdrRank(phdr: elf.Elf64.Phdr) u8 {
    return switch (phdr.type) {
        .NULL => 0,
        .PHDR => 1,
        .INTERP => 2,
        .LOAD => 3,
        .DYNAMIC, .TLS => 4,
        .GNU_EH_FRAME => 5,
        .GNU_STACK => 6,
        else => 7,
    };
}

fn sortPhdrs(
    gpa: Allocator,
    phdrs: *ProgramHeaderList,
    special_indexes: *ProgramHeaderIndexes,
    section_indexes: []OptionalProgramHeaderIndex,
) error{OutOfMemory}!void {
    const Entry = struct {
        phndx: u16,

        pub fn lessThan(program_headers: []const elf.Elf64.Phdr, lhs: @This(), rhs: @This()) bool {
            const lhs_phdr = program_headers[lhs.phndx];
            const rhs_phdr = program_headers[rhs.phndx];
            const lhs_rank = phdrRank(lhs_phdr);
            const rhs_rank = phdrRank(rhs_phdr);
            if (lhs_rank == rhs_rank) return lhs_phdr.vaddr < rhs_phdr.vaddr;
            return lhs_rank < rhs_rank;
        }
    };

    const entries = try gpa.alloc(Entry, phdrs.items.len);
    defer gpa.free(entries);
    for (entries, 0..) |*entry, phndx| {
        entry.* = .{ .phndx = @intCast(phndx) };
    }

    // The `@as` here works around a bug in the C backend.
    mem.sort(Entry, entries, @as([]const elf.Elf64.Phdr, phdrs.items), Entry.lessThan);

    const backlinks = try gpa.alloc(u16, entries.len);
    defer gpa.free(backlinks);
    const slice = try phdrs.toOwnedSlice(gpa);
    defer gpa.free(slice);
    try phdrs.resize(gpa, slice.len);

    for (entries, phdrs.items, 0..) |entry, *phdr, i| {
        backlinks[entry.phndx] = @intCast(i);
        phdr.* = slice[entry.phndx];
    }

    inline for (@typeInfo(ProgramHeaderIndexes).@"struct".field_names) |field_name| {
        if (@field(special_indexes, field_name).int()) |special_index| {
            @field(special_indexes, field_name) = @fromBackingInt(@intCast(backlinks[special_index]));
        }
    }

    for (section_indexes) |*opt_phndx| {
        if (opt_phndx.int()) |index| {
            opt_phndx.* = @fromBackingInt(@intCast(backlinks[index]));
        }
    }
}

fn shdrRank(shdr: elf.Elf64.Shdr, shstrtab: []const u8) u8 {
    const name = shString(shstrtab, shdr.name);
    const flags = shdr.flags.shf;

    switch (shdr.type) {
        .NULL => return 0,
        .DYNSYM => return 2,
        .HASH => return 3,
        .GNU_HASH => return 3,
        .GNU_VERSYM => return 4,
        .GNU_VERDEF => return 4,
        .GNU_VERNEED => return 4,

        .PREINIT_ARRAY,
        .INIT_ARRAY,
        .FINI_ARRAY,
        => return 0xf1,

        .DYNAMIC => return 0xf2,

        .RELA, .GROUP => return 0xf,

        .PROGBITS => if (flags.ALLOC) {
            if (flags.EXECINSTR) {
                return 0xf0;
            } else if (flags.WRITE) {
                return if (flags.TLS) 0xf3 else 0xf5;
            } else if (mem.eql(u8, name, ".interp")) {
                return 1;
            } else if (mem.startsWith(u8, name, ".eh_frame")) {
                return 0xe1;
            } else {
                return 0xe0;
            }
        } else {
            if (mem.startsWith(u8, name, ".debug")) {
                return 0xf7;
            } else {
                return 0xf8;
            }
        },
        .X86_64_UNWIND => return 0xe1,

        .NOBITS => return if (flags.TLS) 0xf4 else 0xf6,
        .SYMTAB => return 0xf9,
        .STRTAB => return if (mem.eql(u8, name, ".dynstr")) 0x4 else 0xfa,
        else => return 0xff,
    }
}

pub fn sortShdrs(
    gpa: Allocator,
    section_indexes: *SectionIndexes,
    sections: *std.MultiArrayList(Section),
    shstrtab: []const u8,
    merge_sections: []Merge.Section,
    comdat_group_sections: []GroupSection,
    zig_object_ptr: ?*ZigObject,
    files: std.MultiArrayList(File.Entry),
) !void {
    const Entry = struct {
        shndx: u32,

        const Context = struct {
            shdrs: []const elf.Elf64.Shdr,
            shstrtab: []const u8,
        };

        pub fn lessThan(ctx: Context, lhs: @This(), rhs: @This()) bool {
            const lhs_rank = shdrRank(ctx.shdrs[lhs.shndx], ctx.shstrtab);
            const rhs_rank = shdrRank(ctx.shdrs[rhs.shndx], ctx.shstrtab);
            if (lhs_rank == rhs_rank) {
                const lhs_name = shString(ctx.shstrtab, ctx.shdrs[lhs.shndx].name);
                const rhs_name = shString(ctx.shstrtab, ctx.shdrs[rhs.shndx].name);
                return std.mem.lessThan(u8, lhs_name, rhs_name);
            }
            return lhs_rank < rhs_rank;
        }
    };

    const shdrs = sections.items(.shdr);

    const entries = try gpa.alloc(Entry, shdrs.len);
    defer gpa.free(entries);
    for (entries, 0..shdrs.len) |*entry, shndx| {
        entry.* = .{ .shndx = @intCast(shndx) };
    }

    const sort_context: Entry.Context = .{
        .shdrs = shdrs,
        .shstrtab = shstrtab,
    };
    mem.sortUnstable(Entry, entries, sort_context, Entry.lessThan);

    const backlinks = try gpa.alloc(u32, entries.len);
    defer gpa.free(backlinks);
    {
        var slice = sections.toOwnedSlice();
        defer slice.deinit(gpa);
        try sections.resize(gpa, slice.len);

        for (entries, 0..) |entry, i| {
            backlinks[entry.shndx] = @intCast(i);
            sections.set(i, slice.get(entry.shndx));
        }
    }

    inline for (@typeInfo(SectionIndexes).@"struct".field_names) |field_name| {
        if (@field(section_indexes, field_name)) |special_index| {
            @field(section_indexes, field_name) = backlinks[special_index];
        }
    }

    for (merge_sections) |*msec| {
        msec.output_section_index = backlinks[msec.output_section_index];
    }

    const slice = sections.slice();
    for (slice.items(.shdr), slice.items(.atom_list_2)) |*shdr, *atom_list| {
        atom_list.output_section_index = backlinks[atom_list.output_section_index];
        for (atom_list.atoms.keys()) |ref| {
            fileLookup(files, ref.file, zig_object_ptr).?.atom(ref.index).?.output_section_index = atom_list.output_section_index;
        }
        if (shdr.type == .RELA) {
            shdr.link = section_indexes.symtab.?;
            shdr.info = backlinks[shdr.info];
        }
    }

    if (zig_object_ptr) |zo| zo.resetShdrIndexes(backlinks);

    for (comdat_group_sections) |*cg| {
        cg.shndx = backlinks[cg.shndx];
    }

    if (section_indexes.symtab) |index| {
        const shdr = &slice.items(.shdr)[index];
        shdr.link = section_indexes.strtab.?;
    }

    if (section_indexes.dynamic) |index| {
        const shdr = &slice.items(.shdr)[index];
        shdr.link = section_indexes.dynstrtab.?;
    }

    if (section_indexes.dynsymtab) |index| {
        const shdr = &slice.items(.shdr)[index];
        shdr.link = section_indexes.dynstrtab.?;
    }

    if (section_indexes.hash) |index| {
        const shdr = &slice.items(.shdr)[index];
        shdr.link = section_indexes.dynsymtab.?;
    }

    if (section_indexes.gnu_hash) |index| {
        const shdr = &slice.items(.shdr)[index];
        shdr.link = section_indexes.dynsymtab.?;
    }

    if (section_indexes.versym) |index| {
        const shdr = &slice.items(.shdr)[index];
        shdr.link = section_indexes.dynsymtab.?;
    }

    if (section_indexes.verneed) |index| {
        const shdr = &slice.items(.shdr)[index];
        shdr.link = section_indexes.dynstrtab.?;
    }

    if (section_indexes.rela_dyn) |index| {
        const shdr = &slice.items(.shdr)[index];
        shdr.link = section_indexes.dynsymtab orelse 0;
    }

    if (section_indexes.rela_plt) |index| {
        const shdr = &slice.items(.shdr)[index];
        shdr.link = section_indexes.dynsymtab.?;
        shdr.info = section_indexes.plt.?;
    }

    if (section_indexes.eh_frame_rela) |index| {
        const shdr = &slice.items(.shdr)[index];
        shdr.link = section_indexes.symtab.?;
        shdr.info = section_indexes.eh_frame.?;
    }
}

fn updateSectionSizes(self: *Elf) !void {
    const slice = self.sections.slice();
    for (slice.items(.shdr), slice.items(.atom_list_2)) |shdr, *atom_list| {
        if (atom_list.atoms.keys().len == 0) continue;
        if (!atom_list.dirty) continue;
        if (self.requiresThunks() and shdr.flags.shf.EXECINSTR) continue;
        atom_list.updateSize(self);
        try atom_list.allocate(self);
        atom_list.dirty = false;
    }

    if (self.requiresThunks()) {
        for (slice.items(.shdr), slice.items(.atom_list_2)) |shdr, *atom_list| {
            if (!shdr.flags.shf.EXECINSTR) continue;
            if (atom_list.atoms.keys().len == 0) continue;
            if (!atom_list.dirty) continue;

            // Create jump/branch range extenders if needed.
            try self.createThunks(atom_list);
            try atom_list.allocate(self);
            atom_list.dirty = false;
        }

        // This might not be needed if there was a link from Atom/Thunk to AtomList.
        for (self.thunks.items) |*th| {
            th.value += slice.items(.atom_list_2)[th.output_section_index].value;
        }
    }

    const shdrs = slice.items(.shdr);
    if (self.section_indexes.eh_frame) |index| {
        shdrs[index].size = try eh_frame.calcEhFrameSize(self);
    }

    if (self.section_indexes.eh_frame_hdr) |index| {
        shdrs[index].size = eh_frame.calcEhFrameHdrSize(self);
    }

    if (self.section_indexes.got) |index| {
        shdrs[index].size = self.got.size(self);
    }

    if (self.section_indexes.plt) |index| {
        shdrs[index].size = self.plt.size(self);
    }

    if (self.section_indexes.got_plt) |index| {
        shdrs[index].size = self.got_plt.size(self);
    }

    if (self.section_indexes.plt_got) |index| {
        shdrs[index].size = self.plt_got.size(self);
    }

    if (self.section_indexes.rela_dyn) |shndx| {
        var num = self.got.numRela(self) + self.copy_rel.numRela();
        if (self.zigObjectPtr()) |zig_object| {
            num += zig_object.num_dynrelocs;
        }
        for (self.objects.items) |index| {
            num += self.file(index).?.object.num_dynrelocs;
        }
        shdrs[shndx].size = num * @sizeOf(elf.Elf64.Rela);
    }

    if (self.section_indexes.rela_plt) |index| {
        shdrs[index].size = self.plt.numRela() * @sizeOf(elf.Elf64.Rela);
    }

    if (self.section_indexes.copy_rel) |index| {
        try self.copy_rel.updateSectionSize(index, self);
    }

    if (self.section_indexes.interp) |index| {
        shdrs[index].size = self.getTarget().dynamic_linker.get().?.len + 1;
    }

    if (self.section_indexes.hash) |index| {
        shdrs[index].size = self.hash.size();
    }

    if (self.section_indexes.gnu_hash) |index| {
        shdrs[index].size = self.gnu_hash.size();
    }

    if (self.section_indexes.dynamic) |index| {
        shdrs[index].size = self.dynamic.size(self);
    }

    if (self.section_indexes.dynsymtab) |index| {
        shdrs[index].size = self.dynsym.size();
    }

    if (self.section_indexes.dynstrtab) |index| {
        shdrs[index].size = self.dynstrtab.items.len;
    }

    if (self.section_indexes.versym) |index| {
        shdrs[index].size = self.versym.items.len * @sizeOf(elf.Versym);
    }

    if (self.section_indexes.verneed) |index| {
        shdrs[index].size = self.verneed.size();
    }

    try self.updateSymtabSize();
    self.updateShStrtabSize();
}

pub fn updateShStrtabSize(self: *Elf) void {
    if (self.section_indexes.shstrtab) |index| {
        self.sections.items(.shdr)[index].size = self.shstrtab.items.len;
    }
}

fn shdrToPhdrFlags(shf: elf.SHF) elf.PF {
    return .{
        .R = true,
        .W = shf.WRITE,
        .X = shf.EXECINSTR,
    };
}

/// Returns maximum number of program headers that may be emitted by the linker.
/// (This is an upper bound so that we can reserve enough space for the header and progam header
/// table without running out of space and being forced to move things around.)
fn getMaxNumberOfPhdrs() u64 {
    // The estimated maximum number of segments the linker can emit for input sections are:
    var num: u64 = max_number_of_object_segments;
    // Any other non-loadable program headers, including TLS, DYNAMIC, GNU_STACK, GNU_EH_FRAME, INTERP:
    num += max_number_of_special_phdrs;
    // PHDR program header and corresponding read-only load segment:
    num += 2;
    return num;
}

fn addLoadPhdrs(self: *Elf) error{OutOfMemory}!void {
    for (self.sections.items(.shdr)) |shdr| {
        if (shdr.type == .NULL) continue;
        if (!shdr.flags.shf.ALLOC) continue;
        const flags = shdrToPhdrFlags(shdr.flags.shf);
        if (self.getPhdr(.{ .flags = flags, .type = .LOAD }) == .none) {
            _ = try self.addPhdr(.{ .flags = flags, .type = .LOAD });
        }
    }
}

/// Allocates PHDR table in virtual memory and in file.
fn allocatePhdrTable(self: *Elf) error{OutOfMemory}!void {
    const diags = &self.base.comp.link_diags;
    const phdr_table = &self.phdrs.items[self.phdr_indexes.table.int().?];
    const phdr_table_load = &self.phdrs.items[self.phdr_indexes.table_load.int().?];

    const ehsize: u64 = switch (self.ptr_width) {
        .p32 => @sizeOf(elf.Elf32.Ehdr),
        .p64 => @sizeOf(elf.Elf64.Ehdr),
    };
    const phsize: u64 = switch (self.ptr_width) {
        .p32 => @sizeOf(elf.Elf32.Phdr),
        .p64 => @sizeOf(elf.Elf64.Phdr),
    };
    const needed_size = self.phdrs.items.len * phsize;
    const available_space = self.allocatedSize(phdr_table.offset);

    if (needed_size > available_space) {
        // In this case, we have two options:
        // 1. increase the available padding for EHDR + PHDR table so that we don't overflow it
        //    (revisit getMaxNumberOfPhdrs())
        // 2. shift everything in file to free more space for EHDR + PHDR table
        // TODO verify `getMaxNumberOfPhdrs()` is accurate and convert this into no-op
        var err = try diags.addErrorWithNotes(1);
        try err.addMsg("fatal linker error: not enough space reserved for EHDR and PHDR table", .{});
        err.addNote("required 0x{x}, available 0x{x}", .{ needed_size, available_space });
    }

    phdr_table_load.filesz = needed_size + ehsize;
    phdr_table_load.memsz = needed_size + ehsize;
    phdr_table.filesz = needed_size;
    phdr_table.memsz = needed_size;
}

/// Allocates alloc sections and creates load segments for sections
/// extracted from input object files.
pub fn allocateAllocSections(self: *Elf) !void {
    // We use this struct to track maximum alignment of all TLS sections.
    // According to https://github.com/rui314/mold/commit/bd46edf3f0fe9e1a787ea453c4657d535622e61f in mold,
    // in-file offsets have to be aligned against the start of TLS program header.
    // If that's not ensured, then in a multi-threaded context, TLS variables across a shared object
    // boundary may not get correctly loaded at an aligned address.
    const Align = struct {
        tls_start_align: u64 = 1,
        first_tls_index: ?usize = null,

        fn isFirstTlsShdr(this: @This(), other: usize) bool {
            if (this.first_tls_index) |index| return index == other;
            return false;
        }

        fn @"align"(this: @This(), index: usize, sh_addralign: u64, addr: u64) u64 {
            const alignment = if (this.isFirstTlsShdr(index)) this.tls_start_align else sh_addralign;
            return mem.alignForward(u64, addr, alignment);
        }
    };

    const slice = self.sections.slice();
    var alignment = Align{};
    for (slice.items(.shdr), 0..) |shdr, i| {
        if (shdr.type == .NULL) continue;
        if (!shdr.flags.shf.TLS) continue;
        if (alignment.first_tls_index == null) alignment.first_tls_index = i;
        alignment.tls_start_align = @max(alignment.tls_start_align, shdr.addralign);
    }

    // Next, calculate segment covers by scanning all alloc sections.
    // If a section matches segment flags with the preceeding section,
    // we put it in the same segment. Otherwise, we create a new cover.
    // This algorithm is simple but suboptimal in terms of space re-use:
    // normally we would also take into account any gaps in allocated
    // virtual and file offsets. However, the simple one will do for one
    // as we are more interested in quick turnaround and compatibility
    // with `findFreeSpace` mechanics than anything else.
    const Cover = std.array_list.Managed(u32);
    const gpa = self.base.comp.gpa;
    var covers: [max_number_of_object_segments]Cover = undefined;
    for (&covers) |*cover| {
        cover.* = Cover.init(gpa);
    }
    defer for (&covers) |*cover| {
        cover.deinit();
    };

    for (slice.items(.shdr), 0..) |shdr, shndx| {
        if (shdr.type == .NULL) continue;
        if (!shdr.flags.shf.ALLOC) continue;
        const flags = shdrToPhdrFlags(shdr.flags.shf);
        try covers[@as(elf.Word, @bitCast(flags)) - 1].append(@intCast(shndx));
    }

    // Now we can proceed with allocating the sections in virtual memory.
    // As the base address we take the end address of the PHDR table.
    // When allocating we first find the largest required alignment
    // of any section that is contained in a cover and use it to align
    // the start address of the segement (and first section).
    const phdr_table = &self.phdrs.items[self.phdr_indexes.table_load.int().?];
    var addr = phdr_table.vaddr + phdr_table.memsz;

    for (covers) |cover| {
        if (cover.items.len == 0) continue;

        var @"align": u64 = self.page_size;
        for (cover.items) |shndx| {
            const shdr = slice.items(.shdr)[shndx];
            if (shdr.type == .NOBITS and shdr.flags.shf.TLS) continue;
            @"align" = @max(@"align", shdr.addralign);
        }

        addr = mem.alignForward(u64, addr, @"align");

        var memsz: u64 = 0;
        var filesz: u64 = 0;
        var i: usize = 0;
        while (i < cover.items.len) : (i += 1) {
            const shndx = cover.items[i];
            const shdr = &slice.items(.shdr)[shndx];
            if (shdr.type == .NOBITS and shdr.flags.shf.TLS) {
                // .tbss is a little special as it's used only by the loader meaning it doesn't
                // need to be actually mmap'ed at runtime. We still need to correctly increment
                // the addresses of every TLS zerofill section tho. Thus, we hack it so that
                // we increment the start address like normal, however, after we are done,
                // the next ALLOC section will get its start address allocated within the same
                // range as the .tbss sections. We will get something like this:
                //
                // ...
                // .tbss 0x10
                // .tcommon 0x20
                // .data 0x10
                // ...
                var tbss_addr = addr;
                while (i < cover.items.len and
                    slice.items(.shdr)[cover.items[i]].type == .NOBITS and
                    slice.items(.shdr)[cover.items[i]].flags.shf.TLS) : (i += 1)
                {
                    const tbss_shndx = cover.items[i];
                    const tbss_shdr = &slice.items(.shdr)[tbss_shndx];
                    tbss_addr = alignment.@"align"(tbss_shndx, tbss_shdr.addralign, tbss_addr);
                    tbss_shdr.addr = tbss_addr;
                    tbss_addr += tbss_shdr.size;
                }
                i -= 1;
                continue;
            }
            const next = alignment.@"align"(shndx, shdr.addralign, addr);
            const padding = next - addr;
            addr = next;
            shdr.addr = addr;
            if (shdr.type != .NOBITS) {
                filesz += padding + shdr.size;
            }
            memsz += padding + shdr.size;
            addr += shdr.size;
        }

        const first = slice.items(.shdr)[cover.items[0]];
        const phndx = self.getPhdr(.{ .type = .LOAD, .flags = shdrToPhdrFlags(first.flags.shf) }).unwrap().?;
        const phdr = &self.phdrs.items[phndx.int()];
        const allocated_size = self.allocatedSize(phdr.offset);
        if (filesz > allocated_size) {
            const old_offset = phdr.offset;
            phdr.offset = 0;
            var new_offset = try self.findFreeSpace(filesz, @"align");
            phdr.offset = new_offset;

            log.debug("moving phdr({d}) from 0x{x} to 0x{x}", .{ phndx, old_offset, new_offset });

            for (cover.items) |shndx| {
                const shdr = &slice.items(.shdr)[shndx];
                slice.items(.phndx)[shndx] = phndx.toOptional();
                if (shdr.type == .NOBITS) {
                    shdr.offset = 0;
                    continue;
                }
                new_offset = alignment.@"align"(shndx, shdr.addralign, new_offset);

                log.debug("moving {s} from 0x{x} to 0x{x}", .{
                    self.getShString(shdr.name),
                    shdr.offset,
                    new_offset,
                });

                if (shdr.offset > 0) {
                    // Get size actually commited to the output file.
                    const existing_size = self.sectionSize(shndx);
                    try self.base.copyRangeAll(shdr.offset, new_offset, existing_size);
                }

                shdr.offset = new_offset;
                new_offset += shdr.size;
            }
        }

        phdr.vaddr = first.addr;
        phdr.paddr = first.addr;
        phdr.memsz = memsz;
        phdr.filesz = filesz;
        phdr.@"align" = @"align";

        addr = mem.alignForward(u64, addr, self.page_size);
    }
}

/// Allocates non-alloc sections (debug info, symtabs, etc.).
pub fn allocateNonAllocSections(self: *Elf) !void {
    for (self.sections.items(.shdr), 0..) |*shdr, shndx| {
        if (shdr.type == .NULL) continue;
        if (shdr.flags.shf.ALLOC) continue;
        const needed_size = shdr.size;
        if (needed_size > self.allocatedSize(shdr.offset)) {
            shdr.size = 0;
            const new_offset = try self.findFreeSpace(needed_size, shdr.addralign);

            log.debug("moving {s} from 0x{x} to 0x{x}", .{
                self.getShString(shdr.name),
                shdr.offset,
                new_offset,
            });

            if (shdr.offset > 0) {
                const existing_size = self.sectionSize(@intCast(shndx));
                try self.base.copyRangeAll(shdr.offset, new_offset, existing_size);
            }

            shdr.offset = new_offset;
            shdr.size = needed_size;
        }
    }
}

fn allocateSpecialPhdrs(self: *Elf) void {
    const slice = self.sections.slice();

    for (&[_]struct { OptionalProgramHeaderIndex, ?u32 }{
        .{ self.phdr_indexes.interp, self.section_indexes.interp },
        .{ self.phdr_indexes.dynamic, self.section_indexes.dynamic },
        .{ self.phdr_indexes.gnu_eh_frame, self.section_indexes.eh_frame_hdr },
    }) |pair| {
        if (pair[0].int()) |index| {
            const shdr = slice.items(.shdr)[pair[1].?];
            const phdr = &self.phdrs.items[index];
            phdr.@"align" = shdr.addralign;
            phdr.offset = shdr.offset;
            phdr.vaddr = shdr.addr;
            phdr.paddr = shdr.addr;
            phdr.filesz = shdr.size;
            phdr.memsz = shdr.size;
        }
    }

    // Set the TLS segment boundaries.
    // We assume TLS sections are laid out contiguously and that there is
    // a single TLS segment.
    if (self.phdr_indexes.tls.int()) |index| {
        const shdrs = slice.items(.shdr);
        const phdr = &self.phdrs.items[index];
        var shndx: u32 = 0;
        while (shndx < shdrs.len) {
            const shdr = shdrs[shndx];
            if (!shdr.flags.shf.TLS) {
                shndx += 1;
                continue;
            }
            phdr.offset = shdr.offset;
            phdr.vaddr = shdr.addr;
            phdr.paddr = shdr.addr;
            phdr.@"align" = shdr.addralign;
            shndx += 1;
            phdr.@"align" = @max(phdr.@"align", shdr.addralign);
            if (shdr.type != .NOBITS) {
                phdr.filesz = shdr.offset + shdr.size - phdr.offset;
            }
            phdr.memsz = shdr.addr + shdr.size - phdr.vaddr;

            while (shndx < shdrs.len) : (shndx += 1) {
                const next = shdrs[shndx];
                if (!next.flags.shf.TLS) break;
                phdr.@"align" = @max(phdr.@"align", next.addralign);
                if (next.type != .NOBITS) {
                    phdr.filesz = next.offset + next.size - phdr.offset;
                }
                phdr.memsz = next.addr + next.size - phdr.vaddr;
            }
        }
    }
}

fn writeAtoms(self: *Elf) !void {
    const gpa = self.base.comp.gpa;

    var undefs: std.array_hash_map.Auto(SymbolResolver.Index, std.array_list.Managed(Ref)) = .empty;
    defer {
        for (undefs.values()) |*refs| refs.deinit();
        undefs.deinit(gpa);
    }

    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();

    const slice = self.sections.slice();
    var has_reloc_errors = false;
    for (slice.items(.shdr), slice.items(.atom_list_2)) |shdr, atom_list| {
        if (shdr.type == .NOBITS) continue;
        if (atom_list.atoms.keys().len == 0) continue;
        atom_list.write(&buffer, &undefs, self) catch |err| switch (err) {
            error.UnsupportedCpuArch => {
                try self.reportUnsupportedCpuArch();
                return error.AlreadyReported;
            },
            error.RelocFailure, error.RelaxFailure => has_reloc_errors = true,
            else => |e| return e,
        };
    }

    try self.reportUndefinedSymbols(&undefs);
    if (has_reloc_errors) return error.AlreadyReported;

    if (self.requiresThunks()) {
        for (self.thunks.items) |th| {
            const thunk_size = th.size(self);
            try buffer.ensureUnusedCapacity(thunk_size);
            const shdr = slice.items(.shdr)[th.output_section_index];
            const offset = @as(u64, @intCast(th.value)) + shdr.offset;
            try th.write(self, &buffer.writer);
            assert(buffer.written().len == thunk_size);
            try self.pwriteAll(buffer.written(), offset);
            buffer.clearRetainingCapacity();
        }
    }
}

pub fn updateSymtabSize(self: *Elf) !void {
    var nlocals: u32 = 0;
    var nglobals: u32 = 0;
    var strsize: u32 = 0;

    const gpa = self.base.comp.gpa;
    const shared_objects = self.shared_objects.values();

    var files = std.array_list.Managed(File.Index).init(gpa);
    defer files.deinit();
    try files.ensureTotalCapacityPrecise(self.objects.items.len + shared_objects.len + 2);

    if (self.zig_object_index) |index| files.appendAssumeCapacity(index);
    for (self.objects.items) |index| files.appendAssumeCapacity(index);
    for (shared_objects) |index| files.appendAssumeCapacity(index);
    if (self.linker_defined_index) |index| files.appendAssumeCapacity(index);

    // Section symbols
    nlocals += @intCast(self.sections.slice().len);

    if (self.requiresThunks()) for (self.thunks.items) |*th| {
        th.output_symtab_ctx.reset();
        th.output_symtab_ctx.ilocal = nlocals;
        th.calcSymtabSize(self);
        nlocals += th.output_symtab_ctx.nlocals;
        strsize += th.output_symtab_ctx.strsize;
    };

    for (files.items) |index| {
        const file_ptr = self.file(index).?;
        const ctx = switch (file_ptr) {
            inline else => |x| &x.output_symtab_ctx,
        };
        ctx.reset();
        ctx.ilocal = nlocals;
        ctx.iglobal = nglobals;
        try file_ptr.updateSymtabSize(self);
        nlocals += ctx.nlocals;
        nglobals += ctx.nglobals;
        strsize += ctx.strsize;
    }

    if (self.section_indexes.got) |_| {
        self.got.output_symtab_ctx.reset();
        self.got.output_symtab_ctx.ilocal = nlocals;
        self.got.updateSymtabSize(self);
        nlocals += self.got.output_symtab_ctx.nlocals;
        strsize += self.got.output_symtab_ctx.strsize;
    }

    if (self.section_indexes.plt) |_| {
        self.plt.output_symtab_ctx.reset();
        self.plt.output_symtab_ctx.ilocal = nlocals;
        self.plt.updateSymtabSize(self);
        nlocals += self.plt.output_symtab_ctx.nlocals;
        strsize += self.plt.output_symtab_ctx.strsize;
    }

    if (self.section_indexes.plt_got) |_| {
        self.plt_got.output_symtab_ctx.reset();
        self.plt_got.output_symtab_ctx.ilocal = nlocals;
        self.plt_got.updateSymtabSize(self);
        nlocals += self.plt_got.output_symtab_ctx.nlocals;
        strsize += self.plt_got.output_symtab_ctx.strsize;
    }

    for (files.items) |index| {
        const file_ptr = self.file(index).?;
        const ctx = switch (file_ptr) {
            inline else => |x| &x.output_symtab_ctx,
        };
        ctx.iglobal += nlocals;
    }

    const slice = self.sections.slice();
    const symtab_shdr = &slice.items(.shdr)[self.section_indexes.symtab.?];
    symtab_shdr.info = nlocals;
    symtab_shdr.link = self.section_indexes.strtab.?;

    const sym_size: u64 = switch (self.ptr_width) {
        .p32 => @sizeOf(elf.Elf32.Sym),
        .p64 => @sizeOf(elf.Elf64.Sym),
    };
    const needed_size = (nlocals + nglobals) * sym_size;
    symtab_shdr.size = needed_size;

    const strtab = &slice.items(.shdr)[self.section_indexes.strtab.?];
    strtab.size = strsize + 1;
}

fn writeSyntheticSections(self: *Elf) !void {
    const gpa = self.base.comp.gpa;
    const slice = self.sections.slice();

    if (self.section_indexes.interp) |shndx| {
        var buffer: [256]u8 = undefined;
        const interp = self.getTarget().dynamic_linker.get().?;
        @memcpy(buffer[0..interp.len], interp);
        buffer[interp.len] = 0;
        const contents = buffer[0 .. interp.len + 1];
        const shdr = slice.items(.shdr)[shndx];
        assert(shdr.size == contents.len);
        try self.pwriteAll(contents, shdr.offset);
    }

    if (self.section_indexes.hash) |shndx| {
        const shdr = slice.items(.shdr)[shndx];
        try self.pwriteAll(self.hash.buffer.items, shdr.offset);
    }

    if (self.section_indexes.gnu_hash) |shndx| {
        const shdr = slice.items(.shdr)[shndx];
        var aw: std.Io.Writer.Allocating = .init(gpa);
        try aw.ensureUnusedCapacity(self.gnu_hash.size());
        defer aw.deinit();
        try self.gnu_hash.write(self, &aw.writer);
        try self.pwriteAll(aw.written(), shdr.offset);
    }

    if (self.section_indexes.versym) |shndx| {
        const shdr = slice.items(.shdr)[shndx];
        try self.pwriteAll(@ptrCast(self.versym.items), shdr.offset);
    }

    if (self.section_indexes.verneed) |shndx| {
        const shdr = slice.items(.shdr)[shndx];
        var buffer = try std.Io.Writer.Allocating.initCapacity(gpa, self.verneed.size());
        defer buffer.deinit();
        try self.verneed.write(&buffer.writer);
        try self.pwriteAll(buffer.written(), shdr.offset);
    }

    if (self.section_indexes.dynamic) |shndx| {
        const shdr = slice.items(.shdr)[shndx];
        var buffer = try std.Io.Writer.Allocating.initCapacity(gpa, self.dynamic.size(self));
        defer buffer.deinit();
        try self.dynamic.write(self, &buffer.writer);
        try self.pwriteAll(buffer.written(), shdr.offset);
    }

    if (self.section_indexes.dynsymtab) |shndx| {
        const shdr = slice.items(.shdr)[shndx];
        var buffer = try std.Io.Writer.Allocating.initCapacity(gpa, self.dynsym.size());
        defer buffer.deinit();
        try self.dynsym.write(self, &buffer.writer);
        try self.pwriteAll(buffer.written(), shdr.offset);
    }

    if (self.section_indexes.dynstrtab) |shndx| {
        const shdr = slice.items(.shdr)[shndx];
        try self.pwriteAll(self.dynstrtab.items, shdr.offset);
    }

    if (self.section_indexes.eh_frame) |shndx| {
        const existing_size = existing_size: {
            const zo = self.zigObjectPtr() orelse break :existing_size 0;
            const sym = zo.symbol(zo.eh_frame_index orelse break :existing_size 0);
            break :existing_size sym.atom(self).?.size;
        };
        const shdr = slice.items(.shdr)[shndx];
        const sh_size = try self.cast(usize, shdr.size);
        var buffer = try std.Io.Writer.Allocating.initCapacity(gpa, @intCast(sh_size - existing_size));
        defer buffer.deinit();
        try eh_frame.writeEhFrame(self, &buffer.writer);
        assert(buffer.written().len == sh_size - existing_size);
        try self.pwriteAll(buffer.written(), shdr.offset + existing_size);
    }

    if (self.section_indexes.eh_frame_hdr) |shndx| {
        const shdr = slice.items(.shdr)[shndx];
        const sh_size = try self.cast(usize, shdr.size);
        var buffer = try std.Io.Writer.Allocating.initCapacity(gpa, sh_size);
        defer buffer.deinit();
        try eh_frame.writeEhFrameHdr(self, &buffer.writer);
        try self.pwriteAll(buffer.written(), shdr.offset);
    }

    if (self.section_indexes.got) |index| {
        const shdr = slice.items(.shdr)[index];
        var buffer = try std.Io.Writer.Allocating.initCapacity(gpa, self.got.size(self));
        defer buffer.deinit();
        try self.got.write(self, &buffer.writer);
        try self.pwriteAll(buffer.written(), shdr.offset);
    }

    if (self.section_indexes.rela_dyn) |shndx| {
        const shdr = slice.items(.shdr)[shndx];
        try self.got.addRela(self);
        try self.copy_rel.addRela(self);
        self.sortRelaDyn();
        try self.pwriteAll(@ptrCast(self.rela_dyn.items), shdr.offset);
    }

    if (self.section_indexes.plt) |shndx| {
        const shdr = slice.items(.shdr)[shndx];
        var buffer = try std.Io.Writer.Allocating.initCapacity(gpa, self.plt.size(self));
        defer buffer.deinit();
        try self.plt.write(self, &buffer.writer);
        try self.pwriteAll(buffer.written(), shdr.offset);
    }

    if (self.section_indexes.got_plt) |shndx| {
        const shdr = slice.items(.shdr)[shndx];
        var buffer = try std.Io.Writer.Allocating.initCapacity(gpa, self.got_plt.size(self));
        defer buffer.deinit();
        try self.got_plt.write(self, &buffer.writer);
        try self.pwriteAll(buffer.written(), shdr.offset);
    }

    if (self.section_indexes.plt_got) |shndx| {
        const shdr = slice.items(.shdr)[shndx];
        var buffer = try std.Io.Writer.Allocating.initCapacity(gpa, self.plt_got.size(self));
        defer buffer.deinit();
        try self.plt_got.write(self, &buffer.writer);
        try self.pwriteAll(buffer.written(), shdr.offset);
    }

    if (self.section_indexes.rela_plt) |shndx| {
        const shdr = slice.items(.shdr)[shndx];
        try self.plt.addRela(self);
        try self.pwriteAll(@ptrCast(self.rela_plt.items), shdr.offset);
    }

    try self.writeSymtab();
    try self.writeShStrtab();
}

pub fn writeShStrtab(self: *Elf) !void {
    if (self.section_indexes.shstrtab) |index| {
        const shdr = self.sections.items(.shdr)[index];
        log.debug("writing .shstrtab from 0x{x} to 0x{x}", .{ shdr.offset, shdr.offset + shdr.size });
        try self.pwriteAll(self.shstrtab.items, shdr.offset);
    }
}

pub fn writeSymtab(self: *Elf) !void {
    const gpa = self.base.comp.gpa;
    const shared_objects = self.shared_objects.values();

    const slice = self.sections.slice();
    const symtab_shdr = slice.items(.shdr)[self.section_indexes.symtab.?];
    const strtab_shdr = slice.items(.shdr)[self.section_indexes.strtab.?];
    const sym_size: u64 = switch (self.ptr_width) {
        .p32 => @sizeOf(elf.Elf32.Sym),
        .p64 => @sizeOf(elf.Elf64.Sym),
    };
    const nsyms = try self.cast(usize, @divExact(symtab_shdr.size, sym_size));

    log.debug("writing {d} symbols in .symtab from 0x{x} to 0x{x}", .{
        nsyms,
        symtab_shdr.offset,
        symtab_shdr.offset + symtab_shdr.size,
    });
    log.debug("writing .strtab from 0x{x} to 0x{x}", .{
        strtab_shdr.offset,
        strtab_shdr.offset + strtab_shdr.size,
    });

    try self.symtab.resize(gpa, nsyms);
    const needed_strtab_size = try self.cast(usize, strtab_shdr.size - 1);
    // TODO we could resize instead and in ZigObject/Object always access as slice
    self.strtab.clearRetainingCapacity();
    self.strtab.appendAssumeCapacity(0);
    try self.strtab.ensureUnusedCapacity(gpa, needed_strtab_size);

    for (slice.items(.shdr), 0..) |shdr, shndx| {
        const out_sym = &self.symtab.items[shndx];
        out_sym.* = .{
            .name = 0,
            .value = shdr.addr,
            .info = .{ .type = if (shdr.type == .NULL) .NOTYPE else .SECTION, .bind = .LOCAL },
            .shndx = @intCast(shndx),
            .size = 0,
            .other = .{ .visibility = .DEFAULT },
        };
    }

    if (self.requiresThunks()) for (self.thunks.items) |th| {
        th.writeSymtab(self);
    };

    if (self.zigObjectPtr()) |zig_object| {
        zig_object.asFile().writeSymtab(self);
    }

    for (self.objects.items) |index| {
        const file_ptr = self.file(index).?;
        file_ptr.writeSymtab(self);
    }

    for (shared_objects) |index| {
        const file_ptr = self.file(index).?;
        file_ptr.writeSymtab(self);
    }

    if (self.linkerDefinedPtr()) |obj| {
        obj.asFile().writeSymtab(self);
    }

    if (self.section_indexes.got) |_| {
        self.got.writeSymtab(self);
    }

    if (self.section_indexes.plt) |_| {
        self.plt.writeSymtab(self);
    }

    if (self.section_indexes.plt_got) |_| {
        self.plt_got.writeSymtab(self);
    }

    const foreign_endian = self.getTarget().cpu.arch.endian() != builtin.cpu.arch.endian();
    switch (self.ptr_width) {
        .p32 => {
            const buf = try gpa.alloc(elf.Elf32.Sym, self.symtab.items.len);
            defer gpa.free(buf);

            for (buf, self.symtab.items) |*out, sym| {
                out.* = .{
                    .name = sym.name,
                    .info = sym.info,
                    .other = sym.other,
                    .shndx = sym.shndx,
                    .value = @intCast(sym.value),
                    .size = @intCast(sym.size),
                };
                if (foreign_endian) mem.byteSwapAllFields(elf.Elf32.Sym, out);
            }
            try self.pwriteAll(@ptrCast(buf), symtab_shdr.offset);
        },
        .p64 => {
            if (foreign_endian) {
                for (self.symtab.items) |*sym| mem.byteSwapAllFields(elf.Elf64.Sym, sym);
            }
            try self.pwriteAll(@ptrCast(self.symtab.items), symtab_shdr.offset);
        },
    }

    try self.pwriteAll(self.strtab.items, strtab_shdr.offset);
}

/// Always 4 or 8 depending on whether this is 32-bit ELF or 64-bit ELF.
pub fn ptrWidthBytes(self: Elf) u8 {
    return switch (self.ptr_width) {
        .p32 => 4,
        .p64 => 8,
    };
}

/// Does not necessarily match `ptrWidthBytes` for example can be 2 bytes
/// in a 32-bit ELF file.
pub fn archPtrWidthBytes(self: Elf) u8 {
    return @intCast(@divExact(self.getTarget().ptrBitWidth(), 8));
}

fn phdrTo32(phdr: elf.Elf64.Phdr) elf.Elf32.Phdr {
    return .{
        .type = phdr.type,
        .flags = phdr.flags,
        .offset = @intCast(phdr.offset),
        .vaddr = @intCast(phdr.vaddr),
        .paddr = @intCast(phdr.paddr),
        .filesz = @intCast(phdr.filesz),
        .memsz = @intCast(phdr.memsz),
        .@"align" = @intCast(phdr.@"align"),
    };
}

fn shdrTo32(shdr: elf.Elf64.Shdr) elf.Elf32.Shdr {
    return .{
        .name = shdr.name,
        .type = shdr.type,
        .flags = .{ .shf = shdr.flags.shf },
        .addr = @as(u32, @intCast(shdr.addr)),
        .offset = @as(u32, @intCast(shdr.offset)),
        .size = @as(u32, @intCast(shdr.size)),
        .link = shdr.link,
        .info = shdr.info,
        .addralign = @as(u32, @intCast(shdr.addralign)),
        .entsize = @as(u32, @intCast(shdr.entsize)),
    };
}

pub fn padToIdeal(actual_size: anytype) @TypeOf(actual_size) {
    return actual_size +| (actual_size / ideal_factor);
}

/// If a target compiles other output modes as dynamic libraries,
/// this function returns true for those too.
pub fn isEffectivelyDynLib(self: Elf) bool {
    if (self.base.isDynLib()) return true;
    return switch (self.getTarget().os.tag) {
        .haiku => self.base.isExe(),
        else => false,
    };
}

fn getPhdr(self: *Elf, opts: struct {
    type: elf.PT = @enumFromInt(0),
    flags: elf.PF = .{},
}) OptionalProgramHeaderIndex {
    for (self.phdrs.items, 0..) |phdr, phndx| {
        if (self.phdr_indexes.table_load.int()) |index| {
            if (phndx == index) continue;
        }
        if (phdr.type == opts.type and
            @as(elf.Word, @bitCast(phdr.flags)) == @as(elf.Word, @bitCast(opts.flags)))
            return @fromBackingInt(@intCast(phndx));
    }
    return .none;
}

fn addPhdr(self: *Elf, opts: struct {
    type: elf.PT = @enumFromInt(0),
    flags: elf.PF = .{},
    @"align": u64 = 0,
    offset: u64 = 0,
    addr: u64 = 0,
    filesz: u64 = 0,
    memsz: u64 = 0,
}) error{OutOfMemory}!ProgramHeaderIndex {
    const gpa = self.base.comp.gpa;
    const index: ProgramHeaderIndex = @fromBackingInt(@intCast(self.phdrs.items.len));
    try self.phdrs.append(gpa, .{
        .type = opts.type,
        .flags = opts.flags,
        .offset = opts.offset,
        .vaddr = opts.addr,
        .paddr = opts.addr,
        .filesz = opts.filesz,
        .memsz = opts.memsz,
        .@"align" = opts.@"align",
    });
    return index;
}

pub fn addRelaShdr(self: *Elf, name: u32, shndx: u32) !u32 {
    const entsize: u64 = switch (self.ptr_width) {
        .p32 => @sizeOf(elf.Elf32.Rela),
        .p64 => @sizeOf(elf.Elf64.Rela),
    };
    const addralign: u64 = switch (self.ptr_width) {
        .p32 => @alignOf(elf.Elf32.Rela),
        .p64 => @alignOf(elf.Elf64.Rela),
    };
    return self.addSection(.{
        .name = name,
        .type = shtInt(.RELA),
        .flags = shfInt(.{ .INFO_LINK = true }),
        .entsize = entsize,
        .info = shndx,
        .addralign = addralign,
    });
}

/// Encodes a typed section type as the raw integer stored in `AddSectionOpts`.
inline fn shtInt(t: elf.SHT) u32 {
    return @intFromEnum(t);
}

/// Encodes typed section flags as the raw integer stored in `AddSectionOpts`.
inline fn shfInt(f: elf.SHF) u64 {
    return @as(elf.Word, @bitCast(f));
}

pub const AddSectionOpts = struct {
    name: u32 = 0,
    type: u32 = @intFromEnum(elf.SHT.NULL),
    flags: u64 = 0,
    link: u32 = 0,
    info: u32 = 0,
    addralign: u64 = 0,
    entsize: u64 = 0,
};

pub fn addSection(self: *Elf, opts: AddSectionOpts) !u32 {
    const gpa = self.base.comp.gpa;
    const index: u32 = @intCast(try self.sections.addOne(gpa));
    self.sections.set(index, .{
        .shdr = .{
            .name = opts.name,
            .type = @enumFromInt(opts.type),
            .flags = @bitCast(opts.flags),
            .addr = 0,
            .offset = 0,
            .size = 0,
            .link = opts.link,
            .info = opts.info,
            .addralign = opts.addralign,
            .entsize = opts.entsize,
        },
    });
    return index;
}

pub fn sectionByName(self: *Elf, name: [:0]const u8) ?u32 {
    for (self.sections.items(.shdr), 0..) |*shdr, i| {
        const this_name = self.getShString(shdr.name);
        if (mem.eql(u8, this_name, name)) return @intCast(i);
    } else return null;
}

const RelaDyn = struct {
    offset: u64,
    sym: u64 = 0,
    type: u32,
    addend: i64 = 0,
    target: ?*const Symbol = null,
};

pub fn addRelaDyn(self: *Elf, opts: RelaDyn) !void {
    try self.rela_dyn.ensureUnusedCapacity(self.base.alloctor, 1);
    self.addRelaDynAssumeCapacity(opts);
}

pub fn addRelaDynAssumeCapacity(self: *Elf, opts: RelaDyn) void {
    relocs_log.debug("  {f}: [{x} => {d}({s})] + {x}", .{
        relocation.fmtRelocType(opts.type, self.getTarget().cpu.arch),
        opts.offset,
        opts.sym,
        if (opts.target) |sym| sym.name(self) else "",
        opts.addend,
    });
    self.rela_dyn.appendAssumeCapacity(.{
        .offset = opts.offset,
        .info = .{ .type = opts.type, .sym = @intCast(opts.sym) },
        .addend = opts.addend,
    });
}

fn sortRelaDyn(self: *Elf) void {
    const Sort = struct {
        fn rank(rel: elf.Elf64.Rela, ctx: *Elf) u2 {
            const cpu_arch = ctx.getTarget().cpu.arch;
            const r_type = rel.info.type;
            const r_kind = relocation.decode(r_type, cpu_arch).?;
            return switch (r_kind) {
                .rel => 0,
                .irel => 2,
                else => 1,
            };
        }

        pub fn lessThan(ctx: *Elf, lhs: elf.Elf64.Rela, rhs: elf.Elf64.Rela) bool {
            if (rank(lhs, ctx) == rank(rhs, ctx)) {
                if (lhs.info.sym == rhs.info.sym) return lhs.offset < rhs.offset;
                return lhs.info.sym < rhs.info.sym;
            }
            return rank(lhs, ctx) < rank(rhs, ctx);
        }
    };
    mem.sort(elf.Elf64.Rela, self.rela_dyn.items, self, Sort.lessThan);
}

pub fn calcNumIRelativeRelocs(self: *Elf) usize {
    var count: usize = self.num_ifunc_dynrelocs;

    for (self.got.entries.items) |entry| {
        if (entry.tag != .got) continue;
        const sym = self.symbol(entry.ref).?;
        if (sym.isIFunc(self)) count += 1;
    }

    return count;
}

pub fn getStartStopBasename(self: Elf, shdr: elf.Elf64.Shdr) ?[]const u8 {
    const name = self.getShString(shdr.name);
    if (shdr.flags.shf.ALLOC and name.len > 0) {
        if (Elf.isCIdentifier(name)) return name;
    }
    return null;
}

pub fn isCIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    const first_c = name[0];
    if (!std.ascii.isAlphabetic(first_c) and first_c != '_') return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

pub fn addThunk(self: *Elf) !Thunk.Index {
    const index = @as(Thunk.Index, @intCast(self.thunks.items.len));
    const th = try self.thunks.addOne(self.base.comp.gpa);
    th.* = .{};
    return index;
}

pub fn thunk(self: *Elf, index: Thunk.Index) *Thunk {
    assert(index < self.thunks.items.len);
    return &self.thunks.items[index];
}

pub fn file(self: *Elf, index: File.Index) ?File {
    return fileLookup(self.files, index, self.zig_object);
}

fn fileLookup(files: std.MultiArrayList(File.Entry), index: File.Index, zig_object: ?*ZigObject) ?File {
    const tag = files.items(.tags)[index];
    return switch (tag) {
        .null => null,
        .linker_defined => .{ .linker_defined = &files.items(.data)[index].linker_defined },
        .zig_object => .{ .zig_object = zig_object.? },
        .object => .{ .object = &files.items(.data)[index].object },
        .shared_object => .{ .shared_object = &files.items(.data)[index].shared_object },
    };
}

pub fn addFileHandle(
    gpa: Allocator,
    file_handles: *std.ArrayList(File.Handle),
    handle: Io.File,
) Allocator.Error!File.HandleIndex {
    try file_handles.append(gpa, handle);
    return @intCast(file_handles.items.len - 1);
}

pub fn fileHandle(self: Elf, index: File.HandleIndex) File.Handle {
    return self.file_handles.items[index];
}

pub fn atom(self: *Elf, ref: Ref) ?*Atom {
    const file_ptr = self.file(ref.file) orelse return null;
    return file_ptr.atom(ref.index);
}

pub fn group(self: *Elf, ref: Ref) *Group {
    return self.file(ref.file).?.group(ref.index);
}

pub fn symbol(self: *Elf, ref: Ref) ?*Symbol {
    const file_ptr = self.file(ref.file) orelse return null;
    return file_ptr.symbol(ref.index);
}

pub fn getGlobalSymbol(self: *Elf, name: []const u8, lib_name: ?[]const u8) !u32 {
    return self.zigObjectPtr().?.getGlobalSymbol(self, name, lib_name);
}

pub fn zigObjectPtr(self: *Elf) ?*ZigObject {
    return self.zig_object;
}

pub fn linkerDefinedPtr(self: *Elf) ?*LinkerDefined {
    const index = self.linker_defined_index orelse return null;
    return self.file(index).?.linker_defined;
}

pub fn getOrCreateMergeSection(self: *Elf, name: [:0]const u8, flags: u64, @"type": u32) !Merge.Section.Index {
    const gpa = self.base.comp.gpa;
    const shf: elf.SHF = @bitCast(@as(elf.Word, @truncate(flags)));
    const out_name = name: {
        if (self.base.isRelocatable()) break :name name;
        if (mem.eql(u8, name, ".rodata") or mem.startsWith(u8, name, ".rodata"))
            break :name if (shf.STRINGS) ".rodata.str" else ".rodata.cst";
        break :name name;
    };
    for (self.merge_sections.items, 0..) |msec, index| {
        if (mem.eql(u8, msec.name(self), out_name)) return @intCast(index);
    }
    const out_off = try self.insertShString(out_name);
    const out_flags = blk: {
        var f = shf;
        f.COMPRESSED = false;
        f.GROUP = false;
        break :blk @as(u64, @as(elf.Word, @bitCast(f)));
    };
    const index: Merge.Section.Index = @intCast(self.merge_sections.items.len);
    const msec = try self.merge_sections.addOne(gpa);
    msec.* = .{
        .name_offset = out_off,
        .flags = out_flags,
        .type = @"type",
    };
    return index;
}

pub fn mergeSection(self: *Elf, index: Merge.Section.Index) *Merge.Section {
    assert(index < self.merge_sections.items.len);
    return &self.merge_sections.items[index];
}

pub fn gotAddress(self: *Elf) i64 {
    const shndx = blk: {
        if (self.getTarget().cpu.arch == .x86_64 and self.section_indexes.got_plt != null)
            break :blk self.section_indexes.got_plt.?;
        break :blk if (self.section_indexes.got) |shndx| shndx else null;
    };
    return if (shndx) |index| @intCast(self.sections.items(.shdr)[index].addr) else 0;
}

pub fn tpAddress(self: *Elf) i64 {
    const index = self.phdr_indexes.tls.int() orelse return 0;
    const phdr = self.phdrs.items[index];
    const addr = switch (self.getTarget().cpu.arch) {
        .x86_64 => mem.alignForward(u64, phdr.vaddr + phdr.memsz, phdr.@"align"),
        .aarch64, .aarch64_be => mem.alignBackward(u64, phdr.vaddr - 16, phdr.@"align"),
        .riscv64, .riscv64be => phdr.vaddr,
        else => |arch| std.debug.panic("TODO implement getTpAddress for {s}", .{@tagName(arch)}),
    };
    return @intCast(addr);
}

pub fn dtpAddress(self: *Elf) i64 {
    const index = self.phdr_indexes.tls.int() orelse return 0;
    const phdr = self.phdrs.items[index];
    return @intCast(phdr.vaddr);
}

pub fn tlsAddress(self: *Elf) i64 {
    const index = self.phdr_indexes.tls.int() orelse return 0;
    const phdr = self.phdrs.items[index];
    return @intCast(phdr.vaddr);
}

pub fn getShString(self: Elf, off: u32) [:0]const u8 {
    return shString(self.shstrtab.items, off);
}

fn shString(
    shstrtab: []const u8,
    off: u32,
) [:0]const u8 {
    const slice = shstrtab[off..];
    return slice[0..mem.findScalar(u8, slice, 0).? :0];
}

pub fn insertShString(self: *Elf, name: [:0]const u8) error{OutOfMemory}!u32 {
    const gpa = self.base.comp.gpa;
    const off = @as(u32, @intCast(self.shstrtab.items.len));
    try self.shstrtab.ensureUnusedCapacity(gpa, name.len + 1);
    self.shstrtab.print(gpa, "{s}\x00", .{name}) catch unreachable;
    return off;
}

pub fn getDynString(self: Elf, off: u32) [:0]const u8 {
    assert(off < self.dynstrtab.items.len);
    return mem.sliceTo(@as([*:0]const u8, @ptrCast(self.dynstrtab.items.ptr + off)), 0);
}

pub fn insertDynString(self: *Elf, name: []const u8) error{OutOfMemory}!u32 {
    const gpa = self.base.comp.gpa;
    const off = @as(u32, @intCast(self.dynstrtab.items.len));
    try self.dynstrtab.ensureUnusedCapacity(gpa, name.len + 1);
    self.dynstrtab.print(gpa, "{s}\x00", .{name}) catch unreachable;
    return off;
}

fn reportUndefinedSymbols(self: *Elf, undefs: anytype) !void {
    const gpa = self.base.comp.gpa;
    const diags = &self.base.comp.link_diags;
    const max_notes = 4;

    try diags.msgs.ensureUnusedCapacity(gpa, undefs.count());

    for (undefs.keys(), undefs.values()) |key, refs| {
        const undef_sym = self.resolver.keys.items[key - 1];
        const nrefs = @min(refs.items.len, max_notes);
        const nnotes = nrefs + @intFromBool(refs.items.len > max_notes);

        var err = try diags.addErrorWithNotesAssumeCapacity(nnotes);
        try err.addMsg("undefined symbol: {s}", .{undef_sym.name(self)});

        for (refs.items[0..nrefs]) |ref| {
            const atom_ptr = self.atom(ref).?;
            const file_ptr = atom_ptr.file(self).?;
            err.addNote("referenced by {f}:{s}", .{ file_ptr.fmtPath(), atom_ptr.name(self) });
        }

        if (refs.items.len > max_notes) {
            const remaining = refs.items.len - max_notes;
            err.addNote("referenced {d} more times", .{remaining});
        }
    }
}

fn reportDuplicates(self: *Elf, dupes: anytype) error{ HasDuplicates, OutOfMemory }!void {
    if (dupes.keys().len == 0) return; // Nothing to do
    const diags = &self.base.comp.link_diags;

    const max_notes = 3;

    for (dupes.keys(), dupes.values()) |key, notes| {
        const sym = self.resolver.keys.items[key - 1];
        const nnotes = @min(notes.items.len, max_notes) + @intFromBool(notes.items.len > max_notes);

        var err = try diags.addErrorWithNotes(nnotes + 1);
        try err.addMsg("duplicate symbol definition: {s}", .{sym.name(self)});
        err.addNote("defined by {f}", .{sym.file(self).?.fmtPath()});

        var inote: usize = 0;
        while (inote < @min(notes.items.len, max_notes)) : (inote += 1) {
            const file_ptr = self.file(notes.items[inote]).?;
            err.addNote("defined by {f}", .{file_ptr.fmtPath()});
        }

        if (notes.items.len > max_notes) {
            const remaining = notes.items.len - max_notes;
            err.addNote("defined {d} more times", .{remaining});
        }
    }

    return error.HasDuplicates;
}

fn reportUnsupportedCpuArch(self: *Elf) error{OutOfMemory}!void {
    const diags = &self.base.comp.link_diags;
    var err = try diags.addErrorWithNotes(0);
    try err.addMsg("fatal linker error: unsupported CPU architecture {s}", .{
        @tagName(self.getTarget().cpu.arch),
    });
}

pub fn addFileError(
    self: *Elf,
    file_index: File.Index,
    comptime format: []const u8,
    args: anytype,
) error{OutOfMemory}!void {
    const diags = &self.base.comp.link_diags;
    var err = try diags.addErrorWithNotes(1);
    try err.addMsg(format, args);
    err.addNote("while parsing {f}", .{self.file(file_index).?.fmtPath()});
}

pub fn failFile(
    self: *Elf,
    file_index: File.Index,
    comptime format: []const u8,
    args: anytype,
) error{ OutOfMemory, AlreadyReported } {
    try addFileError(self, file_index, format, args);
    return error.AlreadyReported;
}

const FormatShdr = struct {
    elf_file: *Elf,
    shdr: elf.Elf64.Shdr,
};

fn fmtShdr(self: *Elf, shdr: elf.Elf64.Shdr) std.fmt.Alt(FormatShdr, formatShdr) {
    return .{ .data = .{
        .shdr = shdr,
        .elf_file = self,
    } };
}

fn formatShdr(ctx: FormatShdr, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const shdr = ctx.shdr;
    try writer.print("{s} : @{x} ({x}) : align({x}) : size({x}) : entsize({x}) : flags({f})", .{
        ctx.elf_file.getShString(shdr.name), shdr.offset,
        shdr.addr,                           shdr.addralign,
        shdr.size,                           shdr.entsize,
        fmtShdrFlags(shdr.flags.shf),
    });
}

pub fn fmtShdrFlags(shf: elf.SHF) std.fmt.Alt(elf.SHF, formatShdrFlags) {
    return .{ .data = shf };
}

fn formatShdrFlags(shf: elf.SHF, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (shf.WRITE) {
        try writer.writeAll("W");
    }
    if (shf.ALLOC) {
        try writer.writeAll("A");
    }
    if (shf.EXECINSTR) {
        try writer.writeAll("X");
    }
    if (shf.MERGE) {
        try writer.writeAll("M");
    }
    if (shf.STRINGS) {
        try writer.writeAll("S");
    }
    if (shf.INFO_LINK) {
        try writer.writeAll("I");
    }
    if (shf.LINK_ORDER) {
        try writer.writeAll("L");
    }
    if (shf.PROC.X86_64.EXCLUDE) {
        try writer.writeAll("E");
    }
    if (shf.COMPRESSED) {
        try writer.writeAll("C");
    }
    if (shf.GROUP) {
        try writer.writeAll("G");
    }
    if (shf.OS_NONCONFORMING) {
        try writer.writeAll("O");
    }
    if (shf.TLS) {
        try writer.writeAll("T");
    }
    if (shf.PROC.X86_64.LARGE) {
        try writer.writeAll("l");
    }
    if (shf.PROC.MIPS.ADDR or shf.OS.ARM.PURECODE) {
        try writer.writeAll("p");
    }
}

const FormatPhdr = struct {
    elf_file: *Elf,
    phdr: elf.Elf64.Phdr,
};

fn fmtPhdr(self: *Elf, phdr: elf.Elf64.Phdr) std.fmt.Alt(FormatPhdr, formatPhdr) {
    return .{ .data = .{
        .phdr = phdr,
        .elf_file = self,
    } };
}

fn formatPhdr(ctx: FormatPhdr, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const phdr = ctx.phdr;
    const write = phdr.flags.W;
    const read = phdr.flags.R;
    const exec = phdr.flags.X;
    var flags: [3]u8 = @splat('_');
    if (exec) flags[0] = 'X';
    if (write) flags[1] = 'W';
    if (read) flags[2] = 'R';
    const p_type = switch (phdr.type) {
        .LOAD => "LOAD",
        .TLS => "TLS",
        .GNU_EH_FRAME => "GNU_EH_FRAME",
        .GNU_STACK => "GNU_STACK",
        .DYNAMIC => "DYNAMIC",
        .INTERP => "INTERP",
        .NULL => "NULL",
        .PHDR => "PHDR",
        .NOTE => "NOTE",
        else => "UNKNOWN",
    };
    try writer.print("{s} : {s} : @{x} ({x}) : align({x}) : filesz({x}) : memsz({x})", .{
        p_type,        flags,       phdr.offset, phdr.vaddr,
        phdr.@"align", phdr.filesz, phdr.memsz,
    });
}

pub fn dumpState(self: *Elf) std.fmt.Alt(*Elf, fmtDumpState) {
    return .{ .data = self };
}

fn fmtDumpState(self: *Elf, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const shared_objects = self.shared_objects.values();

    if (self.zigObjectPtr()) |zig_object| {
        try writer.print("zig_object({d}) : {s}\n", .{ zig_object.index, zig_object.basename });
        try writer.print("{f}{f}", .{
            zig_object.fmtAtoms(self),
            zig_object.fmtSymtab(self),
        });
        try writer.writeByte('\n');
    }

    for (self.objects.items) |index| {
        const object = self.file(index).?.object;
        try writer.print("object({d}) : {f}", .{ index, object.fmtPath() });
        if (!object.alive) try writer.writeAll(" : [*]");
        try writer.writeByte('\n');
        try writer.print("{f}{f}{f}{f}{f}\n", .{
            object.fmtAtoms(self),
            object.fmtCies(self),
            object.fmtFdes(self),
            object.fmtSymtab(self),
            object.fmtGroups(self),
        });
    }

    for (shared_objects) |index| {
        const shared_object = self.file(index).?.shared_object;
        try writer.print("shared_object({d}) : {f} : needed({})", .{
            index, shared_object.path, shared_object.needed,
        });
        if (!shared_object.alive) try writer.writeAll(" : [*]");
        try writer.writeByte('\n');
        try writer.print("{f}\n", .{shared_object.fmtSymtab(self)});
    }

    if (self.linker_defined_index) |index| {
        const linker_defined = self.file(index).?.linker_defined;
        try writer.print("linker_defined({d}) : (linker defined)\n", .{index});
        try writer.print("{f}\n", .{linker_defined.fmtSymtab(self)});
    }

    const slice = self.sections.slice();
    {
        try writer.writeAll("atom lists\n");
        for (slice.items(.shdr), slice.items(.atom_list_2), 0..) |shdr, atom_list, shndx| {
            try writer.print("shdr({d}) : {s} : {f}\n", .{ shndx, self.getShString(shdr.name), atom_list.fmt(self) });
        }
    }

    if (self.requiresThunks()) {
        try writer.writeAll("thunks\n");
        for (self.thunks.items, 0..) |th, index| {
            try writer.print("thunk({d}) : {f}\n", .{ index, th.fmt(self) });
        }
    }

    try writer.print("{f}\n", .{self.got.fmt(self)});
    try writer.print("{f}\n", .{self.plt.fmt(self)});

    try writer.writeAll("Output groups\n");
    for (self.group_sections.items) |cg| {
        try writer.print("  shdr({d}) : GROUP({f})\n", .{ cg.shndx, cg.cg_ref });
    }

    try writer.writeAll("\nOutput merge sections\n");
    for (self.merge_sections.items) |msec| {
        try writer.print("  shdr({d}) : {f}\n", .{ msec.output_section_index, msec.fmt(self) });
    }

    try writer.writeAll("\nOutput shdrs\n");
    for (slice.items(.shdr), slice.items(.phndx), 0..) |shdr, phndx, shndx| {
        try writer.print("  shdr({d}) : phdr({d}) : {f}\n", .{
            shndx,
            phndx,
            self.fmtShdr(shdr),
        });
    }
    try writer.writeAll("\nOutput phdrs\n");
    for (self.phdrs.items, 0..) |phdr, phndx| {
        try writer.print("  phdr({d}) : {f}\n", .{ phndx, self.fmtPhdr(phdr) });
    }
}

/// Caller owns the memory.
pub fn preadAllAlloc(allocator: Allocator, io: Io, io_file: Io.File, offset: u64, size: u64) ![]u8 {
    const buffer = try allocator.alloc(u8, math.cast(usize, size) orelse return error.Overflow);
    errdefer allocator.free(buffer);
    const amt = try io_file.readPositionalAll(io, buffer, offset);
    if (amt != size) return error.InputOutput;
    return buffer;
}

/// Binary search
pub fn bsearch(comptime T: type, haystack: []const T, predicate: anytype) usize {
    var min: usize = 0;
    var max: usize = haystack.len;
    while (min < max) {
        const index = (min + max) / 2;
        const curr = haystack[index];
        if (predicate.predicate(curr)) {
            min = index + 1;
        } else {
            max = index;
        }
    }
    return min;
}

/// Linear search
pub fn lsearch(comptime T: type, haystack: []const T, predicate: anytype) usize {
    var i: usize = 0;
    while (i < haystack.len) : (i += 1) {
        if (predicate.predicate(haystack[i])) break;
    }
    return i;
}

pub fn getTarget(self: *const Elf) *const std.Target {
    return &self.base.comp.root_mod.resolved_target.result;
}

fn requiresThunks(self: Elf) bool {
    return switch (self.getTarget().cpu.arch) {
        .aarch64, .aarch64_be => true,
        .x86_64, .riscv64, .riscv64be => false,
        else => @panic("TODO unimplemented architecture"),
    };
}

/// The following three values are only observed at compile-time and used to emit a compile error
/// to remind the programmer to update expected maximum numbers of different program header types
/// so that we reserve enough space for the program header table up-front.
/// Bump these numbers when adding or deleting a Zig specific pre-allocated segment, or adding
/// more special-purpose program headers.
const max_number_of_object_segments = 9;
const max_number_of_special_phdrs = 5;

const default_entry_addr = 0x8000000;

pub const base_tag: link.File.Tag = .elf;

pub const Group = struct {
    signature_off: u32,
    file_index: File.Index,
    shndx: u32,
    members_start: u32,
    members_len: u32,
    is_comdat: bool,
    alive: bool = true,

    pub fn file(cg: Group, elf_file: *Elf) File {
        return elf_file.file(cg.file_index).?;
    }

    pub fn signature(cg: Group, elf_file: *Elf) [:0]const u8 {
        return cg.file(elf_file).object.getString(cg.signature_off);
    }

    pub fn members(cg: Group, elf_file: *Elf) []const u32 {
        const object = cg.file(elf_file).object;
        return object.group_data.items[cg.members_start..][0..cg.members_len];
    }

    pub const Index = u32;
};

pub const SymtabCtx = struct {
    ilocal: u32 = 0,
    iglobal: u32 = 0,
    nlocals: u32 = 0,
    nglobals: u32 = 0,
    strsize: u32 = 0,

    pub fn reset(ctx: *SymtabCtx) void {
        ctx.ilocal = 0;
        ctx.iglobal = 0;
        ctx.nlocals = 0;
        ctx.nglobals = 0;
        ctx.strsize = 0;
    }
};

pub const null_sym = elf.Elf64.Sym{
    .name = 0,
    .info = .{ .type = .NOTYPE, .bind = .LOCAL },
    .other = .{ .visibility = .DEFAULT },
    .shndx = 0,
    .value = 0,
    .size = 0,
};

pub const null_shdr = elf.Elf64.Shdr{
    .name = 0,
    .type = .NULL,
    .flags = .{ .shf = .{} },
    .addr = 0,
    .offset = 0,
    .size = 0,
    .link = 0,
    .info = 0,
    .addralign = 0,
    .entsize = 0,
};

pub const SystemLib = struct {
    needed: bool = false,
    path: Path,
};

pub const Ref = struct {
    index: u32 = 0,
    file: u32 = 0,

    pub fn eql(ref: Ref, other: Ref) bool {
        return ref.index == other.index and ref.file == other.file;
    }

    pub fn format(ref: Ref, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("ref({d},{d})", .{ ref.index, ref.file });
    }
};

pub const SymbolResolver = struct {
    keys: std.ArrayList(Key) = .empty,
    values: std.ArrayList(Ref) = .empty,
    table: std.array_hash_map.Auto(void, void) = .empty,

    const Result = struct {
        found_existing: bool,
        index: Index,
        ref: *Ref,
    };

    pub fn deinit(resolver: *SymbolResolver, allocator: Allocator) void {
        resolver.keys.deinit(allocator);
        resolver.values.deinit(allocator);
        resolver.table.deinit(allocator);
    }

    pub fn getOrPut(
        resolver: *SymbolResolver,
        allocator: Allocator,
        ref: Ref,
        elf_file: *Elf,
    ) !Result {
        const adapter = Adapter{ .keys = resolver.keys.items, .elf_file = elf_file };
        const key = Key{ .index = ref.index, .file_index = ref.file };
        const gop = try resolver.table.getOrPutAdapted(allocator, key, adapter);
        if (!gop.found_existing) {
            try resolver.keys.append(allocator, key);
            _ = try resolver.values.addOne(allocator);
        }
        return .{
            .found_existing = gop.found_existing,
            .index = @intCast(gop.index + 1),
            .ref = &resolver.values.items[gop.index],
        };
    }

    pub fn get(resolver: SymbolResolver, index: Index) ?Ref {
        if (index == 0) return null;
        return resolver.values.items[index - 1];
    }

    pub fn reset(resolver: *SymbolResolver) void {
        resolver.keys.clearRetainingCapacity();
        resolver.values.clearRetainingCapacity();
        resolver.table.clearRetainingCapacity();
    }

    const Key = struct {
        index: Symbol.Index,
        file_index: File.Index,

        fn name(key: Key, elf_file: *Elf) [:0]const u8 {
            const ref = Ref{ .index = key.index, .file = key.file_index };
            return elf_file.symbol(ref).?.name(elf_file);
        }

        fn file(key: Key, elf_file: *Elf) ?File {
            return elf_file.file(key.file_index);
        }

        fn eql(key: Key, other: Key, elf_file: *Elf) bool {
            const key_name = key.name(elf_file);
            const other_name = other.name(elf_file);
            return mem.eql(u8, key_name, other_name);
        }

        fn hash(key: Key, elf_file: *Elf) u32 {
            return @truncate(Hash.hash(0, key.name(elf_file)));
        }
    };

    const Adapter = struct {
        keys: []const Key,
        elf_file: *Elf,

        pub fn eql(ctx: @This(), key: Key, b_void: void, b_map_index: usize) bool {
            _ = b_void;
            const other = ctx.keys[b_map_index];
            return key.eql(other, ctx.elf_file);
        }

        pub fn hash(ctx: @This(), key: Key) u32 {
            return key.hash(ctx.elf_file);
        }
    };

    pub const Index = u32;
};

const Section = struct {
    /// Section header.
    shdr: elf.Elf64.Shdr,

    /// Assigned program header index if any.
    phndx: OptionalProgramHeaderIndex = .none,

    /// List of atoms contributing to this section.
    /// TODO currently this is only used for relocations tracking in relocatable mode
    /// but will be merged with atom_list_2.
    atom_list: std.ArrayList(Ref) = .empty,

    /// List of atoms contributing to this section.
    /// This can be used by sections that require special handling such as init/fini array, etc.
    atom_list_2: AtomList = .{},

    /// Index of the last allocated atom in this section.
    last_atom: Ref = .{ .index = 0, .file = 0 },

    /// A list of atoms that have surplus capacity. This list can have false
    /// positives, as functions grow and shrink over time, only sometimes being added
    /// or removed from the freelist.
    ///
    /// An atom has surplus capacity when its overcapacity value is greater than
    /// padToIdeal(minimum_atom_size). That is, when it has so
    /// much extra capacity, that we could fit a small new symbol in it, itself with
    /// ideal_capacity or more.
    ///
    /// Ideal capacity is defined by size + (size / ideal_factor)
    ///
    /// Overcapacity is measured by actual_capacity - ideal_capacity. Note that
    /// overcapacity can be negative. A simple way to have negative overcapacity is to
    /// allocate a fresh text block, which will have ideal capacity, and then grow it
    /// by 1 byte. It will then have -1 overcapacity.
    free_list: std.ArrayList(Ref) = .empty,
};

pub fn sectionSize(self: *Elf, shndx: u32) u64 {
    const last_atom_ref = self.sections.items(.last_atom)[shndx];
    const atom_ptr = self.atom(last_atom_ref) orelse return 0;
    return @as(u64, @intCast(atom_ptr.value)) + atom_ptr.size;
}

fn defaultEntrySymbolName(cpu_arch: std.Target.Cpu.Arch) []const u8 {
    return switch (cpu_arch) {
        .mips, .mipsel, .mips64, .mips64el => "__start",
        else => "_start",
    };
}

fn createThunks(elf_file: *Elf, atom_list: *AtomList) !void {
    const gpa = elf_file.base.comp.gpa;
    const cpu_arch = elf_file.getTarget().cpu.arch;

    // A branch will need an extender if its target is larger than
    // `2^(jump_bits - 1) - margin` where margin is some arbitrary number.
    const max_distance = switch (cpu_arch) {
        .aarch64, .aarch64_be => 0x500_000,
        .x86_64, .riscv64, .riscv64be => unreachable,
        else => @panic("unhandled arch"),
    };

    const advance = struct {
        fn advance(list: *AtomList, size: u64, alignment: Atom.Alignment) !i64 {
            const offset = alignment.forward(list.size);
            const padding = offset - list.size;
            list.size += padding + size;
            list.alignment = list.alignment.max(alignment);
            return @intCast(offset);
        }
    }.advance;

    for (atom_list.atoms.keys()) |ref| {
        elf_file.atom(ref).?.value = -1;
    }

    var i: usize = 0;
    while (i < atom_list.atoms.keys().len) {
        const start = i;
        const start_atom = elf_file.atom(atom_list.atoms.keys()[start]).?;
        assert(start_atom.alive);
        start_atom.value = try advance(atom_list, start_atom.size, start_atom.alignment);
        i += 1;

        while (i < atom_list.atoms.keys().len) : (i += 1) {
            const atom_ptr = elf_file.atom(atom_list.atoms.keys()[i]).?;
            assert(atom_ptr.alive);
            if (@as(i64, @intCast(atom_ptr.alignment.forward(atom_list.size))) - start_atom.value >= max_distance)
                break;
            atom_ptr.value = try advance(atom_list, atom_ptr.size, atom_ptr.alignment);
        }

        // Insert a thunk at the group end
        const thunk_index = try elf_file.addThunk();
        const thunk_ptr = elf_file.thunk(thunk_index);
        thunk_ptr.output_section_index = atom_list.output_section_index;

        // Scan relocs in the group and create trampolines for any unreachable callsite
        for (atom_list.atoms.keys()[start..i]) |ref| {
            const atom_ptr = elf_file.atom(ref).?;
            const file_ptr = atom_ptr.file(elf_file).?;
            log.debug("atom({f}) {s}", .{ ref, atom_ptr.name(elf_file) });
            for (atom_ptr.relocs(elf_file)) |rel| {
                const is_reachable = switch (cpu_arch) {
                    .aarch64, .aarch64_be => r: {
                        const r_type: elf.R_AARCH64 = @fromBackingInt(@intCast(rel.info.type));
                        if (r_type != .CALL26 and r_type != .JUMP26) break :r true;
                        const target_ref = file_ptr.resolveSymbol(rel.info.sym, elf_file);
                        const target = elf_file.symbol(target_ref).?;
                        if (target.flags.has_plt) break :r false;
                        if (atom_ptr.output_section_index != target.output_section_index) break :r false;
                        const target_atom = target.atom(elf_file).?;
                        if (target_atom.value == -1) break :r false;
                        const saddr = atom_ptr.address(elf_file) + @as(i64, @intCast(rel.offset));
                        const taddr = target.address(.{}, elf_file);
                        _ = math.cast(i28, taddr + rel.addend - saddr) orelse break :r false;
                        break :r true;
                    },
                    .x86_64, .riscv64, .riscv64be => unreachable,
                    else => @panic("unsupported arch"),
                };
                if (is_reachable) continue;
                const target = file_ptr.resolveSymbol(rel.info.sym, elf_file);
                try thunk_ptr.symbols.put(gpa, target, {});
            }
            atom_ptr.addExtra(.{ .thunk = thunk_index }, elf_file);
        }

        thunk_ptr.value = try advance(atom_list, thunk_ptr.size(elf_file), Atom.Alignment.fromNonzeroByteUnits(2));

        log.debug("thunk({d}) : {f}", .{ thunk_index, thunk_ptr.fmt(elf_file) });
    }
}

pub fn stringTableLookup(strtab: []const u8, off: u32) [:0]const u8 {
    const slice = strtab[off..];
    return slice[0..mem.findScalar(u8, slice, 0).? :0];
}

pub fn pwriteAll(elf_file: *Elf, bytes: []const u8, offset: u64) error{AlreadyReported}!void {
    const comp = elf_file.base.comp;
    const io = comp.io;
    const diags = &comp.link_diags;
    elf_file.base.file.?.writePositionalAll(io, bytes, offset) catch |err|
        return diags.fail("failed to write: {t}", .{err});
}

pub fn setLength(elf_file: *Elf, length: u64) error{AlreadyReported}!void {
    const comp = elf_file.base.comp;
    const io = comp.i;
    const diags = &comp.link_diags;
    elf_file.base.file.?.setLength(io, length) catch |err| {
        return diags.fail("failed to set file end pos: {s}", .{@errorName(err)});
    };
}

pub fn cast(elf_file: *Elf, comptime T: type, x: anytype) error{AlreadyReported}!T {
    return std.math.cast(T, x) orelse {
        const comp = elf_file.base.comp;
        const diags = &comp.link_diags;
        return diags.fail("encountered {d}, overflowing {d}-bit value", .{ x, @bitSizeOf(T) });
    };
}

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const builtin = @import("builtin");
const assert = std.debug.assert;
const elf = std.elf;
const fs = std.fs;
const log = std.log.scoped(.link);
const relocs_log = std.log.scoped(.link_relocs);
const state_log = std.log.scoped(.link_state);
const math = std.math;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Hash = std.hash.Wyhash;
const Path = std.Build.Cache.Path;
const Stat = std.Build.Cache.File.Stat;

const codegen = @import("../codegen.sig");
const eh_frame = @import("Elf/eh_frame.sig");
const gc = @import("Elf/gc.sig");
const musl = @import("../libs/musl.sig");
const link = @import("../link.sig");
const relocatable = @import("Elf/relocatable.sig");
const relocation = @import("Elf/relocation.sig");
const target_util = @import("../target.sig");
const trace = @import("../tracy.sig").trace;
const synthetic_sections = @import("Elf/synthetic_sections.sig");

const Merge = @import("Elf/Merge.sig");
const Archive = @import("Elf/Archive.sig");
const AtomList = @import("Elf/AtomList.sig");
const Compilation = @import("../Compilation.sig");
const GroupSection = synthetic_sections.GroupSection;
const CopyRelSection = synthetic_sections.CopyRelSection;
const Diags = @import("../link.sig").Diags;
const DynamicSection = synthetic_sections.DynamicSection;
const DynsymSection = synthetic_sections.DynsymSection;
const Dwarf = @import("Dwarf.sig");
const Elf = @This();
const File = @import("Elf/file.sig").File;
const GnuHashSection = synthetic_sections.GnuHashSection;
const GotSection = synthetic_sections.GotSection;
const GotPltSection = synthetic_sections.GotPltSection;
const HashSection = synthetic_sections.HashSection;
const LinkerDefined = @import("Elf/LinkerDefined.sig");
const Zcu = @import("../Zcu.sig");
const Object = @import("Elf/Object.sig");
const InternPool = @import("../InternPool.sig");
const PltSection = synthetic_sections.PltSection;
const PltGotSection = synthetic_sections.PltGotSection;
const SharedObject = @import("Elf/SharedObject.sig");
const Symbol = @import("Elf/Symbol.sig");
const StringTable = @import("StringTable.sig");
const Thunk = @import("Elf/Thunk.sig");
const Value = @import("../Value.sig");
const VerneedSection = synthetic_sections.VerneedSection;
const ZigObject = @import("Elf/ZigObject.sig");
