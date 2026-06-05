const Coff = @This();

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
const ModuleDefinition = @import("../libs/mingw/def.zig").ModuleDefinition;
const implib = @import("../libs/mingw/implib.zig");

base: link.File,
mf: MappedFile,
nodes: std.MultiArrayList(Node),
members: std.ArrayList(Member),
pending_members: std.AutoArrayHashMapUnmanaged(Member.Index, void),
lib_string_table: std.ArrayList(String),
lib_string_len: u64,
long_names_table: LongNamesTable,
import_table: ImportTable,
export_table: ExportTable,
strings: std.HashMapUnmanaged(
    u32,
    void,
    std.hash_map.StringIndexContext,
    std.hash_map.default_max_load_percentage,
),
string_bytes: std.ArrayList(u8),
image_section_table: std.ArrayList(Symbol.Index),
pseudo_section_table: std.array_hash_map.Auto(String, Symbol.Index),
object_section_table: std.array_hash_map.Auto(String, Symbol.Index),
symbol_table: std.ArrayList(Symbol),
globals: std.array_hash_map.Auto(GlobalName, Symbol.Index),
global_pending_index: u32,
navs: std.array_hash_map.Auto(InternPool.Nav.Index, Symbol.Index),
uavs: std.array_hash_map.Auto(InternPool.Index, Symbol.Index),
lazy: std.EnumArray(link.File.LazySymbol.Kind, struct {
    map: std.array_hash_map.Auto(InternPool.Index, Symbol.Index),
    pending_index: u32,
}),
pending_uavs: std.array_hash_map.Auto(Node.UavMapIndex, struct {
    alignment: InternPool.Alignment,
}),
relocs: std.ArrayList(Reloc),
const_prog_node: std.Progress.Node,
synth_prog_node: std.Progress.Node,

pub const default_file_alignment: u16 = 0x200;
pub const default_size_of_stack_reserve: u32 = 0x1000000;
pub const default_size_of_stack_commit: u32 = 0x1000;
pub const default_size_of_heap_reserve: u32 = 0x100000;
pub const default_size_of_heap_commit: u32 = 0x1000;

/// This is the start of a Portable Executable (PE) file.
/// It starts with a MS-DOS header followed by a MS-DOS stub program.
/// This data does not change so we include it as follows in all binaries.
///
/// In this context,
/// A "paragraph" is 16 bytes.
/// A "page" is 512 bytes.
/// A "long" is 4 bytes.
/// A "word" is 2 bytes.
pub const msdos_stub: [120]u8 = .{
    'M', 'Z', // Magic number. Stands for Mark Zbikowski (designer of the MS-DOS executable format).
    0x78, 0x00, // Number of bytes in the last page. This matches the size of this entire MS-DOS stub.
    0x01, 0x00, // Number of pages.
    0x00, 0x00, // Number of entries in the relocation table.
    0x04, 0x00, // The number of paragraphs taken up by the header. 4 * 16 = 64, which matches the header size (all bytes before the MS-DOS stub program).
    0x00, 0x00, // The number of paragraphs required by the program.
    0x00, 0x00, // The number of paragraphs requested by the program.
    0x00, 0x00, // Initial value for SS (relocatable segment address).
    0x00, 0x00, // Initial value for SP.
    0x00, 0x00, // Checksum.
    0x00, 0x00, // Initial value for IP.
    0x00, 0x00, // Initial value for CS (relocatable segment address).
    0x40, 0x00, // Absolute offset to relocation table. 64 matches the header size (all bytes before the MS-DOS stub program).
    0x00, 0x00, // Overlay number. Zero means this is the main executable.
}
    // Reserved words.
    ++ .{
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
    }
    // OEM-related fields.
    ++ .{
        0x00, 0x00, // OEM identifier.
        0x00, 0x00, // OEM information.
    }
    // Reserved words.
    ++ .{
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
    }
    // Address of the PE header (a long). This matches the size of this entire MS-DOS stub, so that's the address of what's after this MS-DOS stub.
    ++ .{ 0x78, 0x00, 0x00, 0x00 }
    // What follows is a 16-bit x86 MS-DOS program of 7 instructions that prints the bytes after these instructions and then exits.
    ++ .{
        // Set the value of the data segment to the same value as the code segment.
        0x0e, // push cs
        0x1f, // pop ds
        // Set the DX register to the address of the message.
        // If you count all bytes of these 7 instructions you get 14, so that's the address of what's after these instructions.
        0xba, 14, 0x00, // mov dx, 14
        // Set AH to the system call code for printing a message.
        0xb4, 0x09, // mov ah, 0x09
        // Perform the system call to print the message.
        0xcd, 0x21, // int 0x21
        // Set AH to 0x4c which is the system call code for exiting, and set AL to 0x01 which is the exit code.
        0xb8, 0x01, 0x4c, // mov ax, 0x4c01
        // Peform the system call to exit the program with exit code 1.
        0xcd, 0x21, // int 0x21
    }
    // Message to print.
    ++ "This program cannot be run in DOS mode.".*
    // Message terminators.
    ++ .{
        '$', // We do not pass a length to the print system call; the string is terminated by this character.
        0x00, 0x00, // Terminating zero bytes.
    };

pub const Node = union(enum) {
    file,
    header,
    /// Images and archives only.
    signature,
    /// Archives only.
    archive_member_header: Member.Index,
    archive_member: Member.Index,

    coff_header,
    /// Image only
    optional_header,
    /// Image only
    data_directories,
    section_table,
    image_section: Symbol.Index,

    /// Only images contain imports
    import_directory_table,
    import_lookup_table: ImportTable.Index,
    import_address_table: ImportTable.Index,
    import_hint_name_table: ImportTable.Index,

    /// Only images contain exports
    export_directory_table,
    export_address_table,
    export_name_pointer_table,
    export_ordinal_table,
    export_name_table,

    pseudo_section: PseudoSectionMapIndex,
    object_section: ObjectSectionMapIndex,
    global: GlobalMapIndex,
    nav: NavMapIndex,
    uav: UavMapIndex,
    lazy_code: LazyMapRef.Index(.code),
    lazy_const_data: LazyMapRef.Index(.const_data),

    /// Takes the place of a known node index when that node is not present in the output
    placeholder,

    pub const PseudoSectionMapIndex = enum(u32) {
        _,

        pub fn name(psmi: PseudoSectionMapIndex, coff: *const Coff) String {
            return coff.pseudo_section_table.keys()[@intFromEnum(psmi)];
        }

        pub fn symbol(psmi: PseudoSectionMapIndex, coff: *const Coff) Symbol.Index {
            return coff.pseudo_section_table.values()[@intFromEnum(psmi)];
        }
    };

    pub const ObjectSectionMapIndex = enum(u32) {
        _,

        pub fn name(osmi: ObjectSectionMapIndex, coff: *const Coff) String {
            return coff.object_section_table.keys()[@intFromEnum(osmi)];
        }

        pub fn symbol(osmi: ObjectSectionMapIndex, coff: *const Coff) Symbol.Index {
            return coff.object_section_table.values()[@intFromEnum(osmi)];
        }
    };

    pub const GlobalMapIndex = enum(u32) {
        _,

        pub fn globalName(gmi: GlobalMapIndex, coff: *const Coff) GlobalName {
            return coff.globals.keys()[@intFromEnum(gmi)];
        }

        pub fn symbol(gmi: GlobalMapIndex, coff: *const Coff) Symbol.Index {
            return coff.globals.values()[@intFromEnum(gmi)];
        }
    };

    pub const NavMapIndex = enum(u32) {
        _,

        pub fn navIndex(nmi: NavMapIndex, coff: *const Coff) InternPool.Nav.Index {
            return coff.navs.keys()[@intFromEnum(nmi)];
        }

        pub fn symbol(nmi: NavMapIndex, coff: *const Coff) Symbol.Index {
            return coff.navs.values()[@intFromEnum(nmi)];
        }
    };

    pub const UavMapIndex = enum(u32) {
        _,

        pub fn uavValue(umi: UavMapIndex, coff: *const Coff) InternPool.Index {
            return coff.uavs.keys()[@intFromEnum(umi)];
        }

        pub fn symbol(umi: UavMapIndex, coff: *const Coff) Symbol.Index {
            return coff.uavs.values()[@intFromEnum(umi)];
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

                pub fn lazySymbol(lmi: @This(), coff: *const Coff) link.File.LazySymbol {
                    return lmi.ref().lazySymbol(coff);
                }

                pub fn symbol(lmi: @This(), coff: *const Coff) Symbol.Index {
                    return lmi.ref().symbol(coff);
                }
            };
        }

        pub fn lazySymbol(lmr: LazyMapRef, coff: *const Coff) link.File.LazySymbol {
            return .{ .kind = lmr.kind, .ty = coff.lazy.getPtrConst(lmr.kind).map.keys()[lmr.index] };
        }

        pub fn symbol(lmr: LazyMapRef, coff: *const Coff) Symbol.Index {
            return coff.lazy.getPtrConst(lmr.kind).map.values()[lmr.index];
        }
    };

    pub const Tag = @typeInfo(Node).@"union".tag_type.?;

    const known_count = @typeInfo(@TypeOf(known)).@"struct".field_names.len;
    const known = known: {
        const Known = enum {
            file,
            header,
            signature,
            first_linker_member_header,
            first_linker_member,
            second_linker_member_header,
            second_linker_member,
            longnames_member_header,
            longnames_member,
            zcu_member_header,
            zcu_member,
            coff_header,
            optional_header,
            data_directories,
            section_table,
        };
        var mut_known: std.enums.EnumFieldStruct(Known, MappedFile.Node.Index, null) = undefined;
        const info = @typeInfo(Known).@"enum";
        for (info.field_names, info.field_values) |field_name, field_value|
            @field(mut_known, field_name) = @enumFromInt(field_value);
        break :known mut_known;
    };

    comptime {
        if (!std.debug.runtime_safety) std.debug.assert(@sizeOf(Node) == 8);
    }
};

pub const Member = struct {
    kind: Kind,
    header_ni: MappedFile.Node.Index,
    content_ni: MappedFile.Node.Index,
    // Maps symbols contained in this member to their index in the first linker member's symbol table
    // TODO: This could contain information about the name string if we need
    symbol_offsets: std.AutoArrayHashMapUnmanaged(Symbol.Index, u33),

    pub const Kind = enum {
        first_linker,
        second_linker,
        longnames,
        coff,
        import,
    };

    pub const Index = enum(u16) {
        first,
        second,
        longnames,
        _,

        const known_count = @typeInfo(Index).@"enum".fields.len;

        pub fn get(member_index: Member.Index, coff: *Coff) *Member {
            return &coff.members.items[@intFromEnum(member_index)];
        }
    };

    pub fn headerPtr(member: *Member, coff: *Coff) *std.coff.ArchiveMemberHeader {
        return @ptrCast(@alignCast(member.header_ni.slice(&coff.mf)));
    }

    pub fn initHeader(member: *Member, coff: *Coff, name: []const u8, timestamp: u32) !void {
        const header = member.headerPtr(coff);
        try storeHeaderName(coff, &header.name, name);
        storeHeaderDecimalStr(&header.date, timestamp);

        // Matching the Microsoft behaviour of emitting blanks for these fields
        header.user_id = @splat(' ');
        header.group_id = @splat(' ');

        // file_mode is actually octal, but we only ever write 0 to it
        storeHeaderDecimalStr(&header.file_mode, 0);
        if (!member.content_ni.hasResized(&coff.mf))
            storeHeaderDecimalStr(
                &header.size,
                member.content_ni.location(&coff.mf).resolve(&coff.mf)[1],
            );

        @memcpy(&header.end_of_header, "`\n");
    }

    /// Sets `name` as the name field of this member's header, either directly (if it's short enough),
    /// or by creating an entry in the longnames member and storing a reference to that entry.
    pub fn storeHeaderName(coff: *Coff, field: *[16]u8, name: []const u8) !void {
        if (name.len < field.len) {
            @memcpy(field[0..name.len], name);
            field[name.len] = '/';
            const padding = field.len - name.len - 1;
            if (padding > 0) @memset(field[field.len - padding ..], ' ');
        } else {
            const gpa = coff.base.comp.gpa;
            const entries_ctx = LongNamesTable.Adapter{ .coff = coff };
            const gop = try coff.long_names_table.entries.getOrPutAdapted(
                gpa,
                name,
                entries_ctx,
            );

            if (!gop.found_existing) {
                errdefer _ = coff.export_table.entries.pop();

                _, const old_size = Node.known.longnames_member.location(&coff.mf).resolve(&coff.mf);
                const new_size = old_size + name.len + 1;
                assert(new_size < comptime try std.math.powi(u64, 10, field.len - 1));

                try Node.known.longnames_member.resize(&coff.mf, gpa, new_size);
                const name_table_slice = Node.known.longnames_member.slice(&coff.mf);
                const name_slice = name_table_slice[old_size..][0 .. name.len + 1];
                @memcpy(name_slice[0..name.len], name);
                name_slice[name.len] = 0;

                gop.value_ptr.* = .{
                    .index = old_size,
                    .len = name.len,
                };
            }

            field[0] = '/';
            storeHeaderDecimalStr(field[1..], gop.value_ptr.index);
        }
    }

    pub fn storeHeaderDecimalStr(field_ptr: anytype, value: u64) void {
        const array_info = @typeInfo(@typeInfo(@TypeOf(field_ptr)).pointer.child).array;
        assert(array_info.child == u8);
        assert(value < comptime try std.math.powi(u64, 10, array_info.len));
        _ = std.fmt.printInt(field_ptr, value, 10, .lower, .{
            .width = array_info.len,
            .alignment = .left,
            .fill = ' ',
        });
    }
};

pub const LongNamesTable = struct {
    ni: MappedFile.Node.Index = .none,
    entries: std.AutoArrayHashMapUnmanaged(void, Entry),

    pub const Entry = struct {
        index: u64,
        len: u64,
    };

    const Adapter = struct {
        coff: *Coff,

        pub fn eql(adapter: Adapter, lhs_key: []const u8, _: void, rhs_index: usize) bool {
            assert(adapter.coff.isArchive()); // TODO: move to helper that uses this
            const longnames_slice = Node.known.longnames_member.slice(&adapter.coff.mf);
            const rhs = adapter.coff.long_names_table.entries.values()[rhs_index];
            return std.mem.eql(u8, longnames_slice[rhs.index..][0..rhs.len], lhs_key);
        }

        pub fn hash(_: Adapter, key: []const u8) u32 {
            assert(std.mem.indexOfScalar(u8, key, 0) == null);
            return std.array_hash_map.hashString(key);
        }
    };
};

pub const ExportTable = struct {
    ni: MappedFile.Node.Index,
    export_directory_table_ni: MappedFile.Node.Index,
    export_address_table_si: Symbol.Index,
    name_pointer_table_ni: MappedFile.Node.Index,
    ordinal_table_ni: MappedFile.Node.Index,
    name_table_ni: MappedFile.Node.Index,
    entries: std.AutoArrayHashMapUnmanaged(void, Entry),
    pending_sort: bool = false,

    pub const Entry = struct {
        si: Symbol.Index,
        name_index: u32,
        name_len: u32,
        export_address_table_ri: Reloc.Index,
    };

    const Adapter = struct {
        coff: *Coff,

        pub fn eql(adapter: Adapter, lhs_key: []const u8, _: void, rhs_index: usize) bool {
            const coff = adapter.coff;
            const name_table_slice = coff.export_table.name_table_ni.slice(&coff.mf);
            const rhs = coff.export_table.entries.values()[rhs_index];
            return std.mem.eql(u8, name_table_slice[rhs.name_index..][0..rhs.name_len], lhs_key);
        }

        pub fn hash(_: Adapter, key: []const u8) u32 {
            assert(std.mem.indexOfScalar(u8, key, 0) == null);
            return std.array_hash_map.hashString(key);
        }
    };

    pub const Ordinal = enum(u16) {
        _,

        pub fn get(export_index: ExportTable.Ordinal, coff: *Coff) *Entry {
            return &coff.export_table.entries.values()[@intFromEnum(export_index)];
        }
    };
};

pub const ImportTable = struct {
    ni: MappedFile.Node.Index,
    entries: std.array_hash_map.Auto(void, Entry),

    pub const Entry = struct {
        import_lookup_table_ni: MappedFile.Node.Index,
        import_address_table_si: Symbol.Index,
        import_hint_name_table_ni: MappedFile.Node.Index,
        len: u32,
        hint_name_len: u32,
    };

    const Adapter = struct {
        coff: *Coff,

        pub fn eql(adapter: Adapter, lhs_key: []const u8, _: void, rhs_index: usize) bool {
            const coff = adapter.coff;
            const dll_name = coff.import_table.entries.values()[rhs_index]
                .import_hint_name_table_ni.sliceConst(&coff.mf);
            return std.mem.startsWith(u8, dll_name, lhs_key) and
                std.mem.startsWith(u8, dll_name[lhs_key.len..], ".dll\x00");
        }

        pub fn hash(_: Adapter, key: []const u8) u32 {
            assert(std.mem.indexOfScalar(u8, key, 0) == null);
            return std.array_hash_map.hashString(key);
        }
    };

    pub const Index = enum(u32) {
        _,

        pub fn get(import_index: ImportTable.Index, coff: *Coff) *Entry {
            return &coff.import_table.entries.values()[@intFromEnum(import_index)];
        }
    };
};

