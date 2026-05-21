const Elf = @This();

const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const log = std.log.scoped(.link);

const codegen = @import("../codegen.zig");
const Compilation = @import("../Compilation.zig");
const InternPool = @import("../InternPool.zig");
const link = @import("../link.zig");
const MappedFile = @import("MappedFile.zig");
const target_util = @import("../target.zig");
const Type = @import("../Type.zig");
const Value = @import("../Value.zig");
const Zcu = @import("../Zcu.zig");

base: link.File,
options: link.File.OpenOptions,
mf: MappedFile,
ni: Node.Known,
nodes: std.MultiArrayList(Node),
shdrs: std.ArrayList(Section),
phdrs: std.ArrayList(MappedFile.Node.Index),
shndx: struct {
    got: Section.Index,
    got_plt: Section.Index,
    plt: Section.Index,
    plt_sec: Section.Index,
    dynsym: Section.Index,
    dynstr: Section.Index,
    dynamic: Section.Index,
    tdata: Section.Index,
    // These sections are created only as needed, and are initially `.UNDEF`.
    init_array: Section.Index,
    fini_array: Section.Index,
    preinit_array: Section.Index,
},
symtab: std.ArrayList(Symbol),
globals: struct {
    strong_def: std.array_hash_map.Auto(String(.strtab), Symbol.Global),
    weak_def: std.array_hash_map.Auto(String(.strtab), Symbol.Global),
    strong_undef: std.array_hash_map.Auto(String(.strtab), Symbol.Global),
    weak_undef: std.array_hash_map.Auto(String(.strtab), Symbol.Global),
},
/// Key is a node which is a valid `Symbol.node` value, value is the name of the first global symbol
/// in that node. That symbol is the head of a linked list: see `Symbol.Global.next_in_node`.
///
/// Value is never `.empty`.
///
/// We use a separate hash map for this data rather than storing it in `navs` etc to save memory,
/// because the vast majority of nodes which can export global symbols actually will not.
node_global_symbols: std.array_hash_map.Auto(MappedFile.Node.Index, String(.strtab)),
shstrtab: StringTable,
strtab: StringTable,
dynstr: StringTable,
got: struct {
    len: u32,
    tlsld: GotIndex,
    plt: std.AutoArrayHashMapUnmanaged(Symbol.Id, void),
},
first_plt_reloc: Reloc.Index,
first_dynamic_reloc: Reloc.Index,
needed: std.AutoArrayHashMapUnmanaged(String(.dynstr), void),
inputs: std.ArrayList(struct {
    path: std.Build.Cache.Path,
    member: ?[]const u8,
    file_symbol: Symbol.LocalIndex,
}),
input_sections: std.ArrayList(InputSection),
input_section_pending_index: u32,
navs: std.AutoArrayHashMapUnmanaged(InternPool.Nav.Index, struct {
    /// The start index of the contiguous sequence of relocations in this NAV.
    first_reloc: Reloc.Index,
    lsi: Symbol.LocalIndex,
}),
uavs: std.AutoArrayHashMapUnmanaged(InternPool.Index, struct {
    /// The start index of the contiguous sequence of relocations in this UAV.
    first_reloc: Reloc.Index,
    lsi: Symbol.LocalIndex,
}),
lazy: std.EnumArray(link.File.LazySymbol.Kind, struct {
    map: std.AutoArrayHashMapUnmanaged(InternPool.Index, struct {
        /// The start index of the contiguous sequence of relocations in this lazy code/data.
        first_reloc: Reloc.Index,
        lsi: Symbol.LocalIndex,
    }),
    pending_index: u32,
}),
pending_uavs: std.ArrayList(Node.UavMapIndex),
relocs: std.ArrayList(Reloc),
/// Index matches the index into `shdrs`.
section_by_name: std.array_hash_map.Auto(String(.shstrtab), void),

/// Key is the name of a global symbol which has been moved to a new symtab index. Any relocation
/// entries which target that symbol must be updated to reference the correct symbol index.
changed_symtab_index: std.array_hash_map.Auto(String(.strtab), void),

const_prog_node: std.Progress.Node,
synth_prog_node: std.Progress.Node,
input_prog_node: std.Progress.Node,

const Node = union(enum) {
    /// Cannot contain relocations.
    file,
    /// Cannot contain relocations.
    ehdr,
    /// Cannot contain relocations.
    shdr,
    /// Cannot contain relocations.
    segment: u32,
    /// The section '.plt' may contain relocations via `elf.first_plt_reloc`.
    ///
    /// The section '.dynamic' may contain relocations via `elf.first_dynamic_reloc`.
    ///
    /// Otherwise, cannot contain relocations.
    section: Section.Index,
    /// May contain relocations through the `first_reloc` field in `elf.input_sections`.
    input_section: InputSection.Index,
    /// May contain relocations through the `first_reloc` field in `elf.navs`.
    nav: NavMapIndex,
    /// May contain relocations through the `first_reloc` field in `elf.uavs`.
    uav: UavMapIndex,
    /// May contain relocations through the `first_reloc` field in `elf.lazy.map`.
    lazy_code: LazyMapRef.Index(.code),
    /// May contain relocations through the `first_reloc` field in `elf.lazy.map`.
    lazy_const_data: LazyMapRef.Index(.const_data),

    pub const InputIndex = enum(u32) {
        _,

        pub fn path(ii: InputIndex, elf: *const Elf) std.Build.Cache.Path {
            return elf.inputs.items[@intFromEnum(ii)].path;
        }

        pub fn member(ii: InputIndex, elf: *const Elf) ?[]const u8 {
            return elf.inputs.items[@intFromEnum(ii)].member;
        }

        pub fn fileSymbol(ii: InputIndex, elf: *const Elf) Symbol.LocalIndex {
            return elf.inputs.items[@intFromEnum(ii)].file_symbol;
        }

        pub fn localSymbolRange(ii: InputIndex, elf: *Elf) [2]Symbol.LocalIndex {
            if (@intFromEnum(ii) + 1 < elf.inputs.items.len) {
                const next_ii: InputIndex = @enumFromInt(@intFromEnum(ii) + 1);
                return .{ ii.fileSymbol(elf), next_ii.fileSymbol(elf) };
            } else {
                const local_symbols_len = switch (elf.shdrPtr(.symtab)) {
                    inline else => |shdr| elf.targetLoad(&shdr.info),
                };
                return .{ ii.fileSymbol(elf), @enumFromInt(local_symbols_len) };
            }
        }
    };

    pub const NavMapIndex = enum(u32) {
        _,

        pub fn navIndex(nmi: NavMapIndex, elf: *const Elf) InternPool.Nav.Index {
            return elf.navs.keys()[@intFromEnum(nmi)];
        }

        pub fn symbol(nmi: NavMapIndex, elf: *const Elf) Symbol.LocalIndex {
            return elf.navs.values()[@intFromEnum(nmi)].lsi;
        }

        fn firstReloc(nmi: NavMapIndex, elf: *const Elf) Reloc.Index {
            return elf.navs.values()[@intFromEnum(nmi)].first_reloc;
        }
    };

    pub const UavMapIndex = enum(u32) {
        _,

        pub fn uavValue(umi: UavMapIndex, elf: *const Elf) InternPool.Index {
            return elf.uavs.keys()[@intFromEnum(umi)];
        }

        pub fn symbol(umi: UavMapIndex, elf: *const Elf) Symbol.LocalIndex {
            return elf.uavs.values()[@intFromEnum(umi)].lsi;
        }

        fn firstReloc(umi: UavMapIndex, elf: *const Elf) Reloc.Index {
            return elf.uavs.values()[@intFromEnum(umi)].first_reloc;
        }
    };

    pub const LazyMapRef = struct {
        kind: link.File.LazySymbol.Kind,
        index: u32,

        pub fn Index(comptime kind: link.File.LazySymbol.Kind) type {
            return enum(u32) {
                _,

                pub fn ref(lmi: @This()) LazyMapRef {
                    return .{ .kind = kind, .index = @intFromEnum(lmi) };
                }

                pub fn lazySymbol(lmi: @This(), elf: *const Elf) link.File.LazySymbol {
                    return lmi.ref().lazySymbol(elf);
                }

                pub fn symbol(lmi: @This(), elf: *const Elf) Symbol.LocalIndex {
                    return lmi.ref().symbol(elf);
                }

                fn firstReloc(lmi: @This(), elf: *const Elf) Reloc.Index {
                    return lmi.ref().firstReloc(elf);
                }
            };
        }

        pub fn lazySymbol(lmr: LazyMapRef, elf: *const Elf) link.File.LazySymbol {
            return .{ .kind = lmr.kind, .ty = elf.lazy.getPtrConst(lmr.kind).map.keys()[lmr.index] };
        }

        pub fn symbol(lmr: LazyMapRef, elf: *const Elf) Symbol.LocalIndex {
            return elf.lazy.getPtrConst(lmr.kind).map.values()[lmr.index].lsi;
        }

        fn firstReloc(lmr: LazyMapRef, elf: *const Elf) Reloc.Index {
            return elf.lazy.getPtrConst(lmr.kind).map.values()[lmr.index].first_reloc;
        }
    };

    pub const Known = struct {
        comptime file: MappedFile.Node.Index = .root,
        comptime ehdr: MappedFile.Node.Index = @enumFromInt(1),
        comptime shdr: MappedFile.Node.Index = @enumFromInt(2),
        comptime rodata: MappedFile.Node.Index = @enumFromInt(3),
        comptime phdr: MappedFile.Node.Index = @enumFromInt(4),
        comptime text: MappedFile.Node.Index = @enumFromInt(5),
        comptime data: MappedFile.Node.Index = @enumFromInt(6),
        comptime data_rel_ro: MappedFile.Node.Index = @enumFromInt(7),

        tls: MappedFile.Node.Index,
    };

    comptime {
        if (!std.debug.runtime_safety) std.debug.assert(@sizeOf(Node) == 8);
    }

    /// In this linker implementation, `link.File.AtomId` is a type-erased `MappedFile.Node.Index`.
    fn toAtom(ni: MappedFile.Node.Index) link.File.AtomId {
        return @enumFromInt(@intFromEnum(ni));
    }
    /// In this linker implementation, `link.File.AtomId` is a type-erased `MappedFile.Node.Index`.
    fn fromAtom(atom: link.File.AtomId) MappedFile.Node.Index {
        return @enumFromInt(@intFromEnum(atom));
    }
};

const InputSection = struct {
    input: Node.InputIndex,
    file_location: MappedFile.Node.FileLocation,
    vaddr: u64,
    /// The node corresponding to this input section.
    node: MappedFile.Node.Index,
    /// The start index of the contiguous sequence of relocations in this input section.
    first_reloc: Reloc.Index,

    const Index = enum(u32) {
        _,

        fn ptr(isi: InputSection.Index, elf: *Elf) *InputSection {
            return &elf.input_sections.items[@intFromEnum(isi)];
        }

        fn ptrConst(isi: InputSection.Index, elf: *const Elf) *const InputSection {
            return &elf.input_sections.items[@intFromEnum(isi)];
        }

        fn input(isi: InputSection.Index, elf: *const Elf) Node.InputIndex {
            return isi.ptrConst(elf).input;
        }

        fn fileLocation(isi: InputSection.Index, elf: *const Elf) MappedFile.Node.FileLocation {
            return isi.ptrConst(elf).file_location;
        }

        fn node(isi: InputSection.Index, elf: *const Elf) MappedFile.Node.Index {
            return isi.ptrConst(elf).node;
        }
    };
};

const Section = struct {
    /// The node corresponding to this section.
    ni: MappedFile.Node.Index,
    /// A symbol which is exactly at the start of this section.
    ///
    /// If the section does not have flag `std.elf.SHF.ALLOC`, this is `.null`.
    lsi: Symbol.LocalIndex,
    rela_shndx: Section.Index,
    rela_free: RelIndex,

    pub const RelIndex = enum(u32) {
        none,
        _,

        pub fn wrap(i: ?u32) RelIndex {
            return @enumFromInt((i orelse return .none) + 1);
        }
        pub fn unwrap(ri: RelIndex) ?u32 {
            return switch (ri) {
                .none => null,
                _ => @intFromEnum(ri) - 1,
            };
        }
    };

    pub const Index = enum(Tag) {
        UNDEF = std.elf.SHN_UNDEF,
        LIVEPATCH = reserve(std.elf.SHN_LIVEPATCH),
        ABS = reserve(std.elf.SHN_ABS),
        COMMON = reserve(std.elf.SHN_COMMON),

        symtab = 1,
        shstrtab,
        strtab,
        rodata,
        text,
        data,
        data_rel_ro,

        _,

        pub const Tag = u32;

        pub const LORESERVE: Index = .fromSection(std.elf.SHN_LORESERVE);
        pub const HIRESERVE: Index = .fromSection(std.elf.SHN_HIRESERVE);
        comptime {
            assert(@intFromEnum(HIRESERVE) == std.math.maxInt(Tag));
        }

        fn reserve(sec: std.elf.Section) Tag {
            assert(sec >= std.elf.SHN_LORESERVE and sec <= std.elf.SHN_HIRESERVE);
            return @as(Tag, std.math.maxInt(Tag) - std.elf.SHN_HIRESERVE) + sec;
        }

        pub fn fromSection(sec: std.elf.Section) Index {
            return switch (sec) {
                std.elf.SHN_UNDEF...std.elf.SHN_LORESERVE - 1 => @enumFromInt(sec),
                std.elf.SHN_LORESERVE...std.elf.SHN_HIRESERVE => @enumFromInt(reserve(sec)),
            };
        }
        pub fn toSection(s: Index) ?std.elf.Section {
            return switch (@intFromEnum(s)) {
                std.elf.SHN_UNDEF...std.elf.SHN_LORESERVE - 1 => |sec| @intCast(sec),
                std.elf.SHN_LORESERVE...reserve(std.elf.SHN_LORESERVE) - 1 => null,
                reserve(std.elf.SHN_LORESERVE)...reserve(std.elf.SHN_HIRESERVE) => |sec| @intCast(
                    sec - reserve(std.elf.SHN_LORESERVE) + std.elf.SHN_LORESERVE,
                ),
            };
        }

        fn get(s: Index, elf: *Elf) *Section {
            return &elf.shdrs.items[@intFromEnum(s)];
        }

        fn name(s: Index, elf: *Elf) String(.shstrtab) {
            return switch (elf.shdrPtr(s)) {
                inline else => |shdr| @enumFromInt(elf.targetLoad(&shdr.name)),
            };
        }

        fn vaddr(s: Index, elf: *Elf) u64 {
            return switch (s.get(elf).lsi) {
                .null => 0,
                else => |lsi| Symbol.Id.local(lsi).value(elf),
            };
        }

        fn rename(shndx: Index, elf: *Elf, new_name: []const u8) !void {
            const shstrtab_entry = try elf.string(.shstrtab, new_name);
            switch (elf.shdrPtr(shndx)) {
                inline else => |shdr| elf.targetStore(&shdr.name, @intFromEnum(shstrtab_entry)),
            }
        }
    };
};

fn ensureUnusedSymbolCapacity(elf: *Elf, len: u32, kind: enum { all_local, maybe_global }) !void {
    const gpa = elf.base.comp.gpa;

    try elf.symtab.ensureUnusedCapacity(gpa, len);

    // If adding locals, we may need to move one global out of the way for each local. If adding
    // globals, they could all get demoted to STB_LOCAL, which would mean we move those N globals
    // *and* we move up to N other globals out of their way.
    try elf.changed_symtab_index.ensureUnusedCapacity(gpa, switch (kind) {
        .all_local => len,
        .maybe_global => len * 2,
    });

    {
        // Ensure the symtab section's node is big enough
        const need_node_size: u64 = switch (elf.shdrPtr(.symtab)) {
            inline else => |shdr, class| elf.targetLoad(&shdr.size) + len * @sizeOf(class.ElfN().Sym),
        };
        _, const cur_node_size = Section.Index.symtab.get(elf).ni.location(&elf.mf).resolve(&elf.mf);
        if (cur_node_size < need_node_size) {
            const new_node_size = need_node_size +| need_node_size / MappedFile.growth_factor;
            try Section.Index.symtab.get(elf).ni.resize(&elf.mf, gpa, new_node_size);
        }
    }

    switch (kind) {
        .all_local => {},
        .maybe_global => {
            try elf.globals.strong_def.ensureUnusedCapacity(gpa, len);
            try elf.globals.weak_def.ensureUnusedCapacity(gpa, len);
            try elf.globals.strong_undef.ensureUnusedCapacity(gpa, len);
            try elf.globals.weak_undef.ensureUnusedCapacity(gpa, len);

            try elf.node_global_symbols.ensureUnusedCapacity(gpa, len);

            if (elf.shndx.dynsym != .UNDEF) {
                // Ensure the `.dynsym` section's node is big enough
                const dynsym_need_size: u64 = switch (elf.shdrPtr(elf.shndx.dynsym)) {
                    inline else => |shdr, class| elf.targetLoad(&shdr.size) + len * @sizeOf(class.ElfN().Sym),
                };
                _, const dynsym_cur_size = elf.shndx.dynsym.get(elf).ni.location(&elf.mf).resolve(&elf.mf);
                if (dynsym_cur_size < dynsym_need_size) {
                    const new_size = dynsym_need_size +| dynsym_need_size / MappedFile.growth_factor;
                    try elf.shndx.dynsym.get(elf).ni.resize(&elf.mf, gpa, new_size);
                }

                try elf.got.plt.ensureUnusedCapacity(gpa, len);
                const need_plt_capacity = elf.got.plt.count() + len;

                switch (elf.ehdrField(.machine)) {
                    else => |machine| @panic(@tagName(machine)),
                    .X86_64 => {
                        // Ensure the `.plt` section's node is big enough
                        const plt_need_size: usize = 16 * (1 + need_plt_capacity);
                        _, const plt_cur_size = elf.shndx.plt.get(elf).ni.location(&elf.mf).resolve(&elf.mf);
                        if (plt_cur_size < plt_need_size) {
                            const new_size = plt_need_size +| plt_need_size / MappedFile.growth_factor;
                            try elf.shndx.plt.get(elf).ni.resize(&elf.mf, gpa, new_size);
                        }

                        // Ensure the `.got.plt` section's node is big enough
                        const got_plt_need_size: usize = switch (elf.identClass()) {
                            .NONE, _ => unreachable,
                            inline else => |class| @sizeOf(class.ElfN().Addr) * (3 + need_plt_capacity),
                        };
                        _, const got_plt_cur_size = elf.shndx.got_plt.get(elf).ni.location(&elf.mf).resolve(&elf.mf);
                        if (got_plt_cur_size < got_plt_need_size) {
                            const new_size = got_plt_need_size +| got_plt_need_size / MappedFile.growth_factor;
                            try elf.shndx.got_plt.get(elf).ni.resize(&elf.mf, gpa, new_size);
                        }

                        // Ensure the `.plt.sec` section's node is big enough
                        const plt_sec_need_size: usize = 16 * need_plt_capacity;
                        _, const plt_sec_cur_size = elf.shndx.plt_sec.get(elf).ni.location(&elf.mf).resolve(&elf.mf);
                        if (plt_sec_cur_size < plt_sec_need_size) {
                            const new_size = plt_sec_need_size +| plt_sec_need_size / MappedFile.growth_factor;
                            try elf.shndx.plt_sec.get(elf).ni.resize(&elf.mf, gpa, new_size);
                        }

                        // Ensure the `.rela.plt` section's node is big enough
                        const rela_plt_shndx = elf.shndx.got_plt.get(elf).rela_shndx;
                        const rela_plt_need_size: usize = switch (elf.shdrPtr(rela_plt_shndx)) {
                            inline else => |shdr| @intCast(elf.targetLoad(&shdr.entsize) * need_plt_capacity),
                        };
                        _, const rela_plt_cur_size = rela_plt_shndx.get(elf).ni.location(&elf.mf).resolve(&elf.mf);
                        if (rela_plt_cur_size < rela_plt_need_size) {
                            const new_size = rela_plt_need_size +| rela_plt_need_size / MappedFile.growth_factor;
                            try rela_plt_shndx.get(elf).ni.resize(&elf.mf, gpa, new_size);
                        } else {
                            // Still mark `.rela.plt` as resized so that the DT_PLTRELSZ entry can
                            // be updated if we do indeed add a PLT entry.
                            try rela_plt_shndx.get(elf).ni.resized(gpa, &elf.mf);
                        }
                    },
                }
            }
        },
    }
}

const AddLocalSymbolOptions = struct {
    node: MappedFile.Node.Index,
    name: String(.strtab),
    value: u64,
    size: u64,
    type: std.elf.STT,
    shndx: Section.Index,
};
fn addLocalSymbolAssumeCapacity(elf: *Elf, opts: AddLocalSymbolOptions) Symbol.LocalIndex {
    switch (elf.shdrPtr(.symtab)) {
        inline else => |shdr, class| {
            const ent_size = @sizeOf(class.ElfN().Sym);

            // `shdr.info` stores the index of the first global symbol. We will replace it with our
            // new local symbol, and move the global symbol to a new index at the end of the symtab.
            const target_index: Symbol.Index = @enumFromInt(elf.targetLoad(&shdr.info));

            const old_size = elf.targetLoad(&shdr.size);
            const new_size = old_size + ent_size;

            assert(elf.symtab.items.len == @divExact(old_size, ent_size));

            elf.targetStore(&shdr.info, @intFromEnum(target_index) + 1);
            elf.targetStore(&shdr.size, new_size);

            const new_index: Symbol.Index = @enumFromInt(elf.symtab.items.len);
            elf.symtab.appendAssumeCapacity(undefined);

            const target_sym = @field(elf.symPtr(target_index), @tagName(class));

            if (target_index != new_index) {
                // Move the global at `target_index` to `new_index`. First the symtab entry...
                const new_sym = @field(elf.symPtr(new_index), @tagName(class));
                new_sym.* = target_sym.*;
                // ...then the `elf.symtab` metadata...
                new_index.ptr(elf).* = target_index.ptr(elf).*;
                // ...then update the `elf.globals` tracking.
                const global_name: String(.strtab) = @enumFromInt(elf.targetLoad(&new_sym.name));
                elf.globalByName(global_name).?.symtab_index = new_index;

                if (target_index.ptr(elf).first_target_reloc != .none) {
                    // This symbol's index is changing, so queue an update of relocs targeting it.
                    elf.changed_symtab_index.putAssumeCapacity(global_name, {});
                }
            }

            target_index.ptr(elf).* = .{
                .node = opts.node,
                .first_target_reloc = .none,
            };

            target_sym.* = .{
                .name = @intFromEnum(opts.name),
                .value = @intCast(opts.value),
                .size = @intCast(opts.size),
                .info = .{ .type = opts.type, .bind = .LOCAL },
                .other = .{ .visibility = .DEFAULT },
                .shndx = opts.shndx.toSection().?,
            };
            if (elf.targetEndian() != native_endian) {
                std.mem.byteSwapAllFields(class.ElfN().Sym, target_sym);
            }

            return @enumFromInt(@intFromEnum(target_index));
        },
    }
}

