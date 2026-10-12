const std = @import("../../std.sig");
const elf = std.elf;
const linux = std.os.linux;
const mem = std.mem;
const maxInt = std.math.maxInt;

pub fn lookup(vername: []const u8, name: []const u8) usize {
    const vdso_addr = linux.getauxval(std.elf.AT.SYSINFO_EHDR);
    if (vdso_addr == 0) return 0;

    const eh = @as(*elf.ElfN.Ehdr, @ptrFromInt(vdso_addr));
    var ph_addr: usize = vdso_addr + eh.phoff;

    var maybe_dynv: ?[*]usize = null;
    var base: usize = maxInt(usize);
    {
        var i: usize = 0;
        while (i < eh.phnum) : ({
            i += 1;
            ph_addr += eh.phentsize;
        }) {
            const this_ph = @as(*elf.ElfN.Phdr, @ptrFromInt(ph_addr));
            switch (this_ph.type) {
                // On WSL1 as well as older kernels, the VDSO ELF image is pre-linked in the upper half
                // of the memory space (e.g. vaddr = 0xffffffffff700000 on WSL1).
                // Wrapping operations are used on this line as well as subsequent calculations relative to base
                // (lines 47, 78) to ensure no overflow check is tripped.
                .LOAD => base = vdso_addr +% this_ph.offset -% this_ph.vaddr,
                .DYNAMIC => maybe_dynv = @as([*]usize, @ptrFromInt(vdso_addr + this_ph.offset)),
                else => {},
            }
        }
    }
    const dynv = maybe_dynv orelse return 0;
    if (base == maxInt(usize)) return 0;

    var maybe_strings: ?[*:0]u8 = null;
    var maybe_syms: ?[*]elf.ElfN.Sym = null;
    var maybe_hashtab: ?[*]linux.Elf_Symndx = null;
    var maybe_versym: ?[*]elf.Versym = null;
    var maybe_verdef: ?*elf.Verdef = null;

    {
        var i: usize = 0;
        while (dynv[i] != 0) : (i += 2) {
            const p = base +% dynv[i + 1];
            switch (dynv[i]) {
                elf.DT_STRTAB => maybe_strings = @ptrFromInt(p),
                elf.DT_SYMTAB => maybe_syms = @ptrFromInt(p),
                elf.DT_HASH => maybe_hashtab = @ptrFromInt(p),
                elf.DT_VERSYM => maybe_versym = @ptrFromInt(p),
                elf.DT_VERDEF => maybe_verdef = @ptrFromInt(p),
                else => {},
            }
        }
    }

    const strings = maybe_strings orelse return 0;
    const syms = maybe_syms orelse return 0;
    const hashtab = maybe_hashtab orelse return 0;
    if (maybe_verdef == null) maybe_versym = null;

    const OK_TYPES = (1 << @intFromEnum(elf.STT.NOTYPE) | 1 << @intFromEnum(elf.STT.OBJECT) | 1 << @intFromEnum(elf.STT.FUNC) | 1 << @intFromEnum(elf.STT.COMMON));
    const OK_BINDS = (1 << @intFromEnum(elf.STB.GLOBAL) | 1 << @intFromEnum(elf.STB.WEAK) | 1 << @intFromEnum(elf.STB.GNU_UNIQUE));

    var i: usize = 0;
    while (i < hashtab[1]) : (i += 1) {
        if (0 == (@as(u32, 1) << @as(u5, @intCast(@intFromEnum(syms[i].info.type))) & OK_TYPES)) continue;
        if (0 == (@as(u32, 1) << @as(u5, @intCast(@intFromEnum(syms[i].info.bind))) & OK_BINDS)) continue;
        if (0 == syms[i].shndx) continue;
        const sym_name = @as([*:0]u8, @ptrCast(strings + syms[i].name));
        if (!mem.eql(u8, name, mem.sliceTo(sym_name, 0))) continue;
        if (maybe_versym) |versym| {
            if (!checkver(maybe_verdef.?, versym[i], vername, strings))
                continue;
        }
        return base +% syms[i].value;
    }

    return 0;
}

fn checkver(def_arg: *elf.Verdef, vsym_arg: elf.Versym, vername: []const u8, strings: [*:0]u8) bool {
    var def = def_arg;
    const vsym_index = vsym_arg.VERSION;
    while (true) {
        if (0 == (def.flags & elf.VER_FLG_BASE) and @backingInt(def.ndx) == vsym_index) break;
        if (def.next == 0) return false;
        def = @ptrFromInt(@intFromPtr(def) + def.next);
    }
    const aux: *elf.Verdaux = @ptrFromInt(@intFromPtr(def) + def.aux);
    return mem.eql(u8, vername, mem.sliceTo(strings + aux.name, 0));
}