pub const String = enum(u32) {
    @".data" = 0,
    @".idata" = 6,
    @".rdata" = 13,
    @".text" = 20,
    @".tls$" = 26,
    @".edata" = 32,
    _,

    pub const Optional = enum(u32) {
        @".data" = @intFromEnum(String.@".data"),
        @".rdata" = @intFromEnum(String.@".rdata"),
        @".text" = @intFromEnum(String.@".text"),
        @".tls$" = @intFromEnum(String.@".tls$"),
        @".edata" = @intFromEnum(String.@".edata"),
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(os: String.Optional) ?String {
            return switch (os) {
                else => |s| @enumFromInt(@intFromEnum(s)),
                .none => null,
            };
        }

        pub fn toSlice(os: String.Optional, coff: *Coff) ?[:0]const u8 {
            return (os.unwrap() orelse return null).toSlice(coff);
        }
    };

    pub fn toSlice(s: String, coff: *Coff) [:0]const u8 {
        const slice = coff.string_bytes.items[@intFromEnum(s)..];
        return slice[0..std.mem.indexOfScalar(u8, slice, 0).? :0];
    }

    pub fn toOptional(s: String) String.Optional {
        return @enumFromInt(@intFromEnum(s));
    }
};

pub const GlobalName = struct { name: String, lib_name: String.Optional };

pub const Symbol = struct {
    ni: MappedFile.Node.Index,
    rva: u32,
    size: u32,
    /// Relocations contained within this symbol
    loc_relocs: Reloc.Index,
    /// Relocations targeting this symbol
    target_relocs: Reloc.Index,
    section_number: SectionNumber,
    unused0: u32 = 0,
    unused1: u32 = 0,
    unused2: u16 = 0,

    pub const SectionNumber = enum(i16) {
        UNDEFINED = 0,
        ABSOLUTE = -1,
        DEBUG = -2,
        _,

        fn toIndex(sn: SectionNumber) u15 {
            return @intCast(@intFromEnum(sn) - 1);
        }

        pub fn symbol(sn: SectionNumber, coff: *const Coff) Symbol.Index {
            return coff.image_section_table.items[sn.toIndex()];
        }

        pub fn header(sn: SectionNumber, coff: *Coff) *std.coff.SectionHeader {
            return &coff.sectionTableSlice()[sn.toIndex()];
        }
    };

    pub const Index = enum(u32) {
        null,
        data,
        rdata,
        text,
        _,

        const known_count = @typeInfo(Index).@"enum".field_names.len;

        pub fn get(si: Symbol.Index, coff: *Coff) *Symbol {
            return &coff.symbol_table.items[@intFromEnum(si)];
        }

        pub fn node(si: Symbol.Index, coff: *Coff) MappedFile.Node.Index {
            const ni = si.get(coff).ni;
            assert(ni != .none);
            return ni;
        }

        pub fn flushMoved(si: Symbol.Index, coff: *Coff) void {
            const sym = si.get(coff);
            sym.rva = coff.computeNodeRva(sym.ni);
            si.applyLocationRelocs(coff);
            si.applyTargetRelocs(coff);
        }

        pub fn applyLocationRelocs(si: Symbol.Index, coff: *Coff) void {
            for (coff.relocs.items[@intFromEnum(si.get(coff).loc_relocs)..]) |*reloc| {
                if (reloc.loc != si) break;
                reloc.apply(coff);
            }
        }

        pub fn applyTargetRelocs(si: Symbol.Index, coff: *Coff) void {
            var ri = si.get(coff).target_relocs;
            while (ri != .none) {
                const reloc = ri.get(coff);
                assert(reloc.target == si);
                reloc.apply(coff);
                ri = reloc.next;
            }
        }

        pub fn deleteLocationRelocs(si: Symbol.Index, coff: *Coff) void {
            const sym = si.get(coff);
            for (coff.relocs.items[@intFromEnum(sym.loc_relocs)..]) |*reloc| {
                if (reloc.loc != si) break;
                reloc.delete(coff);
            }
            sym.loc_relocs = .none;
        }
    };

    comptime {
        if (!std.debug.runtime_safety) std.debug.assert(@sizeOf(Symbol) == 32);
    }
};

pub const Reloc = extern struct {
    type: Reloc.Type,
    prev: Reloc.Index,
    next: Reloc.Index,
    loc: Symbol.Index,
    target: Symbol.Index,
    unused: u32,
    offset: u64,
    addend: i64,

    pub const Type = extern union {
        AMD64: std.coff.IMAGE.REL.AMD64,
        ARM: std.coff.IMAGE.REL.ARM,
        ARM64: std.coff.IMAGE.REL.ARM64,
        SH: std.coff.IMAGE.REL.SH,
        PPC: std.coff.IMAGE.REL.PPC,
        I386: std.coff.IMAGE.REL.I386,
        IA64: std.coff.IMAGE.REL.IA64,
        MIPS: std.coff.IMAGE.REL.MIPS,
        M32R: std.coff.IMAGE.REL.M32R,
    };

    pub const Index = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn get(si: Reloc.Index, coff: *Coff) *Reloc {
            return &coff.relocs.items[@intFromEnum(si)];
        }
    };

    pub fn apply(reloc: *const Reloc, coff: *Coff) void {
        const loc_sym = reloc.loc.get(coff);
        switch (loc_sym.ni) {
            .none => return,
            else => |ni| if (ni.hasMoved(&coff.mf)) return,
        }
        const target_sym = reloc.target.get(coff);
        switch (target_sym.ni) {
            .none => return,
            else => |ni| if (ni.hasMoved(&coff.mf)) return,
        }
        const loc_slice = loc_sym.ni.slice(&coff.mf)[@intCast(reloc.offset)..];
        const target_rva = target_sym.rva +% @as(u64, @bitCast(reloc.addend));
        const target_endian = coff.targetEndian();

        // TODO: Is this right?
        const base = if (coff.isImage())
            coff.optionalHeaderField(.image_base)
        else
            0; // should be offset within section - take target_rva - section_rva (but section is 0!)

        switch (coff.targetLoad(&coff.headerPtr().machine)) {
            else => |machine| @panic(@tagName(machine)),
            .AMD64 => switch (reloc.type.AMD64) {
                else => |kind| @panic(@tagName(kind)),
                .ABSOLUTE => {},
                .ADDR64 => std.mem.writeInt(
                    u64,
                    loc_slice[0..8],
                    base + target_rva,
                    target_endian,
                ),
                .ADDR32 => std.mem.writeInt(
                    u32,
                    loc_slice[0..4],
                    @intCast(base + target_rva),
                    target_endian,
                ),
                .ADDR32NB => std.mem.writeInt(
                    u32,
                    loc_slice[0..4],
                    @intCast(target_rva),
                    target_endian,
                ),
                .REL32 => std.mem.writeInt(
                    i32,
                    loc_slice[0..4],
                    @intCast(@as(i64, @bitCast(target_rva -% (loc_sym.rva + reloc.offset + 4)))),
                    target_endian,
                ),
                .REL32_1 => std.mem.writeInt(
                    i32,
                    loc_slice[0..4],
                    @intCast(@as(i64, @bitCast(target_rva -% (loc_sym.rva + reloc.offset + 5)))),
                    target_endian,
                ),
                .REL32_2 => std.mem.writeInt(
                    i32,
                    loc_slice[0..4],
                    @intCast(@as(i64, @bitCast(target_rva -% (loc_sym.rva + reloc.offset + 6)))),
                    target_endian,
                ),
                .REL32_3 => std.mem.writeInt(
                    i32,
                    loc_slice[0..4],
                    @intCast(@as(i64, @bitCast(target_rva -% (loc_sym.rva + reloc.offset + 7)))),
                    target_endian,
                ),
                .REL32_4 => std.mem.writeInt(
                    i32,
                    loc_slice[0..4],
                    @intCast(@as(i64, @bitCast(target_rva -% (loc_sym.rva + reloc.offset + 8)))),
                    target_endian,
                ),
                .REL32_5 => std.mem.writeInt(
                    i32,
                    loc_slice[0..4],
                    @intCast(@as(i64, @bitCast(target_rva -% (loc_sym.rva + reloc.offset + 9)))),
                    target_endian,
                ),
                .SECREL => std.mem.writeInt(
                    u32,
                    loc_slice[0..4],
                    coff.computeNodeSectionOffset(target_sym.ni),
                    target_endian,
                ),
            },
            .I386 => switch (reloc.type.I386) {
                else => |kind| @panic(@tagName(kind)),
                .ABSOLUTE => {},
                .DIR16 => std.mem.writeInt(
                    u16,
                    loc_slice[0..2],
                    @intCast(base + target_rva),
                    target_endian,
                ),
                .REL16 => std.mem.writeInt(
                    i16,
                    loc_slice[0..2],
                    @intCast(@as(i64, @bitCast(target_rva -% (loc_sym.rva + reloc.offset + 2)))),
                    target_endian,
                ),
                .DIR32 => std.mem.writeInt(
                    u32,
                    loc_slice[0..4],
                    @intCast(base + target_rva),
                    target_endian,
                ),
                .DIR32NB => std.mem.writeInt(
                    u32,
                    loc_slice[0..4],
                    @intCast(target_rva),
                    target_endian,
                ),
                .REL32 => std.mem.writeInt(
                    i32,
                    loc_slice[0..4],
                    @intCast(@as(i64, @bitCast(target_rva -% (loc_sym.rva + reloc.offset + 4)))),
                    target_endian,
                ),
                .SECREL => std.mem.writeInt(
                    u32,
                    loc_slice[0..4],
                    coff.computeNodeSectionOffset(target_sym.ni),
                    target_endian,
                ),
            },
        }
    }

    pub fn delete(reloc: *Reloc, coff: *Coff) void {
        switch (reloc.prev) {
            .none => {
                const target = reloc.target.get(coff);
                assert(target.target_relocs.get(coff) == reloc);
                target.target_relocs = reloc.next;
            },
            else => |prev| prev.get(coff).next = reloc.next,
        }
        switch (reloc.next) {
            .none => {},
            else => |next| next.get(coff).prev = reloc.prev,
        }
        reloc.* = undefined;
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
) !*Coff {
    return create(arena, comp, path, options);
}
pub fn createEmpty(
    arena: std.mem.Allocator,
    comp: *Compilation,
    path: std.Build.Cache.Path,
    options: link.File.OpenOptions,
) !*Coff {
    return create(arena, comp, path, options);
}
fn create(
    arena: std.mem.Allocator,
    comp: *Compilation,
    path: std.Build.Cache.Path,
    options: link.File.OpenOptions,
) !*Coff {
    const target = &comp.root_mod.resolved_target.result;
    assert(target.ofmt == .coff);
    if (target.cpu.arch.endian() != comptime targetEndian(undefined))
        return error.UnsupportedCOFFArchitecture;
    const machine = target.toCoffMachine();
    const timestamp: u32 = 0;
    const major_subsystem_version = options.major_subsystem_version orelse 6;
    const minor_subsystem_version = options.minor_subsystem_version orelse 0;
    const magic: std.coff.OptionalHeader.Magic = switch (target.ptrBitWidth()) {
        0...32 => .PE32,
        33...64 => .@"PE32+",
        else => return error.UnsupportedCOFFArchitecture,
    };
    const section_align: std.mem.Alignment = switch (machine) {
        .AMD64, .I386 => @enumFromInt(12),
        .SH3, .SH3DSP, .SH4, .SH5 => @enumFromInt(12),
        .MIPS16, .MIPSFPU, .MIPSFPU16, .WCEMIPSV2 => @enumFromInt(12),
        .POWERPC, .POWERPCFP => @enumFromInt(12),
        .ALPHA, .ALPHA64 => @enumFromInt(13),
        .IA64 => @enumFromInt(13),
        .ARM => @enumFromInt(12),
        else => return error.UnsupportedCOFFArchitecture,
    };

    const io = comp.io;

    const coff = try arena.create(Coff);
    const file = try path.root_dir.handle.createFile(io, path.sub_path, .{
        .read = true,
        .permissions = link.File.determinePermissions(comp.config.output_mode, comp.config.link_mode),
    });
    errdefer file.close(io);
    coff.* = .{
        .base = .{
            .tag = .coff2,

            .comp = comp,
            .emit = path,

            .file = file,
            .gc_sections = false,
            .print_gc_sections = false,
            .build_id = .none,
            .allow_shlib_undefined = false,
            .stack_size = 0,
        },
        .mf = try .init(file, comp.gpa, io),
        .nodes = .empty,
        .members = .empty,
        .pending_members = .empty,
        .lib_string_table = .empty,
        .lib_string_len = 0,
        .long_names_table = .{
            .entries = .empty,
        },
        .import_table = .{
            .ni = .none,
            .entries = .empty,
        },
        .export_table = .{
            .ni = .none,
            .export_directory_table_ni = .none,
            .export_address_table_si = .null,
            .name_pointer_table_ni = .none,
            .ordinal_table_ni = .none,
            .name_table_ni = .none,
            .entries = .empty,
        },
        .strings = .empty,
        .string_bytes = .empty,
        .image_section_table = .empty,
        .pseudo_section_table = .empty,
        .object_section_table = .empty,
        .symbol_table = .empty,
        .globals = .empty,
        .global_pending_index = 0,
        .navs = .empty,
        .uavs = .empty,
        .lazy = .initFill(.{
            .map = .empty,
            .pending_index = 0,
        }),
        .pending_uavs = .empty,
        .relocs = .empty,
        .const_prog_node = .none,
        .synth_prog_node = .none,
    };
    errdefer coff.deinit();

    {
        const strings = std.enums.values(String);
        try coff.strings.ensureTotalCapacityContext(comp.gpa, @intCast(strings.len), .{
            .bytes = &coff.string_bytes,
        });
        for (strings) |string| assert(try coff.getOrPutString(@tagName(string)) == string);
    }

    try coff.initHeaders(
        machine,
        timestamp,
        major_subsystem_version,
        minor_subsystem_version,
        magic,
        section_align,
        std.fs.path.basename(path.sub_path),
    );
    return coff;
}

pub fn deinit(coff: *Coff) void {
    const gpa = coff.base.comp.gpa;
    coff.mf.deinit(gpa);
    coff.nodes.deinit(gpa);
    coff.long_names_table.entries.deinit(gpa);
    coff.import_table.entries.deinit(gpa);
    coff.export_table.entries.deinit(gpa);
    coff.strings.deinit(gpa);
    coff.string_bytes.deinit(gpa);
    coff.image_section_table.deinit(gpa);
    coff.pseudo_section_table.deinit(gpa);
    coff.object_section_table.deinit(gpa);
    coff.symbol_table.deinit(gpa);
    coff.globals.deinit(gpa);
    coff.navs.deinit(gpa);
    coff.uavs.deinit(gpa);
    for (&coff.lazy.values) |*lazy| lazy.map.deinit(gpa);
    coff.pending_uavs.deinit(gpa);
    coff.relocs.deinit(gpa);
    coff.* = undefined;
}

fn isImage(coff: *const Coff) bool {
    const comp = coff.base.comp;
    return switch (comp.config.output_mode) {
        .Exe => true,
        .Lib => switch (comp.config.link_mode) {
            .static => false,
            .dynamic => true,
        },
        .Obj => false,
    };
}

fn isArchive(coff: *const Coff) bool {
    const comp = coff.base.comp;
    return switch (comp.config.output_mode) {
        .Exe => false,
        .Lib => switch (comp.config.link_mode) {
            .static => true,
            .dynamic => false,
        },
        .Obj => false,
    };
}