const AddGlobalSymbolOptions = struct {
    const Name = struct {
        strtab: String(.strtab),
        dynstr: String(.dynstr),
        fn string(elf: *Elf, slice: []const u8) !Name {
            return .{
                .strtab = try elf.string(.strtab, slice),
                .dynstr = switch (elf.shndx.dynsym) {
                    .UNDEF => .empty,
                    else => try elf.string(.dynstr, slice),
                },
            };
        }
    };

    node: MappedFile.Node.Index,
    name: Name,
    lib_name: ?[]const u8 = null,
    value: u64,
    size: u64,
    type: std.elf.STT,
    bind: enum { strong, weak },
    visibility: std.elf.STV,
    shndx: Section.Index,
};
fn addGlobalSymbolAssumeCapacity(elf: *Elf, opts: AddGlobalSymbolOptions) error{MultipleDefinitions}!Symbol.Id {
    _ = opts.lib_name; // TODO

    if (elf.shndx.dynsym == .UNDEF) {
        assert(opts.name.dynstr == .empty);
    } else {
        assert(std.mem.eql(u8, opts.name.dynstr.slice(elf), opts.name.strtab.slice(elf)));
    }

    // We break from this `switch` only if this symbol name did not previously exist at all and so
    // we have added a new entry to one of the maps in `elf.globals`. In that case we actually need
    // a new symtab entry.
    const new_global_ptr: *Symbol.Global = if (opts.shndx != .UNDEF) switch (opts.bind) {
        .strong => new_global: {
            const gop = elf.globals.strong_def.getOrPutAssumeCapacity(opts.name.strtab);
            if (gop.found_existing) return error.MultipleDefinitions;
            const old_kv = elf.globals.weak_def.fetchSwapRemove(opts.name.strtab) orelse
                elf.globals.strong_undef.fetchSwapRemove(opts.name.strtab) orelse
                elf.globals.weak_undef.fetchSwapRemove(opts.name.strtab) orelse {
                // The symbol did not already exist, so we'll use the "new global" path.
                break :new_global gop.value_ptr;
            };
            gop.value_ptr.* = old_kv.value;
            elf.setGlobalSymbolValue(opts.name.strtab, gop.value_ptr, .{
                .node = opts.node,
                .value = opts.value,
                .size = opts.size,
                .type = opts.type,
                .shndx = opts.shndx,
            });
            elf.mergeGlobalSymbolVisibility(gop.value_ptr, opts.visibility, .strong);
            return .global(opts.name.strtab);
        },
        .weak => new_global: {
            if (elf.globals.strong_def.getPtr(opts.name.strtab)) |global| {
                // The existing definition holds, we just merge our visibility in.
                elf.mergeGlobalSymbolVisibility(global, opts.visibility, .strong);
                return .global(opts.name.strtab);
            }
            const gop = elf.globals.weak_def.getOrPutAssumeCapacity(opts.name.strtab);
            if (gop.found_existing) {
                // The existing definition holds, we just merge our visibility in.
                elf.mergeGlobalSymbolVisibility(gop.value_ptr, opts.visibility, .weak);
                return .global(opts.name.strtab);
            }
            const old_kv = elf.globals.strong_undef.fetchSwapRemove(opts.name.strtab) orelse
                elf.globals.weak_undef.fetchSwapRemove(opts.name.strtab) orelse {
                // The symbol did not already exist, so we'll use the "new global" path.
                break :new_global gop.value_ptr;
            };
            gop.value_ptr.* = old_kv.value;
            elf.setGlobalSymbolValue(opts.name.strtab, gop.value_ptr, .{
                .node = opts.node,
                .value = opts.value,
                .size = opts.size,
                .type = opts.type,
                .shndx = opts.shndx,
            });
            elf.mergeGlobalSymbolVisibility(gop.value_ptr, opts.visibility, .weak);
            return .global(opts.name.strtab);
        },
    } else switch (opts.bind) {
        .strong => new_global: {
            if (elf.globals.strong_def.getPtr(opts.name.strtab)) |global| {
                // The existing definition holds, we just merge our visibility in.
                elf.mergeGlobalSymbolVisibility(global, opts.visibility, .strong);
                return .global(opts.name.strtab);
            }
            if (elf.globals.weak_def.getPtr(opts.name.strtab)) |global| {
                // The existing definition holds, we just merge our visibility in.
                elf.mergeGlobalSymbolVisibility(global, opts.visibility, .weak);
                return .global(opts.name.strtab);
            }
            const gop = elf.globals.strong_undef.getOrPutAssumeCapacity(opts.name.strtab);
            if (gop.found_existing) {
                // The existing symbol is okay, we just merge our visibility in.
                elf.mergeGlobalSymbolVisibility(gop.value_ptr, opts.visibility, .strong);
                return .global(opts.name.strtab);
            }
            const old_kv = elf.globals.weak_undef.fetchSwapRemove(opts.name.strtab) orelse {
                // The symbol did not already exist, so we'll use the "new global" path.
                break :new_global gop.value_ptr;
            };
            gop.value_ptr.* = old_kv.value;
            elf.mergeGlobalSymbolVisibility(gop.value_ptr, opts.visibility, .strong);
            return .global(opts.name.strtab);
        },
        .weak => new_global: {
            if (elf.globals.strong_def.getPtr(opts.name.strtab) orelse
                elf.globals.strong_undef.getPtr(opts.name.strtab)) |global|
            {
                // The existing symbol is okay, we just merge our visibility in.
                elf.mergeGlobalSymbolVisibility(global, opts.visibility, .strong);
                return .global(opts.name.strtab);
            }
            if (elf.globals.weak_def.getPtr(opts.name.strtab)) |global| {
                // The existing symbol is okay, we just merge our visibility in.
                elf.mergeGlobalSymbolVisibility(global, opts.visibility, .weak);
                return .global(opts.name.strtab);
            }
            const gop = elf.globals.weak_undef.getOrPutAssumeCapacity(opts.name.strtab);
            if (gop.found_existing) {
                // The existing symbol is okay, we just merge our visibility in.
                elf.mergeGlobalSymbolVisibility(gop.value_ptr, opts.visibility, .weak);
                return .global(opts.name.strtab);
            }
            break :new_global gop.value_ptr;
        },
    };

    const force_local_bind: bool = switch (opts.visibility) {
        .HIDDEN, .INTERNAL => elf.ehdrField(.type) != .REL,
        .PROTECTED, .DEFAULT => false,
    };

    const bind: std.elf.STB = if (force_local_bind) b: {
        break :b .LOCAL;
    } else switch (opts.bind) {
        .strong => .GLOBAL,
        .weak => .WEAK,
    };

    const sym_index: Symbol.Index = @enumFromInt(elf.symtab.items.len);
    elf.symtab.appendAssumeCapacity(.{
        .node = opts.node,
        .first_target_reloc = .none,
    });
    switch (elf.shdrPtr(.symtab)) {
        inline else => |shdr, class| {
            const Sym = class.ElfN().Sym;
            // Increase the symtab size...
            const old_size = elf.targetLoad(&shdr.size);
            assert(old_size == @intFromEnum(sym_index) * @sizeOf(Sym));
            elf.targetStore(&shdr.size, old_size + @sizeOf(Sym));
            // ...then populate the newly-valid symbol pointer
            const sym = @field(elf.symPtr(sym_index), @tagName(class));
            sym.* = .{
                .name = @intFromEnum(opts.name.strtab),
                .value = @intCast(opts.value),
                .size = @intCast(opts.size),
                .info = .{ .type = opts.type, .bind = bind },
                .other = .{ .visibility = opts.visibility },
                .shndx = opts.shndx.toSection().?,
            };
            if (elf.targetEndian() != native_endian) {
                std.mem.byteSwapAllFields(Sym, sym);
            }
        },
    }

    const old_head: String(.strtab) = old_head: {
        if (opts.node == .none) break :old_head .empty;
        const gop = elf.node_global_symbols.getOrPutAssumeCapacity(opts.node);
        const old_head: String(.strtab) = if (gop.found_existing) gop.value_ptr.* else .empty;
        gop.value_ptr.* = opts.name.strtab;
        break :old_head old_head;
    };

    new_global_ptr.* = .{
        .symtab_index = sym_index,
        .dynsym_index = dynsym_index: {
            if (elf.shndx.dynsym == .UNDEF) break :dynsym_index 0;
            if (force_local_bind) break :dynsym_index 0;
            switch (elf.shdrPtr(elf.shndx.dynsym)) {
                inline else => |shdr, class| {
                    const Sym = class.ElfN().Sym;
                    // Increase the dynamic symbol table size...
                    const old_size = elf.targetLoad(&shdr.size);
                    elf.targetStore(&shdr.size, old_size + @sizeOf(Sym));
                    const dynsym_index: u32 = @intCast(@divExact(old_size, @sizeOf(Sym)));
                    // ...then populate the newly-valid symbol pointer
                    const sym = @field(elf.dynsymPtr(dynsym_index), @tagName(class));
                    sym.* = .{
                        .name = @intFromEnum(opts.name.dynstr),
                        .value = @intCast(opts.value),
                        .size = @intCast(opts.size),
                        .info = .{ .type = opts.type, .bind = bind },
                        .other = .{ .visibility = opts.visibility },
                        .shndx = opts.shndx.toSection().?,
                    };
                    if (elf.targetEndian() != native_endian) {
                        std.mem.byteSwapAllFields(Sym, sym);
                    }
                    break :dynsym_index dynsym_index;
                },
            }
        },
        .prev_in_node = .empty,
        .next_in_node = old_head,
    };

    if (old_head != .empty) {
        const old_head_ptr = elf.globalByName(old_head).?;
        assert(old_head_ptr.symtab_index.ptr(elf).node == opts.node);
        assert(old_head_ptr.prev_in_node == .empty);
        old_head_ptr.prev_in_node = opts.name.strtab;
    }

    if (force_local_bind) {
        elf.moveDemotedGlobal(new_global_ptr);
    }

    if (new_global_ptr.dynsym_index != 0 and
        opts.visibility == .DEFAULT and
        opts.shndx == .UNDEF and
        opts.type == .FUNC)
    {
        // We're adding an undefined global STT_FUNC symbol which could be resolved by another DSO.
        // We therefore might need a PLT entry, so let's add one now. TODO: it'd be good to remove
        // the PLT entry if we later discover a link inpu which resolves this reference.
        elf.addPltEntry(opts.name.strtab, new_global_ptr.dynsym_index);
    }

    return .global(opts.name.strtab);
}
fn setGlobalSymbolValue(
    elf: *Elf,
    global_name: String(.strtab),
    global_ptr: *Symbol.Global,
    new: struct {
        node: MappedFile.Node.Index,
        value: u64,
        size: u64,
        type: std.elf.STT,
        shndx: Section.Index,
    },
) void {
    const old_node = global_ptr.symtab_index.ptr(elf).node;
    if (old_node != .none) {
        if (global_ptr.next_in_node != .empty) {
            const next = elf.globalByName(global_ptr.next_in_node).?;
            assert(next.prev_in_node == global_name);
            assert(next.symtab_index.ptr(elf).node == old_node);
            next.prev_in_node = global_ptr.prev_in_node;
        }
        if (global_ptr.prev_in_node != .empty) {
            const prev = elf.globalByName(global_ptr.prev_in_node).?;
            assert(prev.next_in_node == global_name);
            assert(prev.symtab_index.ptr(elf).node == old_node);
            prev.next_in_node = global_ptr.next_in_node;
        } else {
            // We're the start of the linked list, so we need to change the head.
            if (global_ptr.next_in_node == .empty) {
                assert(elf.node_global_symbols.fetchSwapRemove(old_node).?.value == global_name);
            } else {
                elf.node_global_symbols.getPtr(old_node).?.* = global_ptr.next_in_node;
            }
        }
    } else {
        assert(global_ptr.next_in_node == .empty);
        assert(global_ptr.prev_in_node == .empty);
    }

    global_ptr.symtab_index.ptr(elf).node = new.node;

    const old_head: String(.strtab) = old_head: {
        if (new.node == .none) break :old_head .empty;
        const gop = elf.node_global_symbols.getOrPutAssumeCapacity(new.node);
        const old_head: String(.strtab) = if (gop.found_existing) gop.value_ptr.* else .empty;
        gop.value_ptr.* = global_name;
        break :old_head old_head;
    };

    global_ptr.prev_in_node = .empty;
    global_ptr.next_in_node = old_head;

    if (old_head != .empty) {
        const old_head_ptr = elf.globalByName(old_head).?;
        assert(old_head_ptr.symtab_index.ptr(elf).node == new.node);
        assert(old_head_ptr.prev_in_node == .empty);
        old_head_ptr.prev_in_node = global_name;
    }

    // Now for the easy bit where we actually update the symtab entry.
    switch (elf.symPtr(global_ptr.symtab_index)) {
        inline else => |sym| {
            // Don't bother with `sym.value` here: it'll be updated by `flushMoved`.
            elf.targetStore(&sym.size, @intCast(new.size));
            elf.targetStore(&sym.shndx, new.shndx.toSection().?);
            const old_bind = elf.targetLoad(&sym.info).bind;
            elf.targetStore(&sym.info, .{
                .type = new.type,
                .bind = old_bind,
            });
        },
    }

    // ...and also the dynsym entry if there is one.
    if (global_ptr.dynsym_index != 0) switch (elf.dynsymPtr(global_ptr.dynsym_index)) {
        inline else => |sym| {
            // Don't bother with `sym.value` here: it'll be updated by `flushMoved`.
            elf.targetStore(&sym.size, @intCast(new.size));
            elf.targetStore(&sym.shndx, new.shndx.toSection().?);
            const old_bind = elf.targetLoad(&sym.info).bind;
            elf.targetStore(&sym.info, .{
                .type = new.type,
                .bind = old_bind,
            });
        },
    };

    global_ptr.flushMoved(elf, new.value);
}
/// When the same global symbol appears in two inputs---even if one symbol is defined and the other
/// undefined---their visibility values are combined to determine the resulting visibility, which
/// can also affect the bind of the symbol we output.
fn mergeGlobalSymbolVisibility(elf: *Elf, global_ptr: *Symbol.Global, other_visibility: std.elf.STV, bind: enum { strong, weak }) void {
    const old_visibility: std.elf.STV = switch (elf.symPtr(global_ptr.symtab_index)) {
        inline else => |sym| elf.targetLoad(&sym.other).visibility,
    };
    // The combined visibility is essentially the "strictest" of the two, with most strict being
    // INTERNAL, followed by HIDDEN, PROTECTED, DEFAULT.
    const new_visibility: std.elf.STV, const newly_hidden: bool = switch (old_visibility) {
        .INTERNAL => .{ .INTERNAL, false },
        .HIDDEN => switch (other_visibility) {
            .INTERNAL => .{ .INTERNAL, false },
            .HIDDEN, .PROTECTED, .DEFAULT => .{ .HIDDEN, false },
        },
        .PROTECTED => switch (other_visibility) {
            .INTERNAL => .{ .INTERNAL, true },
            .HIDDEN => .{ .HIDDEN, true },
            .PROTECTED, .DEFAULT => .{ .PROTECTED, false },
        },
        .DEFAULT => switch (other_visibility) {
            .INTERNAL => .{ .INTERNAL, true },
            .HIDDEN => .{ .HIDDEN, true },
            .PROTECTED => .{ .PROTECTED, false },
            .DEFAULT => .{ .DEFAULT, false },
        },
    };
    // If the symbol is HIDDEN/INTERNAL and we're emitting an ELF module (executable or shared
    // object), then the symbol should have binding STB_LOCAL in the output. Therefore, if we are
    // putting the global in this state for the first time---let's call it "demoting" the global to
    // STB_LOCAL---we need to update its bind in the symtab.
    const demote_to_local = newly_hidden and elf.ehdrField(.type) != .REL;
    switch (elf.symPtr(global_ptr.symtab_index)) {
        inline else => |sym, class| {
            const old_info = elf.targetLoad(&sym.info);
            const new_info: class.ElfN().Sym.Info = .{
                .type = old_info.type,
                .bind = if (demote_to_local) b: {
                    assert(old_info.bind != .LOCAL);
                    break :b .LOCAL;
                } else if (old_info.bind == .LOCAL) .LOCAL else switch (bind) {
                    .strong => .GLOBAL,
                    .weak => .WEAK,
                },
            };
            elf.targetStore(&sym.other, .{ .visibility = new_visibility });
            elf.targetStore(&sym.info, new_info);
            // also update dynsym
            if (global_ptr.dynsym_index != 0) {
                const dynsym = @field(elf.dynsymPtr(global_ptr.dynsym_index), @tagName(class));
                elf.targetStore(&dynsym.other, .{ .visibility = new_visibility });
                elf.targetStore(&dynsym.info, new_info);
            }
        },
    }
    if (demote_to_local) {
        // When demoting a global to STB_LOCAL, we need to move its symtab index so that it is with
        // the STB_LOCAL symbols instead of the global symbols.
        elf.moveDemotedGlobal(global_ptr);
    }
}
/// If a symbol which was STB_GLOBAL/STB_WEAK becomes STB_LOCAL (see `mergeGlobalSymbolVisibility`),
/// the symbol must be moved from the "globals" part of the symtab to the "locals" part, because ELF
/// requires that all STB_LOCAL symbols in a symbol table appear before any global symbols.
fn moveDemotedGlobal(elf: *Elf, global_ptr: *Symbol.Global) void {
    assert(elf.ehdrField(.type) != .REL); // demotion only happens when emitting an ELF module
    switch (elf.shdrPtr(.symtab)) {
        inline else => |shdr, class| {
            // `shdr.info` stores the index of the first global symbol. We are going to swap the
            // demoted symbol with that first global symbol, then increment that start index.
            const dest_index: Symbol.Index = @enumFromInt(elf.targetLoad(&shdr.info));
            const src_index = global_ptr.symtab_index;

            // This global should currently be in the "global symbols" part of the symtab, since our
            // job is to move it *out* of that part:
            assert(@intFromEnum(src_index) >= @intFromEnum(dest_index));

            elf.targetStore(&shdr.info, @intFromEnum(dest_index) + 1);

            if (src_index == dest_index) {
                // The demoted global was already the first global, so we don't need to do any swap.
                return;
            }

            const src_sym_ptr = @field(elf.symPtr(src_index), @tagName(class));
            const dest_sym_ptr = @field(elf.symPtr(dest_index), @tagName(class));

            const this_name: String(.strtab) = @enumFromInt(elf.targetLoad(&src_sym_ptr.name));
            assert(elf.globalByName(this_name).? == global_ptr);
            if (global_ptr.symtab_index.ptr(elf).first_target_reloc != .none) {
                // This symbol's index is changing, so queue an update of relocs targeting it.
                elf.changed_symtab_index.putAssumeCapacity(this_name, {});
            }

            const other_name: String(.strtab) = @enumFromInt(elf.targetLoad(&dest_sym_ptr.name));
            const other_global_ptr = elf.globalByName(other_name).?;
            assert(other_global_ptr.symtab_index == dest_index);
            if (other_global_ptr.symtab_index.ptr(elf).first_target_reloc != .none) {
                // This other symbol's index is changing, so queue an update of relocs targeting it.
                elf.changed_symtab_index.putAssumeCapacity(other_name, {});
            }

            // First swap the symtab entries...
            std.mem.swap(class.ElfN().Sym, src_sym_ptr, dest_sym_ptr);
            // ...then the `elf.symtab` metadata...
            std.mem.swap(Symbol, src_index.ptr(elf), dest_index.ptr(elf));
            // ...then update the `elf.globals` tracking.
            global_ptr.symtab_index = dest_index;
            other_global_ptr.symtab_index = src_index;

            // We also need to get rid of the dynsym entry if there is one. For simplicity, just
            // replace it with a dummy entry which will never be used and will not cause problems.
            // TODO: we should have a free-list of dynsym slots so that other symbols can go here.
            // TODO: it would also be best to just avoid having gaps in the dynsym altogether.
            if (global_ptr.dynsym_index != 0) {
                const dynsym = @field(elf.dynsymPtr(global_ptr.dynsym_index), @tagName(class));
                dynsym.* = .{
                    .name = @intFromEnum(String(.dynstr).empty),
                    .value = 0,
                    .size = 0,
                    .info = .{
                        .type = .NOTYPE,
                        // STB_WEAK is important: we mustn't cause a dynamic linker error if the
                        // symbol can't be resolved.
                        .bind = .WEAK,
                    },
                    // SHN_UNDEF is important: we mustn't define this symbol for other DSOs.
                    .shndx = std.elf.SHN_UNDEF,
                    .other = .{ .visibility = .DEFAULT },
                };
                if (elf.targetEndian() != native_endian) {
                    std.mem.byteSwapAllFields(class.ElfN().Sym, dynsym);
                }
            }
        },
    }
}
fn addPltEntry(elf: *Elf, global_name: String(.strtab), dynsym_index: u32) void {
    const target_endian = elf.targetEndian();
    const plt_index: u32 = @intCast(elf.got.plt.count());
    elf.got.plt.putAssumeCapacityNoClobber(.global(global_name), {});
    switch (elf.ehdrField(.machine)) {
        else => |machine| @panic(@tagName(machine)),
        .X86_64 => {
            const plt_ni = elf.shndx.plt.get(elf).ni;
            const plt_addr = plt_addr: switch (elf.shdrPtr(elf.shndx.plt)) {
                inline else => |shdr| {
                    const old_size = 16 * (1 + plt_index);
                    assert(elf.targetLoad(&shdr.size) == old_size);
                    elf.targetStore(&shdr.size, old_size + 16);
                    const plt_slice = plt_ni.slice(&elf.mf)[old_size..][0..16];
                    @memcpy(plt_slice, &[16]u8{
                        0xf3, 0x0f, 0x1e, 0xfa, // endbr64
                        0x68, 0x00, 0x00, 0x00, 0x00, // push $0x0
                        0xe9, 0x00, 0x00, 0x00, 0x00, // jmp 0
                        0x66, 0x90, // xchg %ax,%ax
                    });
                    std.mem.writeInt(u32, plt_slice[5..][0..4], plt_index, target_endian);
                    std.mem.writeInt(
                        i32,
                        plt_slice[10..][0..4],
                        -@as(i32, @intCast(old_size + 14)),
                        target_endian,
                    );
                    break :plt_addr elf.targetLoad(&shdr.addr) + old_size;
                },
            };

            const got_plt_shndx = elf.shndx.got_plt;
            const got_plt_ni = elf.shndx.got_plt.get(elf).ni;
            const got_plt_addr = got_plt_addr: switch (elf.shdrPtr(got_plt_shndx)) {
                inline else => |shdr, class| {
                    const ent_size = @sizeOf(class.ElfN().Addr);
                    const old_size = ent_size * (3 + plt_index);
                    elf.targetStore(&shdr.size, old_size + ent_size);
                    std.mem.writeInt(
                        class.ElfN().Addr,
                        got_plt_ni.slice(&elf.mf)[old_size..][0..ent_size],
                        @intCast(plt_addr),
                        target_endian,
                    );
                    break :got_plt_addr elf.targetLoad(&shdr.addr) + old_size;
                },
            };

            const plt_sec_ni = elf.shndx.plt_sec.get(elf).ni;
            switch (elf.shdrPtr(elf.shndx.plt_sec)) {
                inline else => |shdr| {
                    const old_size = 16 * plt_index;
                    elf.targetStore(&shdr.size, old_size + 16);
                    const plt_sec_slice = plt_sec_ni.slice(&elf.mf)[old_size..][0..16];
                    @memcpy(plt_sec_slice, &[16]u8{
                        0xf3, 0x0f, 0x1e, 0xfa, // endbr64
                        0xff, 0x25, 0x00, 0x00, 0x00, 0x00, // jmp *0x0(%rip)
                        0x66, 0x0f, 0x1f, 0x44, 0x00, 0x00, // nopw 0x0(%rax,%rax,1)
                    });
                    std.mem.writeInt(
                        i32,
                        plt_sec_slice[6..][0..4],
                        @intCast(@as(i64, @bitCast(
                            got_plt_addr -% (elf.targetLoad(&shdr.addr) + old_size + 10),
                        ))),
                        target_endian,
                    );
                },
            }

            const rela_plt_shndx = got_plt_shndx.get(elf).rela_shndx;
            const rela_plt_ni = rela_plt_shndx.get(elf).ni;
            switch (elf.shdrPtr(rela_plt_shndx)) {
                inline else => |shdr, class| {
                    const Rela = class.ElfN().Rela;
                    const rela_size = elf.targetLoad(&shdr.entsize);
                    const old_size = rela_size * plt_index;
                    const new_size = old_size + rela_size;
                    elf.targetStore(&shdr.size, new_size);
                    const rela: *Rela = @ptrCast(@alignCast(
                        rela_plt_ni.slice(&elf.mf)[@intCast(old_size)..@intCast(new_size)],
                    ));
                    rela.* = .{
                        .offset = @intCast(got_plt_addr),
                        .info = .{
                            .type = @intFromEnum(std.elf.R_X86_64.JUMP_SLOT),
                            .sym = @intCast(dynsym_index),
                        },
                        .addend = 0,
                    };
                    if (target_endian != native_endian) std.mem.byteSwapAllFields(Rela, rela);
                },
            }
        },
    }
}

const Symbol = struct {
    /// The node which this symbol's value is defined relative to. Possible values are:
    /// * `.none` for a SHN_ABS or SHN_UNDEF symbol
    /// * A section (the symbol's value is some vaddr in that section)
    /// * An input section (the symbol's value is some vaddr in that input section)
    /// * A NAV, UAV, or lazy code/data (the symbol's value is exactly the vaddr of that node)
    node: MappedFile.Node.Index,

    /// The head of a linked list of relocations targeting this symbol.
    first_target_reloc: Reloc.Index,

    const Global = struct {
        /// The current index of the symtab entry for this global symbol.
        symtab_index: Symbol.Index,
        /// The current index of the dynsym entry for this global symbol. If the global has been
        /// demoted to STB_LOCAL, it does not have a dynsym entry and this field is set to 0.
        dynsym_index: u32,

        /// The next entry in a linked list of global symbols with the same `Symbol.node` value.
        ///
        /// If `node` is `.none`, this is `.empty`.
        next_in_node: String(.strtab),
        /// The previous entry in a linked list of global symbols with the same `Symbol.node` value.
        ///
        /// If `node` is `.none`, this is `.empty`.
        prev_in_node: String(.strtab),

        /// Like `Symbol.Index.flushMoved`, but also updates the dynamic symbol table if necessary.
        fn flushMoved(g: *const Global, elf: *Elf, value: u64) void {
            g.symtab_index.flushMoved(elf, value);
            if (g.dynsym_index != 0) {
                switch (elf.dynsymPtr(g.dynsym_index)) {
                    inline else => |sym| elf.targetStore(&sym.value, @intCast(value)),
                }
            }
        }
    };

    /// An index directly into the symtab. These values are not stable (global symbols are sometimes
    /// moved to new locations in the symtab) and therefore should only be used ephemerally.
    ///
    /// Local symbols *do* have stable indices into the symtab; see `LocalIndex`.
    ///
    /// For a stable reference to an arbitrary symbol, see `Id`.
    const Index = enum(u32) {
        null = 0,
        _,

        fn flushMoved(si: Symbol.Index, elf: *Elf, value: u64) void {
            switch (elf.symPtr(si)) {
                inline else => |sym| elf.targetStore(&sym.value, @intCast(value)),
            }
            if (elf.ehdrField(.type) != .REL) {
                var ri = si.ptr(elf).first_target_reloc;
                while (ri != .none) {
                    const reloc = ri.get(elf);
                    assert(reloc.target.index(elf) == si);
                    reloc.apply(elf);
                    ri = reloc.next;
                }
            }
        }
        fn ptr(si: Symbol.Index, elf: *Elf) *Symbol {
            return &elf.symtab.items[@intFromEnum(si)];
        }
    };

    /// A `LocalIndex` is a raw index into the symtab like `Index`, but it guarantees that the
    /// symbol in question has STB_LOCAL binding, which guarantees that its symtab index is stable
    /// so can be stored long-term without needing to be updated
    ///
    /// This is because symbols which have STB_LOCAL binding in the output file gain fixed symtab
    /// indices, thanks to a combination of a few factors:
    /// * We never remove STB_LOCAL symbols
    /// * There is no symbol ordering requirement *within* the leading range of STB_LOCAL symbols
    /// * A symbol visibility which demotes a global to STB_LOCAL binding can never be reverted by
    ///   a subsequent operation (different visibilities resolve to the "strictest" one)
    const LocalIndex = enum(u32) {
        null = 0,
        _,

        fn index(li: LocalIndex) Index {
            return @enumFromInt(@intFromEnum(li));
        }
    };

    /// Opaque, stable identifier for a symbol. Does not necessarily equal the index into the symtab.
    const Id = packed struct(u32) {
        kind: enum(u1) { local, global },
        raw: u31,

        const @"null": Symbol.Id = .local(.null);

        fn local(lsi: Symbol.LocalIndex) Symbol.Id {
            return .{ .kind = .local, .raw = @intCast(@intFromEnum(lsi)) };
        }
        fn global(name: String(.strtab)) Symbol.Id {
            return .{ .kind = .global, .raw = @intCast(@intFromEnum(name)) };
        }
        fn unwrap(s: Symbol.Id) union(enum) {
            local: Symbol.LocalIndex,
            global: String(.strtab),
        } {
            return switch (s.kind) {
                .local => .{ .local = @enumFromInt(s.raw) },
                .global => .{ .global = @enumFromInt(s.raw) },
            };
        }

        fn toTypeErased(s: Symbol.Id) link.File.SymbolId {
            return @enumFromInt(@as(u32, @bitCast(s)));
        }
        fn fromTypeErased(s: link.File.SymbolId) Symbol.Id {
            return @bitCast(@intFromEnum(s));
        }

        fn index(s: Symbol.Id, elf: *const Elf) Symbol.Index {
            return switch (s.unwrap()) {
                .local => |lsi| lsi.index(),
                .global => |name| elf.globalByName(name).?.symtab_index,
            };
        }

        fn value(s: Symbol.Id, elf: *Elf) u64 {
            return switch (elf.symPtr(s.index(elf))) {
                inline else => |sym| elf.targetLoad(&sym.value),
            };
        }

        /// Returns `true` if the target of `s` has moved, meaning the symbol's value will change at
        /// some point due to a call to `flushMoved`.
        fn hasMoved(s: Symbol.Id, elf: *Elf) bool {
            const node = s.index(elf).ptr(elf).node;
            if (node == .none) return false;
            return node.hasMoved(&elf.mf);
        }
    };
};

fn globalByName(elf: *const Elf, name: String(.strtab)) ?*Symbol.Global {
    if (elf.globals.strong_def.getPtr(name)) |ptr| return ptr;
    if (elf.globals.weak_def.getPtr(name)) |ptr| return ptr;
    if (elf.globals.strong_undef.getPtr(name)) |ptr| return ptr;
    if (elf.globals.weak_undef.getPtr(name)) |ptr| return ptr;
    return null;
}