fn initHeaders(
    coff: *Coff,
    machine: std.coff.IMAGE.FILE.MACHINE,
    timestamp: u32,
    major_subsystem_version: u16,
    minor_subsystem_version: u16,
    magic: std.coff.OptionalHeader.Magic,
    section_align: std.mem.Alignment,
    file_name: []const u8,
) !void {
    const comp = coff.base.comp;
    const gpa = comp.gpa;
    const target_endian = coff.targetEndian();
    const file_align: std.mem.Alignment = comptime .fromByteUnits(default_file_alignment);
    const is_image = coff.isImage();
    const is_archive = coff.isArchive();

    const optional_header_size: u16 = if (is_image) switch (magic) {
        _ => unreachable,
        inline else => |ct_magic| @sizeOf(@field(std.coff.OptionalHeader, @tagName(ct_magic))),
    } else 0;
    const data_directories_size: u16 = if (is_image)
        @sizeOf(std.coff.ImageDataDirectory) * std.coff.IMAGE.DIRECTORY_ENTRY.len
    else
        0;

    var expected_nodes_len: usize = Node.known_count;
    if (comp.zcu != null) {
        expected_nodes_len += 3;
        if (is_image) expected_nodes_len += 9;
        expected_nodes_len += @as(usize, @intFromBool(comp.config.any_non_single_threaded)) * 2;
    }
    defer assert(coff.nodes.len == expected_nodes_len);

    try coff.nodes.ensureTotalCapacity(gpa, expected_nodes_len);
    coff.nodes.appendAssumeCapacity(.file);

    const header_ni = Node.known.header;
    assert(header_ni == try coff.mf.addOnlyChildNode(gpa, Node.known.file, .{
        .alignment = coff.mf.flags.block_size,
        .fixed = true,
    }));
    coff.nodes.appendAssumeCapacity(.header);

    const pe_signature = "PE\x00\x00";
    const archive_signature = "!<arch>\n";

    const signature_ni = Node.known.signature;
    assert(signature_ni == try coff.mf.addLastChildNode(gpa, if (is_image) header_ni else Node.known.file, .{
        .size = if (is_image)
            msdos_stub.len + pe_signature.len
        else if (is_archive)
            archive_signature.len
        else
            0,
        .alignment = .@"4",
        .fixed = true,
    }));
    coff.nodes.appendAssumeCapacity(.signature);

    const signature_slice = signature_ni.slice(&coff.mf);
    if (is_image) {
        @memcpy(signature_slice[0..msdos_stub.len], &msdos_stub);
        @memcpy(signature_slice[signature_slice.len - pe_signature.len ..], pe_signature);
    } else if (is_archive) {
        @memcpy(signature_slice, archive_signature);
    }

    const opt_zcu_coff_parent_ni = if (is_archive) parent: {
        const initial_member_count = Member.Index.known_count + @intFromBool(comp.zcu != null);
        try coff.members.ensureTotalCapacity(gpa, initial_member_count);

        assert(Member.Index.first == try coff.addMemberAssumeCapacity(.first_linker, @sizeOf(u32)));
        coff.targetStore(coff.firstLinkerMemberNumSymbolsPtr(), 0);

        assert(Member.Index.second == try coff.addMemberAssumeCapacity(.second_linker, 2 * @sizeOf(u32)));
        coff.targetStore(coff.secondLinkerMemberNumMembersPtr(), 0);
        coff.targetStore(coff.secondLinkerMemberNumSymbolsPtr(), 0);

        assert(Member.Index.longnames == try coff.addMemberAssumeCapacity(.longnames, 0));

        const first_linker_member = Member.Index.first.get(coff);
        const second_linker_member = Member.Index.second.get(coff);
        const longnames_member = Member.Index.longnames.get(coff);

        try first_linker_member.initHeader(coff, "", timestamp);
        try second_linker_member.initHeader(coff, "", timestamp);
        try longnames_member.initHeader(coff, "/", timestamp);

        if (comp.zcu) |zcu| {
            const zcu_mi = try coff.addMemberAssumeCapacity(.coff, @sizeOf(std.coff.Header));
            const zcu_member = zcu_mi.get(coff);
            try zcu_member.initHeader(coff, zcu.main_mod.fully_qualified_name, timestamp);

            break :parent zcu_member.content_ni;
        }

        assert(Node.known.zcu_member_header == try coff.mf.addLastChildNode(gpa, Node.known.file, .{}));
        assert(Node.known.zcu_member == try coff.mf.addLastChildNode(gpa, Node.known.file, .{}));
        coff.nodes.appendAssumeCapacity(.placeholder);
        coff.nodes.appendAssumeCapacity(.placeholder);

        break :parent null;
    } else parent: {
        // TODO: Not ideal to have this many placeholder nodes - use two distinct `Node.known` types?
        while (true) {
            const placeholder_ni = try coff.mf.addLastChildNode(gpa, Node.known.file, .{});
            coff.nodes.appendAssumeCapacity(.placeholder);
            if (placeholder_ni == Node.known.zcu_member) break;
        }

        break :parent if (comp.zcu != null) Node.known.header else null;
    };

    const zcu_coff_parent_ni = opt_zcu_coff_parent_ni orelse {
        // If we're not generating any code, no more known nodes are used
        while (coff.nodes.len < Node.known_count) {
            _ = try coff.mf.addLastChildNode(gpa, Node.known.file, .{});
            coff.nodes.appendAssumeCapacity(.placeholder);
        }

        return;
    };

    const coff_header_ni = Node.known.coff_header;
    assert(coff_header_ni == try coff.mf.addLastChildNode(gpa, zcu_coff_parent_ni, .{
        .size = @sizeOf(std.coff.Header),
        .alignment = .@"4",
        .fixed = true,
    }));
    coff.nodes.appendAssumeCapacity(.coff_header);
    {
        const coff_header = coff.headerPtr();
        coff_header.* = .{
            .machine = machine,
            .number_of_sections = 0,
            .time_date_stamp = timestamp,
            .pointer_to_symbol_table = 0,
            .number_of_symbols = 0,
            .size_of_optional_header = optional_header_size + data_directories_size,
            .flags = .{
                .RELOCS_STRIPPED = is_image,
                .EXECUTABLE_IMAGE = is_image,
                .DEBUG_STRIPPED = true,
                .@"32BIT_MACHINE" = magic == .PE32,
                .LARGE_ADDRESS_AWARE = magic == .@"PE32+",
                .DLL = comp.config.output_mode == .Lib and comp.config.link_mode == .dynamic,
            },
        };
        if (target_endian != native_endian) std.mem.byteSwapAllFields(std.coff.Header, coff_header);
    }

    const optional_header_ni = Node.known.optional_header;
    assert(optional_header_ni == try coff.mf.addLastChildNode(gpa, zcu_coff_parent_ni, .{
        .size = optional_header_size,
        .alignment = .@"4",
        .fixed = true,
    }));
    coff.nodes.appendAssumeCapacity(.optional_header);
    if (is_image) {
        coff.targetStore(&coff.optionalHeaderStandardPtr().magic, magic);
        switch (coff.optionalHeaderPtr()) {
            .PE32 => |optional_header| {
                optional_header.* = .{
                    .standard = .{
                        .magic = .PE32,
                        .major_linker_version = 0,
                        .minor_linker_version = 0,
                        .size_of_code = 0,
                        .size_of_initialized_data = 0,
                        .size_of_uninitialized_data = 0,
                        .address_of_entry_point = 0,
                        .base_of_code = 0,
                    },
                    .base_of_data = 0,
                    .image_base = switch (coff.base.comp.config.output_mode) {
                        .Exe => 0x400000,
                        .Lib => switch (coff.base.comp.config.link_mode) {
                            .static => 0,
                            .dynamic => 0x10000000,
                        },
                        .Obj => 0,
                    },
                    .section_alignment = @intCast(section_align.toByteUnits()),
                    .file_alignment = @intCast(file_align.toByteUnits()),
                    .major_operating_system_version = 6,
                    .minor_operating_system_version = 0,
                    .major_image_version = 0,
                    .minor_image_version = 0,
                    .major_subsystem_version = major_subsystem_version,
                    .minor_subsystem_version = minor_subsystem_version,
                    .win32_version_value = 0,
                    .size_of_image = 0,
                    .size_of_headers = 0,
                    .checksum = 0,
                    .subsystem = .WINDOWS_CUI,
                    .dll_flags = .{
                        .HIGH_ENTROPY_VA = true,
                        .DYNAMIC_BASE = true,
                        .TERMINAL_SERVER_AWARE = true,
                        .NX_COMPAT = true,
                    },
                    .size_of_stack_reserve = default_size_of_stack_reserve,
                    .size_of_stack_commit = default_size_of_stack_commit,
                    .size_of_heap_reserve = default_size_of_heap_reserve,
                    .size_of_heap_commit = default_size_of_heap_commit,
                    .loader_flags = 0,
                    .number_of_rva_and_sizes = std.coff.IMAGE.DIRECTORY_ENTRY.len,
                };
                if (target_endian != native_endian)
                    std.mem.byteSwapAllFields(std.coff.OptionalHeader.PE32, optional_header);
            },
            .@"PE32+" => |optional_header| {
                optional_header.* = .{
                    .standard = .{
                        .magic = .@"PE32+",
                        .major_linker_version = 0,
                        .minor_linker_version = 0,
                        .size_of_code = 0,
                        .size_of_initialized_data = 0,
                        .size_of_uninitialized_data = 0,
                        .address_of_entry_point = 0,
                        .base_of_code = 0,
                    },
                    .image_base = switch (coff.base.comp.config.output_mode) {
                        .Exe => 0x140000000,
                        .Lib => switch (coff.base.comp.config.link_mode) {
                            .static => 0,
                            .dynamic => 0x180000000,
                        },
                        .Obj => 0,
                    },
                    .section_alignment = @intCast(section_align.toByteUnits()),
                    .file_alignment = @intCast(file_align.toByteUnits()),
                    .major_operating_system_version = 6,
                    .minor_operating_system_version = 0,
                    .major_image_version = 0,
                    .minor_image_version = 0,
                    .major_subsystem_version = major_subsystem_version,
                    .minor_subsystem_version = minor_subsystem_version,
                    .win32_version_value = 0,
                    .size_of_image = 0,
                    .size_of_headers = 0,
                    .checksum = 0,
                    .subsystem = .WINDOWS_CUI,
                    .dll_flags = .{
                        .HIGH_ENTROPY_VA = true,
                        .DYNAMIC_BASE = true,
                        .TERMINAL_SERVER_AWARE = true,
                        .NX_COMPAT = true,
                    },
                    .size_of_stack_reserve = default_size_of_stack_reserve,
                    .size_of_stack_commit = default_size_of_stack_commit,
                    .size_of_heap_reserve = default_size_of_heap_reserve,
                    .size_of_heap_commit = default_size_of_heap_commit,
                    .loader_flags = 0,
                    .number_of_rva_and_sizes = std.coff.IMAGE.DIRECTORY_ENTRY.len,
                };
                if (target_endian != native_endian)
                    std.mem.byteSwapAllFields(std.coff.OptionalHeader.@"PE32+", optional_header);
            },
        }
    }

    const data_directories_ni = Node.known.data_directories;
    assert(data_directories_ni == try coff.mf.addLastChildNode(gpa, zcu_coff_parent_ni, .{
        .size = data_directories_size,
        .alignment = .@"4",
        .fixed = true,
    }));
    coff.nodes.appendAssumeCapacity(.data_directories);
    if (is_image) {
        const data_directories = coff.dataDirectorySlice();
        @memset(data_directories, .{ .virtual_address = 0, .size = 0 });
        if (target_endian != native_endian) std.mem.byteSwapAllFields(
            [std.coff.IMAGE.DIRECTORY_ENTRY.len]std.coff.ImageDataDirectory,
            data_directories,
        );
    }

    const section_table_ni = Node.known.section_table;
    assert(section_table_ni == try coff.mf.addLastChildNode(gpa, zcu_coff_parent_ni, .{
        .alignment = .@"4",
        .fixed = true,
    }));
    coff.nodes.appendAssumeCapacity(.section_table);

    assert(coff.nodes.len == Node.known_count);

    try coff.symbol_table.ensureTotalCapacity(gpa, Symbol.Index.known_count);
    coff.symbol_table.addOneAssumeCapacity().* = .{
        .ni = .none,
        .rva = 0,
        .size = 0,
        .loc_relocs = .none,
        .target_relocs = .none,
        .section_number = .UNDEFINED,
    };
    assert(try coff.addSection(".data", .{
        .CNT_INITIALIZED_DATA = true,
        .MEM_READ = true,
        .MEM_WRITE = true,
    }) == .data);
    assert(try coff.addSection(".rdata", .{
        .CNT_INITIALIZED_DATA = true,
        .MEM_READ = true,
    }) == .rdata);
    assert(try coff.addSection(".text", .{
        .CNT_CODE = true,
        .MEM_EXECUTE = true,
        .MEM_READ = true,
    }) == .text);

    if (is_image) {
        coff.import_table.ni = try coff.mf.addLastChildNode(
            gpa,
            (try coff.objectSectionMapIndex(
                .@".idata",
                coff.mf.flags.block_size,
                .{ .read = true },
            )).symbol(coff).node(coff),
            .{ .alignment = .@"4", .moved = true },
        );
        coff.nodes.appendAssumeCapacity(.import_directory_table);

        coff.export_table.ni = (try coff.pseudoSectionMapIndex(
            .@".edata",
            .of(std.coff.ExportDirectoryTable),
            .{ .read = true },
        )).symbol(coff).node(coff);

        coff.export_table.export_directory_table_ni = try coff.mf.addLastChildNode(
            gpa,
            coff.export_table.ni,
            .{
                .size = @sizeOf(std.coff.ExportDirectoryTable) + file_name.len + 1,
                .moved = true,
                .fixed = true,
            },
        );
        coff.nodes.appendAssumeCapacity(.export_directory_table);

        const name_index = @sizeOf(std.coff.ExportDirectoryTable);
        const table_slice = coff.export_table.export_directory_table_ni.slice(&coff.mf);
        @memcpy(table_slice[name_index..][0..file_name.len], file_name[0..file_name.len]);
        @memset(table_slice[name_index + file_name.len ..], 0);

        const export_address_table_ni = try coff.mf.addLastChildNode(gpa, coff.export_table.ni, .{
            .alignment = .of(std.coff.ExportAddressTableEntry),
            .moved = true,
        });
        coff.nodes.appendAssumeCapacity(.export_address_table);

        try coff.symbol_table.ensureUnusedCapacity(gpa, 1);
        coff.export_table.export_address_table_si = coff.addSymbolAssumeCapacity();

        const export_address_table_sym = coff.export_table.export_address_table_si.get(coff);
        export_address_table_sym.ni = export_address_table_ni;
        assert(export_address_table_sym.loc_relocs == .none);
        export_address_table_sym.loc_relocs = @enumFromInt(coff.relocs.items.len);
        export_address_table_sym.section_number =
            coff.getNode(coff.export_table.ni).pseudo_section.symbol(coff).get(coff).section_number;

        coff.export_table.name_pointer_table_ni = try coff.mf.addLastChildNode(gpa, coff.export_table.ni, .{
            .alignment = .of(std.coff.ExportNamePointerTableEntry),
            .moved = true,
        });
        coff.nodes.appendAssumeCapacity(.export_name_pointer_table);

        coff.export_table.ordinal_table_ni = try coff.mf.addLastChildNode(gpa, coff.export_table.ni, .{
            .alignment = .of(std.coff.ExportOrdinalTableEntry),
            .moved = true,
        });
        coff.nodes.appendAssumeCapacity(.export_ordinal_table);

        coff.export_table.name_table_ni = try coff.mf.addLastChildNode(gpa, coff.export_table.ni, .{
            .alignment = .of(u8),
            .moved = true,
        });
        coff.nodes.appendAssumeCapacity(.export_name_table);

        const export_directory_table = coff.exportDirectoryTable();
        export_directory_table.* = .{
            .flags = 0,
            .time_date_stamp = timestamp,
            .major_version = 0,
            .minor_version = 0,
            .name_rva = 0,
            .ordinal_base = 1,
            .number_of_entries = 0,
            .number_of_names = 0,
            .export_address_table_rva = 0,
            .name_pointer_table_rva = 0,
            .ordinal_table_rva = 0,
        };
        if (target_endian != native_endian)
            std.mem.byteSwapAllFields(std.coff.ExportDirectoryTable, export_directory_table);
    }

    // While tls variables allocated at runtime are writable, the template itself is not
    if (comp.config.any_non_single_threaded) _ = try coff.objectSectionMapIndex(
        .@".tls$",
        if (is_image) coff.mf.flags.block_size else .@"1",
        .{ .read = true },
    );
}

pub fn startProgress(coff: *Coff, prog_node: std.Progress.Node) void {
    prog_node.increaseEstimatedTotalItems(3);
    coff.const_prog_node = prog_node.start("Constants", coff.pending_uavs.count());
    coff.synth_prog_node = prog_node.start("Synthetics", count: {
        var count = coff.globals.count() - coff.global_pending_index;
        for (&coff.lazy.values) |*lazy| count += lazy.map.count() - lazy.pending_index;
        break :count count;
    });
    coff.mf.update_prog_node = prog_node.start("Relocations", coff.mf.updates.items.len);
}

pub fn endProgress(coff: *Coff) void {
    coff.mf.update_prog_node.end();
    coff.mf.update_prog_node = .none;
    coff.synth_prog_node.end();
    coff.synth_prog_node = .none;
    coff.const_prog_node.end();
    coff.const_prog_node = .none;
}

fn getNode(coff: *const Coff, ni: MappedFile.Node.Index) Node {
    return coff.nodes.get(@intFromEnum(ni));
}
fn computeNodeRva(coff: *Coff, ni: MappedFile.Node.Index) u32 {
    const parent_rva = parent_rva: {
        const parent_si = switch (coff.getNode(ni.parent(&coff.mf))) {
            .file,
            .header,
            .signature,
            .archive_member_header,
            .archive_member,
            .coff_header,
            .optional_header,
            .data_directories,
            .section_table,
            .export_name_table,
            .placeholder,
            => unreachable,
            .image_section => |si| si,
            .import_directory_table => break :parent_rva coff.targetLoad(
                &coff.dataDirectoryPtr(.IMPORT).virtual_address,
            ),
            .import_lookup_table => |import_index| break :parent_rva coff.targetLoad(
                &coff.importDirectoryEntryPtr(import_index).import_lookup_table_rva,
            ),
            .import_address_table => |import_index| break :parent_rva coff.targetLoad(
                &coff.importDirectoryEntryPtr(import_index).import_address_table_rva,
            ),
            .import_hint_name_table => |import_index| break :parent_rva coff.targetLoad(
                &coff.importDirectoryEntryPtr(import_index).name_rva,
            ),
            .export_directory_table => break :parent_rva coff.targetLoad(
                &coff.dataDirectoryPtr(.EXPORT).virtual_address,
            ),
            .export_address_table => break :parent_rva coff.targetLoad(
                &coff.exportDirectoryTable().export_address_table_rva,
            ),
            .export_name_pointer_table => break :parent_rva coff.targetLoad(
                &coff.exportDirectoryTable().name_pointer_table_rva,
            ),
            .export_ordinal_table => break :parent_rva coff.targetLoad(
                &coff.exportDirectoryTable().ordinal_table_rva,
            ),
            inline .pseudo_section,
            .object_section,
            .global,
            .nav,
            .uav,
            .lazy_code,
            .lazy_const_data,
            => |mi| mi.symbol(coff),
        };
        break :parent_rva parent_si.get(coff).rva;
    };
    const offset, _ = ni.location(&coff.mf).resolve(&coff.mf);
    return @intCast(parent_rva + offset);
}
fn computeNodeSectionOffset(coff: *Coff, ni: MappedFile.Node.Index) u32 {
    var section_offset: u32 = 0;
    var parent_ni = ni;
    while (true) {
        const offset, _ = parent_ni.location(&coff.mf).resolve(&coff.mf);
        section_offset += @intCast(offset);
        parent_ni = parent_ni.parent(&coff.mf);
        switch (coff.getNode(parent_ni)) {
            else => unreachable,
            .image_section, .pseudo_section => return section_offset,
            .object_section => {},
        }
    }
}

pub inline fn targetEndian(_: *const Coff) std.lang.Endian {
    return .little;
}
fn targetLoad(coff: *const Coff, ptr: anytype) @typeInfo(@TypeOf(ptr)).pointer.child {
    const Child = @typeInfo(@TypeOf(ptr)).pointer.child;
    return switch (@typeInfo(Child)) {
        else => @compileError(@typeName(Child)),
        .int => std.mem.toNative(Child, ptr.*, coff.targetEndian()),
        .@"enum" => |@"enum"| @enumFromInt(coff.targetLoad(@as(*@"enum".tag_type, @ptrCast(ptr)))),
        .@"struct" => |@"struct"| @bitCast(
            coff.targetLoad(@as(*@"struct".backing_integer.?, @ptrCast(ptr))),
        ),
    };
}
fn targetStore(coff: *const Coff, ptr: anytype, val: @typeInfo(@TypeOf(ptr)).pointer.child) void {
    const Child = @typeInfo(@TypeOf(ptr)).pointer.child;
    return switch (@typeInfo(Child)) {
        else => @compileError(@typeName(Child)),
        .int => ptr.* = std.mem.nativeTo(Child, val, coff.targetEndian()),
        .@"enum" => |@"enum"| coff.targetStore(
            @as(*@"enum".tag_type, @ptrCast(ptr)),
            @intFromEnum(val),
        ),
        .@"struct" => |@"struct"| coff.targetStore(
            @as(*@"struct".backing_integer.?, @ptrCast(ptr)),
            @bitCast(val),
        ),
    };
}

pub fn headerPtr(coff: *Coff) *std.coff.Header {
    assert(coff.base.comp.zcu != null);
    return @ptrCast(@alignCast(Node.known.coff_header.slice(&coff.mf)));
}

pub fn firstLinkerMemberNumSymbolsPtr(coff: *Coff) *u32 {
    assert(coff.isArchive());
    return @ptrCast(@alignCast(Node.known.first_linker_member.slice(&coff.mf)));
}

pub fn firstLinkerMemberOffsetsSlice(coff: *Coff) []u32 {
    const len = std.mem.toNative(u32, coff.firstLinkerMemberNumSymbolsPtr().*, .big);
    return @ptrCast(@alignCast(Node.known.first_linker_member.slice(&coff.mf)[@sizeOf(u32)..][0 .. len * @sizeOf(u32)]));
}

pub fn secondLinkerMemberNumMembersPtr(coff: *Coff) *u32 {
    assert(coff.isArchive());
    return @ptrCast(@alignCast(Node.known.second_linker_member.slice(&coff.mf)));
}

pub fn secondLinkerMemberOffsetsSlice(coff: *Coff) []u32 {
    const num_members = coff.targetLoad(coff.secondLinkerMemberNumMembersPtr());
    return @ptrCast(@alignCast(
        Node.known.second_linker_member.slice(&coff.mf)[@sizeOf(u32)..][0 .. num_members * @sizeOf(u32)],
    ));
}

pub fn secondLinkerMemberNumSymbolsPtr(coff: *Coff) *u32 {
    const num_members = coff.targetLoad(coff.secondLinkerMemberNumMembersPtr());
    return @ptrCast(@alignCast(
        Node.known.second_linker_member.slice(&coff.mf)[(1 + num_members) * @sizeOf(u32) ..],
    ));
}

pub fn secondLinkerMemberIndicesSlice(coff: *Coff) []u16 {
    const num_members = coff.targetLoad(coff.secondLinkerMemberNumMembersPtr());
    const num_symbols = coff.targetLoad(coff.secondLinkerMemberNumSymbolsPtr());
    return @ptrCast(@alignCast(
        Node.known.second_linker_member.slice(&coff.mf)[(2 + num_members) * @sizeOf(u32) ..][0 .. num_symbols * @sizeOf(u16)],
    ));
}

pub fn secondLinkerMemberStringsSlice(coff: *Coff) []u8 {
    const num_members = coff.targetLoad(coff.secondLinkerMemberNumMembersPtr());
    const num_symbols = coff.targetLoad(coff.secondLinkerMemberNumSymbolsPtr());
    return @ptrCast(@alignCast(
        Node.known.second_linker_member.slice(&coff.mf)[(2 + num_members) * @sizeOf(u32) + num_symbols * @sizeOf(u16) ..],
    ));
}

pub fn optionalHeaderStandardPtr(coff: *Coff) *std.coff.OptionalHeader {
    return @ptrCast(@alignCast(
        Node.known.optional_header.slice(&coff.mf)[0..@sizeOf(std.coff.OptionalHeader)],
    ));
}

pub const OptionalHeaderPtr = union(std.coff.OptionalHeader.Magic) {
    PE32: *std.coff.OptionalHeader.PE32,
    @"PE32+": *std.coff.OptionalHeader.@"PE32+",
};
pub fn optionalHeaderPtr(coff: *Coff) OptionalHeaderPtr {
    assert(coff.isImage());
    const slice = Node.known.optional_header.slice(&coff.mf);
    return switch (coff.targetLoad(&coff.optionalHeaderStandardPtr().magic)) {
        _ => unreachable,
        inline else => |magic| @unionInit(
            OptionalHeaderPtr,
            @tagName(magic),
            @ptrCast(@alignCast(slice)),
        ),
    };
}
pub fn optionalHeaderField(
    coff: *Coff,
    comptime field: std.meta.FieldEnum(std.coff.OptionalHeader.@"PE32+"),
) @FieldType(std.coff.OptionalHeader.@"PE32+", @tagName(field)) {
    assert(coff.isImage());
    return switch (coff.optionalHeaderPtr()) {
        inline else => |optional_header| coff.targetLoad(&@field(optional_header, @tagName(field))),
    };
}

pub fn dataDirectorySlice(
    coff: *Coff,
) *[std.coff.IMAGE.DIRECTORY_ENTRY.len]std.coff.ImageDataDirectory {
    assert(coff.isImage());
    return @ptrCast(@alignCast(Node.known.data_directories.slice(&coff.mf)));
}
pub fn dataDirectoryPtr(
    coff: *Coff,
    entry: std.coff.IMAGE.DIRECTORY_ENTRY,
) *std.coff.ImageDataDirectory {
    return &coff.dataDirectorySlice()[@intFromEnum(entry)];
}

pub fn sectionTableSlice(coff: *Coff) []std.coff.SectionHeader {
    return @ptrCast(@alignCast(Node.known.section_table.slice(&coff.mf)));
}

pub fn importDirectoryTableSlice(coff: *Coff) []std.coff.ImportDirectoryEntry {
    assert(coff.isImage());
    return @ptrCast(@alignCast(coff.import_table.ni.slice(&coff.mf)));
}
pub fn importDirectoryEntryPtr(
    coff: *Coff,
    import_index: ImportTable.Index,
) *std.coff.ImportDirectoryEntry {
    return &coff.importDirectoryTableSlice()[@intFromEnum(import_index)];
}

pub fn exportDirectoryTable(coff: *Coff) *std.coff.ExportDirectoryTable {
    return @ptrCast(@alignCast(coff.export_table.export_directory_table_ni.slice(&coff.mf)));
}

pub fn exportNamePointerTableSlice(coff: *Coff) []std.coff.ExportNamePointerTableEntry {
    const debug = coff.export_table.name_pointer_table_ni.slice(&coff.mf);
    _ = debug;

    return @ptrCast(@alignCast(coff.export_table.name_pointer_table_ni.slice(&coff.mf)));
}

pub fn exportOrdinalTableSlice(coff: *Coff) []std.coff.ExportOrdinalTableEntry {
    return @ptrCast(@alignCast(coff.export_table.ordinal_table_ni.slice(&coff.mf)));
}

fn addSymbolAssumeCapacity(coff: *Coff) Symbol.Index {
    defer coff.symbol_table.addOneAssumeCapacity().* = .{
        .ni = .none,
        .rva = 0,
        .size = 0,
        .loc_relocs = .none,
        .target_relocs = .none,
        .section_number = .UNDEFINED,
    };
    return @enumFromInt(coff.symbol_table.items.len);
}

fn initSymbolAssumeCapacity(coff: *Coff) !Symbol.Index {
    const si = coff.addSymbolAssumeCapacity();
    return si;
}

fn getOrPutString(coff: *Coff, string: []const u8) !String {
    try coff.ensureUnusedStringCapacity(string.len);
    return coff.getOrPutStringAssumeCapacity(string);
}
fn getOrPutOptionalString(coff: *Coff, string: ?[]const u8) !String.Optional {
    return (try coff.getOrPutString(string orelse return .none)).toOptional();
}

fn ensureUnusedStringCapacity(coff: *Coff, len: usize) !void {
    const gpa = coff.base.comp.gpa;
    try coff.strings.ensureUnusedCapacityContext(gpa, 1, .{ .bytes = &coff.string_bytes });
    try coff.string_bytes.ensureUnusedCapacity(gpa, len + 1);
}
fn getOrPutStringAssumeCapacity(coff: *Coff, string: []const u8) String {
    const gop = coff.strings.getOrPutAssumeCapacityAdapted(
        string,
        std.hash_map.StringIndexAdapter{ .bytes = &coff.string_bytes },
    );
    if (!gop.found_existing) {
        gop.key_ptr.* = @intCast(coff.string_bytes.items.len);
        gop.value_ptr.* = {};
        coff.string_bytes.appendSliceAssumeCapacity(string);
        coff.string_bytes.appendAssumeCapacity(0);
    }
    return @enumFromInt(gop.key_ptr.*);
}

pub fn globalSymbol(coff: *Coff, name: []const u8, lib_name: ?[]const u8) !Symbol.Index {
    return (try getOrPutGlobalSymbol(coff, name, lib_name)).value_ptr.*;
}

fn getOrPutGlobalSymbol(
    coff: *Coff,
    name: []const u8,
    lib_name: ?[]const u8,
) !std.AutoArrayHashMapUnmanaged(GlobalName, Symbol.Index).GetOrPutResult {
    const gpa = coff.base.comp.gpa;
    try coff.symbol_table.ensureUnusedCapacity(gpa, 1);
    const sym_gop = try coff.globals.getOrPut(gpa, .{
        .name = try coff.getOrPutString(name),
        .lib_name = try coff.getOrPutOptionalString(lib_name),
    });
    if (!sym_gop.found_existing) {
        sym_gop.value_ptr.* = coff.addSymbolAssumeCapacity();
        coff.synth_prog_node.increaseEstimatedTotalItems(1);
    }
    return sym_gop;
}

fn navSection(
    coff: *Coff,
    zcu: *Zcu,
    nav_resolved: @typeInfo(@FieldType(InternPool.Nav, "resolved")).optional.child,
) !Symbol.Index {
    const ip = &zcu.intern_pool;
    const default: String, const attributes: ObjectSectionAttributes =
        if (nav_resolved.@"threadlocal" and coff.base.comp.config.any_non_single_threaded) .{
            .@".tls$", .{ .read = true, .write = true },
        } else if (ip.isFunctionType(nav_resolved.type)) .{
            .@".text", .{ .read = true, .execute = true },
        } else if (nav_resolved.@"const") .{
            .@".rdata", .{ .read = true },
        } else .{
            .@".data", .{ .read = true, .write = true },
        };

    return (try coff.objectSectionMapIndex(
        (try coff.getOrPutOptionalString(nav_resolved.@"linksection".toSlice(ip))).unwrap() orelse default,
        switch (nav_resolved.@"linksection") {
            .none => coff.mf.flags.block_size,
            else => switch (nav_resolved.@"align") {
                .none => Type.fromInterned(ip.typeOf(nav_resolved.value)).abiAlignment(zcu),
                else => |alignment| alignment,
            }.toStdMem(),
        },
        attributes,
    )).symbol(coff);
}
fn navMapIndex(coff: *Coff, zcu: *Zcu, nav_index: InternPool.Nav.Index) !Node.NavMapIndex {
    const gpa = zcu.gpa;
    try coff.symbol_table.ensureUnusedCapacity(gpa, 1);
    const sym_gop = try coff.navs.getOrPut(gpa, nav_index);
    if (!sym_gop.found_existing) sym_gop.value_ptr.* = coff.addSymbolAssumeCapacity();
    return @enumFromInt(sym_gop.index);
}
pub fn navSymbol(coff: *Coff, zcu: *Zcu, nav_index: InternPool.Nav.Index) !Symbol.Index {
    const ip = &zcu.intern_pool;
    const nav = ip.getNav(nav_index);
    if (nav.getExtern(ip)) |@"extern"| return coff.globalSymbol(
        @"extern".name.toSlice(ip),
        @"extern".lib_name.toSlice(ip),
    );
    const nmi = try coff.navMapIndex(zcu, nav_index);
    return nmi.symbol(coff);
}

fn uavMapIndex(coff: *Coff, uav_val: InternPool.Index) !Node.UavMapIndex {
    const gpa = coff.base.comp.gpa;
    try coff.symbol_table.ensureUnusedCapacity(gpa, 1);
    const sym_gop = try coff.uavs.getOrPut(gpa, uav_val);
    if (!sym_gop.found_existing) sym_gop.value_ptr.* = coff.addSymbolAssumeCapacity();
    return @enumFromInt(sym_gop.index);
}
pub fn uavSymbol(coff: *Coff, uav_val: InternPool.Index) !Symbol.Index {
    const umi = try coff.uavMapIndex(uav_val);
    return umi.symbol(coff);
}

pub fn lazySymbol(coff: *Coff, lazy: link.File.LazySymbol) !Symbol.Index {
    const gpa = coff.base.comp.gpa;
    try coff.symbol_table.ensureUnusedCapacity(gpa, 1);
    const sym_gop = try coff.lazy.getPtr(lazy.kind).map.getOrPut(gpa, lazy.ty);
    if (!sym_gop.found_existing) {
        sym_gop.value_ptr.* = try coff.initSymbolAssumeCapacity();
        coff.synth_prog_node.increaseEstimatedTotalItems(1);
    }
    return sym_gop.value_ptr.*;
}

pub fn getNavVAddr(
    coff: *Coff,
    pt: Zcu.PerThread,
    nav: InternPool.Nav.Index,
    reloc_info: link.File.RelocInfo,
) !u64 {
    return coff.getVAddr(reloc_info, try coff.navSymbol(pt.zcu, nav));
}

pub fn getUavVAddr(
    coff: *Coff,
    uav: InternPool.Index,
    reloc_info: link.File.RelocInfo,
) !u64 {
    return coff.getVAddr(reloc_info, try coff.uavSymbol(uav));
}