pub fn symbolForAtom(elf: *Elf, atom: link.File.AtomId) link.File.SymbolId {
    const lsi: Symbol.LocalIndex = switch (elf.getNode(Node.fromAtom(atom))) {
        .file,
        .ehdr,
        .shdr,
        .segment,
        .section,
        .input_section,
        => unreachable,

        inline .nav,
        .uav,
        .lazy_code,
        .lazy_const_data,
        => |i| i.symbol(elf),
    };
    const s: Symbol.Id = .local(lsi);
    return s.toTypeErased();
}
pub fn lazySymbol(elf: *Elf, lazy: link.File.LazySymbol) !link.File.SymbolId {
    const gpa = elf.base.comp.gpa;

    try elf.ensureUnusedSymbolCapacity(1, .all_local);
    try elf.nodes.ensureUnusedCapacity(gpa, 1);
    try elf.lazy.getPtr(lazy.kind).map.ensureUnusedCapacity(gpa, 1);

    const gop = elf.lazy.getPtr(lazy.kind).map.getOrPutAssumeCapacity(lazy.ty);
    if (!gop.found_existing) {
        const shndx: Section.Index, const sym_type: std.elf.STT = switch (lazy.kind) {
            .code => .{ .text, .FUNC },
            .const_data => .{ .rodata, .OBJECT },
        };
        const node = try elf.mf.addLastChildNode(gpa, shndx.get(elf).ni, .{});
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(
            &name_buf,
            "__lazy_{t}_{d}",
            .{ lazy.kind, @intFromEnum(lazy.ty) },
        ) catch unreachable;
        gop.value_ptr.* = .{
            .lsi = elf.addLocalSymbolAssumeCapacity(.{
                .node = node,
                .name = try elf.string(.strtab, name),
                .value = 0,
                .size = 0,
                .type = sym_type,
                .shndx = shndx,
            }),
            .first_reloc = .none,
        };
        elf.nodes.appendAssumeCapacity(switch (lazy.kind) {
            .code => .{ .lazy_code = @enumFromInt(gop.index) },
            .const_data => .{ .lazy_const_data = @enumFromInt(gop.index) },
        });
        elf.synth_prog_node.increaseEstimatedTotalItems(1);
    }
    const s: Symbol.Id = .local(gop.value_ptr.lsi);
    return s.toTypeErased();
}
pub fn externSymbol(elf: *Elf, opts: struct {
    name: []const u8,
    lib_name: ?[]const u8,
    type: std.elf.STT,
    linkage: std.lang.GlobalLinkage = .strong,
    visibility: std.lang.SymbolVisibility = .default,
}) !link.File.SymbolId {
    try elf.ensureUnusedSymbolCapacity(1, .maybe_global);
    const symbol = elf.addGlobalSymbolAssumeCapacity(.{
        .node = .none,
        .name = try .string(elf, opts.name),
        .lib_name = opts.lib_name,
        .value = 0,
        .size = 0,
        .type = opts.type,
        .bind = switch (opts.linkage) {
            .internal => @panic("TODO internal extern symbol"),
            .strong => .strong,
            .weak => .weak,
            .link_once => return error.LinkOnceUnsupported,
        },
        .visibility = switch (opts.visibility) {
            .default => .DEFAULT,
            .hidden => .HIDDEN,
            .protected => .PROTECTED,
        },
        .shndx = .UNDEF,
    }) catch |err| switch (err) {
        error.MultipleDefinitions => unreachable, // shndx is undef
    };
    return symbol.toTypeErased();
}
pub fn addReloc(
    elf: *Elf,
    atom: link.File.AtomId,
    offset: u64,
    target: link.File.SymbolId,
    addend: i64,
    @"type": Reloc.Type,
) !void {
    const node: MappedFile.Node.Index = Node.fromAtom(atom);
    try elf.ensureUnusedRelocCapacity(node, 1);
    elf.addRelocAssumeCapacity(node, offset, .fromTypeErased(target), addend, @"type");
}
pub fn navSymbol(elf: *Elf, nav_index: InternPool.Nav.Index) !link.File.SymbolId {
    const zcu = elf.base.comp.zcu.?;
    const ip = &zcu.intern_pool;
    const nav = ip.getNav(nav_index);
    if (nav.getExtern(ip)) |@"extern"| {
        return elf.externSymbol(.{
            .name = @"extern".name.toSlice(ip),
            .lib_name = @"extern".lib_name.toSlice(ip),
            .type = elf.navType(nav.resolved.?),
            .linkage = @"extern".linkage,
            .visibility = @"extern".visibility,
        });
    }
    const nmi = try elf.navMapIndex(zcu, nav_index);
    const s: Symbol.Id = .local(nmi.symbol(elf));
    return s.toTypeErased();
}
pub fn uavSymbol(
    elf: *Elf,
    uav_val: InternPool.Index,
    uav_align: InternPool.Alignment,
) !link.File.SymbolId {
    const umi = try elf.uavMapIndex(uav_val, uav_align);
    const s: Symbol.Id = .local(umi.symbol(elf));
    return s.toTypeErased();
}
pub fn getNavVAddr(
    elf: *Elf,
    pt: Zcu.PerThread,
    nav: InternPool.Nav.Index,
    reloc_info: link.File.RelocInfo,
) !u64 {
    _ = pt;
    return elf.getVAddr(reloc_info, try elf.navSymbol(nav));
}
pub fn getUavVAddr(
    elf: *Elf,
    uav_val: InternPool.Index,
    reloc_info: link.File.RelocInfo,
) !u64 {
    return elf.getVAddr(reloc_info, try elf.uavSymbol(uav_val, .none));
}
pub fn getVAddr(elf: *Elf, reloc_info: link.File.RelocInfo, target: link.File.SymbolId) !u64 {
    const node: MappedFile.Node.Index = Node.fromAtom(reloc_info.parent.atom_index);
    const target_sym: Symbol.Id = .fromTypeErased(target);
    try elf.ensureUnusedRelocCapacity(node, 1);
    elf.addRelocAssumeCapacity(
        node,
        reloc_info.offset,
        target_sym,
        reloc_info.addend,
        .absAddr(elf),
    );
    return target_sym.value(elf);
}
pub fn lowerUav(
    elf: *Elf,
    pt: Zcu.PerThread,
    uav_val: InternPool.Index,
    uav_align: InternPool.Alignment,
    src_loc: Zcu.LazySrcLoc,
) !codegen.SymbolResult {
    _ = pt;
    const umi = elf.uavMapIndex(uav_val, uav_align) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => |e| return .{ .fail = try Zcu.ErrorMsg.create(
            elf.base.comp.gpa,
            src_loc,
            "linker failed to update constant: {s}",
            .{@errorName(e)},
        ) },
    };
    const s: Symbol.Id = .local(umi.symbol(elf));
    return .{ .sym_index = s.toTypeErased() };
}

const StringSection = enum {
    shstrtab,
    strtab,
    dynstr,
    fn shndx(s: StringSection, elf: *const Elf) Section.Index {
        return switch (s) {
            .strtab => .strtab,
            .shstrtab => .shstrtab,
            .dynstr => elf.shndx.dynstr,
        };
    }
};
fn String(section: StringSection) type {
    return enum(u32) {
        empty = 0,
        _,

        fn slice(str: @This(), elf: *Elf) [:0]const u8 {
            const section_node = section.shndx(elf).get(elf).ni;
            const overlong = section_node.sliceConst(&elf.mf)[@intFromEnum(str)..];
            return overlong[0..std.mem.findScalar(u8, overlong, 0).? :0];
        }
    };
}
fn string(elf: *Elf, comptime section: StringSection, key: []const u8) !String(section) {
    const st: *StringTable = &@field(elf, @tagName(section));
    return @enumFromInt(try st.get(elf, section.shndx(elf), key));
}

const StringTable = struct {
    map: std.HashMapUnmanaged(u32, void, StringTable.Context, std.hash_map.default_max_load_percentage),

    const Context = struct {
        slice: []const u8,

        pub fn eql(_: Context, lhs_key: u32, rhs_key: u32) bool {
            return lhs_key == rhs_key;
        }

        pub fn hash(ctx: Context, key: u32) u64 {
            return std.hash_map.hashString(std.mem.sliceTo(ctx.slice[key..], 0));
        }
    };

    const Adapter = struct {
        slice: []const u8,

        pub fn eql(adapter: Adapter, lhs_key: []const u8, rhs_key: u32) bool {
            return std.mem.startsWith(u8, adapter.slice[rhs_key..], lhs_key) and
                adapter.slice[rhs_key + lhs_key.len] == 0;
        }

        pub fn hash(_: Adapter, key: []const u8) u64 {
            assert(std.mem.indexOfScalar(u8, key, 0) == null);
            return std.hash_map.hashString(key);
        }
    };

    pub fn get(st: *StringTable, elf: *Elf, shndx: Section.Index, key: []const u8) !u32 {
        // If we are in `initHeaders` the strtab might not be initalized yet, so we need to special
        // case the empty string.
        if (key.len == 0) return 0;

        const gpa = elf.base.comp.gpa;
        const ni = shndx.get(elf).ni;
        const slice_const = ni.sliceConst(&elf.mf);
        const gop = try st.map.getOrPutContextAdapted(
            gpa,
            key,
            StringTable.Adapter{ .slice = slice_const },
            .{ .slice = slice_const },
        );
        if (gop.found_existing) return gop.key_ptr.*;
        try ni.resized(gpa, &elf.mf);
        const old_size, const new_size = size: switch (elf.shdrPtr(shndx)) {
            inline else => |shdr| {
                const old_size: u32 = @intCast(elf.targetLoad(&shdr.size));
                const new_size: u32 = @intCast(old_size + key.len + 1);
                elf.targetStore(&shdr.size, new_size);
                break :size .{ old_size, new_size };
            },
        };
        _, const node_size = ni.location(&elf.mf).resolve(&elf.mf);
        if (new_size > node_size)
            try ni.resize(&elf.mf, gpa, new_size +| new_size / MappedFile.growth_factor);
        const slice = ni.slice(&elf.mf)[old_size..];
        @memcpy(slice[0..key.len], key);
        slice[key.len] = 0;
        gop.key_ptr.* = old_size;
        return old_size;
    }
};

const GotIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn wrap(i: ?u32) GotIndex {
        const gi: GotIndex = @enumFromInt(i orelse return .none);
        assert(gi != .none);
        return gi;
    }
    pub fn unwrap(gi: GotIndex) ?u32 {
        return switch (gi) {
            _ => @intFromEnum(gi),
            .none => null,
        };
    }
};

const Reloc = extern struct {
    type: Reloc.Type,
    prev: Reloc.Index,
    next: Reloc.Index,
    node: MappedFile.Node.Index,
    target: Symbol.Id,
    index: Section.RelIndex,
    offset: u64,
    addend: i64,

    pub const Type = extern union {
        X86_64: std.elf.R_X86_64,
        AARCH64: std.elf.R_AARCH64,
        RISCV: std.elf.R_RISCV,
        PPC64: std.elf.R_PPC64,

        pub fn none(elf: *Elf) Reloc.Type {
            return switch (elf.ehdrField(.machine)) {
                else => unreachable,
                .AARCH64 => .{ .AARCH64 = .NONE },
                .PPC64 => .{ .PPC64 = .NONE },
                .RISCV => .{ .RISCV = .NONE },
                .X86_64 => .{ .X86_64 = .NONE },
            };
        }
        pub fn absAddr(elf: *Elf) Reloc.Type {
            return switch (elf.ehdrField(.machine)) {
                else => unreachable,
                .AARCH64 => .{ .AARCH64 = .ABS64 },
                .PPC64 => .{ .PPC64 = .ADDR64 },
                .RISCV => .{ .RISCV = .@"64" },
                .X86_64 => .{ .X86_64 = .@"64" },
            };
        }
        pub fn sizeAddr(elf: *Elf) Reloc.Type {
            return switch (elf.ehdrField(.machine)) {
                else => unreachable,
                .X86_64 => .{ .X86_64 = .SIZE64 },
            };
        }

        pub fn wrap(int: u32, elf: *Elf) Reloc.Type {
            return switch (elf.ehdrField(.machine)) {
                else => unreachable,
                inline .AARCH64,
                .PPC64,
                .RISCV,
                .X86_64,
                => |machine| @unionInit(Reloc.Type, @tagName(machine), @enumFromInt(int)),
            };
        }
        pub fn unwrap(rt: Reloc.Type, elf: *Elf) u32 {
            return switch (elf.ehdrField(.machine)) {
                else => unreachable,
                inline .AARCH64,
                .PPC64,
                .RISCV,
                .X86_64,
                => |machine| @intFromEnum(@field(rt, @tagName(machine))),
            };
        }
    };

    pub const Index = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn get(si: Reloc.Index, elf: *Elf) *Reloc {
            return &elf.relocs.items[@intFromEnum(si)];
        }
    };

    pub fn apply(reloc: *const Reloc, elf: *Elf) void {
        assert(elf.ehdrField(.type) != .REL);
        assert(reloc.node != .none);
        if (reloc.node.hasMoved(&elf.mf) or reloc.target.hasMoved(elf)) {
            // There's no point applying the relocation now, because it will be re-applied by
            // `flushMoved` at some point anyway.
            return;
        }
        const node_vaddr: u64 = switch (elf.getNode(reloc.node)) {
            .file => unreachable,
            .ehdr => unreachable,
            .shdr => unreachable,
            .segment => unreachable,
            .section => |shndx| shndx.vaddr(elf),
            .input_section => |isi| isi.ptrConst(elf).vaddr,
            inline .nav,
            .uav,
            .lazy_code,
            .lazy_const_data,
            => |i| Symbol.Id.local(i.symbol(elf)).value(elf),
        };
        const dest_vaddr = node_vaddr + reloc.offset;
        const dest_slice = reloc.node.slice(&elf.mf)[@intCast(reloc.offset)..];
        const target_endian = elf.targetEndian();
        switch (elf.symPtr(reloc.target.index(elf))) {
            inline else => |target_sym, class| {
                const target_value = elf.targetLoad(&target_sym.value) +% @as(u64, @bitCast(reloc.addend));
                switch (elf.ehdrField(.machine)) {
                    else => |machine| @panic(@tagName(machine)),
                    .X86_64 => switch (reloc.type.X86_64) {
                        else => |kind| @panic(@tagName(kind)),
                        .@"64" => std.mem.writeInt(
                            u64,
                            dest_slice[0..8],
                            target_value,
                            target_endian,
                        ),
                        .PC32 => std.mem.writeInt(
                            i32,
                            dest_slice[0..4],
                            @intCast(@as(i64, @bitCast(target_value -% dest_vaddr))),
                            target_endian,
                        ),
                        .PLT32 => std.mem.writeInt(
                            i32,
                            dest_slice[0..4],
                            @intCast(@as(i64, @bitCast(if (elf.got.plt.getIndex(reloc.target)) |plt_index|
                                elf.targetLoad(&@field(
                                    elf.shdrPtr(elf.shndx.plt_sec),
                                    @tagName(class),
                                ).addr) +% 16 * plt_index +%
                                    @as(u64, @bitCast(reloc.addend)) -% dest_vaddr
                            else
                                target_value -% dest_vaddr))),
                            target_endian,
                        ),
                        .@"32" => std.mem.writeInt(
                            u32,
                            dest_slice[0..4],
                            @intCast(target_value),
                            target_endian,
                        ),
                        .@"32S" => std.mem.writeInt(
                            i32,
                            dest_slice[0..4],
                            @intCast(@as(i64, @bitCast(target_value))),
                            target_endian,
                        ),
                        .TLSLD => std.mem.writeInt(
                            i32,
                            dest_slice[0..4],
                            @intCast(@as(i64, @bitCast(
                                elf.shndx.got.vaddr(elf) +%
                                    @as(u64, @bitCast(reloc.addend)) +%
                                    @as(u64, 8) * elf.got.tlsld.unwrap().? -%
                                    dest_vaddr,
                            ))),
                            target_endian,
                        ),
                        .DTPOFF32 => std.mem.writeInt(
                            i32,
                            dest_slice[0..4],
                            @intCast(@as(i64, @bitCast(target_value))),
                            target_endian,
                        ),
                        .TPOFF32 => {
                            const phdr = @field(elf.phdrSlice(), @tagName(class));
                            const ph = &phdr[elf.getNode(elf.ni.tls).segment];
                            assert(elf.targetLoad(&ph.type) == .TLS);
                            std.mem.writeInt(
                                i32,
                                dest_slice[0..4],
                                @intCast(@as(i64, @bitCast(target_value -% elf.targetLoad(&ph.memsz)))),
                                target_endian,
                            );
                        },
                        .SIZE32 => std.mem.writeInt(
                            u32,
                            dest_slice[0..4],
                            @intCast(
                                elf.targetLoad(&target_sym.size) +% @as(u64, @bitCast(reloc.addend)),
                            ),
                            target_endian,
                        ),
                        .SIZE64 => std.mem.writeInt(
                            u64,
                            dest_slice[0..8],
                            elf.targetLoad(&target_sym.size) +% @as(u64, @bitCast(reloc.addend)),
                            target_endian,
                        ),
                    },
                }
            },
        }
    }

    pub fn delete(reloc: *Reloc, elf: *Elf) void {
        switch (reloc.prev) {
            .none => {
                const target_ptr = reloc.target.index(elf).ptr(elf);
                assert(target_ptr.first_target_reloc.get(elf) == reloc);
                target_ptr.first_target_reloc = reloc.next;
            },
            else => |prev| prev.get(elf).next = reloc.next,
        }
        switch (reloc.next) {
            .none => {},
            else => |next| next.get(elf).prev = reloc.prev,
        }
        switch (elf.ehdrField(.type)) {
            .NONE, .CORE, _ => unreachable,
            .REL => {
                const sh = elf.getNodeShndx(reloc.node).get(elf);
                switch (elf.shdrPtr(sh.rela_shndx)) {
                    inline else => |shdr, class| {
                        const Rela = class.ElfN().Rela;
                        const ent_size = elf.targetLoad(&shdr.entsize);
                        const start = ent_size * reloc.index.unwrap().?;
                        const rela_slice = sh.rela_shndx.get(elf).ni.slice(&elf.mf);
                        const rela: *Rela = @ptrCast(@alignCast(
                            rela_slice[@intCast(start)..][0..@intCast(ent_size)],
                        ));
                        rela.* = .{
                            .offset = @intFromEnum(sh.rela_free),
                            .info = .{
                                .type = @intCast(Reloc.Type.none(elf).unwrap(elf)),
                                .sym = 0,
                            },
                            .addend = 0,
                        };
                    },
                }
                sh.rela_free = reloc.index;
            },
            .EXEC, .DYN => assert(reloc.index == .none),
        }
        reloc.* = undefined;
    }

    fn updateTargetIndex(reloc: *const Reloc, elf: *Elf) void {
        assert(elf.ehdrField(.type) == .REL);
        const sh = elf.getNodeShndx(reloc.node).get(elf);
        switch (elf.shdrPtr(sh.rela_shndx)) {
            inline else => |shdr, class| {
                assert(elf.targetLoad(&shdr.entsize) == @sizeOf(class.ElfN().Rela));
                const size = elf.targetLoad(&shdr.size);
                const raw_rela_slice = sh.rela_shndx.get(elf).ni.slice(&elf.mf);
                const rela_slice: []class.ElfN().Rela = @ptrCast(@alignCast(raw_rela_slice[0..@intCast(size)]));
                elf.targetStore(&rela_slice[reloc.index.unwrap().?].info, .{
                    .type = @intCast(reloc.type.unwrap(elf)),
                    .sym = @intCast(@intFromEnum(reloc.target.index(elf))),
                });
            },
        }
    }

    fn updateNodeOffset(reloc: *const Reloc, elf: *Elf, node_offset: u64) void {
        assert(elf.ehdrField(.type) == .REL);
        const total_offset = node_offset + reloc.offset;
        const sh = elf.getNodeShndx(reloc.node).get(elf);
        switch (elf.shdrPtr(sh.rela_shndx)) {
            inline else => |shdr, class| {
                assert(elf.targetLoad(&shdr.entsize) == @sizeOf(class.ElfN().Rela));
                const size = elf.targetLoad(&shdr.size);
                const raw_rela_slice = sh.rela_shndx.get(elf).ni.slice(&elf.mf);
                const rela_slice: []class.ElfN().Rela = @ptrCast(@alignCast(raw_rela_slice[0..@intCast(size)]));
                elf.targetStore(&rela_slice[reloc.index.unwrap().?].offset, @intCast(total_offset));
            },
        }
    }

    comptime {
        if (!std.debug.runtime_safety) std.debug.assert(@sizeOf(Reloc) == 40);
    }
};

pub fn open(
    arena: std.mem.Allocator,
    comp: *Compilation,
    path: std.Build.Cache.Path,
    options: link.File.OpenOptions,
) !*Elf {
    return create(arena, comp, path, options);
}
pub fn createEmpty(
    arena: std.mem.Allocator,
    comp: *Compilation,
    path: std.Build.Cache.Path,
    options: link.File.OpenOptions,
) !*Elf {
    return create(arena, comp, path, options);
}
fn create(
    arena: std.mem.Allocator,
    comp: *Compilation,
    path: std.Build.Cache.Path,
    options: link.File.OpenOptions,
) !*Elf {
    const io = comp.io;
    const target = &comp.root_mod.resolved_target.result;
    assert(target.ofmt == .elf);
    const class: std.elf.CLASS = switch (target.ptrBitWidth()) {
        0...32 => .@"32",
        33...64 => .@"64",
        else => return error.UnsupportedELFArchitecture,
    };
    const data: std.elf.DATA = switch (target.cpu.arch.endian()) {
        .little => .@"2LSB",
        .big => .@"2MSB",
    };
    const osabi: std.elf.OSABI = switch (target.os.tag) {
        else => if (target.abi.isGnu()) .GNU else .NONE,
        .freestanding, .other => .STANDALONE,
        .netbsd => .NETBSD,
        .illumos => .SOLARIS,
        .freebsd, .ps4 => .FREEBSD,
        .openbsd => .OPENBSD,
        .cuda => .CUDA,
        .amdhsa => .AMDGPU_HSA,
        .amdpal => .AMDGPU_PAL,
        .mesa3d => .AMDGPU_MESA3D,
    };
    const @"type": std.elf.ET = switch (comp.config.output_mode) {
        .Exe => if (comp.config.pie or target.os.tag == .haiku) .DYN else .EXEC,
        .Lib => switch (comp.config.link_mode) {
            .static => .REL,
            .dynamic => .DYN,
        },
        .Obj => .REL,
    };
    const machine = target.toElfMachine();
    const maybe_interp = switch (comp.config.link_mode) {
        .static => null,
        .dynamic => switch (comp.config.output_mode) {
            .Exe => target.dynamic_linker.get(),
            .Lib => if (comp.root_mod.resolved_target.is_explicit_dynamic_linker)
                target.dynamic_linker.get()
            else
                null,
            .Obj => null,
        },
    };

    const elf = try arena.create(Elf);
    const file = try path.root_dir.handle.createFile(io, path.sub_path, .{
        .read = true,
        .permissions = link.File.determinePermissions(comp.config.output_mode, comp.config.link_mode),
    });
    errdefer file.close(io);
    elf.* = .{
        .base = .{
            .tag = .elf2,

            .comp = comp,
            .emit = path,

            .file = file,
            .gc_sections = false,
            .print_gc_sections = false,
            .build_id = .none,
            .allow_shlib_undefined = false,
            .stack_size = 0,
        },
        .options = options,
        .mf = try .init(file, comp.gpa, io),
        .ni = .{
            .tls = .none,
        },
        .nodes = .empty,
        .shdrs = .empty,
        .phdrs = .empty,
        .shndx = .{
            .got = .UNDEF,
            .got_plt = .UNDEF,
            .plt = .UNDEF,
            .plt_sec = .UNDEF,
            .dynsym = .UNDEF,
            .dynstr = .UNDEF,
            .dynamic = .UNDEF,
            .tdata = .UNDEF,
            .init_array = .UNDEF,
            .fini_array = .UNDEF,
            .preinit_array = .UNDEF,
        },
        .symtab = .empty,
        .globals = .{
            .strong_def = .empty,
            .weak_def = .empty,
            .strong_undef = .empty,
            .weak_undef = .empty,
        },
        .node_global_symbols = .empty,
        .shstrtab = .{ .map = .empty },
        .strtab = .{ .map = .empty },
        .dynstr = .{ .map = .empty },
        .got = .{
            .len = 0,
            .tlsld = .none,
            .plt = .empty,
        },
        .first_plt_reloc = .none,
        .first_dynamic_reloc = .none,
        .needed = .empty,
        .inputs = .empty,
        .input_sections = .empty,
        .input_section_pending_index = 0,
        .navs = .empty,
        .uavs = .empty,
        .lazy = comptime .initFill(.{
            .map = .empty,
            .pending_index = 0,
        }),
        .pending_uavs = .empty,
        .relocs = .empty,
        .section_by_name = .empty,
        .changed_symtab_index = .empty,
        .const_prog_node = .none,
        .synth_prog_node = .none,
        .input_prog_node = .none,
    };
    errdefer elf.deinit();

    try elf.initHeaders(class, data, osabi, @"type", machine, maybe_interp);
    return elf;
}

pub fn deinit(elf: *Elf) void {
    const gpa = elf.base.comp.gpa;
    elf.mf.deinit(gpa);
    elf.nodes.deinit(gpa);
    elf.shdrs.deinit(gpa);
    elf.phdrs.deinit(gpa);
    elf.symtab.deinit(gpa);
    elf.globals.strong_def.deinit(gpa);
    elf.globals.weak_def.deinit(gpa);
    elf.globals.strong_undef.deinit(gpa);
    elf.globals.weak_undef.deinit(gpa);
    elf.node_global_symbols.deinit(gpa);
    elf.shstrtab.map.deinit(gpa);
    elf.strtab.map.deinit(gpa);
    elf.dynstr.map.deinit(gpa);
    elf.got.plt.deinit(gpa);
    elf.needed.deinit(gpa);
    for (elf.inputs.items) |input| if (input.member) |m| gpa.free(m);
    elf.inputs.deinit(gpa);
    elf.input_sections.deinit(gpa);
    elf.navs.deinit(gpa);
    elf.uavs.deinit(gpa);
    for (&elf.lazy.values) |*lazy| lazy.map.deinit(gpa);
    elf.pending_uavs.deinit(gpa);
    elf.relocs.deinit(gpa);
    elf.section_by_name.deinit(gpa);
    elf.changed_symtab_index.deinit(gpa);
    elf.* = undefined;
}