pub fn getVAddr(coff: *Coff, reloc_info: link.File.RelocInfo, target_si: Symbol.Index) !u64 {
    try coff.addReloc(
        @enumFromInt(@intFromEnum(reloc_info.parent.atom_index)),
        reloc_info.offset,
        target_si,
        reloc_info.addend,
        switch (coff.targetLoad(&coff.headerPtr().machine)) {
            else => unreachable,
            .AMD64 => .{ .AMD64 = .ADDR64 },
            .I386 => .{ .I386 = .DIR32 },
        },
    );

    var vaddr: u64 = target_si.get(coff).rva;
    if (coff.isImage()) vaddr += coff.optionalHeaderField(.image_base);
    return vaddr;
}

/// Caller guarantees there is capacity for one member and two nodes
fn addMemberAssumeCapacity(coff: *Coff, kind: Member.Kind, size: usize) !Member.Index {
    const comp = coff.base.comp;
    const gpa = comp.gpa;

    // TODO: These two nodes could to be inside a movable node? Only if coff or import

    const header_ni = try coff.mf.addLastChildNode(gpa, Node.known.file, .{
        .size = @sizeOf(std.coff.ArchiveMemberHeader),
        .alignment = .@"2",
        .fixed = true,
        .moved = true,
    });

    const content_ni = try coff.mf.addLastChildNode(gpa, Node.known.file, .{
        // The actual alignment required by the spec is 2, but  to allow aligned access to
        // the various COFF data structures in-place during linking we overalign
        .alignment = switch (kind) {
            .coff => .@"4",
            else => .@"2",
        },
        .size = size,
        .resized = size > 0,
        .fixed = true,
    });

    const mi: Member.Index = @enumFromInt(coff.members.items.len);
    coff.members.appendAssumeCapacity(.{
        .kind = kind,
        .header_ni = header_ni,
        .content_ni = content_ni,
        .symbol_offsets = .empty,
    });

    coff.nodes.appendAssumeCapacity(.{ .archive_member_header = mi });
    coff.nodes.appendAssumeCapacity(.{ .archive_member = mi });

    switch (kind) {
        .first_linker, .second_linker, .longnames => {},
        else => {
            const new_num_members = coff.members.items.len - Member.Index.known_count;
            coff.targetStore(
                coff.secondLinkerMemberNumMembersPtr(),
                @intCast(new_num_members),
            );

            const old_size = Node.known.second_linker_member.location(&coff.mf).resolve(&coff.mf)[1];
            const old_header_size = new_num_members * @sizeOf(u32);
            const trailing_size = old_size - old_header_size;
            try Node.known.second_linker_member.resize(&coff.mf, gpa, old_size + @sizeOf(u32));

            const slice = Node.known.second_linker_member.slice(&coff.mf);
            @memmove(
                slice[old_header_size + @sizeOf(u32) ..][0..trailing_size],
                slice[old_header_size..][0..trailing_size],
            );

            // Offset will be written by flushMoved on header_ni
        },
    }

    switch (kind) {
        .first_linker,
        .longnames,
        .import,
        => {},
        .second_linker,
        .coff,
        => {
            try coff.pending_members.ensureTotalCapacity(
                gpa,
                coff.pending_members.capacity() + 1,
            );
        },
    }

    return mi;
}

fn appendMemberSymbolString(
    coff: *Coff,
    strings_ni: MappedFile.Node.Index,
    new_size: u64,
    name: []const u8,
    offset: u64,
) !void {
    try strings_ni.resize(&coff.mf, coff.base.comp.gpa, new_size);
    const name_slice = strings_ni.slice(&coff.mf)[offset..][0 .. name.len + 1];
    @memcpy(name_slice[0..name.len], name);
    name_slice[name.len] = 0;
}

fn addMemberSymbol(
    coff: *Coff,
    name: String,
    mi: Member.Index,
    si: Symbol.Index,
) !void {
    const gpa = coff.base.comp.gpa;
    const member = mi.get(coff);
    assert(member.kind == .coff);

    const gop = try member.symbol_offsets.getOrPut(gpa, si);
    if (gop.found_existing) return;

    // TODO: Detect duplicate names (ie. a name used by a symbol in another member, not the zcu since those already go through globals)

    const symbol_index = blk: {
        const num_symbols_ptr = coff.firstLinkerMemberNumSymbolsPtr();
        const num_symbols = std.mem.toNative(u32, num_symbols_ptr.*, .big);
        num_symbols_ptr.* = std.mem.nativeTo(u32, num_symbols + 1, .big);
        break :blk num_symbols;
    };

    gop.value_ptr.* = symbol_index;
    const name_slice = name.toSlice(coff);

    // Linker member fields are not modeled as nodes because MappedFile
    // can't guarantee that they will be tightly packed after resizing

    const new_string_table_size = coff.lib_string_len + name_slice.len + 1;
    defer coff.lib_string_len = new_string_table_size;

    {
        const old_header_size = @sizeOf(u32) + symbol_index * @sizeOf(u32);
        const new_header_size = old_header_size + @sizeOf(u32);
        try Node.known.first_linker_member.resize(&coff.mf, gpa, new_header_size + new_string_table_size);

        const slice = Node.known.first_linker_member.slice(&coff.mf);
        @memmove(slice[new_header_size..][0..coff.lib_string_len], slice[old_header_size..][0..coff.lib_string_len]);
        @memcpy(slice[new_header_size + coff.lib_string_len ..][0 .. name_slice.len + 1], name_slice[0 .. name_slice.len + 1]);

        // New offset entry is written in flushMember
    }

    {
        const num_members = coff.targetLoad(coff.secondLinkerMemberNumMembersPtr());
        const old_header_size = 2 * @sizeOf(u32) + num_members * @sizeOf(u32) + symbol_index * @sizeOf(u16);
        const new_header_size = old_header_size + @sizeOf(u16);
        try Node.known.second_linker_member.resize(&coff.mf, gpa, new_header_size + new_string_table_size);

        const needs_sort = if (coff.lib_string_table.items.len > 0)
            std.mem.lessThan(
                u8,
                name_slice,
                coff.lib_string_table.items[coff.lib_string_table.items.len - 1].toSlice(coff),
            )
        else
            false;

        try coff.lib_string_table.append(gpa, name);

        const slice = Node.known.second_linker_member.slice(&coff.mf);
        const num_symbols_ptr: *u32 = @ptrCast(@alignCast(slice[@sizeOf(u32) + num_members * @sizeOf(u32) ..]));
        coff.targetStore(num_symbols_ptr, symbol_index + 1);

        if (needs_sort) {
            // The entire string table is rebuilt in flushMember after sorting
            coff.pending_members.putAssumeCapacity(Member.Index.second, {});
        } else {
            @memmove(slice[new_header_size..][0..coff.lib_string_len], slice[old_header_size..][0..coff.lib_string_len]);
            @memcpy(slice[new_header_size + coff.lib_string_len ..][0 .. name_slice.len + 1], name_slice[0 .. name_slice.len + 1]);
        }

        // Indices in this table are 1-based
        const index_ptr: *u16 = @ptrCast(@alignCast(slice[old_header_size..]));
        coff.targetStore(index_ptr, @intCast(@intFromEnum(mi) - Member.Index.known_count + 1));
    }

    coff.pending_members.putAssumeCapacity(mi, {});
}

fn addSection(coff: *Coff, name: []const u8, flags: std.coff.SectionHeader.Flags) !Symbol.Index {
    assert(coff.base.comp.zcu != null);

    const gpa = coff.base.comp.gpa;
    try coff.nodes.ensureUnusedCapacity(gpa, 1);
    try coff.image_section_table.ensureUnusedCapacity(gpa, 1);
    try coff.symbol_table.ensureUnusedCapacity(gpa, 1);

    const coff_header = coff.headerPtr();
    const section_index = coff.targetLoad(&coff_header.number_of_sections);
    const section_table_len = section_index + 1;
    coff.targetStore(&coff_header.number_of_sections, section_table_len);
    try Node.known.section_table.resize(
        &coff.mf,
        gpa,
        @sizeOf(std.coff.SectionHeader) * section_table_len,
    );

    const parent_ni, const alignment = if (coff.isArchive())
        .{ Node.known.zcu_member, .@"1" }
    else
        .{ Node.known.file, coff.mf.flags.block_size };

    const ni = try coff.mf.addLastChildNode(gpa, parent_ni, .{
        .alignment = alignment,
        .moved = true,
        .bubbles_moved = false,
    });

    const si = coff.addSymbolAssumeCapacity();
    coff.image_section_table.appendAssumeCapacity(si);
    coff.nodes.appendAssumeCapacity(.{ .image_section = si });
    const section_table = coff.sectionTableSlice();

    const virtual_size, const rva = if (coff.isImage()) block: {
        const virtual_size = coff.optionalHeaderField(.section_alignment);
        const rva: u32 = switch (section_index) {
            0 => @intCast(Node.known.header.location(&coff.mf).resolve(&coff.mf)[1]),
            else => coff.image_section_table.items[section_index - 1].get(coff).rva +
                coff.targetLoad(&section_table[section_index - 1].virtual_size),
        };

        break :block .{ virtual_size, rva };
    } else .{ 0, 0 };

    {
        const sym = si.get(coff);
        sym.ni = ni;
        sym.rva = rva;
        sym.section_number = @enumFromInt(section_table_len);
    }
    const section = &section_table[section_index];
    section.* = .{
        .name = undefined,
        .virtual_size = virtual_size,
        .virtual_address = rva,
        .size_of_raw_data = 0,
        .pointer_to_raw_data = 0,
        .pointer_to_relocations = 0,
        .pointer_to_linenumbers = 0,
        .number_of_relocations = 0,
        .number_of_linenumbers = 0,
        .flags = flags,
    };
    @memcpy(section.name[0..name.len], name);
    @memset(section.name[name.len..], 0);
    if (coff.targetEndian() != native_endian)
        std.mem.byteSwapAllFields(std.coff.SectionHeader, section);

    if (coff.isImage()) {
        switch (coff.optionalHeaderPtr()) {
            inline else => |optional_header| coff.targetStore(
                &optional_header.size_of_image,
                @intCast(rva + virtual_size),
            ),
        }
    }

    return si;
}

const ObjectSectionAttributes = packed struct {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    shared: bool = false,
    nopage: bool = false,
    nocache: bool = false,
    discard: bool = false,
    remove: bool = false,
};
fn pseudoSectionMapIndex(
    coff: *Coff,
    name: String,
    alignment: std.mem.Alignment,
    attributes: ObjectSectionAttributes,
) !Node.PseudoSectionMapIndex {
    const gpa = coff.base.comp.gpa;
    const pseudo_section_gop = try coff.pseudo_section_table.getOrPut(gpa, name);
    const psmi: Node.PseudoSectionMapIndex = @enumFromInt(pseudo_section_gop.index);
    if (!pseudo_section_gop.found_existing) {
        const parent: Symbol.Index = if (attributes.execute)
            .text
        else if (attributes.write)
            .data
        else
            .rdata;
        try coff.nodes.ensureUnusedCapacity(gpa, 1);
        try coff.symbol_table.ensureUnusedCapacity(gpa, 1);
        const ni = try coff.mf.addLastChildNode(gpa, parent.node(coff), .{ .alignment = alignment });
        const si = coff.addSymbolAssumeCapacity();
        pseudo_section_gop.value_ptr.* = si;
        const sym = si.get(coff);
        sym.ni = ni;
        sym.rva = coff.computeNodeRva(ni);
        sym.section_number = parent.get(coff).section_number;
        assert(sym.loc_relocs == .none);
        sym.loc_relocs = @enumFromInt(coff.relocs.items.len);
        coff.nodes.appendAssumeCapacity(.{ .pseudo_section = psmi });
    }
    return psmi;
}
fn objectSectionMapIndex(
    coff: *Coff,
    name: String,
    alignment: std.mem.Alignment,
    attributes: ObjectSectionAttributes,
) !Node.ObjectSectionMapIndex {
    const gpa = coff.base.comp.gpa;
    const object_section_gop = try coff.object_section_table.getOrPut(gpa, name);
    const osmi: Node.ObjectSectionMapIndex = @enumFromInt(object_section_gop.index);
    if (!object_section_gop.found_existing) {
        try coff.ensureUnusedStringCapacity(name.toSlice(coff).len);
        const name_slice = name.toSlice(coff);
        const parent = (try coff.pseudoSectionMapIndex(coff.getOrPutStringAssumeCapacity(
            name_slice[0 .. std.mem.indexOfScalar(u8, name_slice, '$') orelse name_slice.len],
        ), alignment, attributes)).symbol(coff);
        try coff.nodes.ensureUnusedCapacity(gpa, 1);
        try coff.symbol_table.ensureUnusedCapacity(gpa, 1);
        const parent_ni = parent.node(coff);
        var prev_ni: MappedFile.Node.Index = .none;
        var next_it = parent_ni.children(&coff.mf);
        while (next_it.next()) |next_ni| switch (std.mem.order(
            u8,
            name_slice,
            coff.getNode(next_ni).object_section.name(coff).toSlice(coff),
        )) {
            .lt => break,
            .eq => unreachable,
            .gt => prev_ni = next_ni,
        };
        const ni = switch (prev_ni) {
            .none => try coff.mf.addFirstChildNode(gpa, parent_ni, .{
                .alignment = alignment,
                .fixed = true,
            }),
            else => try coff.mf.addNodeAfter(gpa, prev_ni, .{
                .alignment = alignment,
                .fixed = true,
            }),
        };
        const si = coff.addSymbolAssumeCapacity();
        object_section_gop.value_ptr.* = si;
        const sym = si.get(coff);
        sym.ni = ni;
        sym.rva = coff.computeNodeRva(ni);
        sym.section_number = parent.get(coff).section_number;
        assert(sym.loc_relocs == .none);
        sym.loc_relocs = @enumFromInt(coff.relocs.items.len);
        coff.nodes.appendAssumeCapacity(.{ .object_section = osmi });
    }
    return osmi;
}

pub fn addReloc(
    coff: *Coff,
    loc_si: Symbol.Index,
    offset: u64,
    target_si: Symbol.Index,
    addend: i64,
    @"type": Reloc.Type,
) !void {
    const gpa = coff.base.comp.gpa;
    const target = target_si.get(coff);
    const ri: Reloc.Index = @enumFromInt(coff.relocs.items.len);
    (try coff.relocs.addOne(gpa)).* = .{
        .type = @"type",
        .prev = .none,
        .next = target.target_relocs,
        .loc = loc_si,
        .target = target_si,
        .unused = 0,
        .offset = offset,
        .addend = addend,
    };
    switch (target.target_relocs) {
        .none => {},
        else => |target_ri| target_ri.get(coff).prev = ri,
    }
    target.target_relocs = ri;
}

pub fn loadInput(coff: *Coff, input: link.Input) void {
    _ = coff;
    switch (input) {
        .dso_exact => unreachable,
        inline else => |i, tag| {
            log.debug("loadInput({s}: {f})", .{ @tagName(tag), i.path.fmtEscapeString() });
        },
    }
}

pub fn prelink(coff: *Coff, prog_node: std.Progress.Node) link.Error!void {
    _ = coff;
    _ = prog_node;
}

pub fn updateNav(coff: *Coff, pt: Zcu.PerThread, nav_index: InternPool.Nav.Index) !void {
    coff.updateNavInner(pt, nav_index) catch |err| switch (err) {
        else => |e| return e,
        error.MappedFileIo => return coff.base.cgFail(nav_index, "linker failed to update variable: {t}", .{coff.mf.io_err.?}),
    };
}
fn updateNavInner(coff: *Coff, pt: Zcu.PerThread, nav_index: InternPool.Nav.Index) !void {
    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;

    const nav = ip.getNav(nav_index);
    if (ip.indexToKey(nav.resolved.?.value) == .@"extern") return;
    if (!Type.fromInterned(nav.resolved.?.type).hasRuntimeBits(zcu)) return;

    const nmi = try coff.navMapIndex(zcu, nav_index);
    const si = nmi.symbol(coff);
    const ni = ni: {
        switch (si.get(coff).ni) {
            .none => {
                const sec_si = try coff.navSection(zcu, nav.resolved.?);
                try coff.nodes.ensureUnusedCapacity(gpa, 1);
                const ni = try coff.mf.addLastChildNode(gpa, sec_si.node(coff), .{
                    .alignment = zcu.navAlignment(nav_index).toStdMem(),
                    .moved = true,
                });
                coff.nodes.appendAssumeCapacity(.{ .nav = nmi });
                const sym = si.get(coff);
                sym.ni = ni;
                sym.section_number = sec_si.get(coff).section_number;
            },
            else => si.deleteLocationRelocs(coff),
        }
        const sym = si.get(coff);
        assert(sym.loc_relocs == .none);
        sym.loc_relocs = @enumFromInt(coff.relocs.items.len);
        break :ni sym.ni;
    };

    {
        var nw: MappedFile.Node.Writer = undefined;
        ni.writer(&coff.mf, gpa, &nw);
        defer nw.deinit();
        codegen.generateSymbol(
            &coff.base,
            pt,
            .fromInterned(nav.resolved.?.value),
            &nw.interface,
            .{ .atom_index = @enumFromInt(@intFromEnum(si)) },
        ) catch |err| switch (err) {
            error.WriteFailed => return nw.err.?,
            else => |e| return e,
        };
        si.get(coff).size = @intCast(nw.interface.end);
        si.applyLocationRelocs(coff);
    }

    if (nav.resolved.?.@"linksection".unwrap()) |_| {
        try ni.resize(&coff.mf, gpa, si.get(coff).size);
        var parent_ni = ni;
        while (true) {
            parent_ni = parent_ni.parent(&coff.mf);
            switch (coff.getNode(parent_ni)) {
                else => unreachable,
                .image_section, .pseudo_section => break,
                .object_section => {
                    var child_it = parent_ni.reverseChildren(&coff.mf);
                    const last_offset, const last_size =
                        child_it.next().?.location(&coff.mf).resolve(&coff.mf);
                    try parent_ni.resize(&coff.mf, gpa, last_offset + last_size);
                },
            }
        }
    }
}

pub fn lowerUav(
    coff: *Coff,
    pt: Zcu.PerThread,
    uav_val: InternPool.Index,
    uav_align: InternPool.Alignment,
) !link.File.SymbolId {
    const zcu = pt.zcu;
    const gpa = zcu.gpa;

    try coff.pending_uavs.ensureUnusedCapacity(gpa, 1);
    const umi = try coff.uavMapIndex(uav_val);
    const si = umi.symbol(coff);
    if (switch (si.get(coff).ni) {
        .none => true,
        else => |ni| uav_align.toStdMem().order(ni.alignment(&coff.mf)).compare(.gt),
    }) {
        const gop = coff.pending_uavs.getOrPutAssumeCapacity(umi);
        if (gop.found_existing) {
            gop.value_ptr.alignment = gop.value_ptr.alignment.max(uav_align);
        } else {
            gop.value_ptr.* = .{
                .alignment = uav_align,
            };
            coff.const_prog_node.increaseEstimatedTotalItems(1);
        }
    }
    return @enumFromInt(@intFromEnum(si));
}

pub fn updateFunc(
    coff: *Coff,
    pt: Zcu.PerThread,
    func_index: InternPool.Index,
    mir: *const codegen.AnyMir,
) !void {
    coff.updateFuncInner(pt, func_index, mir) catch |err| switch (err) {
        else => |e| return e,
        error.MappedFileIo => return coff.base.cgFail(
            pt.zcu.funcInfo(func_index).owner_nav,
            "linker failed to update function: {t}",
            .{coff.mf.io_err.?},
        ),
    };
}
fn updateFuncInner(
    coff: *Coff,
    pt: Zcu.PerThread,
    func_index: InternPool.Index,
    mir: *const codegen.AnyMir,
) !void {
    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;
    const func = zcu.funcInfo(func_index);
    const nav = ip.getNav(func.owner_nav);

    const nmi = try coff.navMapIndex(zcu, func.owner_nav);
    const si = nmi.symbol(coff);
    log.debug("updateFunc({f}) = {d}", .{ nav.fqn.fmt(ip), si });
    const ni = ni: {
        switch (si.get(coff).ni) {
            .none => {
                const sec_si = try coff.navSection(zcu, nav.resolved.?);
                try coff.nodes.ensureUnusedCapacity(gpa, 1);
                const mod = zcu.navFileScope(func.owner_nav).mod.?;
                const target = &mod.resolved_target.result;
                const ni = try coff.mf.addLastChildNode(gpa, sec_si.node(coff), .{
                    .alignment = switch (nav.resolved.?.@"align") {
                        .none => switch (mod.optimize_mode) {
                            .Debug,
                            .ReleaseSafe,
                            .ReleaseFast,
                            => target_util.defaultFunctionAlignment(target),
                            .ReleaseSmall => target_util.minFunctionAlignment(target),
                        },
                        else => |a| a.maxStrict(target_util.minFunctionAlignment(target)),
                    }.toStdMem(),
                    .moved = true,
                });
                coff.nodes.appendAssumeCapacity(.{ .nav = nmi });
                const sym = si.get(coff);
                sym.ni = ni;
                sym.section_number = sec_si.get(coff).section_number;
            },
            else => si.deleteLocationRelocs(coff),
        }
        const sym = si.get(coff);
        assert(sym.loc_relocs == .none);
        sym.loc_relocs = @enumFromInt(coff.relocs.items.len);
        break :ni sym.ni;
    };

    var nw: MappedFile.Node.Writer = undefined;
    ni.writer(&coff.mf, gpa, &nw);
    defer nw.deinit();
    codegen.emitFunction(
        &coff.base,
        pt,
        func_index,
        @enumFromInt(@intFromEnum(si)),
        mir,
        &nw.interface,
        .none,
    ) catch |err| switch (err) {
        error.WriteFailed => return nw.err.?,
        else => |e| return e,
    };
    si.get(coff).size = @intCast(nw.interface.end);
    si.applyLocationRelocs(coff);
}

pub fn updateErrorData(coff: *Coff, pt: Zcu.PerThread) !void {
    coff.flushLazy(pt, .{
        .kind = .const_data,
        .index = @intCast(coff.lazy.getPtr(.const_data).map.getIndex(.anyerror_type) orelse return),
    }) catch |err| switch (err) {
        else => |e| return e,
        error.MappedFileIo => return coff.base.comp.link_diags.fail(
            "updateErrorData failed: {t}",
            .{coff.mf.io_err.?},
        ),
    };
}

fn flushImplib(
    coff: *Coff,
    implib_file: []const u8,
) !void {
    // Emitting implibs is only valid for images
    assert(coff.export_table.ni != .none);

    const comp = coff.base.comp;
    const gpa = comp.gpa;
    const io = comp.io;

    const image_name = std.mem.sliceTo(
        coff.export_table.ni.slice(&coff.mf)[@sizeOf(std.coff.ExportDirectoryTable)..],
        0,
    );
    const machine_type = coff.targetLoad(&coff.headerPtr().machine);
    const members = members: {
        const def_arena: std.heap.ArenaAllocator = .init(gpa);
        var def: ModuleDefinition = .{
            .name = image_name,
            .arena = def_arena,
            .type = .mingw,
        };
        defer def.deinit();

        try def.exports.ensureUnusedCapacity(
            def.arena.allocator(),
            coff.export_table.entries.count(),
        );

        const name_table_slice = coff.export_table.name_table_ni.slice(&coff.mf);
        for (coff.export_table.entries.values(), 0..) |entry, ord| {
            const name = name_table_slice[entry.name_index..][0..entry.name_len];
            const section_number = entry.si.get(coff).section_number;
            const import_type: std.coff.ImportType = switch (section_number.symbol(coff)) {
                .data, .rdata => .DATA,
                .text => .CODE,
                else => return comp.link_diags.fail(
                    "unsupported section for export '{s}': {s}",
                    .{ name, &section_number.header(coff).name },
                ),
            };

            def.exports.appendAssumeCapacity(.{
                .name = name,
                .mangled_symbol_name = null,
                .ext_name = null,
                .import_name = null,
                .export_as = null,
                .no_name = false,
                .ordinal = @intCast(ord),
                .type = import_type,
                .private = false,
            });
        }

        def.fixupForImportLibraryGeneration(machine_type);
        break :members try implib.getMembers(gpa, def, machine_type);
    };
    defer members.deinit();

    const lib_sub_path = try std.fs.path.join(gpa, &.{
        std.fs.path.dirname(coff.base.emit.sub_path) orelse "",
        implib_file,
    });
    defer gpa.free(lib_sub_path);

    const lib_final_file = try coff.base.emit.root_dir.handle.createFile(io, lib_sub_path, .{ .truncate = true });
    defer lib_final_file.close(io);
    var buffer: [1024]u8 = undefined;
    var file_writer = lib_final_file.writer(io, &buffer);
    try implib.writeCoffArchive(gpa, &file_writer.interface, members);
    try file_writer.interface.flush();
}

pub fn flush(
    coff: *Coff,
    arena: std.mem.Allocator,
    tid: Zcu.PerThread.Id,
    prog_node: std.Progress.Node,
) !void {
    _ = arena;
    _ = prog_node;
    while (try coff.idle(tid)) {}

    // TODO: Second linker member symbol tables are built here
    if (isArchive(coff)) {
        //Member.Index.second.get(coff).content_ni;
    }

    const comp = coff.base.comp;

    // Implib generation should instead be done via building a MappedFile progressively
    if (comp.emit_implib) |implib_file|
        coff.flushImplib(implib_file) catch |err|
            return comp.link_diags.fail("flushing implib '{s}' failed: {t}", .{ implib_file, err });

    // hack for stage2_x86_64 + coff
    if (comp.compiler_rt_dyn_lib) |crt_file| {
        const io = comp.io;
        const gpa = comp.gpa;

        const compiler_rt_sub_path = try std.fs.path.join(gpa, &.{
            std.fs.path.dirname(coff.base.emit.sub_path) orelse "",
            std.fs.path.basename(crt_file.full_object_path.sub_path),
        });
        defer gpa.free(compiler_rt_sub_path);
        std.Io.Dir.copyFile(
            crt_file.full_object_path.root_dir.handle,
            crt_file.full_object_path.sub_path,
            coff.base.emit.root_dir.handle,
            compiler_rt_sub_path,
            io,
            .{},
        ) catch |err| return comp.link_diags.fail("copy '{s}' failed: {t}", .{ compiler_rt_sub_path, err });
    }

    coff.mf.flush() catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => |e| return comp.link_diags.fail("flush write failed: {t}", .{e}),
    };

    coff.dumpStderr(tid) catch |err|
        return comp.link_diags.fail("dumping link snapshot failed: {t}", .{err});
}

pub fn idle(coff: *Coff, tid: Zcu.PerThread.Id) !bool {
    const comp = coff.base.comp;
    task: {
        while (coff.pending_uavs.pop()) |pending_uav| {
            const sub_prog_node = coff.idleProgNode(tid, coff.const_prog_node, .{ .uav = pending_uav.key });
            defer sub_prog_node.end();
            coff.flushUav(
                .{ .zcu = comp.zcu.?, .tid = tid },
                pending_uav.key,
                pending_uav.value.alignment,
            ) catch |err| switch (err) {
                else => |e| return e,
                error.MappedFileIo => return comp.link_diags.fail(
                    "linker failed to lower constant: {t}",
                    .{coff.mf.io_err.?},
                ),
            };
            break :task;
        }
        if (coff.global_pending_index < coff.globals.count()) {
            const pt: Zcu.PerThread = .{ .zcu = comp.zcu.?, .tid = tid };
            const gmi: Node.GlobalMapIndex = @enumFromInt(coff.global_pending_index);
            coff.global_pending_index += 1;
            const sub_prog_node = coff.synth_prog_node.start(
                gmi.globalName(coff).name.toSlice(coff),
                0,
            );
            defer sub_prog_node.end();
            coff.flushGlobal(pt, gmi) catch |err| switch (err) {
                else => |e| return e,
                error.MappedFileIo => return comp.link_diags.fail(
                    "linker failed to lower constant: {t}",
                    .{coff.mf.io_err.?},
                ),
            };
            break :task;
        }
        var lazy_it = coff.lazy.iterator();
        while (lazy_it.next()) |lazy| if (lazy.value.pending_index < lazy.value.map.count()) {
            const pt: Zcu.PerThread = .{ .zcu = comp.zcu.?, .tid = tid };
            const lmr: Node.LazyMapRef = .{ .kind = lazy.key, .index = lazy.value.pending_index };
            lazy.value.pending_index += 1;
            const kind = switch (lmr.kind) {
                .code => "code",
                .const_data => "data",
            };
            var name: [std.Progress.Node.max_name_len]u8 = undefined;
            const sub_prog_node = coff.synth_prog_node.start(
                std.fmt.bufPrint(&name, "lazy {s} for {f}", .{
                    kind,
                    Type.fromInterned(lmr.lazySymbol(coff).ty).fmt(pt),
                }) catch &name,
                0,
            );
            defer sub_prog_node.end();
            coff.flushLazy(pt, lmr) catch |err| switch (err) {
                else => |e| return e,
                error.MappedFileIo => return comp.link_diags.fail(
                    "linker failed to lower lazy {s}: {t}",
                    .{ kind, coff.mf.io_err.? },
                ),
            };
            break :task;
        };
        while (coff.mf.updates.pop()) |ni| {
            const clean_moved = ni.cleanMoved(&coff.mf);
            const clean_resized = ni.cleanResized(&coff.mf);
            if (clean_moved or clean_resized) {
                const sub_prog_node =
                    coff.idleProgNode(tid, coff.mf.update_prog_node, coff.getNode(ni));
                defer sub_prog_node.end();
                if (clean_moved) try coff.flushMoved(ni);
                if (clean_resized) try coff.flushResized(ni);
                break :task;
            } else coff.mf.update_prog_node.completeOne();
        }
        while (coff.pending_members.pop()) |pending_mi| {
            // TODO: Prog node
            try coff.flushMember(pending_mi.key);
            break :task;
        }
        if (coff.export_table.pending_sort) {
            // TODO: Prog node
            coff.export_table.pending_sort = false;
            coff.flushExportsSort();
            break :task;
        }
    }
    if (coff.pending_uavs.count() > 0) return true;
    if (coff.globals.count() > coff.global_pending_index) return true;
    for (&coff.lazy.values) |lazy| if (lazy.map.count() > lazy.pending_index) return true;
    if (coff.mf.updates.items.len > 0) return true;
    if (coff.pending_members.count() > 0) return true;
    if (coff.export_table.pending_sort) return true;
    return false;
}

fn idleProgNode(
    coff: *Coff,
    tid: Zcu.PerThread.Id,
    prog_node: std.Progress.Node,
    node: Node,
) std.Progress.Node {
    var name: [std.Progress.Node.max_name_len]u8 = undefined;
    return prog_node.start(name: switch (node) {
        else => |tag| @tagName(tag),
        .image_section => |si| std.mem.sliceTo(&si.get(coff).section_number.header(coff).name, 0),
        inline .pseudo_section, .object_section => |smi| smi.name(coff).toSlice(coff),
        .global => |gmi| gmi.globalName(coff).name.toSlice(coff),
        .nav => |nmi| {
            const ip = &coff.base.comp.zcu.?.intern_pool;
            break :name ip.getNav(nmi.navIndex(coff)).fqn.toSlice(ip);
        },
        .uav => |umi| std.fmt.bufPrint(&name, "{f}", .{
            Value.fromInterned(umi.uavValue(coff)).fmtValue(.{
                .zcu = coff.base.comp.zcu.?,
                .tid = tid,
            }),
        }) catch &name,
    }, 0);
}

fn flushUav(
    coff: *Coff,
    pt: Zcu.PerThread,
    umi: Node.UavMapIndex,
    uav_align: InternPool.Alignment,
) !void {
    const zcu = pt.zcu;
    const gpa = zcu.gpa;

    const uav_val = umi.uavValue(coff);
    const si = umi.symbol(coff);
    const ni = ni: {
        switch (si.get(coff).ni) {
            .none => {
                const sec_si = (try coff.objectSectionMapIndex(
                    .@".rdata",
                    coff.mf.flags.block_size,
                    .{ .read = true },
                )).symbol(coff);
                try coff.nodes.ensureUnusedCapacity(gpa, 1);
                const sym = si.get(coff);
                const ni = try coff.mf.addLastChildNode(gpa, sec_si.node(coff), .{
                    .alignment = uav_align.toStdMem(),
                    .moved = true,
                });
                coff.nodes.appendAssumeCapacity(.{ .uav = umi });
                sym.ni = ni;
                sym.section_number = sec_si.get(coff).section_number;
            },
            else => {
                if (si.get(coff).ni.alignment(&coff.mf).order(uav_align.toStdMem()).compare(.gte))
                    return;
                si.deleteLocationRelocs(coff);
            },
        }
        const sym = si.get(coff);
        assert(sym.loc_relocs == .none);
        sym.loc_relocs = @enumFromInt(coff.relocs.items.len);
        break :ni sym.ni;
    };

    var nw: MappedFile.Node.Writer = undefined;
    ni.writer(&coff.mf, gpa, &nw);
    defer nw.deinit();
    codegen.generateSymbol(
        &coff.base,
        pt,
        .fromInterned(uav_val),
        &nw.interface,
        .{ .atom_index = @enumFromInt(@intFromEnum(si)) },
    ) catch |err| switch (err) {
        error.WriteFailed => return nw.err.?,
        else => |e| return e,
    };
    si.get(coff).size = @intCast(nw.interface.end);
    si.applyLocationRelocs(coff);
}