fn initHeaders(
    elf: *Elf,
    class: std.elf.CLASS,
    data: std.elf.DATA,
    osabi: std.elf.OSABI,
    @"type": std.elf.ET,
    machine: std.elf.EM,
    maybe_interp: ?[]const u8,
) !void {
    const comp = elf.base.comp;
    const gpa = comp.gpa;
    const have_dynamic_section = switch (@"type") {
        .NONE, .CORE, _ => unreachable,
        .REL => false,
        .EXEC => comp.config.link_mode == .dynamic,
        .DYN => true,
    };
    const addr_align: std.mem.Alignment = switch (class) {
        .NONE, _ => unreachable,
        .@"32" => .@"4",
        .@"64" => .@"8",
    };

    const shnum: u32 = 1;
    var phnum: u32 = 0;
    const phdr_phndx = phnum;
    phnum += 1;
    const interp_phndx = if (maybe_interp) |_| phndx: {
        defer phnum += 1;
        break :phndx phnum;
    } else undefined;
    const rodata_phndx = phnum;
    phnum += 1;
    const text_phndx = phnum;
    phnum += 1;
    const data_phndx = phnum;
    phnum += 1;
    const tls_phndx = if (comp.config.any_non_single_threaded) phndx: {
        defer phnum += 1;
        break :phndx phnum;
    } else undefined;
    const dynamic_phndx = if (have_dynamic_section) phndx: {
        defer phnum += 1;
        break :phndx phnum;
    } else undefined;
    const relro_phndx = phnum;
    phnum += 1;

    const expected_nodes_len = expected_nodes_len: switch (@"type") {
        .NONE, .CORE, _ => unreachable,
        .REL => {
            // Each phdr is actually going to be an shdr.
            defer phnum = 0;
            break :expected_nodes_len 5 + phnum;
        },
        .EXEC, .DYN => break :expected_nodes_len 10 +
            phnum * 2 - 1 + // each phdr also has a matching shdr, except for the PT_PHDR phdr
            @as(usize, 4) * @intFromBool(have_dynamic_section), // .dynstr, .dynsym, .rela.dyn, .rela.plt
    };
    try elf.nodes.ensureTotalCapacity(gpa, expected_nodes_len);
    try elf.shdrs.ensureTotalCapacity(gpa, shnum);
    try elf.phdrs.resize(gpa, phnum);
    try elf.symtab.ensureTotalCapacity(gpa, 1);
    elf.nodes.appendAssumeCapacity(.file);

    switch (class) {
        .NONE, _ => unreachable,
        inline else => |ct_class| {
            const ElfN = ct_class.ElfN();
            assert(elf.ni.ehdr == try elf.mf.addOnlyChildNode(gpa, elf.ni.file, .{
                .size = @sizeOf(ElfN.Ehdr),
                .alignment = addr_align,
                .fixed = true,
            }));
            elf.nodes.appendAssumeCapacity(.ehdr);

            const ehdr: *ElfN.Ehdr = @ptrCast(@alignCast(elf.ni.ehdr.slice(&elf.mf)));
            ehdr.ident = .{
                .class = class,
                .data = data,
                .version = 1,
                .osabi = osabi,
                .abiversion = 0,
            };
            ehdr.type = @"type";
            ehdr.machine = machine;
            ehdr.version = 1;
            ehdr.entry = 0;
            ehdr.phoff = 0;
            ehdr.shoff = 0;
            ehdr.flags = 0;
            ehdr.ehsize = @sizeOf(ElfN.Ehdr);
            ehdr.phentsize = @sizeOf(ElfN.Phdr);
            ehdr.phnum = @min(phnum, std.elf.PN_XNUM);
            ehdr.shentsize = @sizeOf(ElfN.Shdr);
            ehdr.shnum = if (shnum < std.elf.SHN_LORESERVE) shnum else 0;
            ehdr.shstrndx = std.elf.SHN_UNDEF;
            if (elf.targetEndian() != native_endian) std.mem.byteSwapAllFields(ElfN.Ehdr, ehdr);
        },
    }

    assert(elf.ni.shdr == try elf.mf.addLastChildNode(gpa, elf.ni.file, .{
        .size = @as(u64, elf.ehdrField(.shentsize)) * @as(u64, elf.ehdrField(.shnum)),
        .alignment = elf.mf.flags.block_size,
        .moved = true,
        .resized = true,
    }));
    elf.nodes.appendAssumeCapacity(.shdr);

    var ph_vaddr: u32 = if (@"type" != .REL) ph_vaddr: {
        assert(elf.ni.rodata == try elf.mf.addLastChildNode(gpa, elf.ni.file, .{
            .alignment = elf.mf.flags.block_size,
            .moved = true,
            .bubbles_moved = false,
        }));
        elf.nodes.appendAssumeCapacity(.{ .segment = rodata_phndx });
        elf.phdrs.items[rodata_phndx] = elf.ni.rodata;

        assert(elf.ni.phdr == try elf.mf.addOnlyChildNode(gpa, elf.ni.rodata, .{
            .size = elf.ehdrField(.phentsize) * elf.ehdrField(.phnum),
            .alignment = addr_align,
            .moved = true,
            .resized = true,
            .bubbles_moved = false,
        }));
        elf.nodes.appendAssumeCapacity(.{ .segment = phdr_phndx });
        elf.phdrs.items[phdr_phndx] = elf.ni.phdr;

        assert(elf.ni.text == try elf.mf.addLastChildNode(gpa, elf.ni.file, .{
            .alignment = elf.mf.flags.block_size,
            .moved = true,
            .bubbles_moved = false,
        }));
        elf.nodes.appendAssumeCapacity(.{ .segment = text_phndx });
        elf.phdrs.items[text_phndx] = elf.ni.text;

        assert(elf.ni.data == try elf.mf.addLastChildNode(gpa, elf.ni.file, .{
            .alignment = elf.mf.flags.block_size,
            .moved = true,
            .bubbles_moved = false,
        }));
        elf.nodes.appendAssumeCapacity(.{ .segment = data_phndx });
        elf.phdrs.items[data_phndx] = elf.ni.data;

        assert(elf.ni.data_rel_ro == try elf.mf.addOnlyChildNode(gpa, elf.ni.data, .{
            .alignment = elf.mf.flags.block_size,
            .moved = true,
            .bubbles_moved = false,
        }));
        elf.nodes.appendAssumeCapacity(.{ .segment = relro_phndx });
        elf.phdrs.items[relro_phndx] = elf.ni.data_rel_ro;

        break :ph_vaddr switch (elf.ehdrField(.type)) {
            .NONE, .CORE, _ => unreachable,
            .REL, .DYN => 0,
            .EXEC => switch (machine) {
                .@"386" => 0x400000,
                .AARCH64, .X86_64 => 0x200000,
                .PPC, .PPC64 => 0x10000000,
                .S390, .S390_OLD => 0x1000000,
                .OLD_SPARCV9, .SPARCV9 => 0x100000,
                else => 0x10000,
            },
        };
    } else undefined;
    switch (class) {
        .NONE, _ => unreachable,
        inline else => |ct_class| {
            const ElfN = ct_class.ElfN();
            const target_endian = elf.targetEndian();

            if (@"type" != .REL) {
                const phdr: []ElfN.Phdr = @ptrCast(@alignCast(elf.ni.phdr.slice(&elf.mf)));
                const ph_phdr = &phdr[phdr_phndx];
                ph_phdr.* = .{
                    .type = .PHDR,
                    .offset = 0,
                    .vaddr = 0,
                    .paddr = 0,
                    .filesz = 0,
                    .memsz = 0,
                    .flags = .{ .R = true },
                    .@"align" = @intCast(elf.ni.phdr.alignment(&elf.mf).toByteUnits()),
                };
                if (target_endian != native_endian) std.mem.byteSwapAllFields(ElfN.Phdr, ph_phdr);

                if (maybe_interp) |_| {
                    const ph_interp = &phdr[interp_phndx];
                    ph_interp.* = .{
                        .type = .INTERP,
                        .offset = 0,
                        .vaddr = 0,
                        .paddr = 0,
                        .filesz = 0,
                        .memsz = 0,
                        .flags = .{ .R = true },
                        .@"align" = 1,
                    };
                    if (target_endian != native_endian) std.mem.byteSwapAllFields(ElfN.Phdr, ph_interp);
                }

                _, const rodata_size = elf.ni.rodata.location(&elf.mf).resolve(&elf.mf);
                const ph_rodata = &phdr[rodata_phndx];
                ph_rodata.* = .{
                    .type = if (rodata_size == 0) .NULL else .LOAD,
                    .offset = 0,
                    .vaddr = ph_vaddr,
                    .paddr = ph_vaddr,
                    .filesz = @intCast(rodata_size),
                    .memsz = @intCast(rodata_size),
                    .flags = .{ .R = true },
                    .@"align" = @intCast(elf.ni.rodata.alignment(&elf.mf).toByteUnits()),
                };
                if (target_endian != native_endian) std.mem.byteSwapAllFields(ElfN.Phdr, ph_rodata);
                ph_vaddr += @intCast(rodata_size);

                _, const text_size = elf.ni.text.location(&elf.mf).resolve(&elf.mf);
                const ph_text = &phdr[text_phndx];
                ph_text.* = .{
                    .type = if (text_size == 0) .NULL else .LOAD,
                    .offset = 0,
                    .vaddr = ph_vaddr,
                    .paddr = ph_vaddr,
                    .filesz = @intCast(text_size),
                    .memsz = @intCast(text_size),
                    .flags = .{ .R = true, .X = true },
                    .@"align" = @intCast(elf.ni.text.alignment(&elf.mf).toByteUnits()),
                };
                if (target_endian != native_endian) std.mem.byteSwapAllFields(ElfN.Phdr, ph_text);
                ph_vaddr += @intCast(text_size);

                _, const data_size = elf.ni.data.location(&elf.mf).resolve(&elf.mf);
                const ph_data = &phdr[data_phndx];
                ph_data.* = .{
                    .type = if (data_size == 0) .NULL else .LOAD,
                    .offset = 0,
                    .vaddr = ph_vaddr,
                    .paddr = ph_vaddr,
                    .filesz = @intCast(data_size),
                    .memsz = @intCast(data_size),
                    .flags = .{ .R = true, .W = true },
                    .@"align" = @intCast(elf.ni.data.alignment(&elf.mf).toByteUnits()),
                };
                if (target_endian != native_endian) std.mem.byteSwapAllFields(ElfN.Phdr, ph_data);
                ph_vaddr += @intCast(data_size);

                if (comp.config.any_non_single_threaded) {
                    const ph_tls = &phdr[tls_phndx];
                    ph_tls.* = .{
                        .type = .TLS,
                        .offset = 0,
                        .vaddr = 0,
                        .paddr = 0,
                        .filesz = 0,
                        .memsz = 0,
                        .flags = .{ .R = true },
                        .@"align" = @intCast(elf.mf.flags.block_size.toByteUnits()),
                    };
                    if (target_endian != native_endian) std.mem.byteSwapAllFields(ElfN.Phdr, ph_tls);
                }

                if (have_dynamic_section) {
                    const ph_dynamic = &phdr[dynamic_phndx];
                    ph_dynamic.* = .{
                        .type = .DYNAMIC,
                        .offset = 0,
                        .vaddr = 0,
                        .paddr = 0,
                        .filesz = 0,
                        .memsz = 0,
                        .flags = .{ .R = true, .W = true },
                        .@"align" = @intCast(addr_align.toByteUnits()),
                    };
                    if (target_endian != native_endian) std.mem.byteSwapAllFields(ElfN.Phdr, ph_dynamic);
                }

                const ph_relro = &phdr[relro_phndx];
                ph_relro.* = .{
                    .type = .GNU_RELRO,
                    .offset = 0,
                    .vaddr = 0,
                    .paddr = 0,
                    .filesz = 0,
                    .memsz = 0,
                    .flags = .{ .R = true },
                    .@"align" = @intCast(elf.mf.flags.block_size.toByteUnits()),
                };
                if (target_endian != native_endian) std.mem.byteSwapAllFields(ElfN.Phdr, ph_relro);
            }

            const sh_undef: *ElfN.Shdr = @ptrCast(@alignCast(elf.ni.shdr.slice(&elf.mf)));
            sh_undef.* = .{
                .name = @intFromEnum(String(.shstrtab).empty),
                .type = .NULL,
                .flags = .{ .shf = .{} },
                .addr = 0,
                .offset = 0,
                .size = if (shnum < std.elf.SHN_LORESERVE) 0 else shnum,
                .link = 0,
                .info = if (phnum < std.elf.PN_XNUM) 0 else phnum,
                .addralign = 0,
                .entsize = 0,
            };
            if (target_endian != native_endian) std.mem.byteSwapAllFields(ElfN.Shdr, sh_undef);
            elf.shdrs.appendAssumeCapacity(.{ .lsi = .null, .ni = .none, .rela_shndx = .UNDEF, .rela_free = .none });

            elf.symtab.addOneAssumeCapacity().* = .{
                .node = .none,
                .first_target_reloc = .none,
            };
            assert(.symtab == try elf.addSection(elf.ni.file, .{
                .type = .SYMTAB,
                .size = @sizeOf(ElfN.Sym) * 1,
                .addralign = addr_align,
                .entsize = @sizeOf(ElfN.Sym),
                .node_align = elf.mf.flags.block_size,
                .info = 1, // index of first non-local symbol
            }));
            const symtab_null = @field(elf.symPtr(.null), @tagName(ct_class));
            symtab_null.* = .{
                .name = @intFromEnum(String(.strtab).empty),
                .value = 0,
                .size = 0,
                .info = .{ .type = .NOTYPE, .bind = .LOCAL },
                .other = .{ .visibility = .DEFAULT },
                .shndx = std.elf.SHN_UNDEF,
            };
            if (target_endian != native_endian) std.mem.byteSwapAllFields(ElfN.Sym, symtab_null);

            const ehdr = @field(elf.ehdrPtr(), @tagName(ct_class));
            ehdr.shstrndx = ehdr.shnum;
        },
    }
    assert(.shstrtab == try elf.addSection(elf.ni.file, .{
        .type = .STRTAB,
        .size = 1,
        .entsize = 1,
        .node_align = elf.mf.flags.block_size,
    }));
    Section.Index.get(.shstrtab, elf).ni.slice(&elf.mf)[0] = 0;

    try Section.Index.symtab.rename(elf, ".symtab");
    try Section.Index.shstrtab.rename(elf, ".shstrtab");

    assert(.strtab == try elf.addSection(elf.ni.file, .{
        .name = ".strtab",
        .type = .STRTAB,
        .size = 1,
        .entsize = 1,
        .node_align = elf.mf.flags.block_size,
    }));
    Section.Index.get(.strtab, elf).ni.slice(&elf.mf)[0] = 0;
    switch (elf.shdrPtr(.symtab)) {
        inline else => |shdr| elf.targetStore(&shdr.link, @intFromEnum(Section.Index.strtab)),
    }

    assert(.rodata == try elf.addSection(elf.ni.rodata, .{
        .name = ".rodata",
        .flags = .{ .ALLOC = true },
        .addralign = elf.mf.flags.block_size,
    }));
    assert(.text == try elf.addSection(elf.ni.text, .{
        .name = ".text",
        .flags = .{ .ALLOC = true, .EXECINSTR = true },
        .addralign = elf.mf.flags.block_size,
    }));
    assert(.data == try elf.addSection(elf.ni.data, .{
        .name = ".data",
        .flags = .{ .WRITE = true, .ALLOC = true },
        .addralign = elf.mf.flags.block_size,
    }));
    assert(.data_rel_ro == try elf.addSection(elf.ni.data_rel_ro, .{
        .name = ".data.rel.ro",
        .flags = .{ .WRITE = true, .ALLOC = true },
        .addralign = elf.mf.flags.block_size,
    }));
    if (@"type" != .REL) {
        elf.shndx.got = try elf.addSection(elf.ni.data_rel_ro, .{
            .name = ".got",
            .flags = .{ .WRITE = true, .ALLOC = true },
            .addralign = addr_align,
        });
        elf.shndx.got_plt = try elf.addSection(
            if (elf.options.z_now) elf.ni.data_rel_ro else elf.ni.data,
            .{
                .name = ".got.plt",
                .type = .PROGBITS,
                .flags = .{ .WRITE = true, .ALLOC = true },
                .size = switch (machine) {
                    else => @panic(@tagName(machine)),
                    .@"386" => 3 * 4,
                    .X86_64 => 3 * 8,
                },
                .addralign = addr_align,
            },
        );
        const plt_size: std.elf.Xword, const plt_align: std.mem.Alignment, const plt_sec =
            switch (machine) {
                else => @panic(@tagName(machine)),
                .X86_64 => .{ 16, .@"16", true },
            };
        elf.shndx.plt = try elf.addSection(elf.ni.text, .{
            .name = ".plt",
            .type = .PROGBITS,
            .flags = .{ .ALLOC = true, .EXECINSTR = true },
            .size = plt_size,
            .addralign = plt_align,
            .node_align = elf.mf.flags.block_size,
        });
        if (plt_sec) elf.shndx.plt_sec = try elf.addSection(elf.ni.text, .{
            .name = ".plt.sec",
            .flags = .{ .ALLOC = true, .EXECINSTR = true },
            .addralign = plt_align,
            .node_align = elf.mf.flags.block_size,
        });
        if (maybe_interp) |interp| {
            const interp_ni = try elf.mf.addLastChildNode(gpa, elf.ni.rodata, .{
                .size = interp.len + 1,
                .moved = true,
                .resized = true,
                .bubbles_moved = false,
            });
            elf.nodes.appendAssumeCapacity(.{ .segment = interp_phndx });
            elf.phdrs.items[interp_phndx] = interp_ni;

            const sec_interp_shndx = try elf.addSection(interp_ni, .{
                .name = ".interp",
                .type = .PROGBITS,
                .flags = .{ .ALLOC = true },
                .size = @intCast(interp.len + 1),
            });
            const sec_interp = sec_interp_shndx.get(elf).ni.slice(&elf.mf);
            @memcpy(sec_interp[0..interp.len], interp);
            sec_interp[interp.len] = 0;
        }
        if (have_dynamic_section) {
            const dynamic_ni = try elf.mf.addLastChildNode(gpa, elf.ni.data_rel_ro, .{
                .alignment = addr_align,
                .moved = true,
                .bubbles_moved = false,
            });
            elf.nodes.appendAssumeCapacity(.{ .segment = dynamic_phndx });
            elf.phdrs.items[dynamic_phndx] = dynamic_ni;

            const dynstr_shndx = try elf.addSection(elf.ni.rodata, .{
                .name = ".dynstr",
                .type = .STRTAB,
                .flags = .{ .ALLOC = true },
                .size = 1,
                .entsize = 1,
                .node_align = elf.mf.flags.block_size,
            });
            dynstr_shndx.get(elf).ni.slice(&elf.mf)[0] = 0;
            elf.shndx.dynstr = dynstr_shndx;

            switch (class) {
                .NONE, _ => unreachable,
                inline else => |ct_class| {
                    const Sym = ct_class.ElfN().Sym;
                    elf.shndx.dynsym = try elf.addSection(elf.ni.rodata, .{
                        .name = ".dynsym",
                        .type = .DYNSYM,
                        .flags = .{ .ALLOC = true },
                        .size = @sizeOf(Sym) * 1,
                        .link = dynstr_shndx.toSection().?,
                        .info = 1,
                        .addralign = addr_align,
                        .entsize = @sizeOf(Sym),
                        .node_align = elf.mf.flags.block_size,
                    });
                    const dynsym_null = @field(elf.dynsymPtr(0), @tagName(ct_class));
                    dynsym_null.* = .{
                        .name = @intFromEnum(String(.dynstr).empty),
                        .value = 0,
                        .size = 0,
                        .info = .{ .type = .NOTYPE, .bind = .LOCAL },
                        .other = .{ .visibility = .DEFAULT },
                        .shndx = std.elf.SHN_UNDEF,
                    };
                    if (elf.targetEndian() != native_endian) std.mem.byteSwapAllFields(
                        Sym,
                        dynsym_null,
                    );
                },
            }
            const rela_size: std.elf.Word = switch (class) {
                .NONE, _ => unreachable,
                inline else => |ct_class| @sizeOf(ct_class.ElfN().Rela),
            };
            elf.shndx.got.get(elf).rela_shndx = try elf.addSection(elf.ni.rodata, .{
                .name = ".rela.dyn",
                .type = .RELA,
                .flags = .{ .ALLOC = true },
                .link = elf.shndx.dynsym.toSection().?,
                .addralign = addr_align,
                .entsize = rela_size,
                .node_align = elf.mf.flags.block_size,
            });
            const got_plt_shndx = elf.shndx.got_plt;
            got_plt_shndx.get(elf).rela_shndx = try elf.addSection(elf.ni.rodata, .{
                .name = ".rela.plt",
                .type = .RELA,
                .flags = .{ .ALLOC = true, .INFO_LINK = true },
                .link = elf.shndx.dynsym.toSection().?,
                .info = got_plt_shndx.toSection().?,
                .addralign = addr_align,
                .entsize = rela_size,
                .node_align = elf.mf.flags.block_size,
            });
            elf.shndx.dynamic = try elf.addSection(dynamic_ni, .{
                .name = ".dynamic",
                .type = .DYNAMIC,
                .flags = .{ .ALLOC = true, .WRITE = true },
                .link = dynstr_shndx.toSection().?,
                .entsize = @intCast(addr_align.toByteUnits() * 2),
                .node_align = addr_align,
            });
            switch (machine) {
                else => @panic(@tagName(machine)),
                .X86_64 => {
                    const plt_ni = elf.shndx.plt.get(elf).ni;
                    const got_plt_sym: Symbol.Id = .local(elf.shndx.got_plt.get(elf).lsi);
                    @memcpy(plt_ni.slice(&elf.mf)[0..16], &[16]u8{
                        0xff, 0x35, 0x00, 0x00, 0x00, 0x00, // push 0x0(%rip)
                        0xff, 0x25, 0x00, 0x00, 0x00, 0x00, // jmp *0x0(%rip)
                        0x0f, 0x1f, 0x40, 0x00, // nopl 0x0(%rax)
                    });
                    elf.first_plt_reloc = @enumFromInt(elf.relocs.items.len);
                    try elf.ensureUnusedRelocCapacity(plt_ni, 2);
                    elf.addRelocAssumeCapacity(
                        plt_ni,
                        2,
                        got_plt_sym,
                        8 * 1 - 4,
                        .{ .X86_64 = .PC32 },
                    );
                    elf.addRelocAssumeCapacity(
                        plt_ni,
                        8,
                        got_plt_sym,
                        8 * 2 - 4,
                        .{ .X86_64 = .PC32 },
                    );
                },
            }
        }
        if (comp.config.any_non_single_threaded) {
            elf.ni.tls = try elf.mf.addLastChildNode(gpa, elf.ni.rodata, .{
                .alignment = elf.mf.flags.block_size,
                .moved = true,
                .bubbles_moved = false,
            });
            elf.nodes.appendAssumeCapacity(.{ .segment = tls_phndx });
            elf.phdrs.items[tls_phndx] = elf.ni.tls;
        }
    } else {
        assert(maybe_interp == null);
        assert(!have_dynamic_section);
    }
    if (comp.config.any_non_single_threaded) elf.shndx.tdata = try elf.addSection(elf.ni.tls, .{
        .name = ".tdata",
        .flags = .{ .WRITE = true, .ALLOC = true, .TLS = true },
        .addralign = elf.mf.flags.block_size,
    });
    assert(elf.nodes.len == expected_nodes_len);

    try elf.section_by_name.ensureUnusedCapacity(gpa, elf.shdrs.items.len);
    for (0..elf.shdrs.items.len) |shndx_raw| {
        const shndx: Section.Index = @enumFromInt(shndx_raw);
        elf.section_by_name.putAssumeCapacityNoClobber(shndx.name(elf), {});
    }
}

pub fn startProgress(elf: *Elf, prog_node: std.Progress.Node) void {
    prog_node.increaseEstimatedTotalItems(4);
    elf.const_prog_node = prog_node.start("Constants", elf.pending_uavs.items.len);
    elf.synth_prog_node = prog_node.start("Synthetics", count: {
        var count: usize = 0;
        for (&elf.lazy.values) |*lazy| count += lazy.map.count() - lazy.pending_index;
        break :count count;
    });
    elf.mf.update_prog_node = prog_node.start("Relocations", elf.mf.updates.items.len);
    elf.input_prog_node = prog_node.start(
        "Inputs",
        elf.input_sections.items.len - elf.input_section_pending_index,
    );
}

pub fn endProgress(elf: *Elf) void {
    elf.input_prog_node.end();
    elf.input_prog_node = .none;
    elf.mf.update_prog_node.end();
    elf.mf.update_prog_node = .none;
    elf.synth_prog_node.end();
    elf.synth_prog_node = .none;
    elf.const_prog_node.end();
    elf.const_prog_node = .none;
}

fn getNode(elf: *const Elf, ni: MappedFile.Node.Index) Node {
    return elf.nodes.get(@intFromEnum(ni));
}
/// Asserts that `ni` is a section, input section, NAV, UAV, or lazy code/data.
fn getNodeShndx(elf: *Elf, ni: MappedFile.Node.Index) Section.Index {
    return switch (elf.getNode(ni)) {
        .file => unreachable,
        .ehdr => unreachable,
        .shdr => unreachable,
        .segment => unreachable,

        .section => |shndx| shndx,

        .input_section,
        .nav,
        .uav,
        .lazy_code,
        .lazy_const_data,
        => elf.getNode(ni.parent(&elf.mf)).section,
    };
}
fn computeNodeVAddr(elf: *Elf, ni: MappedFile.Node.Index) u64 {
    const parent_vaddr = switch (elf.getNode(ni.parent(&elf.mf))) {
        .file => return 0,
        .ehdr, .shdr => unreachable,
        .segment => |phndx| switch (elf.phdrSlice()) {
            inline else => |phdr| elf.targetLoad(&phdr[phndx].vaddr),
        },
        .section => |shndx| if (shndx == elf.shndx.tdata) 0 else shndx.vaddr(elf),
        .input_section => unreachable,
        inline .nav, .uav, .lazy_code, .lazy_const_data => |i| Symbol.Id.local(i.symbol(elf)).value(elf),
    };
    const offset, _ = ni.location(&elf.mf).resolve(&elf.mf);
    return parent_vaddr + offset;
}

/// Deletes any existing relocations in the given node, and marks the start of the node's contiguous
/// sequence of relocations, so that the caller may append the node's updated relocations.
///
/// Asserts that `ni` must be a node which supports relocations (see `Elf.Node`). Does not support
/// the special-case sections '.plt' and '.dynamic'.
fn resetNodeRelocs(elf: *Elf, ni: MappedFile.Node.Index) void {
    const first_reloc_ptr: *Reloc.Index = switch (elf.getNode(ni)) {
        .file => unreachable, // cannot contain relocs
        .ehdr => unreachable, // cannot contain relocs
        .shdr => unreachable, // cannot contain relocs
        .segment => unreachable, // cannot contain relocs
        .section => unreachable, // cannot contain relocs (.plt and .dynamic unsupported)
        .input_section => |isi| &elf.input_sections.items[@intFromEnum(isi)].first_reloc,
        .nav => |nmi| &elf.navs.values()[@intFromEnum(nmi)].first_reloc,
        .uav => |umi| &elf.uavs.values()[@intFromEnum(umi)].first_reloc,
        inline .lazy_code, .lazy_const_data => |lmi| &elf.lazy.getPtr(lmi.ref().kind).map.values()[lmi.ref().index].first_reloc,
    };
    if (first_reloc_ptr.* != .none) {
        for (elf.relocs.items[@intFromEnum(first_reloc_ptr.*)..]) |*reloc| {
            if (reloc.node != ni) break;
            reloc.delete(elf);
        }
    }
    first_reloc_ptr.* = @enumFromInt(elf.relocs.items.len);
}

/// Given that `node` has moved, updates all relocations in `node` (starting from `first_reloc`) as
/// needed. In relocatables, this means updating the offsets of those relocations. In ELF modules,
/// this means applying the relocations.
fn flushMovedNodeRelocs(
    elf: *Elf,
    node: MappedFile.Node.Index,
    node_vaddr: u64,
    first_reloc: Reloc.Index,
) void {
    if (first_reloc == .none) return;
    switch (elf.ehdrField(.type)) {
        .NONE, .CORE, _ => unreachable,
        .REL => {
            // In a relocatable, we're not actually applying any relocations ourselves, but we need
            // to update the offsets of the relocation entries since the node they're in has moved.
            for (elf.relocs.items[@intFromEnum(first_reloc)..]) |*reloc| {
                if (reloc.node != node) break;
                reloc.updateNodeOffset(elf, node_vaddr);
            }
        },
        .EXEC, .DYN => {
            // For an ELF module, we just need to apply relocations.
            for (elf.relocs.items[@intFromEnum(first_reloc)..]) |*reloc| {
                if (reloc.node != node) break;
                reloc.apply(elf);
            }
            // TODO: once we're emitting runtime relocation entries, we need to update their offsets
            // too, like the logic for relocatables above.
        },
    }
}