fn flushGlobal(coff: *Coff, pt: Zcu.PerThread, gmi: Node.GlobalMapIndex) !void {
    const zcu = pt.zcu;
    const comp = zcu.comp;
    const gpa = zcu.gpa;
    const gn = gmi.globalName(coff);

    // TODO: We still need to emit a reloc for the __imp_Name symbol?

    if (!coff.isImage()) return;

    if (gn.lib_name.toSlice(coff)) |lib_name| {
        const name = gn.name.toSlice(coff);
        try coff.nodes.ensureUnusedCapacity(gpa, 4);
        try coff.symbol_table.ensureUnusedCapacity(gpa, 1);

        const target_endian = coff.targetEndian();
        const magic = coff.targetLoad(&coff.optionalHeaderStandardPtr().magic);
        const addr_size: u64, const addr_align: std.mem.Alignment = switch (magic) {
            _ => unreachable,
            .PE32 => .{ 4, .@"4" },
            .@"PE32+" => .{ 8, .@"8" },
        };

        const gop = try coff.import_table.entries.getOrPutAdapted(
            gpa,
            lib_name,
            ImportTable.Adapter{ .coff = coff },
        );
        const import_hint_name_align: std.mem.Alignment = .@"2";
        if (!gop.found_existing) {
            errdefer _ = coff.import_table.entries.pop();
            try coff.import_table.ni.resize(
                &coff.mf,
                gpa,
                @sizeOf(std.coff.ImportDirectoryEntry) * (gop.index + 2),
            );
            const import_hint_name_table_len =
                import_hint_name_align.forward(lib_name.len + ".dll".len + 1);
            const idata_section_ni = coff.import_table.ni.parent(&coff.mf);
            const import_lookup_table_ni = try coff.mf.addLastChildNode(gpa, idata_section_ni, .{
                .size = addr_size * 2,
                .alignment = addr_align,
                .moved = true,
            });
            const import_address_table_ni = try coff.mf.addLastChildNode(gpa, idata_section_ni, .{
                .size = addr_size * 2,
                .alignment = addr_align,
                .moved = true,
            });
            const import_address_table_si = coff.addSymbolAssumeCapacity();
            {
                const import_address_table_sym = import_address_table_si.get(coff);
                import_address_table_sym.ni = import_address_table_ni;
                assert(import_address_table_sym.loc_relocs == .none);
                import_address_table_sym.loc_relocs = @enumFromInt(coff.relocs.items.len);
                import_address_table_sym.section_number =
                    coff.getNode(idata_section_ni).object_section.symbol(coff).get(coff).section_number;
            }
            const import_hint_name_table_ni = try coff.mf.addLastChildNode(gpa, idata_section_ni, .{
                .size = import_hint_name_table_len,
                .alignment = import_hint_name_align,
                .moved = true,
            });
            gop.value_ptr.* = .{
                .import_lookup_table_ni = import_lookup_table_ni,
                .import_address_table_si = import_address_table_si,
                .import_hint_name_table_ni = import_hint_name_table_ni,
                .len = 0,
                .hint_name_len = @intCast(import_hint_name_table_len),
            };
            const import_hint_name_slice = import_hint_name_table_ni.slice(&coff.mf);
            @memcpy(import_hint_name_slice[0..lib_name.len], lib_name);
            @memcpy(import_hint_name_slice[lib_name.len..][0..".dll".len], ".dll");
            @memset(import_hint_name_slice[lib_name.len + ".dll".len ..], 0);
            coff.nodes.appendAssumeCapacity(.{ .import_lookup_table = @enumFromInt(gop.index) });
            coff.nodes.appendAssumeCapacity(.{ .import_address_table = @enumFromInt(gop.index) });
            coff.nodes.appendAssumeCapacity(.{ .import_hint_name_table = @enumFromInt(gop.index) });

            const import_directory_entries = coff.importDirectoryTableSlice()[gop.index..][0..2];
            import_directory_entries.* = .{ .{
                .import_lookup_table_rva = coff.computeNodeRva(import_lookup_table_ni),
                .time_date_stamp = 0,
                .forwarder_chain = 0,
                .name_rva = coff.computeNodeRva(import_hint_name_table_ni),
                .import_address_table_rva = coff.computeNodeRva(import_address_table_ni),
            }, .{
                .import_lookup_table_rva = 0,
                .time_date_stamp = 0,
                .forwarder_chain = 0,
                .name_rva = 0,
                .import_address_table_rva = 0,
            } };
            if (target_endian != native_endian)
                std.mem.byteSwapAllFields([2]std.coff.ImportDirectoryEntry, import_directory_entries);
        }
        const import_symbol_index = gop.value_ptr.len;
        gop.value_ptr.len = import_symbol_index + 1;
        const new_symbol_table_size = addr_size * (import_symbol_index + 2);
        const import_hint_name_index = gop.value_ptr.hint_name_len;
        gop.value_ptr.hint_name_len = @intCast(
            import_hint_name_align.forward(import_hint_name_index + 2 + name.len + 1),
        );
        try gop.value_ptr.import_lookup_table_ni.resize(&coff.mf, gpa, new_symbol_table_size);
        const import_address_table_ni = gop.value_ptr.import_address_table_si.node(coff);
        try import_address_table_ni.resize(&coff.mf, gpa, new_symbol_table_size);
        try gop.value_ptr.import_hint_name_table_ni.resize(&coff.mf, gpa, gop.value_ptr.hint_name_len);
        const import_lookup_slice = gop.value_ptr.import_lookup_table_ni.slice(&coff.mf);
        const import_address_slice = import_address_table_ni.slice(&coff.mf);
        const import_hint_name_slice = gop.value_ptr.import_hint_name_table_ni.slice(&coff.mf);
        @memset(import_hint_name_slice[import_hint_name_index..][0..2], 0);
        @memcpy(import_hint_name_slice[import_hint_name_index + 2 ..][0..name.len], name);
        @memset(import_hint_name_slice[import_hint_name_index + 2 + name.len ..], 0);
        const import_hint_name_rva =
            coff.computeNodeRva(gop.value_ptr.import_hint_name_table_ni) + import_hint_name_index;
        switch (magic) {
            _ => unreachable,
            inline .PE32, .@"PE32+" => |ct_magic| {
                const Addr = switch (ct_magic) {
                    _ => comptime unreachable,
                    .PE32 => u32,
                    .@"PE32+" => u64,
                };
                const import_lookup_table: []Addr = @ptrCast(@alignCast(import_lookup_slice));
                const import_address_table: []Addr = @ptrCast(@alignCast(import_address_slice));
                const import_hint_name_rvas: [2]Addr = .{
                    std.mem.nativeTo(Addr, @intCast(import_hint_name_rva), target_endian),
                    std.mem.nativeTo(Addr, 0, target_endian),
                };
                import_lookup_table[import_symbol_index..][0..2].* = import_hint_name_rvas;
                import_address_table[import_symbol_index..][0..2].* = import_hint_name_rvas;
            },
        }
        const si = gmi.symbol(coff);
        const sym = si.get(coff);
        sym.section_number = Symbol.Index.text.get(coff).section_number;
        assert(sym.loc_relocs == .none);
        sym.loc_relocs = @enumFromInt(coff.relocs.items.len);
        switch (coff.targetLoad(&coff.headerPtr().machine)) {
            else => |tag| @panic(@tagName(tag)),
            .AMD64 => {
                const init = [_]u8{ 0xff, 0x25, 0x00, 0x00, 0x00, 0x00 };
                const target = &comp.root_mod.resolved_target.result;
                const ni = try coff.mf.addLastChildNode(gpa, Symbol.Index.text.node(coff), .{
                    .alignment = switch (comp.root_mod.optimize_mode) {
                        .Debug,
                        .ReleaseSafe,
                        .ReleaseFast,
                        => target_util.defaultFunctionAlignment(target),
                        .ReleaseSmall => target_util.minFunctionAlignment(target),
                    }.toStdMem(),
                    .size = init.len,
                });
                @memcpy(ni.slice(&coff.mf)[0..init.len], &init);
                sym.ni = ni;
                sym.size = init.len;
                try coff.addReloc(
                    si,
                    init.len - 4,
                    gop.value_ptr.import_address_table_si,
                    @intCast(addr_size * import_symbol_index),
                    .{ .AMD64 = .REL32 },
                );
            },
        }
        coff.nodes.appendAssumeCapacity(.{ .global = gmi });
        sym.rva = coff.computeNodeRva(sym.ni);
        si.applyLocationRelocs(coff);
    }
}

fn flushLazy(coff: *Coff, pt: Zcu.PerThread, lmr: Node.LazyMapRef) !void {
    const zcu = pt.zcu;
    const gpa = zcu.gpa;

    const lazy = lmr.lazySymbol(coff);
    const si = lmr.symbol(coff);
    const ni = ni: {
        const sym = si.get(coff);
        switch (sym.ni) {
            .none => {
                try coff.nodes.ensureUnusedCapacity(gpa, 1);
                const sec_si: Symbol.Index = switch (lazy.kind) {
                    .code => .text,
                    .const_data => .rdata,
                };
                const ni = try coff.mf.addLastChildNode(gpa, sec_si.node(coff), .{ .moved = true });
                coff.nodes.appendAssumeCapacity(switch (lazy.kind) {
                    .code => .{ .lazy_code = @enumFromInt(lmr.index) },
                    .const_data => .{ .lazy_const_data = @enumFromInt(lmr.index) },
                });
                sym.ni = ni;
                sym.section_number = sec_si.get(coff).section_number;
            },
            else => si.deleteLocationRelocs(coff),
        }
        assert(sym.loc_relocs == .none);
        sym.loc_relocs = @enumFromInt(coff.relocs.items.len);
        break :ni sym.ni;
    };

    var required_alignment: InternPool.Alignment = .none;
    var nw: MappedFile.Node.Writer = undefined;
    ni.writer(&coff.mf, gpa, &nw);
    defer nw.deinit();
    codegen.generateLazySymbol(
        &coff.base,
        pt,
        lazy,
        &required_alignment,
        &nw.interface,
        .none,
        .{ .atom_index = @enumFromInt(@intFromEnum(si)) },
    ) catch |err| switch (err) {
        error.WriteFailed => return nw.err.?,
        else => |e| return e,
    };
    si.get(coff).size = @intCast(nw.interface.end);
    si.applyLocationRelocs(coff);
}

fn flushMoved(coff: *Coff, ni: MappedFile.Node.Index) !void {
    log.debug("flushMoved({s})", .{@tagName(coff.getNode(ni))});
    switch (coff.getNode(ni)) {
        .file,
        .header,
        .signature,
        => unreachable,
        .coff_header,
        .optional_header,
        .data_directories,
        .section_table,
        .placeholder,
        => if (!coff.isArchive()) unreachable,
        .archive_member_header => |mi| {
            const member = mi.get(coff);
            switch (member.kind) {
                .first_linker, .second_linker, .longnames => {},
                else => coff.targetStore(
                    &coff.secondLinkerMemberOffsetsSlice()[@intFromEnum(mi) - Member.Index.known_count],
                    @intCast(ni.fileLocation(&coff.mf, false).offset),
                ),
            }

            if (member.kind == .coff)
                try coff.pending_members.put(coff.base.comp.gpa, mi, {});
        },
        .archive_member,
        => {},
        .image_section => |si| {
            const file_offset = if (isArchive(coff))
                si.get(coff).ni.location(&coff.mf).resolve(&coff.mf)[0]
            else
                ni.fileLocation(&coff.mf, false).offset;

            return coff.targetStore(
                &si.get(coff).section_number.header(coff).pointer_to_raw_data,
                @intCast(file_offset),
            );
        },
        .import_directory_table => coff.targetStore(
            &coff.dataDirectoryPtr(.IMPORT).virtual_address,
            coff.computeNodeRva(ni),
        ),
        .import_lookup_table => |import_index| coff.targetStore(
            &coff.importDirectoryEntryPtr(import_index).import_lookup_table_rva,
            coff.computeNodeRva(ni),
        ),
        .import_address_table => |import_index| {
            const import_address_table_si = import_index.get(coff).import_address_table_si;
            import_address_table_si.flushMoved(coff);
            coff.targetStore(
                &coff.importDirectoryEntryPtr(import_index).import_address_table_rva,
                import_address_table_si.get(coff).rva,
            );
        },
        .import_hint_name_table => |import_index| {
            const target_endian = coff.targetEndian();
            const magic = coff.targetLoad(&coff.optionalHeaderStandardPtr().magic);
            const import_hint_name_rva = coff.computeNodeRva(ni);
            coff.targetStore(
                &coff.importDirectoryEntryPtr(import_index).name_rva,
                import_hint_name_rva,
            );
            const import_entry = import_index.get(coff);
            const import_lookup_slice = import_entry.import_lookup_table_ni.slice(&coff.mf);
            const import_address_slice =
                import_entry.import_address_table_si.node(coff).slice(&coff.mf);
            const import_hint_name_slice = ni.slice(&coff.mf);
            const import_hint_name_align = ni.alignment(&coff.mf);
            var import_hint_name_index: u32 = 0;
            for (0..import_entry.len) |import_symbol_index| {
                import_hint_name_index = @intCast(import_hint_name_align.forward(
                    std.mem.indexOfScalarPos(
                        u8,
                        import_hint_name_slice,
                        import_hint_name_index,
                        0,
                    ).? + 1,
                ));
                switch (magic) {
                    _ => unreachable,
                    inline .PE32, .@"PE32+" => |ct_magic| {
                        const Addr = switch (ct_magic) {
                            _ => comptime unreachable,
                            .PE32 => u32,
                            .@"PE32+" => u64,
                        };
                        const import_lookup_table: []Addr = @ptrCast(@alignCast(import_lookup_slice));
                        const import_address_table: []Addr = @ptrCast(@alignCast(import_address_slice));
                        const rva = std.mem.nativeTo(
                            Addr,
                            import_hint_name_rva + import_hint_name_index,
                            target_endian,
                        );
                        import_lookup_table[import_symbol_index] = rva;
                        import_address_table[import_symbol_index] = rva;
                    },
                }
                import_hint_name_index += 2;
            }
        },
        .export_directory_table => {
            const rva = coff.computeNodeRva(ni);
            coff.targetStore(&coff.dataDirectoryPtr(.EXPORT).virtual_address, rva);
            coff.targetStore(&coff.exportDirectoryTable().name_rva, rva + @sizeOf(std.coff.ExportDirectoryTable));
        },
        .export_address_table => {
            coff.export_table.export_address_table_si.flushMoved(coff);

            // These relocs are applied directly here instead of via the above flushMoved call as
            // they are non-contiguous, and not tracked under export_address_table_si.
            for (coff.export_table.entries.values()) |entry|
                entry.export_address_table_ri.get(coff).apply(coff);

            coff.targetStore(
                &coff.exportDirectoryTable().export_address_table_rva,
                coff.computeNodeRva(ni),
            );
        },
        .export_name_pointer_table => coff.targetStore(
            &coff.exportDirectoryTable().name_pointer_table_rva,
            coff.computeNodeRva(ni),
        ),
        .export_ordinal_table => coff.targetStore(
            &coff.exportDirectoryTable().ordinal_table_rva,
            coff.computeNodeRva(ni),
        ),
        .export_name_table => {
            const name_table_rva = coff.computeNodeRva(coff.export_table.name_table_ni);
            for (
                coff.exportNamePointerTableSlice(),
                coff.exportOrdinalTableSlice(),
            ) |*np, target_ord| {
                const ord: ExportTable.Ordinal = @enumFromInt(coff.targetLoad(&target_ord.unbiased_ordinal));
                const entry = ord.get(coff);
                coff.targetStore(
                    &np.name_rva,
                    @intCast(name_table_rva + entry.name_index),
                );
            }
        },
        inline .pseudo_section,
        .object_section,
        .global,
        .nav,
        .uav,
        .lazy_code,
        .lazy_const_data,
        => |mi| mi.symbol(coff).flushMoved(coff),
    }
    try ni.childrenMoved(coff.base.comp.gpa, &coff.mf);
}