fn identClass(elf: *const Elf) std.elf.CLASS {
    return @enumFromInt(elf.mf.memory_map.memory[std.elf.EI.CLASS]);
}
fn identData(elf: *const Elf) std.elf.DATA {
    return @enumFromInt(elf.mf.memory_map.memory[std.elf.EI.DATA]);
}

fn targetEndian(elf: *const Elf) std.lang.Endian {
    return switch (elf.identData()) {
        .NONE, _ => unreachable,
        .@"2LSB" => .little,
        .@"2MSB" => .big,
    };
}
fn targetLoad(elf: *const Elf, ptr: anytype) @typeInfo(@TypeOf(ptr)).pointer.child {
    const Child = @typeInfo(@TypeOf(ptr)).pointer.child;
    return switch (@typeInfo(Child)) {
        else => @compileError(@typeName(Child)),
        .int => std.mem.toNative(Child, ptr.*, elf.targetEndian()),
        .@"enum" => |@"enum"| @enumFromInt(elf.targetLoad(@as(*@"enum".tag_type, @ptrCast(ptr)))),
        .@"struct" => |@"struct"| @bitCast(
            elf.targetLoad(@as(*@"struct".backing_integer.?, @ptrCast(ptr))),
        ),
    };
}
fn targetStore(elf: *const Elf, ptr: anytype, val: @typeInfo(@TypeOf(ptr)).pointer.child) void {
    const Child = @typeInfo(@TypeOf(ptr)).pointer.child;
    return switch (@typeInfo(Child)) {
        else => @compileError(@typeName(Child)),
        .int => ptr.* = std.mem.nativeTo(Child, val, elf.targetEndian()),
        .@"enum" => |@"enum"| elf.targetStore(
            @as(*@"enum".tag_type, @ptrCast(ptr)),
            @intFromEnum(val),
        ),
        .@"struct" => |@"struct"| elf.targetStore(
            @as(*@"struct".backing_integer.?, @ptrCast(ptr)),
            @bitCast(val),
        ),
    };
}

const EhdrPtr = union(std.elf.CLASS) {
    NONE: noreturn,
    @"32": *std.elf.Elf32.Ehdr,
    @"64": *std.elf.Elf64.Ehdr,
};
fn ehdrPtr(elf: *Elf) EhdrPtr {
    const slice = elf.ni.ehdr.slice(&elf.mf);
    return switch (elf.identClass()) {
        .NONE, _ => unreachable,
        inline else => |class| @unionInit(
            EhdrPtr,
            @tagName(class),
            @ptrCast(@alignCast(slice)),
        ),
    };
}
fn ehdrField(
    elf: *Elf,
    comptime field: std.meta.FieldEnum(std.elf.Elf64.Ehdr),
) @FieldType(std.elf.Elf64.Ehdr, @tagName(field)) {
    return switch (elf.ehdrPtr()) {
        inline else => |ehdr| elf.targetLoad(&@field(ehdr, @tagName(field))),
    };
}

const PhdrSlice = union(std.elf.CLASS) {
    NONE: noreturn,
    @"32": []std.elf.Elf32.Phdr,
    @"64": []std.elf.Elf64.Phdr,
};
fn phdrSlice(elf: *Elf) PhdrSlice {
    assert(elf.ehdrField(.type) != .REL);
    const slice = elf.ni.phdr.slice(&elf.mf);
    return switch (elf.identClass()) {
        .NONE, _ => unreachable,
        inline else => |class| @unionInit(
            PhdrSlice,
            @tagName(class),
            @ptrCast(@alignCast(slice)),
        ),
    };
}

const ShdrPtr = union(std.elf.CLASS) {
    NONE: noreturn,
    @"32": *std.elf.Elf32.Shdr,
    @"64": *std.elf.Elf64.Shdr,
};
fn shdrPtr(elf: *Elf, shndx: Section.Index) ShdrPtr {
    const raw_slice = elf.ni.shdr.slice(&elf.mf);
    switch (elf.identClass()) {
        .NONE, _ => unreachable,
        inline else => |class| {
            const shdr_slice: []class.ElfN().Shdr = @ptrCast(@alignCast(raw_slice));
            const shdr_ptr = &shdr_slice[@intFromEnum(shndx)];
            return @unionInit(ShdrPtr, @tagName(class), shdr_ptr);
        },
    }
}

const SymPtr = union(std.elf.CLASS) {
    NONE: noreturn,
    @"32": *std.elf.Elf32.Sym,
    @"64": *std.elf.Elf64.Sym,
};
fn symPtr(elf: *Elf, index: Symbol.Index) SymPtr {
    const raw_slice = Section.Index.symtab.get(elf).ni.slice(&elf.mf);
    switch (elf.shdrPtr(.symtab)) {
        inline else => |shdr, class| {
            const size = elf.targetLoad(&shdr.size);
            const slice: []class.ElfN().Sym = @ptrCast(@alignCast(raw_slice[0..@intCast(size)]));
            return @unionInit(SymPtr, @tagName(class), &slice[@intFromEnum(index)]);
        },
    }
}
fn dynsymPtr(elf: *Elf, index: u32) SymPtr {
    const raw_slice = elf.shndx.dynsym.get(elf).ni.slice(&elf.mf);
    switch (elf.shdrPtr(elf.shndx.dynsym)) {
        inline else => |shdr, class| {
            const size = elf.targetLoad(&shdr.size);
            const slice: []class.ElfN().Sym = @ptrCast(@alignCast(raw_slice[0..@intCast(size)]));
            return @unionInit(SymPtr, @tagName(class), &slice[index]);
        },
    }
}

fn navType(elf: *const Elf, nav_resolved: InternPool.Nav.Resolved) std.elf.STT {
    const any_non_single_threaded = elf.base.comp.config.any_non_single_threaded;
    return if (any_non_single_threaded and nav_resolved.@"threadlocal")
        .TLS
    else if (elf.base.comp.zcu.?.intern_pool.isFunctionType(nav_resolved.type))
        .FUNC
    else
        .OBJECT;
}
fn mapInputSection(elf: *Elf, opts: struct {
    name: []const u8,
    flags: std.elf.SHF,
    addralign: std.elf.Xword,
    entsize: std.elf.Xword,
}) !Section.Index {
    const gpa = elf.base.comp.gpa;
    if (opts.flags.INFO_LINK or
        opts.flags.LINK_ORDER or
        opts.flags.OS_NONCONFORMING or
        (opts.flags.EXECINSTR and opts.flags.WRITE) or
        (opts.flags.EXECINSTR and opts.flags.TLS))
    {
        return error.UnsupportedSectionFlags;
    }
    if (opts.flags.TLS and elf.ni.tls == .none) {
        assert(!elf.base.comp.config.any_non_single_threaded);
        return error.TlsSectionUnavailable;
    }
    const name: []const u8 = switch (elf.ehdrField(.type)) {
        .NONE, .CORE, _ => unreachable,
        .REL => opts.name,
        .EXEC, .DYN => name: {
            if (std.mem.startsWith(u8, opts.name, ".text.")) break :name ".text";
            if (std.mem.startsWith(u8, opts.name, ".rodata.")) break :name ".rodata";
            if (std.mem.startsWith(u8, opts.name, ".data.")) break :name ".data";
            if (std.mem.startsWith(u8, opts.name, ".data.rel.ro.")) break :name ".data.rel.ro";
            if (std.mem.startsWith(u8, opts.name, ".tdata.")) break :name ".tdata";
            if (std.mem.startsWith(u8, opts.name, ".gcc_except_table.")) break :name ".gcc_except_table";
            // TODO: actually generate a bss section!
            if (std.mem.eql(u8, opts.name, ".bss")) break :name ".data";
            if (std.mem.startsWith(u8, opts.name, ".bss.")) break :name ".data";
            // TODO: actually generate a tbss section!
            if (std.mem.eql(u8, opts.name, ".tbss")) break :name ".tdata";
            if (std.mem.startsWith(u8, opts.name, ".tbss.")) break :name ".tdata";
            break :name opts.name;
        },
    };
    const existing_shndx: Section.Index = existing: {
        const name_shstrtab = try elf.string(.shstrtab, name);
        const gop = try elf.section_by_name.getOrPut(gpa, name_shstrtab);
        if (gop.found_existing) {
            break :existing @enumFromInt(gop.index);
        }
        errdefer assert(elf.section_by_name.pop().?.key == name_shstrtab);
        const parent_node: MappedFile.Node.Index = parent: {
            if (!opts.flags.ALLOC) break :parent elf.ni.file;
            if (opts.flags.EXECINSTR) break :parent elf.ni.text;
            if (opts.flags.TLS) break :parent elf.ni.tls;
            if (opts.flags.WRITE) break :parent elf.ni.data;
            break :parent elf.ni.rodata;
        };
        assert(gop.index == elf.shdrs.items.len);
        return elf.addSection(parent_node, .{
            .name = name,
            .type = .NULL, // because initial size is 0
            .flags = flags: {
                // We need to decompress the section for linking.
                var flags = opts.flags;
                flags.COMPRESSED = false;
                break :flags flags;
            },
            .node_align = .fromByteUnits(std.math.ceilPowerOfTwoAssert(
                usize,
                @intCast(@max(opts.addralign, 1)),
            )),
            .entsize = std.math.lossyCast(u32, opts.entsize),
        });
    };
    // Validate that the input is compatible with this section...
    switch (elf.shdrPtr(existing_shndx)) {
        inline else => |shdr| {
            const cur_flags = elf.targetLoad(&shdr.flags).shf;
            if (cur_flags.EXECINSTR != opts.flags.EXECINSTR or
                cur_flags.WRITE != opts.flags.WRITE or
                cur_flags.TLS != opts.flags.TLS)
            {
                return error.SectionFlagsConflict;
            }

            switch (elf.targetLoad(&shdr.type)) {
                .NULL, .PROGBITS => {},
                else => return error.SectionTypeConflict,
            }
        },
    }
    // ...then realign the section's node if necessary...
    if (opts.addralign > existing_shndx.get(elf).ni.alignment(&elf.mf).toByteUnits()) {
        const new_alignment: std.mem.Alignment = .fromByteUnits(
            std.math.ceilPowerOfTwoAssert(usize, @intCast(opts.addralign)),
        );
        try existing_shndx.get(elf).ni.realign(&elf.mf, gpa, new_alignment);
    }
    // ...and update the shdr as needed.
    switch (elf.shdrPtr(existing_shndx)) {
        inline else => |shdr| {
            // Combine the section flags.
            const cur_flags = elf.targetLoad(&shdr.flags).shf;
            elf.targetStore(&shdr.flags, .{ .shf = .{
                .EXECINSTR = cur_flags.EXECINSTR,
                .WRITE = cur_flags.WRITE,
                .TLS = cur_flags.TLS,
                .ALLOC = cur_flags.ALLOC or opts.flags.ALLOC,
                .STRINGS = cur_flags.STRINGS and opts.flags.STRINGS,
                .MERGE = cur_flags.MERGE and opts.flags.MERGE,
            } });
            // Increase addralign to the maximum of the current value and the new value---the node
            // alignment was already increased above.
            if (opts.addralign > elf.targetLoad(&shdr.addralign)) {
                elf.targetStore(&shdr.addralign, @intCast(opts.addralign));
            }
        },
    }
    return existing_shndx;
}
fn navMapIndex(elf: *Elf, zcu: *Zcu, nav_index: InternPool.Nav.Index) !Node.NavMapIndex {
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;
    const nav = ip.getNav(nav_index);

    try elf.ensureUnusedSymbolCapacity(1, .all_local);
    try elf.nodes.ensureUnusedCapacity(gpa, 1);
    try elf.navs.ensureUnusedCapacity(gpa, 1);

    const nav_gop = elf.navs.getOrPutAssumeCapacity(nav_index);
    const nmi: Node.NavMapIndex = @enumFromInt(nav_gop.index);
    if (!nav_gop.found_existing) {
        const shndx: Section.Index = section: {
            if (nav.resolved.?.@"linksection".toSlice(ip)) |@"linksection"| {
                if (elf.mapInputSection(.{
                    .name = @"linksection",
                    .flags = .{
                        .ALLOC = true,
                        .EXECINSTR = ip.isFunctionType(nav.resolved.?.type),
                        .WRITE = !nav.resolved.?.@"const",
                        .TLS = elf.base.comp.config.any_non_single_threaded and
                            nav.resolved.?.@"threadlocal",
                    },
                    .addralign = 1,
                    .entsize = 0,
                })) |shndx| {
                    break :section shndx;
                } else |err| switch (err) {
                    error.TlsSectionUnavailable,
                    error.UnsupportedSectionFlags,
                    error.SectionTypeConflict,
                    error.SectionFlagsConflict,
                    => {}, // fall back to default behavior below

                    else => |e| return e,
                }
            }
            if (elf.base.comp.config.any_non_single_threaded and nav.resolved.?.@"threadlocal") {
                break :section elf.shndx.tdata;
            } else if (!nav.resolved.?.@"const") {
                break :section .data;
            } else if (ip.isFunctionType(nav.resolved.?.type)) {
                break :section .text;
            } else {
                break :section .rodata;
            }
        };
        const alignment: InternPool.Alignment = switch (Type.fromInterned(nav.resolved.?.type).zigTypeTag(zcu)) {
            .@"fn" => a: {
                const mod = zcu.navFileScope(nav_index).mod.?;
                const target = &mod.resolved_target.result;
                const min = target_util.minFunctionAlignment(target);
                break :a switch (nav.resolved.?.@"align") {
                    else => |a| a.maxStrict(min),
                    .none => switch (mod.optimize_mode) {
                        .Debug,
                        .ReleaseSafe,
                        .ReleaseFast,
                        => target_util.defaultFunctionAlignment(target),
                        .ReleaseSmall => min,
                    }.maxStrict(Type.fromInterned(nav.resolved.?.type).abiAlignment(zcu)),
                };
            },
            else => switch (nav.resolved.?.@"align") {
                .none => Type.fromInterned(nav.resolved.?.type).abiAlignment(zcu),
                else => |a| a,
            },
        };
        const node = try elf.mf.addLastChildNode(gpa, shndx.get(elf).ni, .{
            .alignment = alignment.toStdMem(),
        });
        nav_gop.value_ptr.* = .{
            .lsi = elf.addLocalSymbolAssumeCapacity(.{
                .node = node,
                .name = try elf.string(.strtab, nav.fqn.toSlice(ip)),
                .value = 0,
                .size = 0,
                .type = elf.navType(nav.resolved.?),
                .shndx = shndx,
            }),
            .first_reloc = .none,
        };
        elf.nodes.appendAssumeCapacity(.{ .nav = nmi });
    }
    return nmi;
}

fn uavMapIndex(
    elf: *Elf,
    uav_val: InternPool.Index,
    uav_align: InternPool.Alignment,
) !Node.UavMapIndex {
    const gpa = elf.base.comp.gpa;
    const zcu = elf.base.comp.zcu.?;

    try elf.ensureUnusedSymbolCapacity(1, .all_local);
    try elf.nodes.ensureUnusedCapacity(gpa, 1);
    try elf.uavs.ensureUnusedCapacity(gpa, 1);
    try elf.pending_uavs.ensureUnusedCapacity(gpa, 1);

    const abi_align = Value.fromInterned(uav_val).typeOf(zcu).abiAlignment(zcu);
    const resolved_align: InternPool.Alignment = switch (uav_align) {
        .none => abi_align,
        else => |a| a.minStrict(abi_align),
    };

    const uav_gop = elf.uavs.getOrPutAssumeCapacity(uav_val);
    const umi: Node.UavMapIndex = @enumFromInt(uav_gop.index);
    if (!uav_gop.found_existing) {
        const shndx: Section.Index = .data;
        const node = try elf.mf.addLastChildNode(gpa, shndx.get(elf).ni, .{
            .moved = true, // see assert at end of `flushUav`
            .alignment = resolved_align.toStdMem(),
        });
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(
            &name_buf,
            "__anon_{d}",
            .{@intFromEnum(uav_val)},
        ) catch unreachable;
        uav_gop.value_ptr.* = .{
            .lsi = elf.addLocalSymbolAssumeCapacity(.{
                .node = node,
                .name = try elf.string(.strtab, name),
                .value = 0,
                .size = 0,
                .type = .OBJECT,
                .shndx = shndx,
            }),
            .first_reloc = .none,
        };
        elf.nodes.appendAssumeCapacity(.{ .uav = umi });
        elf.const_prog_node.increaseEstimatedTotalItems(1);
        elf.pending_uavs.appendAssumeCapacity(umi);
    } else {
        const node = uav_gop.value_ptr.lsi.index().ptr(elf).node;
        if (resolved_align.toStdMem().order(node.alignment(&elf.mf)).compare(.gt)) {
            try node.realign(&elf.mf, gpa, resolved_align.toStdMem());
        }
    }
    return umi;
}