fn flushResized(coff: *Coff, ni: MappedFile.Node.Index) !void {
    _, const size = ni.location(&coff.mf).resolve(&coff.mf);
    log.debug("flushResized({s}, 0x{x})", .{ @tagName(coff.getNode(ni)), size });

    switch (coff.getNode(ni)) {
        .file => {
            if (coff.isArchive() and coff.members.items.len > 0) {
                const last_member = coff.members.items[coff.members.items.len - 1];
                assert(Node.known.file.reverseChildren(&coff.mf).ni == last_member.content_ni);
                try coff.flushResized(last_member.content_ni);
            }
        },
        .header => {
            if (coff.isImage()) {
                switch (coff.optionalHeaderPtr()) {
                    inline else => |optional_header| coff.targetStore(
                        &optional_header.size_of_headers,
                        @intCast(size),
                    ),
                }

                if (size > coff.image_section_table.items[0].get(coff).rva) try coff.virtualSlide(
                    0,
                    std.mem.alignForward(
                        u32,
                        @intCast(size * 4),
                        coff.optionalHeaderField(.section_alignment),
                    ),
                );
            }
        },
        .signature,
        .archive_member_header,
        => unreachable,
        .archive_member => |mi| {
            const content_ni = mi.get(coff).content_ni;
            const next_ni = content_ni.next(&coff.mf);
            const offset, _ = content_ni.location(&coff.mf).resolve(&coff.mf);
            const next_offset = switch (next_ni) {
                .none => offset: {
                    assert(content_ni.parent(&coff.mf) == Node.known.file);
                    // This must take into account the final file size. If there are trailing
                    // bytes, they will be expected to contain another valid member header
                    break :offset coff.mf.memory_map.memory.len;
                },
                else => offset: {
                    assert(coff.getNode(next_ni) == .archive_member_header);
                    break :offset next_ni.location(&coff.mf).resolve(&coff.mf)[0];
                },
            };

            // Not inserting IMAGE_ARCHIVE_PAD `\n` byte here, because we are expanding to full size
            Member.storeHeaderDecimalStr(&mi.get(coff).headerPtr(coff).size, next_offset - offset);
        },
        .coff_header,
        .optional_header,
        .data_directories,
        => unreachable,
        .section_table => {},
        .image_section => |si| {
            const sym = si.get(coff);
            const section_index = sym.section_number.toIndex();
            const section = &coff.sectionTableSlice()[section_index];
            coff.targetStore(&section.size_of_raw_data, @intCast(size));
            if (coff.isImage() and size > coff.targetLoad(&section.virtual_size)) {
                const virtual_size = std.mem.alignForward(
                    u32,
                    @intCast(size * 4),
                    coff.optionalHeaderField(.section_alignment),
                );
                coff.targetStore(&section.virtual_size, virtual_size);
                try coff.virtualSlide(section_index + 1, sym.rva + virtual_size);
            }
        },
        .import_directory_table => coff.targetStore(
            &coff.dataDirectoryPtr(.IMPORT).size,
            @intCast(size),
        ),
        .import_lookup_table,
        .import_address_table,
        .import_hint_name_table,
        => {},
        .export_directory_table => unreachable,
        .export_address_table,
        .export_name_pointer_table,
        .export_ordinal_table,
        .export_name_table,
        => {},
        inline .pseudo_section,
        .object_section,
        => |smi, tag| {
            if (tag == .pseudo_section and smi.name(coff) == .@".edata") {
                coff.targetStore(
                    &coff.dataDirectoryPtr(.EXPORT).size,
                    @intCast(size),
                );
            }

            smi.symbol(coff).get(coff).size = @intCast(size);
        },
        .global,
        .nav,
        .uav,
        .lazy_code,
        .lazy_const_data,
        => {},
        .placeholder => unreachable,
    }
}

fn flushMember(coff: *Coff, mi: Member.Index) !void {
    const member = mi.get(coff);
    switch (member.kind) {
        .first_linker,
        .longnames,
        .import,
        => unreachable,
        .second_linker => {
            const Context = struct {
                coff: *Coff,
                indices: []u16,
                strings: []String,

                pub fn lessThan(ctx: @This(), lhs: usize, rhs: usize) bool {
                    return std.mem.lessThan(
                        u8,
                        ctx.strings[lhs].toSlice(ctx.coff),
                        ctx.strings[rhs].toSlice(ctx.coff),
                    );
                }

                pub fn swap(ctx: @This(), lhs: usize, rhs: usize) void {
                    std.mem.swap(u16, &ctx.indices[lhs], &ctx.indices[rhs]);
                    std.mem.swap(String, &ctx.strings[lhs], &ctx.strings[rhs]);
                }
            };

            std.sort.pdqContext(0, coff.lib_string_table.items.len, Context{
                .coff = coff,
                .indices = coff.secondLinkerMemberIndicesSlice(),
                .strings = coff.lib_string_table.items,
            });

            var offset: u64 = 0;

            var string_table = coff.secondLinkerMemberStringsSlice();
            for (coff.lib_string_table.items) |string| {
                const str = string.toSlice(coff);
                @memcpy(string_table[offset..][0..str.len], str);
                string_table[offset + str.len] = 0;
                offset += str.len + 1;
            }
        },
        .coff => {
            const file_offset: u32 = @intCast(member.header_ni.fileLocation(&coff.mf, false).offset);
            const first_linker_offsets = coff.firstLinkerMemberOffsetsSlice();
            for (member.symbol_offsets.values()) |offset_index|
                first_linker_offsets[offset_index] = std.mem.nativeTo(u32, file_offset, .big);
        },
    }
}

fn flushExportsSort(coff: *Coff) void {
    const Context = struct {
        coff: *Coff,
        np: []std.coff.ExportNamePointerTableEntry,
        ord: []std.coff.ExportOrdinalTableEntry,
        entries: []ExportTable.Entry,
        nt: []const u8,

        pub fn lessThan(ctx: @This(), lhs: usize, rhs: usize) bool {
            const lhs_entry = &ctx.entries[ctx.coff.targetLoad(&ctx.ord[lhs].unbiased_ordinal)];
            const rhs_entry = &ctx.entries[ctx.coff.targetLoad(&ctx.ord[rhs].unbiased_ordinal)];
            return std.mem.lessThan(
                u8,
                ctx.nt[lhs_entry.name_index..][0..lhs_entry.name_len],
                ctx.nt[rhs_entry.name_index..][0..rhs_entry.name_len],
            );
        }

        pub fn swap(ctx: @This(), lhs: usize, rhs: usize) void {
            std.mem.swap(std.coff.ExportNamePointerTableEntry, &ctx.np[lhs], &ctx.np[rhs]);
            std.mem.swap(std.coff.ExportOrdinalTableEntry, &ctx.ord[lhs], &ctx.ord[rhs]);
        }
    };

    std.sort.pdqContext(0, coff.export_table.entries.count(), Context{
        .coff = coff,
        .np = coff.exportNamePointerTableSlice(),
        .ord = coff.exportOrdinalTableSlice(),
        .entries = coff.export_table.entries.values(),
        .nt = coff.export_table.name_table_ni.slice(&coff.mf),
    });
}

fn virtualSlide(coff: *Coff, start_section_index: usize, start_rva: u32) !void {
    var rva = start_rva;
    for (
        coff.image_section_table.items[start_section_index..],
        coff.sectionTableSlice()[start_section_index..],
    ) |section_si, *section| {
        const section_sym = section_si.get(coff);
        section_sym.rva = rva;
        coff.targetStore(&section.virtual_address, rva);
        try section_sym.ni.childrenMoved(coff.base.comp.gpa, &coff.mf);
        rva += coff.targetLoad(&section.virtual_size);
    }
    switch (coff.optionalHeaderPtr()) {
        inline else => |optional_header| coff.targetStore(
            &optional_header.size_of_image,
            @intCast(rva),
        ),
    }
}

pub fn updateExports(
    coff: *Coff,
    pt: Zcu.PerThread,
    exported: Zcu.Exported,
    export_indices: []const Zcu.Export.Index,
) !void {
    return coff.updateExportsInner(pt, exported, export_indices) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => |e| coff.base.comp.link_diags.fail("updateExports failed {t}", .{e}) catch error.AnalysisFail,
    };
}
fn updateExportsInner(
    coff: *Coff,
    pt: Zcu.PerThread,
    exported: Zcu.Exported,
    export_indices: []const Zcu.Export.Index,
) !void {
    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;

    switch (exported) {
        .nav => |nav| log.debug("updateExports({f})", .{ip.getNav(nav).fqn.fmt(ip)}),
        .uav => |uav| log.debug("updateExports(@as({f}, {f}))", .{
            Type.fromInterned(ip.typeOf(uav)).fmt(pt),
            Value.fromInterned(uav).fmtValue(pt),
        }),
    }
    try coff.symbol_table.ensureUnusedCapacity(gpa, export_indices.len);
    const exported_si: Symbol.Index = switch (exported) {
        .nav => |nav| try coff.navSymbol(zcu, nav),
        .uav => |uav| @enumFromInt(@intFromEnum(try coff.lowerUav(
            pt,
            uav,
            Type.fromInterned(ip.typeOf(uav)).abiAlignment(zcu),
        ))),
    };
    while (try coff.idle(pt.tid)) {}

    const exported_ni = exported_si.node(coff);
    const exported_sym = exported_si.get(coff);
    for (export_indices) |export_index| {
        const @"export" = export_index.ptr(zcu);
        const name = @"export".opts.name.toSlice(ip);
        const symbol_gop = try coff.getOrPutGlobalSymbol(name, null);
        const export_si = symbol_gop.value_ptr.*;
        const export_sym = export_si.get(coff);
        export_sym.ni = exported_ni;
        export_sym.rva = exported_sym.rva;
        export_sym.size = exported_sym.size;
        export_sym.section_number = exported_sym.section_number;
        export_si.applyTargetRelocs(coff);
        if (@"export".opts.name.eqlSlice("wWinMainCRTStartup", ip)) {
            coff.optionalHeaderStandardPtr().address_of_entry_point = exported_sym.rva;
        } else if (@"export".opts.name.eqlSlice("_tls_used", ip)) {
            const tls_directory = coff.dataDirectoryPtr(.TLS);
            tls_directory.* = .{ .virtual_address = exported_sym.rva, .size = exported_sym.size };
            if (coff.targetEndian() != native_endian)
                std.mem.byteSwapAllFields(std.coff.ImageDataDirectory, tls_directory);
        }

        if (coff.isArchive())
            try coff.addMemberSymbol(
                symbol_gop.key_ptr.*.name,
                coff.getNode(Node.known.zcu_member).archive_member,
                export_si,
            );

        if (coff.export_table.ni == .none) continue;

        const entries_ctx = ExportTable.Adapter{ .coff = coff };
        const gop = try coff.export_table.entries.getOrPutAdapted(
            gpa,
            name,
            entries_ctx,
        );

        if (!gop.found_existing) {
            errdefer _ = coff.export_table.entries.pop();

            const export_count = coff.export_table.entries.count();
            if (export_count > std.math.maxInt(@FieldType(std.coff.ExportDirectoryTable, "number_of_entries")))
                return coff.base.comp.link_diags.fail("exceeded maximum number of exports", .{});

            const name_index: u64 = coff.export_table.name_table_ni.location(&coff.mf).resolve(&coff.mf)[1];
            const new_name_table_size = name_index + name.len + 1;
            if (new_name_table_size > std.math.maxInt(@FieldType(ExportTable.Entry, "name_index")))
                return coff.base.comp.link_diags.fail("exports name table limit reached", .{});

            try coff.export_table.name_table_ni.resize(&coff.mf, gpa, new_name_table_size);

            const name_table_slice = coff.export_table.name_table_ni.slice(&coff.mf);
            @memcpy(name_table_slice[name_index..][0 .. name.len + 1], name[0 .. name.len + 1]);

            // If the new name sorts after the current tail of the sorted list, we don't need to re-sort
            {
                const ordinal_table_slice = coff.exportOrdinalTableSlice();
                if (ordinal_table_slice.len > 0 and !coff.export_table.pending_sort) {
                    const tail_index: ExportTable.Ordinal =
                        @enumFromInt(ordinal_table_slice[ordinal_table_slice.len - 1].unbiased_ordinal);
                    const tail_entry = tail_index.get(coff);
                    const tail_name = name_table_slice[tail_entry.name_index..][0..tail_entry.name_len];
                    coff.export_table.pending_sort = std.mem.lessThan(u8, name, tail_name);
                }
            }

            const edt = coff.exportDirectoryTable();
            coff.targetStore(&edt.number_of_names, @intCast(export_count));
            edt.number_of_entries = edt.number_of_names;

            // TODO: If we had an estimate of the total number of exports this could be a lot more efficient

            try coff.export_table.export_address_table_si.node(coff).resize(
                &coff.mf,
                gpa,
                export_count * @sizeOf(std.coff.ExportAddressTableEntry),
            );

            try coff.export_table.name_pointer_table_ni.resize(
                &coff.mf,
                gpa,
                export_count * @sizeOf(std.coff.ExportNamePointerTableEntry),
            );

            try coff.export_table.ordinal_table_ni.resize(
                &coff.mf,
                gpa,
                export_count * @sizeOf(std.coff.ExportOrdinalTableEntry),
            );

            coff.targetStore(
                &coff.exportNamePointerTableSlice()[gop.index].name_rva,
                @intCast(coff.computeNodeRva(coff.export_table.name_table_ni) + name_index),
            );
            coff.targetStore(
                &coff.exportOrdinalTableSlice()[gop.index].unbiased_ordinal,
                @intCast(gop.index),
            );

            gop.value_ptr.* = .{
                .si = export_si,
                .name_index = @intCast(name_index),
                .name_len = @intCast(name.len),
                .export_address_table_ri = @enumFromInt(coff.relocs.items.len),
            };

            try coff.addReloc(
                coff.export_table.export_address_table_si,
                @intCast(@sizeOf(std.coff.ExportAddressTableEntry) * gop.index),
                export_si,
                0,
                .{ .AMD64 = .ADDR32NB },
            );
        } else {
            gop.value_ptr.si = export_si;
            const reloc = gop.value_ptr.*.export_address_table_ri.get(coff);
            reloc.target = export_si;
            export_si.applyTargetRelocs(coff);
        }
    }
}

pub fn deleteExport(coff: *Coff, exported: Zcu.Exported, name: InternPool.NullTerminatedString) void {
    _ = coff;
    _ = exported;
    _ = name;
}

fn dumpStderr(coff: *Coff, tid: Zcu.PerThread.Id) !void {
    const comp = coff.base.comp;
    const io = comp.io;
    var buffer: [512]u8 = undefined;
    const stderr = try io.lockStderr(&buffer, null);
    defer io.unlockStderr();
    const w = &stderr.file_writer.interface;
    try coff.dump(w, tid);
}

pub fn dump(coff: *Coff, w: *Io.Writer, tid: Zcu.PerThread.Id) !void {
    try coff.printNode(tid, w, .root, 0);
}

pub fn printNode(
    coff: *Coff,
    tid: Zcu.PerThread.Id,
    w: *Io.Writer,
    ni: MappedFile.Node.Index,
    indent: usize,
) !void {
    const node = coff.getNode(ni);
    try w.splatByteAll(' ', indent);
    try w.writeAll(@tagName(node));
    switch (node) {
        else => {},
        .image_section => |si| try w.print("({s})", .{
            std.mem.sliceTo(&si.get(coff).section_number.header(coff).name, 0),
        }),
        .import_lookup_table,
        .import_address_table,
        .import_hint_name_table,
        => |import_index| try w.print("({s})", .{
            std.mem.sliceTo(import_index.get(coff).import_hint_name_table_ni.sliceConst(&coff.mf), 0),
        }),
        inline .pseudo_section, .object_section => |smi| try w.print("({s})", .{
            smi.name(coff).toSlice(coff),
        }),
        .global => |gmi| {
            const gn = gmi.globalName(coff);
            try w.writeByte('(');
            if (gn.lib_name.toSlice(coff)) |lib_name| try w.print("{s}.dll, ", .{lib_name});
            try w.print("{s})", .{gn.name.toSlice(coff)});
        },
        .nav => |nmi| {
            const zcu = coff.base.comp.zcu.?;
            const ip = &zcu.intern_pool;
            const nav = ip.getNav(nmi.navIndex(coff));
            try w.print("({f}, {f})", .{
                Type.fromInterned(ip.typeOf(nav.resolved.?.value)).fmt(.{ .zcu = zcu, .tid = tid }),
                nav.fqn.fmt(ip),
            });
        },
        .uav => |umi| {
            const zcu = coff.base.comp.zcu.?;
            const val: Value = .fromInterned(umi.uavValue(coff));
            try w.print("({f}, {f})", .{
                val.typeOf(zcu).fmt(.{ .zcu = zcu, .tid = tid }),
                val.fmtValue(.{ .zcu = zcu, .tid = tid }),
            });
        },
        inline .lazy_code, .lazy_const_data => |lmi| try w.print("({f})", .{
            Type.fromInterned(lmi.lazySymbol(coff).ty).fmt(.{
                .zcu = coff.base.comp.zcu.?,
                .tid = tid,
            }),
        }),
    }
    {
        const mf_node = &coff.mf.nodes.items[@intFromEnum(ni)];
        const off, const size = mf_node.location().resolve(&coff.mf);
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
    var child_it = ni.children(&coff.mf);
    while (child_it.next()) |child_ni| {
        leaf = false;
        try coff.printNode(tid, w, child_ni, indent + 1);
    }
    if (leaf) {
        const file_loc = ni.fileLocation(&coff.mf, false);
        if (file_loc.size == 0) return;
        var address = file_loc.offset;
        const line_len = 0x10;
        var line_it = std.mem.window(
            u8,
            coff.mf.memory_map.memory[@intCast(file_loc.offset)..][0..@intCast(file_loc.size)],
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
}