pub fn loadInput(elf: *Elf, input: link.Input) (Io.File.Reader.SizeError ||
    Io.File.Reader.Error || MappedFile.Error || error{ EndOfStream, BadMagic, LinkFailure })!void {
    const io = elf.base.comp.io;
    var buf: [4096]u8 = undefined;
    switch (input) {
        .object => |object| {
            var fr = object.file.reader(io, &buf);
            elf.loadObject(object.path, null, &fr, .{
                .offset = fr.logicalPos(),
                .size = try fr.getSize(),
            }) catch |err| switch (err) {
                error.ReadFailed => return fr.err.?,
                else => |e| return e,
            };
        },
        .archive => |archive| {
            var fr = archive.file.reader(io, &buf);
            elf.loadArchive(archive.path, &fr) catch |err| switch (err) {
                error.ReadFailed => return fr.err.?,
                else => |e| return e,
            };
        },
        .res => unreachable,
        .dso => |dso| {
            try elf.needed.ensureUnusedCapacity(elf.base.comp.gpa, 1);
            var fr = dso.file.reader(io, &buf);
            elf.loadDso(dso.path, &fr) catch |err| switch (err) {
                error.ReadFailed => return fr.err.?,
                else => |e| return e,
            };
        },
        .dso_exact => |dso_exact| try elf.loadDsoExact(dso_exact.name),
    }
}
fn loadArchive(elf: *Elf, path: std.Build.Cache.Path, fr: *Io.File.Reader) !void {
    const comp = elf.base.comp;
    const gpa = comp.gpa;
    const diags = &comp.link_diags;
    const r = &fr.interface;

    log.debug("loadArchive({f})", .{path.fmtEscapeString()});
    if (!std.mem.eql(u8, try r.take(std.elf.ARMAG.len), std.elf.ARMAG)) return error.BadMagic;
    var strtab: std.Io.Writer.Allocating = .init(gpa);
    defer strtab.deinit();
    while (r.takeStruct(std.elf.ar_hdr, native_endian)) |header| {
        if (!std.mem.eql(u8, &header.ar_fmag, std.elf.ARFMAG))
            return diags.failParse(path, "bad file magic", .{});
        const offset = fr.logicalPos();
        const size = header.size() catch
            return diags.failParse(path, "bad member size", .{});
        if (std.mem.eql(u8, &header.ar_name, std.elf.STRNAME)) {
            strtab.clearRetainingCapacity();
            try strtab.ensureTotalCapacityPrecise(size);
            r.streamExact(&strtab.writer, size) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                else => |e| return e,
            };
            continue;
        }
        load_object: {
            if (std.mem.eql(u8, &header.ar_name, std.elf.SYMNAME) or
                std.mem.eql(u8, &header.ar_name, std.elf.SYM64NAME) or
                std.mem.eql(u8, &header.ar_name, std.elf.SYMDEFNAME) or
                std.mem.eql(u8, &header.ar_name, std.elf.SYMDEFSORTEDNAME))
            {
                break :load_object;
            }
            const member = header.name() orelse member: {
                const strtab_offset = header.nameOffset() catch |err| switch (err) {
                    error.Overflow => break :member error.Overflow,
                    error.InvalidCharacter => break :load_object,
                } orelse break :load_object;
                const strtab_written = strtab.written();
                if (strtab_offset > strtab_written.len) break :member error.Overflow;
                const member = std.mem.sliceTo(strtab_written[strtab_offset..], '\n');
                break :member if (std.mem.endsWith(u8, member, "/"))
                    member[0 .. member.len - "/".len]
                else
                    member;
            } catch |err| switch (err) {
                error.Overflow => return diags.failParse(path, "bad member name offset", .{}),
            };
            try elf.loadObject(path, member, fr, .{ .offset = offset, .size = size });
        }
        try fr.seekTo(std.mem.alignForward(u64, offset + size, 2));
    } else |err| switch (err) {
        error.EndOfStream => if (!fr.atEnd()) return error.EndOfStream,
        else => |e| return e,
    }
}
fn fmtMemberString(member: ?[]const u8) std.fmt.Alt(?[]const u8, memberStringEscape) {
    return .{ .data = member };
}
fn memberStringEscape(member: ?[]const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("({f})", .{std.zig.fmtString(member orelse return)});
}
fn loadObject(
    elf: *Elf,
    path: std.Build.Cache.Path,
    member: ?[]const u8,
    fr: *Io.File.Reader,
    fl: MappedFile.Node.FileLocation,
) !void {
    const comp = elf.base.comp;
    const gpa = comp.gpa;
    const diags = &comp.link_diags;
    const r = &fr.interface;

    const input_index: Node.InputIndex = @enumFromInt(elf.inputs.items.len);
    log.debug("loadObject({f}{f})", .{ path.fmtEscapeString(), fmtMemberString(member) });
    try elf.checkInputIdent(path, r);
    try elf.ensureUnusedSymbolCapacity(1, .all_local);
    try elf.inputs.ensureUnusedCapacity(gpa, 1);
    const file_symbol = elf.addLocalSymbolAssumeCapacity(.{
        .node = .none,
        .name = try elf.string(.strtab, std.fs.path.stem(member orelse path.sub_path)),
        .value = 0,
        .size = 0,
        .type = .FILE,
        .shndx = .ABS,
    });
    elf.inputs.addOneAssumeCapacity().* = .{
        .path = path,
        .member = if (member) |m| try gpa.dupe(u8, m) else null,
        .file_symbol = file_symbol,
    };
    const target_endian = elf.targetEndian();
    switch (elf.identClass()) {
        .NONE, _ => unreachable,
        inline else => |class| {
            const ElfN = class.ElfN();
            const ehdr = try r.peekStruct(ElfN.Ehdr, target_endian);
            if (ehdr.type != .REL) return diags.failParse(path, "unsupported object type", .{});
            if (ehdr.machine != elf.ehdrField(.machine))
                return diags.failParse(path, "bad machine", .{});
            if (ehdr.shoff == 0 or ehdr.shnum <= 1) return;
            if (ehdr.shoff + @as(u64, ehdr.shentsize) * @as(u64, ehdr.shnum) > fl.size)
                return diags.failParse(path, "bad section header location", .{});
            if (ehdr.shentsize < @sizeOf(ElfN.Shdr))
                return diags.failParse(path, "unsupported shentsize", .{});
            const sections = try gpa.alloc(struct { shdr: ElfN.Shdr, isi: ?InputSection.Index }, ehdr.shnum);
            defer gpa.free(sections);
            try fr.seekTo(fl.offset + ehdr.shoff);
            for (sections) |*section| {
                section.* = .{
                    .shdr = try r.peekStruct(ElfN.Shdr, target_endian),
                    .isi = null,
                };
                try r.discardAll(ehdr.shentsize);
                switch (section.shdr.type) {
                    .NULL, .NOBITS => {},
                    else => if (section.shdr.offset + section.shdr.size > fl.size)
                        return diags.failParse(path, "bad section location", .{}),
                }
            }
            const shstrtab = shstrtab: {
                if (ehdr.shstrndx == std.elf.SHN_UNDEF or ehdr.shstrndx >= ehdr.shnum)
                    return diags.failParse(path, "missing section names", .{});
                const shdr = &sections[ehdr.shstrndx].shdr;
                if (shdr.type != .STRTAB) return diags.failParse(path, "invalid shstrtab type", .{});
                const shstrtab = try gpa.alloc(u8, @intCast(shdr.size));
                errdefer gpa.free(shstrtab);
                try fr.seekTo(fl.offset + shdr.offset);
                try r.readSliceAll(shstrtab);
                break :shstrtab shstrtab;
            };
            defer gpa.free(shstrtab);
            try elf.nodes.ensureUnusedCapacity(gpa, ehdr.shnum - 1);
            try elf.input_sections.ensureUnusedCapacity(gpa, ehdr.shnum - 1);
            for (sections[1..]) |*section| {
                if (section.shdr.name >= shstrtab.len) continue;
                const name = std.mem.sliceTo(shstrtab[section.shdr.name..], 0);
                const opts: struct {
                    shndx: Section.Index,
                    has_file_bits: bool,
                    node_fixed: bool,
                } = switch (section.shdr.type) {
                    else => continue,
                    .PROGBITS, .NOBITS => opts: {
                        const shndx = elf.mapInputSection(.{
                            .name = name,
                            .flags = section.shdr.flags.shf,
                            .addralign = section.shdr.addralign,
                            .entsize = section.shdr.entsize,
                        }) catch |err| switch (err) {
                            error.TlsSectionUnavailable => return diags.failParse(
                                path,
                                "thread-local storage section '{s}' is incompatible with '-fsingle-threaded'",
                                .{name},
                            ),
                            error.UnsupportedSectionFlags => if (!section.shdr.flags.shf.ALLOC) {
                                // It probably doesn't matter, just skip this section.
                                continue;
                            } else return diags.failParse(
                                path,
                                "unsupported flags for section '{s}'",
                                .{name},
                            ),
                            error.SectionTypeConflict => if (!section.shdr.flags.shf.ALLOC) {
                                // It probably doesn't matter, just skip this section.
                                continue;
                            } else return diags.failParse(
                                path,
                                "type of section '{s}' conflicts with other inputs",
                                .{name},
                            ),
                            error.SectionFlagsConflict => if (!section.shdr.flags.shf.ALLOC) {
                                // It probably doesn't matter, just skip this section.
                                continue;
                            } else return diags.failParse(
                                path,
                                "flags of section '{s}' conflict with other inputs",
                                .{name},
                            ),
                            else => |e| return e,
                        };
                        if (section.shdr.flags.shf.COMPRESSED) {
                            // SHF_COMPRESSED is only allowed on non-alloc sections.
                            if (section.shdr.flags.shf.ALLOC) return diags.failParse(
                                path,
                                "section '{s}' has conflicting flags SHF_ALLOC and SHF_COMPRESSED",
                                .{name},
                            );
                            // TODO: handle compressed input sections. We'll need to set a flag to
                            // indicate that `flushInputSection` needs to decompress the section.
                            // But because this section isn't SHF_ALLOC, it's probably okay to just
                            // skip it for now.
                            continue;
                        }
                        break :opts .{
                            .shndx = shndx,
                            .has_file_bits = section.shdr.type == .PROGBITS,
                            // For well-known sections, we know that it's fine to have e.g. random
                            // padding, so there's no need to make the sections fixed. For custom
                            // sections, however, we do want fixed nodes to avoid padding.
                            .node_fixed = shndx != .text and
                                shndx != .rodata and
                                shndx != .data and
                                shndx != .data_rel_ro and
                                shndx != elf.shndx.tdata,
                        };
                    },
                    inline .INIT_ARRAY, .FINI_ARRAY, .PREINIT_ARRAY => |@"type"| .{
                        .shndx = shndx: {
                            // TODO: the input section name may include a "priority" value between 1
                            // and 65535 which should affect the order we assemble input sections in
                            const init_fini_section_name: []const u8 = switch (@"type") {
                                .INIT_ARRAY => "init_array",
                                .FINI_ARRAY => "fini_array",
                                .PREINIT_ARRAY => "preinit_array",
                                else => comptime unreachable,
                            };
                            const shndx: *Section.Index = &@field(elf.shndx, init_fini_section_name);
                            const need_addralign: u8 = switch (class) {
                                .NONE, _ => unreachable,
                                .@"32" => 4,
                                .@"64" => 8,
                            };
                            if (section.shdr.addralign != need_addralign) {
                                return diags.failParse(path, "bad addralign on {t} shdr", .{@"type"});
                            }
                            if (shndx.* == .UNDEF) {
                                try elf.createInitFiniArraySection(shndx, init_fini_section_name, @"type");
                            }
                            switch (elf.shdrPtr(shndx.*)) {
                                inline else => |shdr| {
                                    const old_size = elf.targetLoad(&shdr.size);
                                    elf.targetStore(&shdr.size, @intCast(old_size + section.shdr.size));
                                },
                            }
                            try shndx.get(elf).ni.resized(gpa, &elf.mf);
                            break :shndx shndx.*;
                        },
                        .has_file_bits = true,
                        // This node must be fixed to prevent padding from being added between different
                        // INIT_ARRAY/FINI_ARRAY/PREINIT_ARRAY input sections.
                        .node_fixed = true,
                    },
                };
                const ni = try elf.mf.addLastChildNode(gpa, opts.shndx.get(elf).ni, .{
                    .size = section.shdr.size,
                    .alignment = .fromByteUnits(std.math.ceilPowerOfTwoAssert(
                        usize,
                        @intCast(@max(section.shdr.addralign, 1)),
                    )),
                    .moved = true, // see assert at end of `flushInputSection`
                    .fixed = opts.node_fixed,
                });
                elf.nodes.appendAssumeCapacity(.{
                    .input_section = @enumFromInt(elf.input_sections.items.len),
                });
                section.isi = @enumFromInt(elf.input_sections.items.len);
                elf.input_sections.addOneAssumeCapacity().* = .{
                    .input = input_index,
                    .file_location = .{
                        .offset = fl.offset + section.shdr.offset,
                        .size = if (opts.has_file_bits) section.shdr.size else 0,
                    },
                    // The section vaddr is initially 0, because the symbol addresses are
                    // zero-based. This will eventually be updated by `flushMoved`.
                    .vaddr = 0,
                    .node = ni,
                    .first_reloc = .none,
                };
                elf.synth_prog_node.increaseEstimatedTotalItems(1);
            }
            var symmap: std.ArrayList(Symbol.Id) = .empty;
            defer symmap.deinit(gpa);
            for (sections[1..], 1..) |*symtab, symtab_shndx| switch (symtab.shdr.type) {
                else => {},
                .SYMTAB => {
                    if (symtab.shdr.entsize < @sizeOf(ElfN.Sym))
                        return diags.failParse(path, "unsupported symtab entsize", .{});
                    const strtab = strtab: {
                        if (symtab.shdr.link == std.elf.SHN_UNDEF or symtab.shdr.link >= ehdr.shnum)
                            return diags.failParse(path, "missing symbol names", .{});
                        const shdr = &sections[symtab.shdr.link].shdr;
                        if (shdr.type != .STRTAB)
                            return diags.failParse(path, "invalid strtab type", .{});
                        const strtab = try gpa.alloc(u8, @intCast(shdr.size));
                        errdefer gpa.free(strtab);
                        try fr.seekTo(fl.offset + shdr.offset);
                        try r.readSliceAll(strtab);
                        break :strtab strtab;
                    };
                    defer gpa.free(strtab);
                    const symnum = std.math.sub(u32, std.math.divExact(
                        u32,
                        @intCast(symtab.shdr.size),
                        @intCast(symtab.shdr.entsize),
                    ) catch return diags.failParse(
                        path,
                        "symtab section size (0x{x}) is not a multiple of entsize (0x{x})",
                        .{ symtab.shdr.size, symtab.shdr.entsize },
                    ), 1) catch continue;
                    symmap.clearRetainingCapacity();
                    try symmap.resize(gpa, symnum);
                    try elf.ensureUnusedSymbolCapacity(symnum, .maybe_global);
                    try fr.seekTo(fl.offset + symtab.shdr.offset + symtab.shdr.entsize);
                    for (symmap.items) |*si| {
                        si.* = .null;
                        const input_sym = try r.peekStruct(ElfN.Sym, target_endian);
                        try r.discardAll64(symtab.shdr.entsize);
                        if (input_sym.name >= strtab.len or input_sym.shndx >= ehdr.shnum) continue;

                        const name = std.mem.sliceTo(strtab[input_sym.name..], 0);

                        const sym_type: std.elf.STT = switch (input_sym.info.type) {
                            .NOTYPE, .OBJECT, .FUNC, .TLS => |t| t,
                            .SECTION => .NOTYPE,
                            .FILE, .COMMON, _ => continue,
                        };

                        if (input_sym.shndx == std.elf.SHN_UNDEF) switch (input_sym.info.bind) {
                            else => |bind| return diags.failParse(
                                path,
                                "symbol '{s}' has unsupported binding (0x{x})",
                                .{ name, bind },
                            ),
                            .LOCAL => continue,
                            .GLOBAL, .WEAK, .GNU_UNIQUE => |bind| {
                                si.* = elf.addGlobalSymbolAssumeCapacity(.{
                                    .node = .none,
                                    .name = try .string(elf, name),
                                    .value = input_sym.value,
                                    .size = input_sym.size,
                                    .type = sym_type,
                                    .bind = switch (bind) {
                                        .WEAK, .GNU_UNIQUE => .weak,
                                        .GLOBAL => .strong,
                                        else => unreachable,
                                    },
                                    .visibility = input_sym.other.visibility,
                                    .shndx = .UNDEF,
                                }) catch |err| switch (err) {
                                    error.MultipleDefinitions => unreachable, // shndx is .UNDEF
                                };
                                continue;
                            },
                        };

                        const input_section_node = (sections[input_sym.shndx].isi orelse continue).node(elf);

                        switch (input_sym.info.bind) {
                            else => |bind| return diags.failParse(
                                path,
                                "symbol '{s}' has unsupported binding (0x{x})",
                                .{ name, bind },
                            ),
                            .LOCAL => {
                                const lsi = elf.addLocalSymbolAssumeCapacity(.{
                                    .node = input_section_node,
                                    .name = try elf.string(.strtab, name),
                                    .value = input_sym.value,
                                    .size = input_sym.size,
                                    .type = sym_type,
                                    .shndx = elf.getNodeShndx(input_section_node),
                                });
                                si.* = .local(lsi);
                            },
                            .GLOBAL, .WEAK, .GNU_UNIQUE => |bind| {
                                si.* = elf.addGlobalSymbolAssumeCapacity(.{
                                    .node = input_section_node,
                                    .name = try .string(elf, name),
                                    .value = input_sym.value,
                                    .size = input_sym.size,
                                    .type = sym_type,
                                    .bind = switch (bind) {
                                        .WEAK, .GNU_UNIQUE => .weak,
                                        .GLOBAL => .strong,
                                        else => unreachable,
                                    },
                                    .visibility = input_sym.other.visibility,
                                    .shndx = elf.getNodeShndx(input_section_node),
                                }) catch |err| switch (err) {
                                    error.MultipleDefinitions => return diags.failParse(
                                        path,
                                        "multiple definitions of '{s}'",
                                        .{name},
                                    ),
                                };
                            },
                        }
                    }
                    for (sections[1..]) |*rel_sec| switch (rel_sec.shdr.type) {
                        else => {},
                        inline .REL, .RELA => |sht| {
                            if (rel_sec.shdr.link != symtab_shndx or rel_sec.shdr.info == std.elf.SHN_UNDEF or
                                rel_sec.shdr.info >= ehdr.shnum) continue;
                            const Rel = switch (sht) {
                                else => comptime unreachable,
                                .REL => ElfN.Rel,
                                .RELA => ElfN.Rela,
                            };
                            if (rel_sec.shdr.entsize < @sizeOf(Rel))
                                return diags.failParse(path, "unsupported rel entsize", .{});

                            const loc_sec = &sections[rel_sec.shdr.info];
                            const loc_node = (loc_sec.isi orelse continue).node(elf);
                            elf.resetNodeRelocs(loc_node);

                            const relnum = std.math.divExact(
                                u32,
                                @intCast(rel_sec.shdr.size),
                                @intCast(rel_sec.shdr.entsize),
                            ) catch return diags.failParse(
                                path,
                                "relocation section size (0x{x}) is not a multiple of entsize (0x{x})",
                                .{ rel_sec.shdr.size, rel_sec.shdr.entsize },
                            );
                            try elf.ensureUnusedRelocCapacity(loc_node, relnum);
                            try fr.seekTo(fl.offset + rel_sec.shdr.offset);
                            for (0..relnum) |_| {
                                const rel = try r.peekStruct(Rel, target_endian);
                                try r.discardAll64(rel_sec.shdr.entsize);
                                if (rel.info.sym == 0) continue;
                                if (rel.info.sym > symnum) return diags.failParse(
                                    path,
                                    "relocation target symbol index {d} exceeds symtab size",
                                    .{rel.info.sym},
                                );
                                const target = symmap.items[rel.info.sym - 1];
                                if (target == Symbol.Id.null) {
                                    // If this is not an SHF_ALLOC section, then let's let this
                                    // slide for now, because it probably doesn't affect the final
                                    // binary's functionality for this section to be a bit broken.
                                    if (!loc_sec.shdr.flags.shf.ALLOC) continue;
                                    return diags.failParse(
                                        path,
                                        "unsupported symbol at index {d} required for relocation",
                                        .{rel.info.sym},
                                    );
                                }
                                elf.addRelocAssumeCapacity(
                                    loc_node,
                                    rel.offset - loc_sec.shdr.addr,
                                    target,
                                    rel.addend,
                                    .wrap(rel.info.type, elf),
                                );
                            }
                        },
                    };
                },
            };
        },
    }
}
fn loadDso(elf: *Elf, path: std.Build.Cache.Path, fr: *Io.File.Reader) !void {
    const comp = elf.base.comp;
    const diags = &comp.link_diags;
    const r = &fr.interface;

    log.debug("loadDso({f})", .{path.fmtEscapeString()});
    try elf.checkInputIdent(path, r);
    const target_endian = elf.targetEndian();
    switch (elf.identClass()) {
        .NONE, _ => unreachable,
        inline else => |class| {
            const ElfN = class.ElfN();
            const ehdr = try r.peekStruct(ElfN.Ehdr, target_endian);
            if (ehdr.type != .DYN) return diags.failParse(path, "unsupported dso type", .{});
            if (ehdr.machine != elf.ehdrField(.machine))
                return diags.failParse(path, "bad machine", .{});
            if (ehdr.phoff == 0 or ehdr.phnum <= 1)
                return diags.failParse(path, "no program headers", .{});
            try fr.seekTo(ehdr.phoff);
            const dynamic_ph = for (0..ehdr.phnum) |_| {
                const ph = try r.peekStruct(ElfN.Phdr, target_endian);
                try r.discardAll(ehdr.phentsize);
                switch (ph.type) {
                    else => {},
                    .DYNAMIC => break ph,
                }
            } else return diags.failParse(path, "no dynamic segment", .{});
            const dynnum = std.math.divExact(
                u32,
                @intCast(dynamic_ph.filesz),
                @sizeOf(ElfN.Addr) * 2,
            ) catch return diags.failParse(
                path,
                "dynamic segment filesz (0x{x}) is not a multiple of entsize (0x{x})",
                .{ dynamic_ph.filesz, @sizeOf(ElfN.Addr) * 2 },
            );
            var strtab: ?ElfN.Addr = null;
            var strsz: ?ElfN.Addr = null;
            var soname: ?ElfN.Addr = null;
            try fr.seekTo(dynamic_ph.offset);
            for (0..dynnum) |_| {
                const tag = try r.takeInt(ElfN.Addr, target_endian);
                const val = try r.takeInt(ElfN.Addr, target_endian);
                switch (tag) {
                    else => {},
                    std.elf.DT_STRTAB => strtab = val,
                    std.elf.DT_STRSZ => strsz = val,
                    std.elf.DT_SONAME => soname = val,
                }
            }
            if (strtab == null or soname == null)
                return elf.loadDsoExact(std.fs.path.basename(path.sub_path));
            if (strsz) |size| if (soname.? >= size)
                return diags.failParse(path, "bad soname string", .{});
            try fr.seekTo(ehdr.phoff);
            const ph = for (0..ehdr.phnum) |_| {
                const ph = try r.peekStruct(ElfN.Phdr, target_endian);
                try r.discardAll(ehdr.phentsize);
                switch (ph.type) {
                    else => {},
                    .LOAD => if (strtab.? >= ph.vaddr and
                        strtab.? + (strsz orelse 0) <= ph.vaddr + ph.filesz) break ph,
                }
            } else return diags.failParse(path, "strtab not part of a loaded segment", .{});
            try fr.seekTo(strtab.? + soname.? - ph.vaddr + ph.offset);
            return elf.loadDsoExact(r.peekSentinel(0) catch |err| switch (err) {
                error.StreamTooLong => return diags.failParse(path, "soname too lang", .{}),
                else => |e| return e,
            });
        },
    }
}
fn loadDsoExact(elf: *Elf, name: []const u8) !void {
    log.debug("loadDsoExact({f})", .{std.zig.fmtString(name)});
    if (elf.shndx.dynamic != .UNDEF) {
        try elf.needed.put(elf.base.comp.gpa, try elf.string(.dynstr, name), {});
    }
}

/// Validates that the `std.elf.Ident` present at the start of `r` is a compatible link input.
///
/// Returns an error if it is incompatible, or if the ident is broken or missing.
///
/// Does not advance the position of `r`. Requires `r` to have a 16-byte buffer.
fn checkInputIdent(
    elf: *const Elf,
    path: std.Build.Cache.Path,
    r: *Io.Reader,
) !void {
    const diags = &elf.base.comp.link_diags;

    const ident = try r.peekStructPointer(std.elf.Ident);
    const target: *const std.elf.Ident = @ptrCast(elf.mf.memory_map.memory[0..@sizeOf(std.elf.Ident)]);

    if (!std.mem.eql(u8, &ident.magic, std.elf.MAGIC)) {
        return error.BadMagic;
    }

    if (ident.class != target.class) return diags.failParse(
        path,
        "bad ELF class ({?s})",
        .{std.enums.tagName(std.elf.CLASS, ident.class)},
    );
    if (ident.data != target.data) return diags.failParse(
        path,
        "bad ELF data encoding ({?s})",
        .{std.enums.tagName(std.elf.DATA, ident.data)},
    );
    if (ident.version != target.version) return diags.failParse(
        path,
        "bad ELF version ({d})",
        .{ident.version},
    );

    // OSABI is a bit more complex. On Linux, `.NONE` and `.GNU` are both valid and both common.
    // It sounds reasonable to allow the value we chose *and* allow `.NONE`.
    const expect_abiversion: u8 = abiver: {
        if (ident.osabi == .NONE) break :abiver 0;
        if (ident.osabi == target.osabi) break :abiver target.abiversion;
        return diags.failParse(
            path,
            "bad ELF OS/ABI ({?s})",
            .{std.enums.tagName(std.elf.OSABI, ident.osabi)},
        );
    };
    if (ident.abiversion != expect_abiversion) return diags.failParse(
        path,
        "bad ELF ABI version ({d})",
        .{ident.abiversion},
    );
}

fn createInitFiniArraySection(
    elf: *Elf,
    shndx: *Section.Index,
    comptime name: []const u8,
    @"type": std.elf.SHT,
) !void {
    assert(shndx.* == .UNDEF);
    const gpa = elf.base.comp.gpa;
    const addr_align: std.mem.Alignment = switch (elf.identClass()) {
        .NONE, _ => unreachable,
        .@"32" => .@"4",
        .@"64" => .@"8",
    };
    assert(elf.section_by_name.count() == elf.shdrs.items.len);
    try elf.section_by_name.ensureUnusedCapacity(gpa, 1);
    shndx.* = try elf.addSection(elf.ni.data_rel_ro, .{
        .name = "." ++ name,
        .type = @"type",
        .flags = .{ .WRITE = true, .ALLOC = true },
        .node_align = addr_align,
    });
    elf.section_by_name.putAssumeCapacityNoClobber(shndx.name(elf), {});
    try elf.ensureUnusedSymbolCapacity(2, .maybe_global);
    _ = elf.addGlobalSymbolAssumeCapacity(.{
        .node = shndx.get(elf).ni,
        .name = try .string(elf, "__" ++ name ++ "_start"),
        .value = shndx.vaddr(elf),
        .size = 0,
        .type = .NOTYPE,
        .bind = .strong,
        .visibility = .HIDDEN,
        .shndx = shndx.*,
    }) catch |err| switch (err) {
        error.MultipleDefinitions => return elf.base.comp.link_diags.fail(
            "multiple definitions of '{s}'",
            .{"__" ++ name ++ "_start"},
        ),
    };
    _ = elf.addGlobalSymbolAssumeCapacity(.{
        .node = shndx.get(elf).ni,
        .name = try .string(elf, "__" ++ name ++ "_end"),
        .value = shndx.vaddr(elf),
        .size = 0,
        .type = .NOTYPE,
        .bind = .strong,
        .visibility = .HIDDEN,
        .shndx = shndx.*,
    }) catch |err| switch (err) {
        error.MultipleDefinitions => return elf.base.comp.link_diags.fail(
            "multiple definitions of '{s}'",
            .{"__" ++ name ++ "_end"},
        ),
    };
}

pub fn prelink(elf: *Elf, prog_node: std.Progress.Node) !void {
    _ = prog_node;
    elf.prelinkInner() catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => |e| return elf.base.comp.link_diags.fail("prelink failed: {t}", .{e}),
    };
}
fn prelinkInner(elf: *Elf) !void {
    const comp = elf.base.comp;
    const gpa = comp.gpa;
    try elf.ensureUnusedSymbolCapacity(1, .all_local);
    try elf.inputs.ensureUnusedCapacity(gpa, 1);
    const zcu_name = try std.fmt.allocPrint(gpa, "{s}_zcu", .{
        std.fs.path.stem(elf.base.emit.sub_path),
    });
    defer gpa.free(zcu_name);
    const zcu_file_symbol = elf.addLocalSymbolAssumeCapacity(.{
        .node = .none,
        .name = try elf.string(.strtab, zcu_name),
        .value = 0,
        .size = 0,
        .type = .FILE,
        .shndx = .ABS,
    });
    elf.inputs.addOneAssumeCapacity().* = .{
        .path = elf.base.emit,
        .member = null,
        .file_symbol = zcu_file_symbol,
    };

    if (elf.shndx.dynamic != .UNDEF) switch (elf.identClass()) {
        .NONE, _ => unreachable,
        inline else => |ct_class| {
            const ElfN = ct_class.ElfN();
            const flags: ElfN.Addr = if (elf.options.z_now) std.elf.DF_BIND_NOW else 0;
            const flags_1: ElfN.Addr = if (elf.options.z_now) std.elf.DF_1_NOW else 0;
            const needed_len = elf.needed.count();
            const dynamic_len = needed_len + @intFromBool(elf.options.soname != null) +
                @intFromBool(flags != 0) + @intFromBool(flags_1 != 0) +
                @as(usize, @intFromBool(elf.shndx.init_array != .UNDEF)) * 2 +
                @as(usize, @intFromBool(elf.shndx.fini_array != .UNDEF)) * 2 +
                @as(usize, @intFromBool(elf.shndx.preinit_array != .UNDEF)) * 2 +
                @intFromBool(comp.config.output_mode == .Exe) + 12;
            const dynamic_size: u32 = @intCast(@sizeOf(ElfN.Addr) * 2 * dynamic_len);
            const dynamic_ni = elf.shndx.dynamic.get(elf).ni;
            try dynamic_ni.resize(&elf.mf, gpa, dynamic_size);
            switch (elf.shdrPtr(elf.shndx.dynamic)) {
                inline else => |shdr| elf.targetStore(&shdr.size, dynamic_size),
            }
            const sec_dynamic = dynamic_ni.slice(&elf.mf);
            const dynamic_entries: [][2]ElfN.Addr = @ptrCast(@alignCast(sec_dynamic));
            var dynamic_index: usize = 0;
            for (
                dynamic_entries[dynamic_index..][0..needed_len],
                elf.needed.keys(),
            ) |*dynamic_entry, needed| dynamic_entry.* = .{ std.elf.DT_NEEDED, @intFromEnum(needed) };
            dynamic_index += needed_len;
            if (elf.options.soname) |soname| {
                dynamic_entries[dynamic_index] = .{ std.elf.DT_SONAME, @intFromEnum(try elf.string(.dynstr, soname)) };
                dynamic_index += 1;
            }
            if (flags != 0) {
                dynamic_entries[dynamic_index] = .{ std.elf.DT_FLAGS, flags };
                dynamic_index += 1;
            }
            if (flags_1 != 0) {
                dynamic_entries[dynamic_index] = .{ std.elf.DT_FLAGS_1, flags_1 };
                dynamic_index += 1;
            }
            if (comp.config.output_mode == .Exe) {
                dynamic_entries[dynamic_index] = .{ std.elf.DT_DEBUG, 0 };
                dynamic_index += 1;
            }
            if (elf.shndx.init_array != .UNDEF) {
                dynamic_entries[dynamic_index..][0..2].* = .{
                    .{ std.elf.DT_INIT_ARRAY, @intCast(elf.shndx.init_array.vaddr(elf)) },
                    .{ std.elf.DT_INIT_ARRAYSZ, elf.targetLoad(
                        &@field(elf.shdrPtr(elf.shndx.init_array), @tagName(ct_class)).size,
                    ) },
                };
                try elf.ensureUnusedRelocCapacity(dynamic_ni, 1);
                elf.addRelocAssumeCapacity(
                    dynamic_ni,
                    @sizeOf(ElfN.Addr) * (2 * dynamic_index + 1),
                    .local(elf.shndx.init_array.get(elf).lsi),
                    0,
                    .absAddr(elf),
                );
                dynamic_index += 2;
            }
            if (elf.shndx.fini_array != .UNDEF) {
                dynamic_entries[dynamic_index..][0..2].* = .{
                    .{ std.elf.DT_FINI_ARRAY, @intCast(elf.shndx.fini_array.vaddr(elf)) },
                    .{ std.elf.DT_FINI_ARRAYSZ, elf.targetLoad(
                        &@field(elf.shdrPtr(elf.shndx.fini_array), @tagName(ct_class)).size,
                    ) },
                };
                try elf.ensureUnusedRelocCapacity(dynamic_ni, 1);
                elf.addRelocAssumeCapacity(
                    dynamic_ni,
                    @sizeOf(ElfN.Addr) * (2 * dynamic_index + 1),
                    .local(elf.shndx.fini_array.get(elf).lsi),
                    0,
                    .absAddr(elf),
                );
                dynamic_index += 2;
            }
            if (elf.shndx.preinit_array != .UNDEF) {
                dynamic_entries[dynamic_index..][0..2].* = .{
                    .{ std.elf.DT_PREINIT_ARRAY, @intCast(elf.shndx.preinit_array.vaddr(elf)) },
                    .{ std.elf.DT_PREINIT_ARRAYSZ, elf.targetLoad(
                        &@field(elf.shdrPtr(elf.shndx.preinit_array), @tagName(ct_class)).size,
                    ) },
                };
                try elf.ensureUnusedRelocCapacity(dynamic_ni, 1);
                elf.addRelocAssumeCapacity(
                    dynamic_ni,
                    @sizeOf(ElfN.Addr) * (2 * dynamic_index + 1),
                    .local(elf.shndx.preinit_array.get(elf).lsi),
                    0,
                    .absAddr(elf),
                );
                dynamic_index += 2;
            }
            const rela_dyn_shndx = elf.shndx.got.get(elf).rela_shndx;
            const rela_plt_shndx = elf.shndx.got_plt.get(elf).rela_shndx;
            dynamic_entries[dynamic_index..][0..12].* = .{
                .{ std.elf.DT_RELA, @intCast(rela_dyn_shndx.vaddr(elf)) },
                .{ std.elf.DT_RELASZ, elf.targetLoad(
                    &@field(elf.shdrPtr(rela_dyn_shndx), @tagName(ct_class)).size,
                ) },
                .{ std.elf.DT_RELAENT, @sizeOf(ElfN.Rela) },
                .{ std.elf.DT_JMPREL, @intCast(rela_plt_shndx.vaddr(elf)) },
                .{ std.elf.DT_PLTRELSZ, elf.targetLoad(
                    &@field(elf.shdrPtr(rela_plt_shndx), @tagName(ct_class)).size,
                ) },
                .{ std.elf.DT_PLTGOT, @intCast(elf.shndx.got_plt.vaddr(elf)) },
                .{ std.elf.DT_PLTREL, std.elf.DT_RELA },
                .{ std.elf.DT_SYMTAB, @intCast(elf.shndx.dynsym.vaddr(elf)) },
                .{ std.elf.DT_SYMENT, @sizeOf(ElfN.Sym) },
                .{ std.elf.DT_STRTAB, @intCast(elf.shndx.dynstr.vaddr(elf)) },
                .{ std.elf.DT_STRSZ, elf.targetLoad(
                    &@field(elf.shdrPtr(elf.shndx.dynstr), @tagName(ct_class)).size,
                ) },
                .{ std.elf.DT_NULL, 0 },
            };
            dynamic_index += 12;
            assert(dynamic_index == dynamic_len);
            if (elf.targetEndian() != native_endian) for (dynamic_entries) |*dynamic_entry|
                std.mem.byteSwapAllFields(@TypeOf(dynamic_entry.*), dynamic_entry);

            elf.first_dynamic_reloc = @enumFromInt(elf.relocs.items.len);
            try elf.ensureUnusedRelocCapacity(dynamic_ni, 5);
            elf.addRelocAssumeCapacity(
                dynamic_ni,
                @sizeOf(ElfN.Addr) * (2 * (dynamic_len - 12) + 1),
                .local(rela_dyn_shndx.get(elf).lsi),
                0,
                .absAddr(elf),
            );
            elf.addRelocAssumeCapacity(
                dynamic_ni,
                @sizeOf(ElfN.Addr) * (2 * (dynamic_len - 9) + 1),
                .local(rela_plt_shndx.get(elf).lsi),
                0,
                .absAddr(elf),
            );
            elf.addRelocAssumeCapacity(
                dynamic_ni,
                @sizeOf(ElfN.Addr) * (2 * (dynamic_len - 7) + 1),
                .local(elf.shndx.got_plt.get(elf).lsi),
                0,
                .absAddr(elf),
            );
            elf.addRelocAssumeCapacity(
                dynamic_ni,
                @sizeOf(ElfN.Addr) * (2 * (dynamic_len - 5) + 1),
                .local(elf.shndx.dynsym.get(elf).lsi),
                0,
                .absAddr(elf),
            );
            elf.addRelocAssumeCapacity(
                dynamic_ni,
                @sizeOf(ElfN.Addr) * (2 * (dynamic_len - 3) + 1),
                .local(elf.shndx.dynstr.get(elf).lsi),
                0,
                .absAddr(elf),
            );
        },
    };
}

fn addSection(elf: *Elf, segment_ni: MappedFile.Node.Index, opts: struct {
    name: []const u8 = "",
    type: std.elf.SHT = .NULL,
    flags: std.elf.SHF = .{},
    size: std.elf.Xword = 0,
    link: std.elf.Word = 0,
    info: std.elf.Word = 0,
    addralign: std.mem.Alignment = .@"1",
    entsize: std.elf.Word = 0,
    node_align: std.mem.Alignment = .@"1",
    fixed: bool = false,
}) !Section.Index {
    switch (opts.type) {
        .NULL => assert(opts.size == 0),
        .PROGBITS => assert(opts.size > 0),
        else => {},
    }
    if (opts.flags.ALLOC and elf.ehdrField(.type) != .REL) {
        assert(elf.getNode(segment_ni) == .segment);
    }
    const gpa = elf.base.comp.gpa;
    try elf.nodes.ensureUnusedCapacity(gpa, 1);
    try elf.shdrs.ensureUnusedCapacity(gpa, 1);
    if (opts.flags.ALLOC) try elf.ensureUnusedSymbolCapacity(1, .all_local);

    const shstrtab_entry = try elf.string(.shstrtab, opts.name);
    const shndx: Section.Index, const new_shdr_size = shndx: switch (elf.ehdrPtr()) {
        inline else => |ehdr, class| {
            const shndx, const shnum = alloc_shndx: switch (elf.targetLoad(&ehdr.shnum)) {
                1...std.elf.SHN_LORESERVE - 2 => |shndx| {
                    const shnum = shndx + 1;
                    elf.targetStore(&ehdr.shnum, shnum);
                    break :alloc_shndx .{ shndx, shnum };
                },
                std.elf.SHN_LORESERVE - 1 => |shndx| {
                    const shnum = shndx + 1;
                    elf.targetStore(&ehdr.shnum, 0);
                    elf.targetStore(&@field(elf.shdrPtr(.UNDEF), @tagName(class)).size, shnum);
                    break :alloc_shndx .{ shndx, shnum };
                },
                std.elf.SHN_LORESERVE...std.elf.SHN_HIRESERVE => unreachable,
                0 => {
                    const shnum_ptr = &@field(elf.shdrPtr(.UNDEF), @tagName(class)).size;
                    const shndx: u32 = @intCast(elf.targetLoad(shnum_ptr));
                    const shnum = shndx + 1;
                    elf.targetStore(shnum_ptr, shnum);
                    break :alloc_shndx .{ shndx, shnum };
                },
            };
            assert(shndx < @intFromEnum(Section.Index.LORESERVE));
            break :shndx .{ @enumFromInt(shndx), @as(u64, elf.targetLoad(&ehdr.shentsize)) * @as(u64, shnum) };
        },
    };
    _, const shdr_node_size = elf.ni.shdr.location(&elf.mf).resolve(&elf.mf);
    if (new_shdr_size > shdr_node_size)
        try elf.ni.shdr.resize(&elf.mf, gpa, new_shdr_size +| new_shdr_size / MappedFile.growth_factor);
    const ni = try elf.mf.addLastChildNode(gpa, switch (elf.ehdrField(.type)) {
        .NONE, .CORE, _ => unreachable,
        .REL => elf.ni.file,
        .EXEC, .DYN => segment_ni,
    }, .{
        .size = opts.size,
        .alignment = opts.addralign.max(opts.node_align),
        .fixed = opts.fixed,
        .resized = opts.size > 0,
    });
    const addr = elf.computeNodeVAddr(ni);
    const lsi: Symbol.LocalIndex = if (opts.flags.ALLOC) elf.addLocalSymbolAssumeCapacity(.{
        .node = ni,
        .name = .empty,
        .value = addr,
        .size = 0,
        .type = .SECTION,
        .shndx = shndx,
    }) else .null;
    elf.shdrs.appendAssumeCapacity(.{ .lsi = lsi, .ni = ni, .rela_shndx = .UNDEF, .rela_free = .none });
    elf.nodes.appendAssumeCapacity(.{ .section = shndx });
    const offset = ni.fileLocation(&elf.mf, false).offset;
    switch (elf.shdrPtr(shndx)) {
        inline else => |shdr, class| {
            shdr.* = .{
                .name = @intFromEnum(shstrtab_entry),
                .type = opts.type,
                .flags = .{ .shf = opts.flags },
                .addr = @intCast(addr),
                .offset = @intCast(offset),
                .size = @intCast(opts.size),
                .link = opts.link,
                .info = opts.info,
                .addralign = @intCast(opts.addralign.toByteUnits()),
                .entsize = opts.entsize,
            };
            if (elf.targetEndian() != native_endian) std.mem.byteSwapAllFields(class.ElfN().Shdr, shdr);
        },
    }
    return shndx;
}

fn ensureUnusedRelocCapacity(elf: *Elf, node: MappedFile.Node.Index, len: usize) !void {
    if (len == 0) return;
    const gpa = elf.base.comp.gpa;
    try elf.relocs.ensureUnusedCapacity(gpa, len);
    const class = elf.identClass();
    const rela_shndx, const rela_len = rela: switch (elf.ehdrField(.type)) {
        .NONE, .CORE, _ => unreachable,
        .REL => {
            const shndx = elf.getNodeShndx(node);
            if (shndx.get(elf).rela_shndx == .UNDEF) {
                var bfa_buf: [32]u8 = undefined;
                var bfa: std.heap.BufferFirstAllocator = .init(&bfa_buf, gpa);
                const allocator = bfa.allocator();

                const rela_name = try std.fmt.allocPrint(allocator, ".rela{s}", .{shndx.name(elf).slice(elf)});
                defer allocator.free(rela_name);

                assert(elf.section_by_name.count() == elf.shdrs.items.len);
                try elf.section_by_name.ensureUnusedCapacity(gpa, 1);
                const rela_shndx = try elf.addSection(.none, .{
                    .name = rela_name,
                    .type = .RELA,
                    .link = @intFromEnum(Section.Index.symtab),
                    .info = shndx.toSection().?,
                    .addralign = switch (class) {
                        .NONE, _ => unreachable,
                        .@"32" => .@"4",
                        .@"64" => .@"8",
                    },
                    .entsize = switch (class) {
                        .NONE, _ => unreachable,
                        inline else => |ct_class| @sizeOf(ct_class.ElfN().Rela),
                    },
                    .node_align = elf.mf.flags.block_size,
                });
                elf.section_by_name.putAssumeCapacityNoClobber(rela_shndx.name(elf), {});
                shndx.get(elf).rela_shndx = rela_shndx;
            }
            break :rela .{ shndx.get(elf).rela_shndx, len };
        },
        .EXEC, .DYN => switch (elf.got.tlsld) {
            _ => return,
            .none => if (elf.shndx.dynamic != .UNDEF) {
                try elf.mf.updates.ensureUnusedCapacity(gpa, 1);
                const got_ni = elf.shndx.got.get(elf).ni;
                _, const got_node_size = got_ni.location(&elf.mf).resolve(&elf.mf);
                const got_size = switch (class) {
                    .NONE, _ => unreachable,
                    inline else => |ct_class| (elf.got.len + 2) * @sizeOf(ct_class.ElfN().Addr),
                };
                if (got_size > got_node_size)
                    try got_ni.resize(&elf.mf, gpa, got_size +| got_size / MappedFile.growth_factor);
                break :rela .{ elf.shndx.got.get(elf).rela_shndx, 1 };
            } else return,
        },
    };
    const rela_ni = rela_shndx.get(elf).ni;
    _, const rela_node_size = rela_ni.location(&elf.mf).resolve(&elf.mf);
    const rela_size = switch (elf.shdrPtr(rela_shndx)) {
        inline else => |shdr| elf.targetLoad(&shdr.size) + elf.targetLoad(&shdr.entsize) * rela_len,
    };
    if (rela_size > rela_node_size)
        try rela_ni.resize(&elf.mf, gpa, rela_size +| rela_size / MappedFile.growth_factor);
}
fn addRelocAssumeCapacity(
    elf: *Elf,
    node: MappedFile.Node.Index,
    offset: u64,
    target: Symbol.Id,
    addend: i64,
    @"type": Reloc.Type,
) void {
    assert(node != .none);
    const ri: Reloc.Index = @enumFromInt(elf.relocs.items.len);
    const next: Reloc.Index = next: {
        const target_ptr = target.index(elf).ptr(elf);
        const next = target_ptr.first_target_reloc;
        target_ptr.first_target_reloc = ri;
        break :next next;
    };
    if (next != .none) {
        next.get(elf).prev = ri;
    }
    elf.relocs.addOneAssumeCapacity().* = .{
        .type = @"type",
        .prev = .none,
        .next = next,
        .node = node,
        .target = target,
        .index = index: switch (elf.ehdrField(.type)) {
            .NONE, .CORE, _ => unreachable,
            .REL => {
                const sh = elf.getNodeShndx(node).get(elf);
                switch (elf.shdrPtr(sh.rela_shndx)) {
                    inline else => |shdr, class| {
                        const Rela = class.ElfN().Rela;
                        const ent_size = elf.targetLoad(&shdr.entsize);
                        const rela_slice = sh.rela_shndx.get(elf).ni.slice(&elf.mf);
                        const index: u32 = if (sh.rela_free.unwrap()) |index| alloc_index: {
                            const rela: *Rela = @ptrCast(@alignCast(
                                rela_slice[@intCast(ent_size * index)..][0..@intCast(ent_size)],
                            ));
                            sh.rela_free = @enumFromInt(rela.offset);
                            break :alloc_index index;
                        } else alloc_index: {
                            const old_size = elf.targetLoad(&shdr.size);
                            const new_size = old_size + ent_size;
                            elf.targetStore(&shdr.size, @intCast(new_size));
                            break :alloc_index @intCast(@divExact(old_size, ent_size));
                        };
                        const rela: *Rela = @ptrCast(@alignCast(
                            rela_slice[@intCast(ent_size * index)..][0..@intCast(ent_size)],
                        ));
                        // The `offset` field here needs to equal the offset into the section, which
                        // is *not* the same as our `offset` which is the offset into `node`. We
                        // could calculate it now, but there's no point since `flushMovedNodeRelocs`
                        // will eventually do that for us anyway. So for now, just set offset to 0.
                        rela.* = .{
                            .offset = 0,
                            .info = .{
                                .type = @intCast(@"type".unwrap(elf)),
                                .sym = @intCast(@intFromEnum(target.index(elf))),
                            },
                            .addend = @intCast(addend),
                        };
                        if (elf.targetEndian() != native_endian) std.mem.byteSwapAllFields(Rela, rela);
                        break :index .wrap(index);
                    },
                }
            },
            .EXEC, .DYN => {
                switch (elf.ehdrField(.machine)) {
                    else => |machine| @panic(@tagName(machine)),
                    .AARCH64, .PPC64, .RISCV => {},
                    .X86_64 => switch (@"type".X86_64) {
                        else => {},
                        .TLSLD => switch (elf.got.tlsld) {
                            _ => {},
                            .none => if (elf.shndx.dynamic != .UNDEF) {
                                const tlsld_index = elf.got.len;
                                elf.got.tlsld = .wrap(tlsld_index);
                                elf.got.len = tlsld_index + 2;
                                const got_addr = got_addr: switch (elf.shdrPtr(elf.shndx.got)) {
                                    inline else => |shdr, class| {
                                        const addr_size = @sizeOf(class.ElfN().Addr);
                                        const old_size = addr_size * tlsld_index;
                                        const new_size = old_size + addr_size * 2;
                                        @memset(
                                            elf.shndx.got.get(elf).ni.slice(&elf.mf)[old_size..new_size],
                                            0,
                                        );
                                        break :got_addr elf.targetLoad(&shdr.addr) + old_size;
                                    },
                                };
                                const rela_dyn_shndx = elf.shndx.got.get(elf).rela_shndx;
                                const rela_dyn_ni = rela_dyn_shndx.get(elf).ni;
                                switch (elf.shdrPtr(rela_dyn_shndx)) {
                                    inline else => |shdr, class| {
                                        const Rela = class.ElfN().Rela;
                                        const old_size = elf.targetLoad(&shdr.size);
                                        const new_size = old_size + elf.targetLoad(&shdr.entsize);
                                        elf.targetStore(&shdr.size, new_size);
                                        const rela: *Rela = @ptrCast(@alignCast(rela_dyn_ni
                                            .slice(&elf.mf)[@intCast(old_size)..@intCast(new_size)]));
                                        rela.* = .{
                                            .offset = @intCast(got_addr),
                                            .info = .{
                                                .type = @intFromEnum(std.elf.R_X86_64.DTPMOD64),
                                                .sym = 0,
                                            },
                                            .addend = 0,
                                        };
                                        if (elf.targetEndian() != native_endian)
                                            std.mem.byteSwapAllFields(Rela, rela);
                                    },
                                }
                                rela_dyn_ni.resizedAssumeCapacity(&elf.mf);
                            },
                        },
                    },
                }
                break :index .none;
            },
        },
        .offset = offset,
        .addend = addend,
    };
}

pub fn updateNav(elf: *Elf, pt: Zcu.PerThread, nav_index: InternPool.Nav.Index) !void {
    elf.updateNavInner(pt, nav_index) catch |err| switch (err) {
        error.OutOfMemory,
        error.Overflow,
        error.RelocationNotByteAligned,
        => |e| return e,
        else => |e| return elf.base.cgFail(nav_index, "linker failed to update variable: {t}", .{e}),
    };
}
fn updateNavInner(elf: *Elf, pt: Zcu.PerThread, nav_index: InternPool.Nav.Index) !void {
    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;

    const nav = ip.getNav(nav_index);
    if (ip.indexToKey(nav.resolved.?.value) == .@"extern") return;
    if (!Type.fromInterned(nav.resolved.?.type).hasRuntimeBits(zcu)) return;

    const nmi = try elf.navMapIndex(zcu, nav_index);
    const ni = nmi.symbol(elf).index().ptr(elf).node;
    elf.resetNodeRelocs(ni);

    // Ensure the NAV is marked as moved so that once we're done, `flushMoved` will eventually be
    // called to apply the NAV's new relocations.
    try ni.moved(gpa, &elf.mf);

    var nw: MappedFile.Node.Writer = undefined;
    ni.writer(&elf.mf, gpa, &nw);
    defer nw.deinit();
    codegen.generateSymbol(
        &elf.base,
        pt,
        zcu.navSrcLoc(nav_index),
        .fromInterned(nav.resolved.?.value),
        &nw.interface,
        .{ .atom_index = Node.toAtom(ni) },
    ) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    switch (elf.symPtr(nmi.symbol(elf).index())) {
        inline else => |sym| elf.targetStore(&sym.size, @intCast(nw.interface.end)),
    }
}

pub fn updateFunc(
    elf: *Elf,
    pt: Zcu.PerThread,
    func_index: InternPool.Index,
    mir: *const codegen.AnyMir,
) !void {
    elf.updateFuncInner(pt, func_index, mir) catch |err| switch (err) {
        error.OutOfMemory,
        error.Overflow,
        error.RelocationNotByteAligned,
        error.CodegenFail,
        => |e| return e,
        else => |e| return elf.base.cgFail(
            pt.zcu.funcInfo(func_index).owner_nav,
            "linker failed to update function: {s}",
            .{@errorName(e)},
        ),
    };
}
fn updateFuncInner(
    elf: *Elf,
    pt: Zcu.PerThread,
    func_index: InternPool.Index,
    mir: *const codegen.AnyMir,
) !void {
    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;
    const func = zcu.funcInfo(func_index);
    const nav = ip.getNav(func.owner_nav);

    const nmi = try elf.navMapIndex(zcu, func.owner_nav);
    log.debug("updateFunc({f}) = {d}", .{ nav.fqn.fmt(ip), nmi.symbol(elf) });
    const ni = nmi.symbol(elf).index().ptr(elf).node;
    elf.resetNodeRelocs(ni);

    // Ensure the NAV is marked as moved so that once we're done, `flushMoved` will eventually be
    // called to apply the NAV's new relocations.
    try ni.moved(gpa, &elf.mf);

    var nw: MappedFile.Node.Writer = undefined;
    ni.writer(&elf.mf, gpa, &nw);
    defer nw.deinit();
    codegen.emitFunction(
        &elf.base,
        pt,
        zcu.navSrcLoc(func.owner_nav),
        func_index,
        Node.toAtom(ni),
        mir,
        &nw.interface,
        .none,
    ) catch |err| switch (err) {
        error.WriteFailed => return nw.err.?,
        else => |e| return e,
    };
    switch (elf.symPtr(nmi.symbol(elf).index())) {
        inline else => |sym| elf.targetStore(&sym.size, @intCast(nw.interface.end)),
    }
}

pub fn updateErrorData(elf: *Elf, pt: Zcu.PerThread) !void {
    elf.flushLazy(pt, .{
        .kind = .const_data,
        .index = @intCast(elf.lazy.getPtr(.const_data).map.getIndex(.anyerror_type) orelse return),
    }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.CodegenFail => return error.LinkFailure,
        else => |e| return elf.base.comp.link_diags.fail("updateErrorData failed: {t}", .{e}),
    };
}

pub fn flush(
    elf: *Elf,
    arena: std.mem.Allocator,
    tid: Zcu.PerThread.Id,
    prog_node: std.Progress.Node,
) !void {
    const comp = elf.base.comp;
    _ = arena;
    _ = prog_node;

    if (elf.ehdrField(.type) != .REL and
        elf.shndx.dynamic == .UNDEF and
        elf.globals.strong_undef.count() > 0)
    {
        for (elf.globals.strong_undef.keys()) |name| {
            comp.link_diags.addError("undefined global symbol '{s}'", .{name.slice(elf)});
        }
        return error.LinkFailure;
    }

    while (try elf.idle(tid)) {}

    const entry_addr: u64 = entry: {
        const sym_name_slice: []const u8 = name: switch (elf.options.entry) {
            .default => switch (comp.config.output_mode) {
                .Exe => continue :name .enabled,
                .Lib, .Obj => continue :name .disabled,
            },
            .disabled => break :entry 0,
            .enabled => "_start",
            .named => |named| named,
        };
        const sym_name_strtab = elf.string(.strtab, sym_name_slice) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => |e| return comp.link_diags.fail("flush write failed: {t}", .{e}),
        };
        const global = elf.globalByName(sym_name_strtab) orelse break :entry 0;
        switch (elf.symPtr(global.symtab_index)) {
            inline else => |sym| break :entry elf.targetLoad(&sym.value),
        }
    };
    switch (elf.ehdrPtr()) {
        inline else => |ehdr| elf.targetStore(&ehdr.entry, @intCast(entry_addr)),
    }

    elf.mf.flush() catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => |e| return comp.link_diags.fail("flush write failed: {t}", .{e}),
    };
}

pub fn idle(elf: *Elf, tid: Zcu.PerThread.Id) !bool {
    const comp = elf.base.comp;
    task: {
        while (elf.pending_uavs.pop()) |umi| {
            const sub_prog_node = elf.idleProgNode(tid, elf.const_prog_node, .{ .uav = umi });
            defer sub_prog_node.end();
            elf.flushUav(.{ .zcu = comp.zcu.?, .tid = tid }, umi) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => |e| return comp.link_diags.fail(
                    "linker failed to lower constant: {t}",
                    .{e},
                ),
            };
            break :task;
        }
        var lazy_it = elf.lazy.iterator();
        while (lazy_it.next()) |lazy| if (lazy.value.pending_index < lazy.value.map.count()) {
            const pt: Zcu.PerThread = .{ .zcu = comp.zcu.?, .tid = tid };
            const lmr: Node.LazyMapRef = .{ .kind = lazy.key, .index = lazy.value.pending_index };
            lazy.value.pending_index += 1;
            const kind = switch (lmr.kind) {
                .code => "code",
                .const_data => "data",
            };
            var name: [std.Progress.Node.max_name_len]u8 = undefined;
            const sub_prog_node = elf.synth_prog_node.start(
                std.fmt.bufPrint(&name, "lazy {s} for {f}", .{
                    kind,
                    Type.fromInterned(lmr.lazySymbol(elf).ty).fmt(pt),
                }) catch &name,
                0,
            );
            defer sub_prog_node.end();
            elf.flushLazy(pt, lmr) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => |e| return comp.link_diags.fail(
                    "linker failed to lower lazy {s}: {t}",
                    .{ kind, e },
                ),
            };
            break :task;
        };
        if (elf.input_section_pending_index < elf.input_sections.items.len) {
            const isi: InputSection.Index = @enumFromInt(elf.input_section_pending_index);
            elf.input_section_pending_index += 1;
            const sub_prog_node = elf.idleProgNode(tid, elf.input_prog_node, elf.getNode(isi.node(elf)));
            defer sub_prog_node.end();
            elf.flushInputSection(isi) catch |err| switch (err) {
                else => |e| {
                    const ii = isi.input(elf);
                    return comp.link_diags.fail(
                        "linker failed to read input section '{s}' from \"{f}{f}\": {t}",
                        .{
                            elf.getNode(isi.node(elf).parent(&elf.mf)).section.name(elf).slice(elf),
                            ii.path(elf).fmtEscapeString(),
                            fmtMemberString(ii.member(elf)),
                            e,
                        },
                    );
                },
            };
            break :task;
        }
        if (elf.changed_symtab_index.pop()) |kv| {
            if (elf.ehdrField(.type) == .REL) {
                const sub_prog_node = elf.mf.update_prog_node.start(kv.key.slice(elf), 0);
                defer sub_prog_node.end();
                const sym = elf.globalByName(kv.key).?.symtab_index.ptr(elf);
                var ri = sym.first_target_reloc;
                while (ri != .none) {
                    const reloc = ri.get(elf);
                    reloc.updateTargetIndex(elf);
                    ri = reloc.next;
                }
                break :task;
            }
        }
        while (elf.mf.updates.pop()) |ni| {
            const clean_moved = ni.cleanMoved(&elf.mf);
            const clean_resized = ni.cleanResized(&elf.mf);
            if (clean_moved or clean_resized) {
                const sub_prog_node = elf.idleProgNode(tid, elf.mf.update_prog_node, elf.getNode(ni));
                defer sub_prog_node.end();
                if (clean_moved) try elf.flushMoved(ni);
                if (clean_resized) try elf.flushResized(ni);
                break :task;
            } else elf.mf.update_prog_node.completeOne();
        }
    }
    if (elf.pending_uavs.items.len > 0) return true;
    for (&elf.lazy.values) |lazy| if (lazy.map.count() > lazy.pending_index) return true;
    if (elf.input_sections.items.len > elf.input_section_pending_index) return true;
    if (elf.changed_symtab_index.count() > 0) return true;
    if (elf.mf.updates.items.len > 0) return true;
    return false;
}

fn idleProgNode(
    elf: *Elf,
    tid: Zcu.PerThread.Id,
    prog_node: std.Progress.Node,
    node: Node,
) std.Progress.Node {
    var name: [std.Progress.Node.max_name_len]u8 = undefined;
    return prog_node.start(name: switch (node) {
        else => |tag| @tagName(tag),
        .section => |shndx| shndx.name(elf).slice(elf),
        .input_section => |isi| {
            const ii = isi.input(elf);
            break :name std.fmt.bufPrint(&name, "{f}{f} {s}", .{
                ii.path(elf).fmtEscapeString(),
                fmtMemberString(ii.member(elf)),
                elf.getNode(isi.node(elf).parent(&elf.mf)).section.name(elf).slice(elf),
            }) catch &name;
        },
        .nav => |nmi| {
            const ip = &elf.base.comp.zcu.?.intern_pool;
            break :name ip.getNav(nmi.navIndex(elf)).fqn.toSlice(ip);
        },
        .uav => |umi| std.fmt.bufPrint(&name, "{f}", .{
            Value.fromInterned(umi.uavValue(elf)).fmtValue(.{ .zcu = elf.base.comp.zcu.?, .tid = tid }),
        }) catch &name,
    }, 0);
}

fn flushUav(
    elf: *Elf,
    pt: Zcu.PerThread,
    umi: Node.UavMapIndex,
) !void {
    const comp = elf.base.comp;
    const gpa = comp.gpa;
    const zcu = pt.zcu;

    const uav_val = umi.uavValue(elf);
    const ni = umi.symbol(elf).index().ptr(elf).node;
    elf.resetNodeRelocs(ni);

    var nw: MappedFile.Node.Writer = undefined;
    ni.writer(&elf.mf, gpa, &nw);
    defer nw.deinit();
    // TODO: UAV lowering should never require source locations.
    const dummy_src_loc: Zcu.LazySrcLoc = .{
        .base_node_inst = try zcu.intern_pool.trackZir(gpa, comp.io, pt.tid, .{
            .file = zcu.module_roots.get(zcu.std_mod).?.unwrap().?,
            .inst = .main_struct_inst,
        }),
        .offset = .{ .byte_abs = 0 },
    };
    codegen.generateSymbol(
        &elf.base,
        pt,
        dummy_src_loc,
        .fromInterned(uav_val),
        &nw.interface,
        .{ .atom_index = Node.toAtom(ni) },
    ) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    switch (elf.symPtr(umi.symbol(elf).index())) {
        inline else => |sym| elf.targetStore(&sym.size, @intCast(nw.interface.end)),
    }
    // The UAV should already be considered to have moved, because it is created as moved and
    // pending calls to `flushUav` always happen before pending calls to `flushMoved`.
    assert(ni.hasMoved(&elf.mf));
}

fn flushLazy(elf: *Elf, pt: Zcu.PerThread, lmr: Node.LazyMapRef) !void {
    const zcu = pt.zcu;
    const gpa = zcu.gpa;

    const lazy = lmr.lazySymbol(elf);
    const ni = lmr.symbol(elf).index().ptr(elf).node;
    elf.resetNodeRelocs(ni);

    // Ensure the lazy node is marked as moved so that once we're done, `flushMoved` will eventually
    // be called to apply the lazy node's new relocations.
    try ni.moved(gpa, &elf.mf);

    var required_alignment: InternPool.Alignment = .none;
    var nw: MappedFile.Node.Writer = undefined;
    ni.writer(&elf.mf, gpa, &nw);
    defer nw.deinit();
    try codegen.generateLazySymbol(
        &elf.base,
        pt,
        Type.fromInterned(lazy.ty).srcLocOrNull(pt.zcu) orelse .unneeded,
        lazy,
        &required_alignment,
        &nw.interface,
        .none,
        .{ .atom_index = Node.toAtom(ni) },
    );
    switch (elf.symPtr(lmr.symbol(elf).index())) {
        inline else => |sym| elf.targetStore(&sym.size, @intCast(nw.interface.end)),
    }
}

fn flushInputSection(elf: *Elf, isi: InputSection.Index) !void {
    const file_loc = isi.fileLocation(elf);
    if (file_loc.size == 0) return;
    const comp = elf.base.comp;
    const io = comp.io;
    const gpa = comp.gpa;
    const ii = isi.input(elf);
    const path = ii.path(elf);
    const file = try path.root_dir.handle.openFile(io, path.sub_path, .{});
    defer file.close(io);
    var fr = file.reader(io, &.{});
    try fr.seekTo(file_loc.offset);
    var nw: MappedFile.Node.Writer = undefined;
    isi.node(elf).writer(&elf.mf, gpa, &nw);
    defer nw.deinit();
    if (try nw.interface.sendFileAll(&fr, .limited(@intCast(file_loc.size))) != file_loc.size)
        return error.EndOfStream;
    // The input section should already be considered to have moved, because it is created as moved
    // and pending calls to `flushInputSection` always happen before pending calls to `flushMoved`.
    assert(isi.node(elf).hasMoved(&elf.mf));
}

fn flushFileOffset(elf: *Elf, ni: MappedFile.Node.Index) !void {
    switch (elf.getNode(ni)) {
        else => unreachable,
        .ehdr => assert(ni.fileLocation(&elf.mf, false).offset == 0),
        .shdr => switch (elf.ehdrPtr()) {
            inline else => |ehdr| elf.targetStore(
                &ehdr.shoff,
                @intCast(ni.fileLocation(&elf.mf, false).offset),
            ),
        },
        .segment => |phndx| {
            switch (elf.phdrSlice()) {
                inline else => |phdr, class| {
                    const ph = &phdr[phndx];
                    elf.targetStore(&ph.offset, @intCast(ni.fileLocation(&elf.mf, false).offset));
                    if (elf.targetLoad(&ph.type) == .PHDR) {
                        @field(elf.ehdrPtr(), @tagName(class)).phoff = ph.offset;
                    }
                },
            }
            var child_it = ni.children(&elf.mf);
            while (child_it.next()) |child_ni| try elf.flushFileOffset(child_ni);
        },
        .section => |shndx| switch (elf.shdrPtr(shndx)) {
            inline else => |shdr| elf.targetStore(&shdr.offset, @intCast(
                ni.fileLocation(&elf.mf, false).offset,
            )),
        },
    }
}

fn flushMoved(elf: *Elf, ni: MappedFile.Node.Index) !void {
    switch (elf.getNode(ni)) {
        .file => unreachable,
        .ehdr, .shdr => try elf.flushFileOffset(ni),
        .segment => |phndx| {
            try elf.flushFileOffset(ni);
            switch (elf.phdrSlice()) {
                inline else => |phdr| {
                    const ph = &phdr[phndx];
                    switch (elf.targetLoad(&ph.type)) {
                        else => unreachable,
                        .NULL, .LOAD => return,

                        .DYNAMIC,
                        .INTERP,
                        .PHDR,
                        .TLS,
                        .GNU_RELRO,
                        => {},
                    }
                    elf.targetStore(&ph.vaddr, @intCast(elf.computeNodeVAddr(ni)));
                    ph.paddr = ph.vaddr;
                },
            }
        },
        .section => |shndx| {
            try elf.flushFileOffset(ni);
            const addr = elf.computeNodeVAddr(ni);
            switch (elf.shdrPtr(shndx)) {
                inline else => |shdr, class| {
                    const flags = elf.targetLoad(&shdr.flags).shf;
                    if (flags.ALLOC) {
                        if (elf.shndx.dynamic != .UNDEF) {
                            if (shndx == elf.shndx.got) {
                                const old_addr = elf.targetLoad(&shdr.addr);
                                const rela_dyn_shndx = shndx.get(elf).rela_shndx;
                                const relas: []class.ElfN().Rela = @ptrCast(@alignCast(
                                    rela_dyn_shndx.get(elf).ni.slice(&elf.mf)[0..@intCast(
                                        elf.targetLoad(&@field(
                                            elf.shdrPtr(rela_dyn_shndx),
                                            @tagName(class),
                                        ).size),
                                    )],
                                ));
                                switch (elf.ehdrField(.machine)) {
                                    else => |machine| @panic(@tagName(machine)),
                                    .AARCH64, .PPC64, .RISCV => {},
                                    .X86_64 => for (relas) |*rela| switch (@as(
                                        std.elf.R_X86_64,
                                        @enumFromInt(elf.targetLoad(&rela.info).type),
                                    )) {
                                        else => |@"type"| @panic(@tagName(@"type")),
                                        .RELATIVE => {},
                                        .GLOB_DAT, .DTPMOD64, .DTPOFF64 => elf.targetStore(
                                            &rela.offset,
                                            @intCast(elf.targetLoad(&rela.offset) - old_addr + addr),
                                        ),
                                    },
                                }
                            } else if (shndx == elf.shndx.got_plt) {
                                const target_endian = elf.targetEndian();
                                const old_addr = elf.targetLoad(&shdr.addr);
                                const rela_plt_shndx = shndx.get(elf).rela_shndx;
                                const relas: []class.ElfN().Rela = @ptrCast(@alignCast(
                                    rela_plt_shndx.get(elf).ni.slice(&elf.mf)[0..@intCast(
                                        elf.targetLoad(&@field(
                                            elf.shdrPtr(rela_plt_shndx),
                                            @tagName(class),
                                        ).size),
                                    )],
                                ));
                                const plt_sec_slice = elf.shndx.plt_sec.get(elf).ni.slice(&elf.mf);
                                switch (elf.ehdrField(.machine)) {
                                    else => |machine| @panic(@tagName(machine)),
                                    .AARCH64, .PPC64, .RISCV => {},
                                    .X86_64 => {
                                        for (relas) |*rela| switch (@as(
                                            std.elf.R_X86_64,
                                            @enumFromInt(elf.targetLoad(&rela.info).type),
                                        )) {
                                            else => |@"type"| @panic(@tagName(@"type")),
                                            .JUMP_SLOT => elf.targetStore(
                                                &rela.offset,
                                                @intCast(elf.targetLoad(&rela.offset) - old_addr + addr),
                                            ),
                                        };
                                        for (0..elf.got.plt.count()) |plt_index| {
                                            const slice = plt_sec_slice[16 * plt_index + 6 ..][0..4];
                                            std.mem.writeInt(
                                                i32,
                                                slice,
                                                @intCast(@as(i64, @bitCast(@as(u64, @bitCast(@as(
                                                    i64,
                                                    std.mem.readInt(i32, slice, target_endian),
                                                ))) -% old_addr +% addr))),
                                                target_endian,
                                            );
                                        }
                                    },
                                }
                            } else if (shndx == elf.shndx.plt_sec) {
                                const target_endian = elf.targetEndian();
                                const old_addr = elf.targetLoad(&shdr.addr);
                                const plt_sec_slice = ni.slice(&elf.mf);
                                switch (elf.ehdrField(.machine)) {
                                    else => |machine| @panic(@tagName(machine)),
                                    .AARCH64, .PPC64, .RISCV => {},
                                    .X86_64 => for (0..elf.got.plt.count()) |plt_index| {
                                        const slice = plt_sec_slice[16 * plt_index + 6 ..][0..4];
                                        std.mem.writeInt(
                                            i32,
                                            slice,
                                            @intCast(@as(i64, @bitCast(@as(u64, @bitCast(@as(
                                                i64,
                                                std.mem.readInt(i32, slice, target_endian),
                                            ))) -% addr +% old_addr))),
                                            target_endian,
                                        );
                                    },
                                }
                            }
                        }

                        // Update global symbols targeting this section
                        if (elf.node_global_symbols.get(ni)) |first_name| {
                            assert(first_name != .empty);
                            const old_addr = elf.targetLoad(&shdr.addr);
                            var name = first_name;
                            while (name != .empty) {
                                const global = elf.globalByName(name).?;
                                const old_sym_addr: u64 = switch (elf.symPtr(global.symtab_index)) {
                                    inline else => |sym| elf.targetLoad(&sym.value),
                                };
                                global.flushMoved(elf, old_sym_addr - old_addr + addr);
                                name = global.next_in_node;
                            }
                        }

                        elf.targetStore(&shdr.addr, @intCast(addr));
                        shndx.get(elf).lsi.index().flushMoved(elf, addr);
                    }

                    if (shndx == elf.shndx.plt) {
                        elf.flushMovedNodeRelocs(ni, elf.targetLoad(&shdr.addr), elf.first_plt_reloc);
                    } else if (shndx == elf.shndx.dynamic) {
                        elf.flushMovedNodeRelocs(ni, elf.targetLoad(&shdr.addr), elf.first_dynamic_reloc);
                    }
                },
            }
        },
        .input_section => |isi| {
            const old_section_addr = isi.ptr(elf).vaddr;
            const new_section_addr = elf.computeNodeVAddr(ni);
            isi.ptr(elf).vaddr = new_section_addr;

            // Update local symbols
            const ii = isi.input(elf);
            var lsi, const end_lsi = ii.localSymbolRange(elf);
            while (lsi != end_lsi) : (lsi = @enumFromInt(@intFromEnum(lsi) + 1)) {
                if (lsi.index().ptr(elf).node != ni) continue;
                const old_sym_addr: u64 = switch (elf.symPtr(lsi.index())) {
                    inline else => |sym| switch (elf.targetLoad(&sym.other).visibility) {
                        .HIDDEN, .INTERNAL => {
                            // This is actually a global symbol which got demoted to STB_LOCAL due
                            // to its visibility. It will be handled in the global symbols pass
                            // below; don't touch it now.
                            continue;
                        },
                        .PROTECTED => unreachable, // not allowed for an STB_LOCAL symbol
                        .DEFAULT => elf.targetLoad(&sym.value),
                    },
                };
                lsi.index().flushMoved(elf, old_sym_addr - old_section_addr + new_section_addr);
            }

            // Update global symbols
            if (elf.node_global_symbols.get(ni)) |first_name| {
                assert(first_name != .empty);
                var name = first_name;
                while (name != .empty) {
                    const global = elf.globalByName(name).?;
                    const old_sym_addr: u64 = switch (elf.symPtr(global.symtab_index)) {
                        inline else => |sym| elf.targetLoad(&sym.value),
                    };
                    global.flushMoved(elf, old_sym_addr - old_section_addr + new_section_addr);
                    name = global.next_in_node;
                }
            }

            elf.flushMovedNodeRelocs(ni, new_section_addr, isi.ptrConst(elf).first_reloc);
        },
        inline .nav, .uav, .lazy_code, .lazy_const_data => |mi| {
            const new_addr = elf.computeNodeVAddr(ni);
            mi.symbol(elf).index().flushMoved(elf, new_addr);
            if (elf.node_global_symbols.get(ni)) |first_name| {
                assert(first_name != .empty);
                var name = first_name;
                while (name != .empty) {
                    const global = elf.globalByName(name).?;
                    global.flushMoved(elf, new_addr);
                    name = global.next_in_node;
                }
            }
            elf.flushMovedNodeRelocs(ni, new_addr, mi.firstReloc(elf));
        },
    }
    try ni.childrenMoved(elf.base.comp.gpa, &elf.mf);
}

fn flushResized(elf: *Elf, ni: MappedFile.Node.Index) !void {
    _, const size = ni.location(&elf.mf).resolve(&elf.mf);
    switch (elf.getNode(ni)) {
        .file => {},
        .ehdr => unreachable,
        .shdr => {},
        .segment => |phndx| switch (elf.phdrSlice()) {
            inline else => |phdr| {
                assert(elf.phdrs.items[phndx] == ni);
                const ph = &phdr[phndx];
                elf.targetStore(&ph.filesz, @intCast(size));
                if (size > elf.targetLoad(&ph.memsz)) {
                    switch (elf.targetLoad(&ph.type)) {
                        else => unreachable,
                        .NULL => if (size > 0) elf.targetStore(&ph.type, .LOAD),
                        .LOAD => if (size == 0) elf.targetStore(&ph.type, .NULL),
                        .DYNAMIC, .INTERP, .PHDR, std.elf.PT.GNU_RELRO => {
                            elf.targetStore(&ph.memsz, @intCast(size));
                            return;
                        },
                        .TLS => {
                            elf.targetStore(&ph.memsz, @intCast(size));
                            return ni.childrenMoved(elf.base.comp.gpa, &elf.mf);
                        },
                    }
                    const memsz = ni.alignment(&elf.mf).forward(@intCast(size * 4));
                    elf.targetStore(&ph.memsz, @intCast(memsz));
                    var vaddr = elf.targetLoad(&ph.vaddr);
                    var new_phndx = phndx;
                    for (phdr[phndx + 1 ..], phndx + 1..) |*next_ph, next_phndx| {
                        switch (elf.targetLoad(&next_ph.type)) {
                            else => unreachable,
                            .NULL, .LOAD => {},
                            .DYNAMIC, .INTERP, .PHDR, .TLS, std.elf.PT.GNU_RELRO => break,
                        }
                        const next_vaddr = elf.targetLoad(&next_ph.vaddr);
                        if (vaddr + memsz <= next_vaddr) break;
                        vaddr = next_vaddr + elf.targetLoad(&next_ph.memsz);
                        std.mem.swap(@TypeOf(ph.*), &phdr[new_phndx], next_ph);
                        const next_ni = elf.phdrs.items[next_phndx];
                        elf.phdrs.items[new_phndx] = next_ni;
                        elf.nodes.items(.data)[@intFromEnum(next_ni)] = .{ .segment = new_phndx };
                        new_phndx = @intCast(next_phndx);
                    }
                    if (new_phndx != phndx) {
                        const new_ph = &phdr[new_phndx];
                        elf.targetStore(&new_ph.vaddr, vaddr);
                        new_ph.paddr = new_ph.vaddr;
                        elf.phdrs.items[new_phndx] = ni;
                        elf.nodes.items(.data)[@intFromEnum(ni)] = .{ .segment = new_phndx };
                        try ni.childrenMoved(elf.base.comp.gpa, &elf.mf);
                    }
                }
            },
        },
        .section => |shndx| switch (elf.shdrPtr(shndx)) {
            inline else => |shdr, class| {
                switch (elf.targetLoad(&shdr.type)) {
                    else => unreachable,
                    .NULL => if (size > 0) elf.targetStore(&shdr.type, .PROGBITS),
                    .PROGBITS => if (size == 0) elf.targetStore(&shdr.type, .NULL),
                    .SYMTAB, .DYNAMIC, .REL, .DYNSYM => return,
                    .INIT_ARRAY => {
                        assert(shndx == elf.shndx.init_array);
                        if (elf.shndx.dynamic != .UNDEF) {
                            const dynamic_entries: [][2]class.ElfN().Addr = @ptrCast(@alignCast(
                                elf.shndx.dynamic.get(elf).ni.slice(&elf.mf),
                            ));
                            for (dynamic_entries) |*dynamic_entry|
                                switch (elf.targetLoad(&dynamic_entry[0])) {
                                    else => {},
                                    std.elf.DT_INIT_ARRAYSZ => dynamic_entry[1] = shdr.size,
                                };
                        }
                        const end_sym_index = elf.globalByName(elf.string(.strtab, "__init_array_end") catch unreachable).?.symtab_index;
                        const end_sym_ptr = @field(elf.symPtr(end_sym_index), @tagName(class));
                        const end_vaddr = shndx.vaddr(elf) + elf.targetLoad(&shdr.size);
                        elf.targetStore(&end_sym_ptr.value, @intCast(end_vaddr));
                        end_sym_index.flushMoved(elf, end_vaddr);
                        return;
                    },
                    .FINI_ARRAY => {
                        assert(shndx == elf.shndx.fini_array);
                        if (elf.shndx.dynamic != .UNDEF) {
                            const dynamic_entries: [][2]class.ElfN().Addr = @ptrCast(@alignCast(
                                elf.shndx.dynamic.get(elf).ni.slice(&elf.mf),
                            ));
                            for (dynamic_entries) |*dynamic_entry|
                                switch (elf.targetLoad(&dynamic_entry[0])) {
                                    else => {},
                                    std.elf.DT_FINI_ARRAYSZ => dynamic_entry[1] = shdr.size,
                                };
                        }
                        const end_sym_index = elf.globalByName(elf.string(.strtab, "__fini_array_end") catch unreachable).?.symtab_index;
                        const end_sym_ptr = @field(elf.symPtr(end_sym_index), @tagName(class));
                        const end_vaddr = shndx.vaddr(elf) + elf.targetLoad(&shdr.size);
                        elf.targetStore(&end_sym_ptr.value, @intCast(end_vaddr));
                        end_sym_index.flushMoved(elf, end_vaddr);
                        return;
                    },
                    .PREINIT_ARRAY => {
                        assert(shndx == elf.shndx.preinit_array);
                        if (elf.shndx.dynamic != .UNDEF) {
                            const dynamic_entries: [][2]class.ElfN().Addr = @ptrCast(@alignCast(
                                elf.shndx.dynamic.get(elf).ni.slice(&elf.mf),
                            ));
                            for (dynamic_entries) |*dynamic_entry|
                                switch (elf.targetLoad(&dynamic_entry[0])) {
                                    else => {},
                                    std.elf.DT_PREINIT_ARRAYSZ => dynamic_entry[1] = shdr.size,
                                };
                        }
                        const end_sym_index = elf.globalByName(elf.string(.strtab, "__preinit_array_end") catch unreachable).?.symtab_index;
                        const end_sym_ptr = @field(elf.symPtr(end_sym_index), @tagName(class));
                        const end_vaddr = shndx.vaddr(elf) + elf.targetLoad(&shdr.size);
                        elf.targetStore(&end_sym_ptr.value, @intCast(end_vaddr));
                        end_sym_index.flushMoved(elf, end_vaddr);
                        return;
                    },
                    .STRTAB => {
                        if (elf.shndx.dynamic != .UNDEF) {
                            if (shndx == elf.shndx.dynstr) {
                                const dynamic_entries: [][2]class.ElfN().Addr = @ptrCast(@alignCast(
                                    elf.shndx.dynamic.get(elf).ni.slice(&elf.mf),
                                ));
                                for (dynamic_entries) |*dynamic_entry|
                                    switch (elf.targetLoad(&dynamic_entry[0])) {
                                        else => {},
                                        std.elf.DT_STRSZ => dynamic_entry[1] = shdr.size,
                                    };
                            }
                        }
                        return;
                    },
                    .RELA => {
                        if (elf.shndx.dynamic != .UNDEF) {
                            if (shndx == elf.shndx.got.get(elf).rela_shndx) {
                                const dynamic_entries: [][2]class.ElfN().Addr = @ptrCast(@alignCast(
                                    elf.shndx.dynamic.get(elf).ni.slice(&elf.mf),
                                ));
                                for (dynamic_entries) |*dynamic_entry|
                                    switch (elf.targetLoad(&dynamic_entry[0])) {
                                        else => {},
                                        std.elf.DT_RELASZ => dynamic_entry[1] = shdr.size,
                                    };
                            } else if (shndx == elf.shndx.got_plt.get(elf).rela_shndx) {
                                const dynamic_entries: [][2]class.ElfN().Addr = @ptrCast(@alignCast(
                                    elf.shndx.dynamic.get(elf).ni.slice(&elf.mf),
                                ));
                                for (dynamic_entries) |*dynamic_entry|
                                    switch (elf.targetLoad(&dynamic_entry[0])) {
                                        else => {},
                                        std.elf.DT_PLTRELSZ => dynamic_entry[1] = shdr.size,
                                    };
                            }
                        }
                        return;
                    },
                }
                if (shndx != elf.shndx.plt) {
                    elf.targetStore(&shdr.size, @intCast(size));
                }
            },
        },
        .input_section, .nav, .uav, .lazy_code, .lazy_const_data => {},
    }
}

pub fn updateExports(
    elf: *Elf,
    pt: Zcu.PerThread,
    exported: Zcu.Exported,
    export_indices: []const Zcu.Export.Index,
) !void {
    return elf.updateExportsInner(pt, exported, export_indices) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.LinkFailure => error.AnalysisFail,
        else => |e| switch (elf.base.comp.link_diags.fail(
            "linker failed to update exports: {t}",
            .{e},
        )) {
            error.LinkFailure => return error.AnalysisFail,
        },
    };
}
fn updateExportsInner(
    elf: *Elf,
    pt: Zcu.PerThread,
    exported: Zcu.Exported,
    export_indices: []const Zcu.Export.Index,
) !void {
    const zcu = pt.zcu;
    const ip = &zcu.intern_pool;

    switch (exported) {
        .nav => |nav| log.debug("updateExports({f})", .{ip.getNav(nav).fqn.fmt(ip)}),
        .uav => |uav| log.debug("updateExports(@as({f}, {f}))", .{
            Type.fromInterned(ip.typeOf(uav)).fmt(pt),
            Value.fromInterned(uav).fmtValue(pt),
        }),
    }
    try elf.ensureUnusedSymbolCapacity(@intCast(export_indices.len), .maybe_global);
    const exported_lsi: Symbol.LocalIndex, const @"type": std.elf.STT = switch (exported) {
        .nav => |nav| .{
            (try elf.navMapIndex(zcu, nav)).symbol(elf),
            elf.navType(ip.getNav(nav).resolved.?),
        },
        .uav => |uav| .{ (try elf.uavMapIndex(uav, .none)).symbol(elf), .OBJECT },
    };
    while (try elf.idle(pt.tid)) {}
    const value: u64, const size: u64, const shndx: Section.Index = switch (elf.symPtr(exported_lsi.index())) {
        inline else => |exported_sym| .{
            elf.targetLoad(&exported_sym.value),
            elf.targetLoad(&exported_sym.size),
            .fromSection(elf.targetLoad(&exported_sym.shndx)),
        },
    };
    for (export_indices) |export_index| {
        const @"export" = export_index.ptr(zcu);
        const name = @"export".opts.name.toSlice(ip);
        _ = elf.addGlobalSymbolAssumeCapacity(.{
            .node = .none,
            .name = try .string(elf, name),
            .value = value,
            .size = @intCast(size),
            .type = @"type",
            .bind = switch (@"export".opts.linkage) {
                .internal => @panic("TODO internal linkage"),
                .strong => .strong,
                .weak => .weak,
                .link_once => return error.LinkOnceUnsupported,
            },
            .visibility = switch (@"export".opts.visibility) {
                .default => .DEFAULT,
                .hidden => .HIDDEN,
                .protected => .PROTECTED,
            },
            .shndx = shndx,
        }) catch |err| switch (err) {
            error.MultipleDefinitions => {
                // HACK: because we currently don't/can't delete these exports, we would typically
                // get these errors on every non-initial incremental update. Hack around that by
                // only emitting this error if the symbol we're conflicting with comes from an input
                // section (as opposed to the ZCU).
                const conflicting_global = elf.globalByName(try elf.string(.strtab, name)).?;
                const conflicting_node = conflicting_global.symtab_index.ptr(elf).node;
                if (elf.getNode(conflicting_node) == .input_section) {
                    return elf.base.comp.link_diags.fail(
                        "multiple definitions of '{s}'",
                        .{name},
                    );
                }
            },
        };
    }
}

pub fn deleteExport(elf: *Elf, exported: Zcu.Exported, name: InternPool.NullTerminatedString) void {
    _ = elf;
    _ = exported;
    _ = name;
}

pub fn dump(elf: *Elf, tid: Zcu.PerThread.Id) Io.Cancelable!void {
    const comp = elf.base.comp;
    const io = comp.io;
    var buffer: [512]u8 = undefined;
    const stderr = try io.lockStderr(&buffer, null);
    defer io.lockStderr();
    const w = &stderr.file_writer.interface;
    elf.printNode(tid, w, .root, 0) catch |err| switch (err) {
        error.WriteFailed => return stderr.err.?,
    };
}

pub fn printNode(
    elf: *Elf,
    tid: Zcu.PerThread.Id,
    w: *std.Io.Writer,
    ni: MappedFile.Node.Index,
    indent: usize,
) !void {
    const node = elf.getNode(ni);
    try w.splatByteAll(' ', indent);
    try w.writeAll(@tagName(node));
    switch (node) {
        else => {},
        .segment => |phndx| switch (elf.phdrSlice()) {
            inline else => |phdr| {
                const ph = &phdr[phndx];
                try w.writeByte('(');
                const pt = elf.targetLoad(&ph.type);
                if (std.enums.tagName(std.elf.PT, pt)) |pt_name|
                    try w.writeAll(pt_name)
                else inline for (@typeInfo(std.elf.PT).@"enum".decls) |decl| {
                    const decl_val = @field(std.elf.PT, decl.name);
                    if (@TypeOf(decl_val) != std.elf.PT) continue;
                    if (pt == @field(std.elf.PT, decl.name)) break try w.writeAll(decl.name);
                } else try w.print("0x{x}", .{pt});
                try w.writeAll(", ");
                const pf = elf.targetLoad(&ph.flags);
                if (pf.R) try w.writeByte('R');
                if (pf.W) try w.writeByte('W');
                if (pf.X) try w.writeByte('X');
                try w.writeByte(')');
            },
        },
        .section => |shndx| try w.print("({s})", .{shndx.name(elf).slice(elf)}),
        .input_section => |isi| {
            const ii = isi.input(elf);
            try w.print("({f}{f}, {s})", .{
                ii.path(elf).fmtEscapeString(),
                fmtMemberString(ii.member(elf)),
                elf.getNode(isi.node(elf).parent(&elf.mf)).section.name(elf).slice(elf),
            });
        },
        .nav => |nmi| {
            const zcu = elf.base.comp.zcu.?;
            const ip = &zcu.intern_pool;
            const nav = ip.getNav(nmi.navIndex(elf));
            try w.print("({f}, {f})", .{
                Type.fromInterned(nav.typeOf(ip)).fmt(.{ .zcu = zcu, .tid = tid }),
                nav.fqn.fmt(ip),
            });
        },
        .uav => |umi| {
            const zcu = elf.base.comp.zcu.?;
            const val: Value = .fromInterned(umi.uavValue(elf));
            try w.print("({f}, {f})", .{
                val.typeOf(zcu).fmt(.{ .zcu = zcu, .tid = tid }),
                val.fmtValue(.{ .zcu = zcu, .tid = tid }),
            });
        },
        inline .lazy_code, .lazy_const_data => |lmi| try w.print("({f})", .{
            Type.fromInterned(lmi.lazySymbol(elf).ty).fmt(.{
                .zcu = elf.base.comp.zcu.?,
                .tid = tid,
            }),
        }),
    }
    {
        const mf_node = &elf.mf.nodes.items[@intFromEnum(ni)];
        const off, const size = mf_node.location().resolve(&elf.mf);
        try w.print(" index={d} offset=0x{x} size=0x{x} align=0x{x}{s}{s}{s}{s}\n", .{
            @intFromEnum(ni),
            off,
            size,
            mf_node.flags.alignment.toByteUnits(),
            if (mf_node.flags.fixed) " fixed" else "",
            if (mf_node.flags.moved) " moved" else "",
            if (mf_node.flags.resized) " resized" else "",
            if (mf_node.flags.has_content) " has_content" else "",
        });
    }
    var leaf = true;
    var child_it = ni.children(&elf.mf);
    while (child_it.next()) |child_ni| {
        leaf = false;
        try elf.printNode(tid, w, child_ni, indent + 1);
    }
    if (!leaf) return;
    const file_loc = ni.fileLocation(&elf.mf, false);
    var address = file_loc.offset;
    if (file_loc.size == 0) {
        try w.splatByteAll(' ', indent + 1);
        try w.print("{x:0>8}\n", .{address});
        return;
    }
    const line_len = 0x10;
    var line_it = std.mem.window(
        u8,
        elf.mf.memory_map.memory[@intCast(file_loc.offset)..][0..@intCast(file_loc.size)],
        line_len,
        line_len,
    );
    while (line_it.next()) |line_bytes| : (address += line_len) {
        try w.splatByteAll(' ', indent + 1);
        try w.print("{x:0>8}  ", .{address});
        for (line_bytes) |byte| try w.print("{x:0>2} ", .{byte});
        try w.splatByteAll(' ', 3 * (line_len - line_bytes.len) + 1);
        for (line_bytes) |byte| try w.writeByte(if (std.ascii.isPrint(byte)) byte else '.');
        try w.writeByte('\n');
    }
}
