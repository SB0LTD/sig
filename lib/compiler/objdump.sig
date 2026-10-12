const std = @import("std");
const Io = std.Io;
const fatal = std.process.fatal;
const mem = std.mem;
const assert = std.debug.assert;

const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

var stdout_buffer: [4000]u8 = undefined;

const Options = struct {
    exports: bool,
    exports_sort: bool,
    file_headers: bool,
    imports: bool,
    input_path: []const u8,
    member_filters: []const []const u8 = &.{},
    member_headers: bool,
    elements: std.enums.EnumArray(Element, bool),
    redact: std.enums.EnumArray(FieldKind, bool),
    relocs: bool,
    section_filters: []const []const u8 = &.{},
    section_headers: bool,
    symbol_filters: []const []const u8 = &.{},
    strings: bool,
    symbols: bool,
    tls: bool,

    // Elf-specific
    program_headers: bool,
    dynamic: bool,
    dynamic_relocs: bool,
    dynamic_symbols: bool,
    summary: bool,

    // Disassembly
    disassemble: bool,
    disassemble_all: bool,
    disassemble_symbol: ?[]const u8,

    // Coff-specific
    linker_member: ?std.coff.ArchiveMemberHeader.Kind,
};

const FieldKind = enum {
    va,
    rva,
    ord,
    size,
};

const Element = enum {
    @"file-type",
    @"header-name",
    @"member-path",
    newlines,
    @"table-header",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const arena = init.arena.allocator();

    var i: usize = 1;

    var opt_exports: ?bool = null;
    var opt_exports_sort: ?bool = null;
    var opt_file_headers: ?bool = null;
    var opt_imports: ?bool = null;
    var opt_input_path: ?[]const u8 = null;
    var opt_linker_member: ?std.coff.ArchiveMemberHeader.Kind = null;
    var opt_member_headers: ?bool = null;
    var any_elements = false;
    var elements: ?@FieldType(Options, "elements") = null;
    var redact: @FieldType(Options, "redact") = .initFill(false);
    var opt_relocs: ?bool = null;
    var opt_section_headers: ?bool = null;
    var opt_strings: ?bool = null;
    var opt_symbols: ?bool = null;
    var opt_tls: ?bool = null;
    var opt_program_headers: ?bool = null;
    var opt_dynamic: ?bool = null;
    var opt_dynamic_relocs: ?bool = null;
    var opt_dynamic_symbols: ?bool = null;
    var opt_summary: ?bool = null;
    var opt_disassemble: ?bool = null;
    var opt_disassemble_all: ?bool = null;
    var opt_disassemble_symbol: ?[]const u8 = null;
    var section_filters: std.ArrayList([]const u8) = .empty;
    var symbol_filters: std.ArrayList([]const u8) = .empty;
    var member_filters: std.ArrayList([]const u8) = .empty;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (mem.startsWith(u8, arg, "-")) {
            if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
                return Io.File.stdout().writeStreamingAll(io, usage);
            } else if (mem.eql(u8, arg, "--all-headers")) {
                opt_file_headers = true;
                opt_linker_member = .second_linker;
                opt_member_headers = true;
                opt_section_headers = true;
                opt_symbols = true;
                opt_relocs = true;
                opt_program_headers = true;
                opt_dynamic = true;
            } else if (mem.startsWith(u8, arg, "--exports")) {
                opt_exports = true;
                opt_linker_member = .second_linker;
                if (mem.eql(u8, arg["--exports".len..], "=sort"))
                    opt_exports_sort = true;
            } else if (mem.eql(u8, arg, "--file-headers")) {
                opt_file_headers = true;
            } else if (mem.eql(u8, arg, "--imports")) {
                opt_imports = true;
            } else if (mem.startsWith(u8, arg, "--linker-member")) {
                if (mem.eql(u8, arg["--linker-member".len..], "=1"))
                    opt_linker_member = .first_linker
                else if (mem.eql(u8, arg["--linker-member".len..], "=longnames"))
                    opt_linker_member = .longnames
                else
                    opt_linker_member = .second_linker;
            } else if (mem.eql(u8, arg, "--member-headers")) {
                opt_member_headers = true;
            } else if (mem.startsWith(u8, arg, "--elements=")) {
                any_elements = true;
                var split = std.mem.splitScalar(u8, arg["--elements=".len..], ',');
                while (split.next()) |element| {
                    const kind, const add = if (element.len > 0 and element[0] == '-')
                        .{ element[1..], false }
                    else
                        .{ element, true };

                    if (elements == null) elements = .initFill(false);
                    if (std.meta.stringToEnum(Element, kind)) |format_kind| {
                        elements.?.set(format_kind, add);
                    } else if (std.mem.eql(u8, kind, "all")) {
                        elements.? = .initFill(add);
                    } else {
                        fatal("unrecognized element: '{s}'", .{kind});
                    }
                }
            } else if (mem.startsWith(u8, arg, "--only-member=")) {
                (try member_filters.addOne(arena)).* = try arena.dupe(u8, arg["--only-member=".len..]);
            } else if (mem.startsWith(u8, arg, "--only-section=")) {
                (try section_filters.addOne(arena)).* = try arena.dupe(u8, arg["--only-section=".len..]);
            } else if (mem.startsWith(u8, arg, "--only-symbol=")) {
                (try symbol_filters.addOne(arena)).* = try arena.dupe(u8, arg["--only-symbol=".len..]);
            } else if (mem.startsWith(u8, arg, "--redact=")) {
                const kind = arg["--redact=".len..];
                if (std.meta.stringToEnum(FieldKind, kind)) |field_kind| {
                    redact.set(field_kind, true);
                } else if (std.mem.eql(u8, kind, "all")) {
                    redact = .initFill(true);
                } else {
                    fatal("unrecognized redaction kind: {s}", .{kind});
                }
            } else if (mem.eql(u8, arg, "--relocs")) {
                opt_relocs = true;
            } else if (mem.eql(u8, arg, "--section-headers")) {
                opt_section_headers = true;
            } else if (mem.eql(u8, arg, "-s") or mem.eql(u8, arg, "--snapshot")) {
                elements = .initFill(false);
                redact = .initFill(true);
            } else if (mem.eql(u8, arg, "--strings")) {
                opt_strings = true;
            } else if (mem.eql(u8, arg, "--symbols")) {
                opt_symbols = true;
            } else if (mem.eql(u8, arg, "--tls")) {
                opt_tls = true;
            } else if (mem.eql(u8, arg, "--program-headers") or mem.eql(u8, arg, "--segments")) {
                opt_program_headers = true;
            } else if (mem.eql(u8, arg, "--dynamic")) {
                opt_dynamic = true;
            } else if (mem.eql(u8, arg, "--dynamic-symbols")) {
                opt_dynamic_symbols = true;
            } else if (mem.eql(u8, arg, "--dynamic-relocs")) {
                opt_dynamic_relocs = true;
            } else if (mem.eql(u8, arg, "--summary")) {
                opt_summary = true;
            } else if (mem.eql(u8, arg, "--disassemble-all")) {
                opt_disassemble = true;
                opt_disassemble_all = true;
            } else if (mem.startsWith(u8, arg, "--disassemble=")) {
                opt_disassemble = true;
                opt_disassemble_symbol = try arena.dupe(u8, arg["--disassemble=".len..]);
            } else if (mem.eql(u8, arg, "-d") or mem.eql(u8, arg, "--disassemble")) {
                opt_disassemble = true;
            } else {
                fatal("unrecognized argument: {s}", .{arg});
            }
        } else if (opt_input_path == null) {
            opt_input_path = arg;
        } else {
            fatal("unexpected positional: {s}", .{arg});
        }
    }

    const opts: Options = .{
        .input_path = opt_input_path orelse fatal("missing input file path positional argument", .{}),
        .exports = opt_exports orelse false,
        .exports_sort = opt_exports_sort orelse false,
        .file_headers = opt_file_headers orelse false,
        .imports = opt_imports orelse false,
        .linker_member = opt_linker_member,
        .member_filters = member_filters.items,
        .member_headers = opt_member_headers orelse false,
        .elements = elements orelse .initFill(true),
        .redact = redact,
        .relocs = opt_relocs orelse false,
        .section_filters = section_filters.items,
        .section_headers = opt_section_headers orelse false,
        .strings = opt_strings orelse false,
        .symbol_filters = symbol_filters.items,
        .symbols = opt_symbols orelse false,
        .tls = opt_tls orelse false,
        .program_headers = opt_program_headers orelse false,
        .dynamic = opt_dynamic orelse false,
        .dynamic_relocs = opt_dynamic_relocs orelse false,
        .dynamic_symbols = opt_dynamic_symbols orelse false,
        .summary = opt_summary orelse false,
        .disassemble = opt_disassemble orelse false,
        .disassemble_all = opt_disassemble_all orelse false,
        .disassemble_symbol = opt_disassemble_symbol,
    };

    var file = std.Io.Dir.cwd().openFile(io, opts.input_path, .{}) catch |err|
        fatal("failed to open {s}: {t}", .{ opts.input_path, err });
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);

    const ctx: DumpContext = .{
        .gpa = init.gpa,
        .opts = &opts,
        .fr = &file_reader,
        .w = &stdout_writer.interface,
    };

    dump(&ctx) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
        error.WriteFailed => return stdout_writer.err.?,
        error.UnknownFile => fatal("unrecognized file: {s}", .{opts.input_path}),
        error.ParseFailure => {},
        else => |e| return e,
    };
    try stdout_writer.flush();
}

fn dump(d: *const DumpContext) !void {
    const r = &d.fr.interface;
    try r.fill(4);
    elf: {
        if (!mem.eql(u8, r.buffered()[0..4], std.elf.MAGIC)) break :elf;
        return elf.dump(d);
    }
    macho: {
        if (mem.readInt(u32, r.buffered()[0..4], .little) != std.macho.MH_MAGIC_64) break :macho;
        return macho.dump(d);
    }
    wasm: {
        comptime assert(std.wasm.magic.len == 4);
        if (!mem.eql(u8, r.buffered()[0..4], &std.wasm.magic)) break :wasm;
        return wasm.dump(d);
    }
    coff: {
        const ext = std.fs.path.extension(d.opts.input_path);
        const basename = std.fs.path.basename(d.opts.input_path);
        if (std.mem.eql(u8, ext, ".exe") or std.mem.eql(u8, ext, ".dll")) {
            if (!mem.eql(u8, r.buffered()[0..2], "MZ")) break :coff;
            try r.discardAll(std.coff.pe_pointer_offset);
            const sig_offset = try r.takeInt(u32, .little);
            try d.fr.seekTo(sig_offset);
            const sig = try r.take(4);

            if (!std.mem.eql(u8, sig, std.coff.pe_signature)) {
                try d.w.print("invalid PE signature: {x}", .{sig});
                return error.ParseFailure;
            }

            if (d.element(.@"file-type")) {
                try d.w.print("{s}: PE/COFF image\n\n", .{basename});
                if (d.element(.newlines)) try d.w.writeByte('\n');
            }

            return coff.dumpObject(d, true, basename);
        } else if (std.mem.eql(u8, ext, ".lib")) {
            r.fill(std.coff.archive_signature.len) catch break :coff;
            if (!mem.eql(u8, r.buffered()[0..std.coff.archive_signature.len], std.coff.archive_signature)) break :coff;
            if (d.element(.@"file-type")) {
                try d.w.print("{s}: COFF archive\n", .{basename});
                if (d.element(.newlines)) try d.w.writeByte('\n');
            }

            return coff.dumpArchive(d);
        } else if (std.mem.eql(u8, ext, ".obj")) {
            if (d.element(.@"file-type")) {
                try d.w.print("{s}: COFF object\n", .{basename});
                if (d.element(.newlines)) try d.w.writeByte('\n');
            }

            return coff.dumpObject(d, false, basename);
        }
    }
    return error.UnknownFile;
}

const DumpContext = struct {
    gpa: std.mem.Allocator,
    opts: *const Options,
    fr: *Io.File.Reader,
    w: *Io.Writer,

    fn element(self: *const DumpContext, e: Element) bool {
        return self.opts.elements.get(e);
    }

    fn redacted(self: *const DumpContext, opt_kind: ?FieldKind) bool {
        const kind = opt_kind orelse return false;
        return self.opts.redact.get(kind);
    }

    fn failParse(
        ctx: *const DumpContext,
        comptime fmt: []const u8,
        args: anytype,
    ) noreturn {
        std.log.err("error parsing '{s}'", .{std.fs.path.basename(ctx.opts.input_path)});
        fatal(fmt, args);
    }
};

const elf = struct {
    /// A symbol's value paired with its resolved name. Retained (built in a
    /// gpa-tied arena) for FEAT-003 reloc annotation and disassembly call-target
    /// resolution. Consumed by `disasm`/`Annotator` in later features.
    const SymName = struct {
        value: u64,
        name: []const u8,
    };

    /// Decode the sBPF version carried in an ELF `e_flags` word. sig's own linker
    /// only ever emits `0x3` (sBPFv3); for any other low byte we format
    /// `sbpfv<low-byte>` purely from the numeric value. The v0/v1 boundary is
    /// intentionally NOT asserted — no in-tree source defines one, so inventing it
    /// risks mislabeling third-party objects. Also consumed by FEAT-003.
    fn sbpfVersionName(flags: u32, buf: *[16]u8) []const u8 {
        if (flags == 0x3) return "sbpfv3";
        return std.fmt.bufPrint(buf, "sbpfv{d}", .{flags & 0xff}) catch "sbpfv?";
    }

    /// Write an enum value's tag name, or its numeric value when the (possibly
    /// non-exhaustive) enum carries no name for it. The toolchain's `{t}`
    /// formatter panics ("invalid enum value") on an unnamed non-exhaustive
    /// value, so NEVER print a format-time `{t}` on an enum read from a file;
    /// route it through here instead.
    fn writeEnum(w: *Io.Writer, comptime E: type, value: E, width: usize) !void {
        if (std.enums.tagName(E, value)) |nm| {
            try w.print("{s}", .{nm});
            if (nm.len < width) try w.splatByteAll(' ', width - nm.len);
        } else {
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "0x{x}", .{@intFromEnum(value)}) catch "0x?";
            try w.print("{s}", .{s});
            if (s.len < width) try w.splatByteAll(' ', width - s.len);
        }
    }

    fn shndxName(ix: u16) ?[]const u8 {
        return switch (ix) {
            std.elf.SHN_UNDEF => "UNDEF",
            std.elf.SHN_ABS => "ABS",
            std.elf.SHN_COMMON => "COMMON",
            else => null,
        };
    }

    fn dtName(tag: i64) ?[]const u8 {
        return switch (tag) {
            std.elf.DT_NULL => "NULL",
            std.elf.DT_NEEDED => "NEEDED",
            std.elf.DT_PLTRELSZ => "PLTRELSZ",
            std.elf.DT_PLTGOT => "PLTGOT",
            std.elf.DT_HASH => "HASH",
            std.elf.DT_GNU_HASH => "GNU_HASH",
            std.elf.DT_STRTAB => "STRTAB",
            std.elf.DT_SYMTAB => "SYMTAB",
            std.elf.DT_RELA => "RELA",
            std.elf.DT_RELASZ => "RELASZ",
            std.elf.DT_RELAENT => "RELAENT",
            std.elf.DT_STRSZ => "STRSZ",
            std.elf.DT_SYMENT => "SYMENT",
            std.elf.DT_INIT => "INIT",
            std.elf.DT_FINI => "FINI",
            std.elf.DT_SONAME => "SONAME",
            std.elf.DT_RPATH => "RPATH",
            std.elf.DT_SYMBOLIC => "SYMBOLIC",
            std.elf.DT_REL => "REL",
            std.elf.DT_RELSZ => "RELSZ",
            std.elf.DT_RELENT => "RELENT",
            std.elf.DT_PLTREL => "PLTREL",
            std.elf.DT_DEBUG => "DEBUG",
            std.elf.DT_TEXTREL => "TEXTREL",
            std.elf.DT_JMPREL => "JMPREL",
            std.elf.DT_BIND_NOW => "BIND_NOW",
            std.elf.DT_INIT_ARRAY => "INIT_ARRAY",
            std.elf.DT_FINI_ARRAY => "FINI_ARRAY",
            std.elf.DT_INIT_ARRAYSZ => "INIT_ARRAYSZ",
            std.elf.DT_FINI_ARRAYSZ => "FINI_ARRAYSZ",
            std.elf.DT_RUNPATH => "RUNPATH",
            std.elf.DT_FLAGS => "FLAGS",
            std.elf.DT_FLAGS_1 => "FLAGS_1",
            std.elf.DT_RELACOUNT => "RELACOUNT",
            std.elf.DT_RELCOUNT => "RELCOUNT",
            std.elf.DT_VERSYM => "VERSYM",
            std.elf.DT_VERDEF => "VERDEF",
            else => null,
        };
    }

    /// `.va` for pointer-like dynamic tags, `.size` for size/count tags, else plain.
    fn dtKind(tag: i64) ?FieldKind {
        return switch (tag) {
            std.elf.DT_PLTGOT,
            std.elf.DT_HASH,
            std.elf.DT_GNU_HASH,
            std.elf.DT_STRTAB,
            std.elf.DT_SYMTAB,
            std.elf.DT_RELA,
            std.elf.DT_INIT,
            std.elf.DT_FINI,
            std.elf.DT_REL,
            std.elf.DT_JMPREL,
            std.elf.DT_INIT_ARRAY,
            std.elf.DT_FINI_ARRAY,
            std.elf.DT_VERSYM,
            std.elf.DT_VERDEF,
            => .va,
            std.elf.DT_PLTRELSZ,
            std.elf.DT_RELASZ,
            std.elf.DT_RELAENT,
            std.elf.DT_STRSZ,
            std.elf.DT_SYMENT,
            std.elf.DT_RELSZ,
            std.elf.DT_RELENT,
            std.elf.DT_INIT_ARRAYSZ,
            std.elf.DT_FINI_ARRAYSZ,
            std.elf.DT_RELACOUNT,
            std.elf.DT_RELCOUNT,
            => .size,
            else => null,
        };
    }

    /// Render the symbolic relocation-type name for `machine`, prepending the
    /// `R_<fam>_` family prefix the artifacts actually carry (`{t}` supplies only
    /// the suffix). Unknown machine prints the raw numeric type with an
    /// `(unknown arch)` note — never fails.
    fn printRelocType(w: *Io.Writer, machine: std.elf.EM, raw: u32) !void {
        switch (machine) {
            // sig's own sBPF backend emits R_BPF_* (the R_SBF_* spelling is the
            // Solana-LLVM alias of the same numeric family; we render R_BPF_*).
            .BPF, .SBF => {
                try w.writeAll("R_BPF_");
                try writeEnum(w, std.elf.R_BPF, @enumFromInt(raw), 0);
            },
            .X86_64 => {
                try w.writeAll("R_X86_64_");
                try writeEnum(w, std.elf.R_X86_64, @enumFromInt(raw), 0);
            },
            .AARCH64 => {
                try w.writeAll("R_AARCH64_");
                try writeEnum(w, std.elf.R_AARCH64, @enumFromInt(raw), 0);
            },
            .RISCV => {
                try w.writeAll("R_RISCV_");
                try writeEnum(w, std.elf.R_RISCV, @enumFromInt(raw), 0);
            },
            else => try w.print("0x{x} (unknown arch)", .{raw}),
        }
    }

    fn dump(d: *const DumpContext) !void {
        const gpa = d.gpa;
        const fr = d.fr;
        const w = d.w;
        const r = &fr.interface;
        const basename = std.fs.path.basename(d.opts.input_path);

        // --- Header read (§4.1): peek class/endian WITHOUT consuming, then read
        // the matching namespaced Ehdr so we can capture the raw e_flags word
        // BEFORE Header.init drops it. ---
        const ident = r.peek(@sizeOf(std.elf.Elf64.Ehdr)) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            else => d.failParse("truncated ELF header: {t}", .{err}),
        };
        const endian: std.builtin.Endian = switch (ident[std.elf.EI.DATA]) {
            @backingInt(std.elf.DATA.@"2LSB") => .little,
            @backingInt(std.elf.DATA.@"2MSB") => .big,
            else => d.failParse("unsupported ELF data encoding 0x{x}", .{ident[std.elf.EI.DATA]}),
        };
        const is_64 = switch (ident[std.elf.EI.CLASS]) {
            @backingInt(std.elf.CLASS.@"64") => true,
            @backingInt(std.elf.CLASS.@"32") => false,
            else => d.failParse("unsupported ELF class 0x{x}", .{ident[std.elf.EI.CLASS]}),
        };
        const e_flags: u32 = if (is_64) blk: {
            const raw = r.takeStruct(std.elf.Elf64.Ehdr, endian) catch |err|
                return readOrFail(d, err);
            break :blk raw.flags.int;
        } else blk: {
            const raw = r.takeStruct(std.elf.Elf32.Ehdr, endian) catch |err|
                return readOrFail(d, err);
            break :blk raw.flags.int;
        };
        // Re-read via the convenience path to obtain an iterator-ready Header.
        // (The namespaced Ehdr was already consumed above to capture e_flags; a
        // seek back to 0 lets Header.read re-peek the ident + take the struct.)
        try fr.seekTo(0);
        const hdr = std.elf.Header.read(r) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            else => d.failParse("not a valid ELF header: {t}", .{err}),
        };

        // --- File-type banner (§3). ---
        const typeWord: []const u8 = switch (hdr.type) {
            .REL => "relocatable",
            .DYN => "shared object",
            .EXEC => "executable",
            .CORE => "core",
            else => "unknown",
        };
        if (d.element(.@"file-type")) {
            try w.print("{s}: ELF {s} {s}\n", .{ basename, if (hdr.is_64) "64" else "32", typeWord });
            if (d.element(.newlines)) try w.writeByte('\n');
        }

        // --- --summary (§4.7): one machine-parseable line. ---
        if (d.opts.summary) {
            var vbuf: [16]u8 = undefined;
            const m = hdr.machine;
            try w.writeAll("type=");
            try writeEnum(w, std.elf.ET, hdr.type, 0);
            try w.writeAll(" machine=");
            try writeEnum(w, std.elf.EM, m, 0);
            try w.print("({d})", .{@intFromEnum(m)});
            try w.print(" entry={f} class={s} data={s} flags=0x{x}", .{
                coff.fmtIntField(d, hdr.entry, .{ .kind = .va }),
                if (hdr.is_64) "ELF64" else "ELF32",
                if (endian == .little) "little" else "big",
                e_flags,
            });
            if (m == .BPF or m == .SBF)
                try w.print("({s})", .{sbpfVersionName(e_flags, &vbuf)});
            try w.print(" phnum={d} shnum={d}\n", .{ hdr.phnum, hdr.shnum });
            if (d.element(.newlines)) try w.writeByte('\n');
        }

        // --- --file-headers (§4.1). ---
        if (d.opts.file_headers) {
            if (d.element(.@"header-name")) try w.writeAll("ELF Header:\n");
            const m = hdr.machine;
            try w.print("  class                       {s}\n", .{if (hdr.is_64) "ELF64" else "ELF32"});
            try w.print("  data                        2's complement, {s} endian\n", .{
                if (endian == .little) "little" else "big",
            });
            try w.writeAll("  os/abi                      ");
            try writeEnum(w, std.elf.OSABI, hdr.os_abi, 0);
            try w.print(" ({d})\n", .{@intFromEnum(hdr.os_abi)});
            try w.print("  abi version                 {d}\n", .{hdr.abi_version});
            try w.writeAll("  type                        ");
            try writeEnum(w, std.elf.ET, hdr.type, 0);
            try w.print(" ({d})\n", .{@intFromEnum(hdr.type)});
            try w.writeAll("  machine                     ");
            try writeEnum(w, std.elf.EM, m, 0);
            try w.print(" ({d})\n", .{@intFromEnum(m)});
            try w.print("  entry                       {f}\n", .{coff.fmtIntField(d, hdr.entry, .{ .kind = .va })});
            try w.print("  phoff                       {f}\n", .{coff.fmtIntField(d, hdr.phoff, .{ .kind = .va })});
            try w.print("  shoff                       {f}\n", .{coff.fmtIntField(d, hdr.shoff, .{ .kind = .va })});
            try w.print("  phentsize                   {f}\n", .{coff.fmtIntField(d, hdr.phentsize, .{ .kind = .size })});
            try w.print("  phnum                       {f}\n", .{coff.fmtIntField(d, hdr.phnum, .{ .kind = .size })});
            try w.print("  shentsize                   {f}\n", .{coff.fmtIntField(d, hdr.shentsize, .{ .kind = .size })});
            try w.print("  shnum                       {f}\n", .{coff.fmtIntField(d, hdr.shnum, .{ .kind = .size })});
            try w.print("  shstrndx                    {f}\n", .{coff.fmtIntField(d, hdr.shstrndx, .{ .kind = .size })});
            try w.print("  flags                       0x{x}", .{e_flags});
            if (m == .BPF or m == .SBF) {
                var vbuf: [16]u8 = undefined;
                try w.print(" ({s})", .{sbpfVersionName(e_flags, &vbuf)});
            }
            try w.writeByte('\n');
            if (d.element(.newlines)) try w.writeByte('\n');
        }

        // --- Collect all section headers (retained for symbols/relocs/dynamic
        // and for FEAT-003 disassembly). §4.2 ---
        var sections: std.ArrayList(std.elf.Elf64.Shdr) = .empty;
        defer sections.deinit(gpa);
        {
            var it = hdr.iterateSectionHeaders(fr);
            while (try it.next()) |shdr| (try sections.addOne(gpa)).* = shdr;
        }

        // --- Load the section-name string table (shstrndx section bytes). §4.2 ---
        var shstrtab: []u8 = &.{};
        defer if (shstrtab.len != 0) gpa.free(shstrtab);
        if (hdr.shstrndx < sections.items.len) {
            const sh = sections.items[hdr.shstrndx];
            if (sh.size != 0) {
                try fr.seekTo(sh.offset);
                shstrtab = try r.readAlloc(gpa, sh.size);
            }
        }

        // --- --section-headers (§4.2). ---
        if (d.opts.section_headers) {
            if (d.element(.@"header-name")) try w.writeAll("Section Headers:\n");
            if (d.element(.@"table-header"))
                try w.writeAll("  [Nr] Name                 Type            Flg      Addr   Offset     Size Lk Inf Algn Entsz\n");
            for (sections.items, 0..) |sh, idx| {
                const name = sectionName(d, shstrtab, sh.name);
                if (!filterMatches(d.opts.section_filters, name)) continue;
                try w.print("  [{d: >2}] {s: <20} ", .{ idx, name });
                try writeEnum(w, std.elf.SHT, sh.type, 15);
                try w.print(" {s}{s}{s}  {f} {f} {f} {d: >2} {d: >3} {d: >4} {f}\n", .{
                    if (sh.flags.shf.ALLOC) "A" else "-",
                    if (sh.flags.shf.EXECINSTR) "X" else "-",
                    if (sh.flags.shf.WRITE) "W" else "-",
                    coff.fmtIntField(d, sh.addr, .{ .kind = .va }),
                    coff.fmtIntField(d, sh.offset, .{ .kind = .va }),
                    coff.fmtIntField(d, sh.size, .{ .kind = .size }),
                    sh.link,
                    sh.info,
                    sh.addralign,
                    coff.fmtIntField(d, sh.entsize, .{ .kind = .size }),
                });
            }
            if (d.element(.newlines)) try w.writeByte('\n');
        }

        // --- --program-headers / --segments (§4.3). ---
        if (d.opts.program_headers) {
            if (d.element(.@"header-name")) try w.writeAll("Program Headers:\n");
            if (d.element(.@"table-header"))
                try w.writeAll("  Type            Flg     Offset      VAddr      PAddr   FileSize    MemSize    Align\n");
            var it = hdr.iterateProgramHeaders(fr);
            while (try it.next()) |ph| {
                try w.writeAll("  ");
                try writeEnum(w, std.elf.PT, ph.type, 15);
                try w.print(" {s}{s}{s} {f} {f} {f} {f} {f} {f}\n", .{
                    if (ph.flags.R) "R" else "-",
                    if (ph.flags.W) "W" else "-",
                    if (ph.flags.X) "X" else "-",
                    coff.fmtIntField(d, ph.offset, .{ .kind = .va }),
                    coff.fmtIntField(d, ph.vaddr, .{ .kind = .va }),
                    coff.fmtIntField(d, ph.paddr, .{ .kind = .va }),
                    coff.fmtIntField(d, ph.filesz, .{ .kind = .size }),
                    coff.fmtIntField(d, ph.memsz, .{ .kind = .size }),
                    coff.fmtIntField(d, ph.@"align", .{ .kind = .size }),
                });
            }
            if (d.element(.newlines)) try w.writeByte('\n');
        }

        // --- Symbols (§4.4). Build + retain the value->name table for FEAT-003. ---
        var name_arena: std.heap.ArenaAllocator = .init(gpa);
        defer name_arena.deinit();
        var sym_names: std.ArrayList(SymName) = .empty;
        defer sym_names.deinit(gpa);

        if (d.opts.symbols or d.opts.dynamic_symbols or d.opts.disassemble) {
            // --symbols always populates the retained table (for FEAT-003) even if
            // only --dynamic-symbols printing was requested; printing is gated per
            // call below. Disassembly (-d) also needs the retained value->name
            // table to annotate call targets, so the SYMTAB pass runs (silently,
            // via the element-gated printers) whenever disassembly is requested.
            if (d.opts.symbols or d.opts.disassemble)
                try dumpSymbols(d, &sections, endian, is_64, .SYMTAB, "Symbol table", &name_arena, &sym_names, true, d.opts.symbols);
            if (d.opts.dynamic_symbols)
                try dumpSymbols(d, &sections, endian, is_64, .DYNSYM, "Dynamic symbol table", &name_arena, &sym_names, false, true);
        }

        // --- Relocations (§4.5). ---
        if (d.opts.relocs)
            try dumpRelocs(d, &sections, shstrtab, hdr.machine, endian, is_64, false);
        if (d.opts.dynamic_relocs)
            try dumpRelocs(d, &sections, shstrtab, hdr.machine, endian, is_64, true);

        // --- --dynamic (§4.6). ---
        if (d.opts.dynamic)
            try dumpDynamic(d, &hdr, &sections);

        // --- Disassembly (§6-§7): the inspection views run first, then the
        // decoder walks executable sections. disasm.run is the single Annotator
        // construction site; it consumes the retained value->name table. ---
        if (d.opts.disassemble)
            try disasm.run(d, &hdr, &sections, shstrtab, sym_names.items, e_flags);
    }

    fn readOrFail(d: *const DumpContext, err: anytype) error{ ReadFailed, ParseFailure } {
        return switch (err) {
            error.ReadFailed => error.ReadFailed,
            else => d.failParse("unable to read ELF header: {t}", .{err}),
        };
    }

    fn sectionName(d: *const DumpContext, strtab: []const u8, name: u32) []const u8 {
        if (name >= strtab.len) d.failParse("section name offset 0x{x} out of range", .{name});
        return std.mem.sliceTo(strtab[name..], 0);
    }

    fn dumpSymbols(
        d: *const DumpContext,
        sections: *const std.ArrayList(std.elf.Elf64.Shdr),
        endian: std.builtin.Endian,
        is_64: bool,
        kind: std.elf.SHT,
        header_name: []const u8,
        name_arena: *std.heap.ArenaAllocator,
        sym_names: *std.ArrayList(SymName),
        retain: bool,
        print_rows: bool,
    ) !void {
        const gpa = d.gpa;
        const fr = d.fr;
        const w = d.w;
        const r = &fr.interface;

        // Find the symbol section.
        var opt_shdr: ?std.elf.Elf64.Shdr = null;
        for (sections.items) |sh| {
            if (sh.type == kind) {
                opt_shdr = sh;
                break;
            }
        }
        const shdr = opt_shdr orelse return;

        // Entsize guard (§4.4): never divide by zero / read garbage.
        const esz: u64 = if (is_64) @sizeOf(std.elf.Elf64.Sym) else @sizeOf(std.elf.Elf32.Sym);
        if (shdr.entsize == 0 or shdr.entsize < esz)
            d.failParse("symbol section has invalid entsize 0x{x}", .{shdr.entsize});
        const count = shdr.size / shdr.entsize;

        // Linked string table bytes.
        var strtab: []u8 = &.{};
        defer if (strtab.len != 0) gpa.free(strtab);
        if (shdr.link < sections.items.len) {
            const sstr = sections.items[shdr.link];
            if (sstr.size != 0) {
                try fr.seekTo(sstr.offset);
                strtab = try r.readAlloc(gpa, sstr.size);
            }
        }

        if (print_rows and d.element(.@"header-name")) try w.print("{s}:\n", .{header_name});
        if (print_rows and d.element(.@"table-header"))
            try w.writeAll("   Num:    Value     Size Type    Bind    Vis       Ndx Name\n");

        var idx: u64 = 0;
        while (idx < count) : (idx += 1) {
            try fr.seekTo(shdr.offset + idx * shdr.entsize);
            const sym: std.elf.Elf64.Sym = if (is_64)
                try r.takeStruct(std.elf.Elf64.Sym, endian)
            else blk: {
                const s32 = try r.takeStruct(std.elf.Elf32.Sym, endian);
                break :blk .{
                    .name = s32.name,
                    .info = s32.info,
                    .other = s32.other,
                    .shndx = s32.shndx,
                    .value = s32.value,
                    .size = s32.size,
                };
            };
            const name = resolveSymName(d, strtab, sym.name);

            if (retain and name.len != 0) {
                const dup = try name_arena.allocator().dupe(u8, name);
                (try sym_names.addOne(gpa)).* = .{ .value = sym.value, .name = dup };
            }

            if (!print_rows) continue;
            if (!filterMatches(d.opts.symbol_filters, name)) continue;

            try w.print("  {d: >4}: {f} {f} ", .{
                idx,
                coff.fmtIntField(d, sym.value, .{ .kind = .va }),
                coff.fmtIntField(d, sym.size, .{ .kind = .size }),
            });
            try writeEnum(w, std.elf.STT, sym.info.type, 7);
            try w.writeByte(' ');
            try writeEnum(w, std.elf.STB, sym.info.bind, 7);
            try w.writeByte(' ');
            try writeEnum(w, std.elf.STV, sym.other.visibility, 9);
            try w.writeByte(' ');
            if (shndxName(sym.shndx)) |nm|
                try w.print("{s: >5}", .{nm})
            else
                try w.print("{f}", .{coff.fmtIntField(d, sym.shndx, .{ .kind = .ord })});
            try w.print(" {s}\n", .{name});
        }

        // Keep the retained table sorted by value for FEAT-003 lookups.
        if (retain)
            std.mem.sort(SymName, sym_names.items, {}, struct {
                fn lt(_: void, a: SymName, b: SymName) bool {
                    return a.value < b.value;
                }
            }.lt);

        if (print_rows and d.element(.newlines)) try w.writeByte('\n');
    }

    fn resolveSymName(d: *const DumpContext, strtab: []const u8, name: u32) []const u8 {
        if (name == 0) return "";
        if (name >= strtab.len) d.failParse("symbol name offset 0x{x} out of range", .{name});
        return std.mem.sliceTo(strtab[name..], 0);
    }

    fn dumpRelocs(
        d: *const DumpContext,
        sections: *const std.ArrayList(std.elf.Elf64.Shdr),
        shstrtab: []const u8,
        machine: std.elf.EM,
        endian: std.builtin.Endian,
        is_64: bool,
        dynamic_only: bool,
    ) !void {
        const gpa = d.gpa;
        const fr = d.fr;
        const w = d.w;
        const r = &fr.interface;
        _ = dynamic_only;

        for (sections.items) |shdr| {
            const is_rela = shdr.type == .RELA;
            const is_rel = shdr.type == .REL;
            if (!is_rela and !is_rel) continue;

            const applied = if (shdr.info < sections.items.len)
                sectionName(d, shstrtab, sections.items[shdr.info].name)
            else
                "?";

            // Entsize guard (§4.5).
            const esz: u64 = if (is_rela)
                (if (is_64) @sizeOf(std.elf.Elf64.Rela) else @sizeOf(std.elf.Elf32.Rela))
            else
                (if (is_64) @sizeOf(std.elf.Elf64.Rel) else @sizeOf(std.elf.Elf32.Rel));
            if (shdr.entsize == 0 or shdr.entsize < esz)
                d.failParse("reloc section has invalid entsize 0x{x}", .{shdr.entsize});
            const count = shdr.size / shdr.entsize;

            // Linked symbol table + its string table (for name resolution).
            var symtab_shdr: ?std.elf.Elf64.Shdr = null;
            if (shdr.link < sections.items.len) symtab_shdr = sections.items[shdr.link];
            var strtab: []u8 = &.{};
            defer if (strtab.len != 0) gpa.free(strtab);
            var sym_count: u64 = 0;
            if (symtab_shdr) |st| {
                if (st.entsize != 0) sym_count = st.size / st.entsize;
                if (st.link < sections.items.len) {
                    const sstr = sections.items[st.link];
                    if (sstr.size != 0) {
                        try fr.seekTo(sstr.offset);
                        strtab = try r.readAlloc(gpa, sstr.size);
                    }
                }
            }

            if (d.element(.@"header-name"))
                try w.print("Relocation section '{s}' (for {s}):\n", .{
                    sectionName(d, shstrtab, shdr.name),
                    applied,
                });
            if (d.element(.@"table-header"))
                try w.writeAll("    Offset Type                   Addend Symbol\n");

            var idx: u64 = 0;
            while (idx < count) : (idx += 1) {
                try fr.seekTo(shdr.offset + idx * shdr.entsize);
                const offset: u64, const rtype: u32, const sym: u32, const addend: i64 = if (is_rela) blk: {
                    if (is_64) {
                        const e = try r.takeStruct(std.elf.Elf64.Rela, endian);
                        break :blk .{ e.offset, e.info.type, e.info.sym, e.addend };
                    } else {
                        const e = try r.takeStruct(std.elf.Elf32.Rela, endian);
                        break :blk .{ e.offset, @as(u32, e.info.type), @as(u32, e.info.sym), @as(i64, e.addend) };
                    }
                } else blk: {
                    if (is_64) {
                        const e = try r.takeStruct(std.elf.Elf64.Rel, endian);
                        break :blk .{ e.offset, e.info.type, e.info.sym, @as(i64, 0) };
                    } else {
                        const e = try r.takeStruct(std.elf.Elf32.Rel, endian);
                        break :blk .{ e.offset, @as(u32, e.info.type), @as(u32, e.info.sym), @as(i64, 0) };
                    }
                };

                // Resolve the referenced symbol name.
                var sym_name: []const u8 = "";
                if (symtab_shdr) |st| {
                    if (sym >= sym_count)
                        d.failParse("reloc symbol index {d} out of range", .{sym});
                    const sym_esz: u64 = if (is_64) @sizeOf(std.elf.Elf64.Sym) else @sizeOf(std.elf.Elf32.Sym);
                    try fr.seekTo(st.offset + sym * sym_esz);
                    const name_off: u32 = if (is_64)
                        (try r.takeStruct(std.elf.Elf64.Sym, endian)).name
                    else
                        (try r.takeStruct(std.elf.Elf32.Sym, endian)).name;
                    sym_name = resolveSymName(d, strtab, name_off);
                }

                try w.print("  {f} ", .{coff.fmtIntField(d, offset, .{ .kind = .va })});
                try printRelocType(w, machine, rtype);
                if (is_rela)
                    try w.print(" {d: >10} {s}\n", .{ addend, sym_name })
                else
                    try w.print(" {s: >10} {s}\n", .{ "", sym_name });
            }
            if (d.element(.newlines)) try w.writeByte('\n');
        }
    }

    fn dumpDynamic(
        d: *const DumpContext,
        hdr: *const std.elf.Header,
        sections: *const std.ArrayList(std.elf.Elf64.Shdr),
    ) !void {
        const fr = d.fr;
        const w = d.w;

        var dyn_shdr: ?std.elf.Elf64.Shdr = null;
        for (sections.items) |sh| {
            if (sh.type == .DYNAMIC) {
                dyn_shdr = sh;
                break;
            }
        }
        const shdr = dyn_shdr orelse {
            if (d.element(.@"header-name")) try w.writeAll("no dynamic section\n");
            if (d.element(.newlines)) try w.writeByte('\n');
            return;
        };

        if (d.element(.@"header-name")) try w.writeAll("Dynamic section:\n");
        if (d.element(.@"table-header"))
            try w.writeAll("  Tag                Value\n");

        var it = hdr.iterateDynamicSection(fr, shdr.offset, shdr.size);
        while (try it.next()) |dyn| {
            if (dtName(dyn.tag)) |nm|
                try w.print("  {s: <16} ", .{nm})
            else
                try w.print("  0x{x: <14} ", .{@as(u64, @bitCast(dyn.tag))});
            try w.print("{f}\n", .{coff.fmtIntField(d, dyn.val, .{ .kind = dtKind(dyn.tag) })});
            if (dyn.tag == std.elf.DT_NULL) break;
        }
        if (d.element(.newlines)) try w.writeByte('\n');
    }
};

/// From-scratch sBPF (eBPF 64-bit little-endian) disassembler (design §6-§7).
/// Written in-file because `sig objdump` is a std-only JIT tool and the compiler
/// codegen (src/codegen/aarch64) is NOT reachable from here. sBPF is the only
/// supported machine for 0.6.2; every other machine emits a clear
/// "not implemented" error rather than a stub. The decoder owns no allocation of
/// its own: `run` is the single site that reads section bytes (via gpa with a
/// matching defer free) and constructs the one `Annotator`.
const disasm = struct {
    const Error = Io.Writer.Error || error{ParseFailure};

    /// A symbol's value paired with its resolved name. Shared with the `elf`
    /// namespace that builds the table (FEAT-002); the Annotator binary-searches
    /// it by value to label call targets.
    const SymName = elf.SymName;

    /// A static Solana syscall identified by the murmur3_32 hash of its ASCII
    /// name (SIMD-0178 static-syscall registry). Built once at comptime.
    const SyscallHash = struct {
        hash: u32,
        name: []const u8,
    };

    /// sBPF virtual-memory region bases: the high 32 bits of an address select
    /// the region. Program bytes live at 0x1_0000_0000 (MM_PROGRAM_START).
    const MM_PROGRAM_START: u64 = 0x1_0000_0000;

    /// Resolves symbolic context for an instruction: call targets (syscall hash
    /// first, then a symbol whose value equals the immediate) and memory-region
    /// notes for load/store/lddw addresses.
    const Annotator = struct {
        syms: []const SymName,
        syscalls: []const SyscallHash,
        machine: std.elf.EM,

        /// A `call <imm>` target: match the low 32 bits against the static
        /// syscall hash table first, then fall back to a symbol whose value
        /// equals the full immediate.
        fn resolve(a: *const Annotator, imm: u64) ?[]const u8 {
            const key: u32 = @truncate(imm);
            for (a.syscalls) |sc| {
                if (sc.hash == key) return sc.name;
            }
            for (a.syms) |s| {
                if (s.value == imm) return s.name;
            }
            return null;
        }

        /// A memory-region note for an address (load/store/lddw). The high 32
        /// bits select the region per the sBPF memory map.
        fn region(a: *const Annotator, addr: u64) ?[]const u8 {
            _ = a;
            return switch (addr >> 32) {
                0x1 => "program",
                0x2 => "stack",
                0x3 => "heap",
                0x4 => "input",
                else => null,
            };
        }
    };

    /// murmur3_32 (seed 0) copied VERBATIM from src/codegen/llvm.sig so the
    /// static-syscall hashes computed here match the immediates sig's own
    /// codegen emits. Do NOT alter the constants or the mix sequence.
    fn murmur3_32(key: []const u8) u32 {
        const c1: u32 = 0xcc9e2d51;
        const c2: u32 = 0x1b873593;

        var h: u32 = 0; // seed = 0
        const nblocks = key.len / 4;

        var i: usize = 0;
        while (i < nblocks) : (i += 1) {
            var k: u32 = std.mem.readInt(u32, key[i * 4 ..][0..4], .little);
            k *%= c1;
            k = std.math.rotl(u32, k, 15);
            k *%= c2;
            h ^= k;
            h = std.math.rotl(u32, h, 13);
            h = h *% 5 +% 0xe6546b64;
        }

        const tail = key[nblocks * 4 ..];
        var k1: u32 = 0;
        if (tail.len >= 3) k1 ^= @as(u32, tail[2]) << 16;
        if (tail.len >= 2) k1 ^= @as(u32, tail[1]) << 8;
        if (tail.len >= 1) {
            k1 ^= @as(u32, tail[0]);
            k1 *%= c1;
            k1 = std.math.rotl(u32, k1, 15);
            k1 *%= c2;
            h ^= k1;
        }

        h ^= @as(u32, @intCast(key.len));
        h ^= h >> 16;
        h *%= 0x85ebca6b;
        h ^= h >> 13;
        h *%= 0xc2b2ae35;
        h ^= h >> 16;
        return h;
    }

    /// The SIMD-0178 static-syscall name set (design §7.3). The hashes are
    /// computed at comptime via murmur3_32 so the table carries both the 32-bit
    /// key an sBPF `call` immediate uses and the human name to annotate it with.
    const syscall_names = [_][]const u8{
        "sol_log_",
        "sol_log_64_",
        "sol_log_pubkey",
        "sol_log_compute_units_",
        "sol_sha256",
        "sol_keccak256",
        "sol_blake3",
        "sol_memcpy_",
        "sol_memmove_",
        "sol_memcmp_",
        "sol_memset_",
        "sol_invoke_signed_c",
        "sol_invoke_signed_rust",
        "sol_get_clock_sysvar",
        "sol_get_rent_sysvar",
        "sol_get_epoch_schedule_sysvar",
        "sol_get_fees_sysvar",
        "sol_get_stack_height",
        "sol_create_program_address",
        "sol_try_find_program_address",
        "sol_secp256k1_recover",
        "sol_curve_validate_point",
        "sol_curve_group_op",
        "abort",
        "sol_panic_",
        "sol_alloc_free_",
        "sol_set_return_data",
        "sol_get_return_data",
    };

    const syscalls: []const SyscallHash = blk: {
        // murmur3_32 loops per 4-byte block over ~28 names; the default 1000
        // backwards-branch comptime budget is exhausted in the JIT objdump and
        // build-exe pipelines (they use the default quota, unlike `sig test`),
        // failing before any format handler runs. Raise it for this table only.
        @setEvalBranchQuota(20000);
        var table: [syscall_names.len]SyscallHash = undefined;
        for (syscall_names, 0..) |nm, idx| {
            table[idx] = .{ .hash = murmur3_32(nm), .name = nm };
        }
        const final = table;
        break :blk &final;
    };

    /// sBPF register name (`r0`..`r10`). Values outside 0..10 are rendered
    /// numerically so a malformed field never traps.
    fn regName(buf: *[8]u8, n: u4) []const u8 {
        return std.fmt.bufPrint(buf, "r{d}", .{n}) catch "r?";
    }

    /// A decoded instruction's raw fields (eBPF 64-bit little-endian layout):
    /// opcode:u8, regs:u8 (low nibble dst, high nibble src), off:i16, imm:i32.
    const Insn = struct {
        opcode: u8,
        dst: u4,
        src: u4,
        off: i16,
        imm: i32,
    };

    fn readInsn(code: []const u8) Insn {
        return .{
            .opcode = code[0],
            .dst = @truncate(code[1]),
            .src = @truncate(code[1] >> 4),
            .off = @bitCast(std.mem.readInt(u16, code[2..4], .little)),
            .imm = @bitCast(std.mem.readInt(u32, code[4..8], .little)),
        };
    }

    /// The arithmetic mnemonic for an ALU/ALU64 opcode's operation nibble
    /// (high nibble of the opcode), or null for an unknown operation.
    fn aluOp(op: u8) ?[]const u8 {
        return switch (op & 0xf0) {
            0x00 => "add",
            0x10 => "sub",
            0x20 => "mul",
            0x30 => "div",
            0x40 => "or",
            0x50 => "and",
            0x60 => "lsh",
            0x70 => "rsh",
            0x80 => "neg",
            0x90 => "mod",
            0xa0 => "xor",
            0xb0 => "mov",
            0xc0 => "arsh",
            else => null,
        };
    }

    /// The branch mnemonic for a JMP/JMP32 opcode's operation nibble, or null.
    /// The high nibble selects the op per the authoritative Solana sBPF table
    /// (anza-xyz/sbpf doc/bytecode.md): 0x8 call, 0x9 exit, 0xC jslt, 0xD jsle.
    /// callx (0x8D) is decoded separately in decodeOne so it does not collide
    /// with call (0x85).
    fn jmpOp(op: u8) ?[]const u8 {
        return switch (op & 0xf0) {
            0x00 => "ja",
            0x10 => "jeq",
            0x20 => "jgt",
            0x30 => "jge",
            0x40 => "jset",
            0x50 => "jne",
            0x60 => "jsgt",
            0x70 => "jsge",
            0x80 => "call",
            0x90 => "exit",
            0xa0 => "jlt",
            0xb0 => "jle",
            0xc0 => "jslt",
            0xd0 => "jsle",
            else => null,
        };
    }

    /// The size suffix for a LD/LDX/ST/STX opcode's size bits (bits 3-4):
    /// w (word), h (half), b (byte), dw (double word).
    fn memSize(op: u8) []const u8 {
        return switch (op & 0x18) {
            0x00 => "w",
            0x08 => "h",
            0x10 => "b",
            0x18 => "dw",
            else => unreachable,
        };
    }

    /// Emit the raw bytes of a short/undecodable tail as space-separated hex.
    fn writeRawBytes(w: *Io.Writer, bytes: []const u8) !void {
        for (bytes, 0..) |b, i| {
            if (i != 0) try w.writeByte(' ');
            try w.print("{x:0>2}", .{b});
        }
    }

    /// Decode and render ONE sBPF instruction starting at `code[0]`, with
    /// program-counter `pc`. Returns the byte stride consumed (8, or 16 for the
    /// `lddw` opcode 0x18). Bounds are checked BEFORE any slice: a short tail
    /// emits `<truncated>` plus the remaining raw bytes and returns
    /// error.ParseFailure (no out-of-bounds read). An unknown opcode renders
    /// inline as `<unknown opcode 0xNN>` and advances one 8-byte stride so the
    /// walk continues.
    fn decodeOne(code: []const u8, pc: u64, ann: *const Annotator, w: *Io.Writer) Error!usize {
        _ = pc;
        if (code.len < 8) {
            try w.writeAll("<truncated> ");
            try writeRawBytes(w, code);
            return error.ParseFailure;
        }

        const in = readInsn(code);
        const op = in.opcode;
        const class = op & 0x07;
        const source_is_imm = (op & 0x08) == 0; // bit 3: 0 => imm (K), 1 => src reg (X)
        var dbuf: [8]u8 = undefined;
        var sbuf: [8]u8 = undefined;
        const dst = regName(&dbuf, in.dst);
        const src = regName(&sbuf, in.src);

        switch (class) {
            // ALU (32-bit) and ALU64.
            0x04, 0x07 => {
                const suffix: []const u8 = if (class == 0x04) "32" else "";
                const mnem = aluOp(op) orelse {
                    try w.print("<unknown opcode 0x{x:0>2}> ", .{op});
                    try writeRawBytes(w, code[0..8]);
                    return 8;
                };
                if ((op & 0xf0) == 0x80) {
                    // neg has no source operand.
                    try w.print("{s}{s} {s}", .{ mnem, suffix, dst });
                } else if (source_is_imm) {
                    try w.print("{s}{s} {s}, 0x{x}", .{ mnem, suffix, dst, @as(u32, @bitCast(in.imm)) });
                } else {
                    try w.print("{s}{s} {s}, {s}", .{ mnem, suffix, dst, src });
                }
                return 8;
            },

            // JMP (64-bit) and JMP32.
            0x05, 0x06 => {
                const suffix: []const u8 = if (class == 0x06) "32" else "";
                const mnem = jmpOp(op) orelse {
                    try w.print("<unknown opcode 0x{x:0>2}> ", .{op});
                    try writeRawBytes(w, code[0..8]);
                    return 8;
                };
                switch (op & 0xf0) {
                    0x90 => try w.writeAll("exit"), // exit (opcode 0x95)
                    0x00 => try w.print("ja {d}", .{in.off}), // unconditional
                    0x80 => {
                        // call (0x85, static syscall when src==0) and callx (0x8D,
                        // indirect through src register) share the 0x80 nibble.
                        if ((op & 0x08) != 0) {
                            // callx: target is the src register, not an immediate.
                            try w.print("callx {s}", .{src});
                        } else {
                            // call <imm>; annotate via syscall hash then symbol.
                            try w.print("call 0x{x}", .{@as(u32, @bitCast(in.imm))});
                            if (ann.resolve(@as(u64, @as(u32, @bitCast(in.imm))))) |nm|
                                try w.print(" <{s}>", .{nm});
                        }
                    },
                    else => {
                        if (source_is_imm)
                            try w.print("{s}{s} {s}, 0x{x}, {d}", .{ mnem, suffix, dst, @as(u32, @bitCast(in.imm)), in.off })
                        else
                            try w.print("{s}{s} {s}, {s}, {d}", .{ mnem, suffix, dst, src, in.off });
                    },
                }
                return 8;
            },

            // LD / LDX / ST / STX.
            0x00, 0x01, 0x02, 0x03 => {
                // lddw: opcode 0x18 is a 16-byte immediate-load pair.
                if (op == 0x18) {
                    if (code.len < 16) {
                        try w.writeAll("<truncated> ");
                        try writeRawBytes(w, code);
                        return error.ParseFailure;
                    }
                    const lo: u64 = @as(u32, @bitCast(in.imm));
                    const hi: u64 = std.mem.readInt(u32, code[12..16], .little);
                    const imm64 = (hi << 32) | (lo & 0xffffffff);
                    try w.print("lddw {s}, 0x{x}", .{ dst, imm64 });
                    if (ann.region(imm64)) |rg| try w.print(" ; {s}", .{rg});
                    return 16;
                }

                const sz = memSize(op);
                switch (class) {
                    0x01 => { // LDX: dst = *(size *)(src + off)
                        const addr_note = ann.region(@as(u64, @bitCast(@as(i64, in.off))));
                        try w.print("ldx{s} {s}, [{s}{s}0x{x}]", .{
                            sz, dst, src,
                            if (in.off < 0) "-" else "+",
                            @abs(@as(i64, in.off)),
                        });
                        if (addr_note) |rg| try w.print(" ; {s}", .{rg});
                        return 8;
                    },
                    0x02 => { // ST: *(size *)(dst + off) = imm
                        try w.print("st{s} [{s}{s}0x{x}], 0x{x}", .{
                            sz, dst,
                            if (in.off < 0) "-" else "+",
                            @abs(@as(i64, in.off)),
                            @as(u32, @bitCast(in.imm)),
                        });
                        return 8;
                    },
                    0x03 => { // STX: *(size *)(dst + off) = src
                        try w.print("stx{s} [{s}{s}0x{x}], {s}", .{
                            sz, dst,
                            if (in.off < 0) "-" else "+",
                            @abs(@as(i64, in.off)),
                            src,
                        });
                        return 8;
                    },
                    else => {
                        // LD class 0x00 (other than lddw) is unused by sBPF.
                        try w.print("<unknown opcode 0x{x:0>2}> ", .{op});
                        try writeRawBytes(w, code[0..8]);
                        return 8;
                    },
                }
            },

            else => {
                try w.print("<unknown opcode 0x{x:0>2}> ", .{op});
                try writeRawBytes(w, code[0..8]);
                return 8;
            },
        }
    }

    /// Human name for a machine, for the "not implemented" message. Never traps
    /// on an unnamed non-exhaustive value.
    fn machineName(m: std.elf.EM) []const u8 {
        return std.enums.tagName(std.elf.EM, m) orelse "unknown";
    }

    /// Drive disassembly for the ELF path. SINGLE Annotator construction site:
    /// pairs the FEAT-002 value->name symbol table with the comptime syscall
    /// table and the header machine, then walks each executable section.
    /// Non-sBPF machines emit a clear "not implemented" error.
    fn run(
        d: *const DumpContext,
        hdr: *const std.elf.Header,
        sections: *const std.ArrayList(std.elf.Elf64.Shdr),
        shstrtab: []const u8,
        syms: []const SymName,
        e_flags: u32,
    ) !void {
        const fr = d.fr;
        const w = d.w;
        const r = &fr.interface;

        // --- Decoder selection (§6.2): sBPF only for 0.6.2. ---
        switch (hdr.machine) {
            .BPF, .SBF => {},
            else => d.failParse("disassembly not implemented for {s}", .{machineName(hdr.machine)}),
        }

        const ann: Annotator = .{
            .syms = syms,
            .syscalls = syscalls,
            .machine = hdr.machine,
        };

        const file_size = try fr.getSize();

        if (d.element(.@"header-name")) {
            var vbuf: [16]u8 = undefined;
            try w.print("Disassembly ({s}):\n", .{elf.sbpfVersionName(e_flags, &vbuf)});
        }

        for (sections.items) |shdr| {
            if (!shdr.flags.shf.EXECINSTR) continue;
            if (shdr.size == 0) continue;

            const name = elf.sectionName(d, shstrtab, shdr.name);
            if (!filterMatches(d.opts.section_filters, name)) continue;

            // If a specific symbol was requested, only disassemble sections that
            // contain it (the symbol-range view); otherwise all exec sections.
            if (d.opts.disassemble_symbol) |want| {
                var hit = false;
                for (syms) |s| {
                    if (std.mem.eql(u8, s.name, want) and
                        s.value >= shdr.addr and s.value < shdr.addr + shdr.size)
                    {
                        hit = true;
                        break;
                    }
                }
                if (!hit) continue;
            }

            // EOF/bounds guard before reading section bytes.
            if (shdr.offset > file_size or shdr.offset + shdr.size > file_size)
                d.failParse("section '{s}' bytes out of bounds", .{name});

            try fr.seekTo(shdr.offset);
            const codebytes = try r.readAlloc(d.gpa, shdr.size);
            defer d.gpa.free(codebytes);

            if (d.element(.@"header-name")) try w.print("{s}:\n", .{name});

            const base = shdr.addr;
            var cursor: usize = 0;
            while (cursor < codebytes.len) {
                const pc = base + cursor;

                // Section/symbol/entry banner when a symbol starts here.
                for (syms) |s| {
                    if (s.value == pc and s.name.len != 0) {
                        try w.print("{f} <{s}>:\n", .{ coff.fmtIntField(d, pc, .{ .kind = .va }), s.name });
                        break;
                    }
                }
                if (pc == MM_PROGRAM_START and d.element(.@"header-name"))
                    try w.writeAll("; entrypoint\n");

                // Address + raw-byte prefix.
                try w.print("  {f}:  ", .{coff.fmtIntField(d, pc, .{ .kind = .va })});

                const stride = decodeOne(codebytes[cursor..], pc, &ann, w) catch |err| switch (err) {
                    error.ParseFailure => {
                        try w.writeByte('\n');
                        // Short/undecodable tail already rendered; stop this section.
                        break;
                    },
                    else => |e| return e,
                };
                try w.writeByte('\n');
                cursor += stride;
            }
            if (d.element(.newlines)) try w.writeByte('\n');
        }
    }
};

const macho = struct {
    /// Human-readable name for the CPU type carried in a Mach-O header. Only the
    /// 64-bit CPU types sig cares about are named; anything else prints as bare
    /// hex (the design forbids `{t}` here — `cpu_type_t` is a plain integer, not
    /// an enum, so there is no tag to format).
    fn machoCpuName(cputype: std.macho.cpu_type_t) ?[]const u8 {
        return switch (cputype) {
            std.macho.CPU_TYPE_X86_64 => "X86_64",
            std.macho.CPU_TYPE_ARM64 => "ARM64",
            else => null,
        };
    }

    /// Human-readable name for the Mach-O `filetype` word. `filetype` is a plain
    /// `u32`, NOT an enum, so this is a manual switch (never `{t}`). Returns the
    /// empty string for anything unrecognized; the caller falls back to bare hex.
    fn machoFiletypeName(ft: u32) []const u8 {
        return switch (ft) {
            std.macho.MH_OBJECT => "OBJECT",
            std.macho.MH_EXECUTE => "EXECUTE",
            std.macho.MH_CORE => "CORE",
            std.macho.MH_DYLIB => "DYLIB",
            std.macho.MH_BUNDLE => "BUNDLE",
            std.macho.MH_DSYM => "DSYM",
            else => "",
        };
    }

    fn dump(d: *const DumpContext) !void {
        const fr = d.fr;
        const w = d.w;
        const r = &fr.interface;
        const basename = std.fs.path.basename(d.opts.input_path);

        // --- Variant guard (§8.1 step 3). The dispatcher only routes here when
        // the leading word is MH_MAGIC_64, but re-check explicitly so fat/
        // universal (FAT_MAGIC/CIGAM) and 32-bit (MH_MAGIC) inputs that somehow
        // reach this handler produce a clear error, never a stub or a misparse.
        // Phases 2/3 (fat/universal + 32-bit) are out of scope. ---
        const magic = r.peek(4) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            else => d.failParse("truncated Mach-O header: {t}", .{err}),
        };
        const magic_word = mem.readInt(u32, magic[0..4], .little);
        switch (magic_word) {
            std.macho.MH_MAGIC_64 => {},
            std.macho.MH_MAGIC,
            std.macho.MH_CIGAM,
            std.macho.MH_CIGAM_64,
            std.macho.FAT_MAGIC,
            std.macho.FAT_CIGAM,
            std.macho.FAT_MAGIC_64,
            std.macho.FAT_CIGAM_64,
            => d.failParse("unsupported Mach-O variant (fat/universal and 32-bit are not supported)", .{}),
            else => d.failParse("not a Mach-O file (magic 0x{x})", .{magic_word}),
        }

        const h = r.takeStruct(std.macho.mach_header_64, .little) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            else => d.failParse("truncated Mach-O header: {t}", .{err}),
        };

        // --- File-type banner (§3). ---
        if (d.element(.@"file-type")) {
            const ftname = machoFiletypeName(h.filetype);
            if (ftname.len != 0)
                try w.print("{s}: Mach-O 64-bit {s}\n", .{ basename, ftname })
            else
                try w.print("{s}: Mach-O 64-bit object\n", .{basename});
            if (d.element(.newlines)) try w.writeByte('\n');
        }

        // --- --file-headers (§8.1 step 1). All element/redaction aware. ---
        if (d.opts.file_headers) {
            if (d.element(.@"header-name")) try w.writeAll("Mach-O Header:\n");
            try w.print("  magic                       0x{x}\n", .{h.magic});
            if (machoCpuName(h.cputype)) |nm|
                try w.print("  cputype                     {s} (0x{x})\n", .{ nm, @as(u32, @bitCast(h.cputype)) })
            else
                try w.print("  cputype                     0x{x}\n", .{@as(u32, @bitCast(h.cputype))});
            try w.print("  cpusubtype                  0x{x}\n", .{@as(u32, @bitCast(h.cpusubtype))});
            const ftname = machoFiletypeName(h.filetype);
            if (ftname.len != 0)
                try w.print("  filetype                    {s} (0x{x})\n", .{ ftname, h.filetype })
            else
                try w.print("  filetype                    0x{x}\n", .{h.filetype});
            try w.print("  ncmds                       {f}\n", .{coff.fmtIntField(d, h.ncmds, .{ .kind = .size })});
            try w.print("  sizeofcmds                  {f}\n", .{coff.fmtIntField(d, h.sizeofcmds, .{ .kind = .size })});
            try w.print("  flags                       0x{x}\n", .{h.flags});
            if (d.element(.newlines)) try w.writeByte('\n');
        }

        const want_sections = d.opts.section_headers;
        const want_symbols = d.opts.symbols;
        if (!want_sections and !want_symbols) return;

        const file_size = try fr.getSize();

        // --- Load-command walk (§8.1 step 2). Each command starts at a known
        // offset; we re-seek per command and advance by cmdsize so a command we
        // do not re-read in full still lands us on the next one. The header is
        // @sizeOf(mach_header_64) bytes; commands follow immediately. ---
        if (want_sections and d.element(.@"header-name")) try w.writeAll("Sections:\n");
        if (want_sections and d.element(.@"table-header"))
            try w.writeAll("  Segment,Section               Addr       Size     Offset Align\n");

        var cmd_off: u64 = @sizeOf(std.macho.mach_header_64);
        var cmd_i: u32 = 0;
        while (cmd_i < h.ncmds) : (cmd_i += 1) {
            if (cmd_off + @sizeOf(std.macho.load_command) > file_size)
                d.failParse("load command {d} out of bounds", .{cmd_i});
            try fr.seekTo(cmd_off);
            const lc = r.takeStruct(std.macho.load_command, .little) catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                else => d.failParse("truncated load command {d}: {t}", .{ cmd_i, err }),
            };
            if (lc.cmdsize < @sizeOf(std.macho.load_command) or cmd_off + lc.cmdsize > file_size)
                d.failParse("load command {d} has invalid cmdsize 0x{x}", .{ cmd_i, lc.cmdsize });

            switch (lc.cmd) {
                .SEGMENT_64 => if (want_sections) {
                    try fr.seekTo(cmd_off);
                    const seg = r.takeStruct(std.macho.segment_command_64, .little) catch |err| switch (err) {
                        error.ReadFailed => return error.ReadFailed,
                        else => d.failParse("truncated SEGMENT_64 command {d}: {t}", .{ cmd_i, err }),
                    };
                    const segname = seg.segName();
                    var sec_i: u32 = 0;
                    while (sec_i < seg.nsects) : (sec_i += 1) {
                        const sect = r.takeStruct(std.macho.section_64, .little) catch |err| switch (err) {
                            error.ReadFailed => return error.ReadFailed,
                            else => d.failParse("truncated section {d} in segment '{s}': {t}", .{ sec_i, segname, err }),
                        };
                        const sectname = sect.sectName();
                        try w.print("  {s},{s}", .{ segname, sectname });
                        const label_len = segname.len + 1 + sectname.len;
                        if (label_len < 28) try w.splatByteAll(' ', 28 - label_len);
                        try w.print(" {f} {f} {f} {d: >4}\n", .{
                            coff.fmtIntField(d, sect.addr, .{ .kind = .va }),
                            coff.fmtIntField(d, sect.size, .{ .kind = .size }),
                            coff.fmtIntField(d, @as(u64, sect.offset), .{ .kind = .va }),
                            sect.@"align",
                        });
                    }
                },
                .SYMTAB => if (want_symbols) {
                    try fr.seekTo(cmd_off);
                    const sc = r.takeStruct(std.macho.symtab_command, .little) catch |err| switch (err) {
                        error.ReadFailed => return error.ReadFailed,
                        else => d.failParse("truncated SYMTAB command {d}: {t}", .{ cmd_i, err }),
                    };
                    try dumpSymtab(d, sc, file_size);
                },
                else => {},
            }

            cmd_off += lc.cmdsize;
        }

        if (want_sections and d.element(.newlines)) try w.writeByte('\n');
    }

    /// Read and print the Mach-O symbol table described by a SYMTAB command
    /// (§8.1 step 2). The string table is read once into a gpa buffer; each
    /// `nlist_64` entry's `n_strx` indexes it. Strict allocator discipline:
    /// every `readAlloc` has a matching `defer gpa.free`.
    fn dumpSymtab(d: *const DumpContext, sc: std.macho.symtab_command, file_size: u64) !void {
        const gpa = d.gpa;
        const fr = d.fr;
        const w = d.w;
        const r = &fr.interface;

        const esz = @sizeOf(std.macho.nlist_64);
        if (@as(u64, sc.symoff) + @as(u64, sc.nsyms) * esz > file_size)
            d.failParse("symbol table out of bounds", .{});
        if (@as(u64, sc.stroff) + @as(u64, sc.strsize) > file_size)
            d.failParse("string table out of bounds", .{});

        var strtab: []u8 = &.{};
        defer if (strtab.len != 0) gpa.free(strtab);
        if (sc.strsize != 0) {
            try fr.seekTo(sc.stroff);
            strtab = try r.readAlloc(gpa, sc.strsize);
        }

        if (d.element(.@"header-name")) try w.writeAll("Symbol table:\n");
        if (d.element(.@"table-header"))
            try w.writeAll("  Value    Name\n");

        try fr.seekTo(sc.symoff);
        var sym_i: u32 = 0;
        while (sym_i < sc.nsyms) : (sym_i += 1) {
            const nl = r.takeStruct(std.macho.nlist_64, .little) catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                else => d.failParse("truncated symbol {d}: {t}", .{ sym_i, err }),
            };
            const name = if (nl.n_strx == 0 or nl.n_strx >= strtab.len)
                ""
            else
                std.mem.sliceTo(strtab[nl.n_strx..], 0);
            if (!filterMatches(d.opts.symbol_filters, name)) continue;
            try w.print("  {f} {s}\n", .{
                coff.fmtIntField(d, nl.n_value, .{ .kind = .va }),
                name,
            });
        }
        if (d.element(.newlines)) try w.writeByte('\n');
    }
};

const wasm = struct {
    /// Name of a wasm section id. `Section` is a non-exhaustive `enum(u8)`, so a
    /// format-time `{t}` would panic on an unknown id (see the FEAT-002 toolchain
    /// finding); route it through `tagName` with a numeric fallback instead.
    fn sectionName(id: std.wasm.Section) []const u8 {
        return std.enums.tagName(std.wasm.Section, id) orelse "custom?";
    }

    fn dump(d: *const DumpContext) !void {
        const fr = d.fr;
        const w = d.w;
        const r = &fr.interface;
        const basename = std.fs.path.basename(d.opts.input_path);

        // --- Magic + version check (§8.2). The dispatcher already matched the
        // 4-byte magic; consume it and verify the version word. ---
        const magic = r.take(4) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            else => d.failParse("truncated WebAssembly header: {t}", .{err}),
        };
        if (!mem.eql(u8, magic, &std.wasm.magic))
            d.failParse("not a WebAssembly module", .{});
        const ver = r.take(4) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            else => d.failParse("truncated WebAssembly header: {t}", .{err}),
        };
        if (!mem.eql(u8, ver, &std.wasm.version))
            d.failParse("unsupported WebAssembly version {d}.{d}.{d}.{d}", .{ ver[0], ver[1], ver[2], ver[3] });
        const version = mem.readInt(u32, ver[0..4], .little);

        // --- File-type banner (§3). ---
        if (d.element(.@"file-type")) {
            try w.print("{s}: WebAssembly binary (version {d})\n", .{ basename, version });
            if (d.element(.newlines)) try w.writeByte('\n');
        }

        // --- --file-headers prints the version word (§8.2 step). ---
        if (d.opts.file_headers) {
            if (d.element(.@"header-name")) try w.writeAll("WebAssembly Header:\n");
            try w.print("  version                     {d}\n", .{version});
            if (d.element(.newlines)) try w.writeByte('\n');
        }

        const want_inventory = d.opts.section_headers or d.opts.summary;
        if (!want_inventory) return;

        const file_size = try fr.getSize();

        // --- Section-sequence walk (§8.2). Each section is `id: u8` followed by
        // a LEB128 u32 byte-size, then that many content bytes. We print the
        // inventory (name + size) and, for export/name-custom sections where the
        // payload is cheaply decodable, list the exported/module names. Full
        // operand decode is OUT OF SCOPE. ---
        if (d.element(.@"header-name")) try w.writeAll("Sections:\n");
        if (d.element(.@"table-header"))
            try w.writeAll("  Id Name            Size\n");

        while (fr.logicalPos() < file_size) {
            const id_byte = r.takeByte() catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                else => break,
            };
            const id: std.wasm.Section = @enumFromInt(id_byte);
            const size = r.takeLeb128(u32) catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                else => d.failParse("malformed LEB128 size for section 0x{x}", .{id_byte}),
            };
            const body_start = fr.logicalPos();
            if (body_start + size > file_size)
                d.failParse("section '{s}' size 0x{x} out of bounds", .{ sectionName(id), size });

            try w.print("  {d: >2} {s: <15} {f}\n", .{
                id_byte,
                sectionName(id),
                coff.fmtIntField(d, size, .{ .kind = .size }),
            });

            switch (id) {
                .@"export" => try listExports(d, body_start, size),
                .custom => try listCustomName(d, body_start, size),
                else => {},
            }

            // Advance to the next section regardless of how much of the body we
            // decoded above.
            try fr.seekTo(body_start + size);
        }

        if (d.element(.newlines)) try w.writeByte('\n');
    }

    /// List the names in a wasm export section (§8.2). Layout: LEB128 count, then
    /// for each export a LEB128-length name, 1 kind byte, and a LEB128 index. We
    /// print only the names (operand/index decode is out of scope); any malformed
    /// entry stops the listing without failing the whole dump.
    fn listExports(d: *const DumpContext, body_start: u64, size: u32) !void {
        const fr = d.fr;
        const w = d.w;
        const r = &fr.interface;
        const body_end = body_start + size;

        try fr.seekTo(body_start);
        const count = r.takeLeb128(u32) catch return;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (fr.logicalPos() >= body_end) break;
            const name_len = r.takeLeb128(u32) catch break;
            if (fr.logicalPos() + name_len > body_end) break;
            const name = r.take(name_len) catch break;
            try w.print("    export {s}\n", .{name});
            // kind byte + LEB128 index — skip, we only list names.
            _ = r.takeByte() catch break;
            _ = r.takeLeb128(u32) catch break;
        }
    }

    /// Print the module name carried by a wasm custom "name" section (§8.2). Only
    /// the leading section-name string is listed (the full name-map decode is out
    /// of scope); a non-"name" custom section just prints its name string.
    fn listCustomName(d: *const DumpContext, body_start: u64, size: u32) !void {
        const fr = d.fr;
        const w = d.w;
        const r = &fr.interface;
        const body_end = body_start + size;

        try fr.seekTo(body_start);
        const name_len = r.takeLeb128(u32) catch return;
        if (fr.logicalPos() + name_len > body_end) return;
        const name = r.take(name_len) catch return;
        try w.print("    name \"{s}\"\n", .{name});
    }
};

const coff = struct {
    const DIRECTORY_ENTRY = std.coff.IMAGE.DIRECTORY_ENTRY;

    const Section = struct {
        header: std.coff.SectionHeader,
        name: []const u8,

        fn rvaFileOffset(section: *const Section, rva: u32) !u32 {
            if (rva < section.header.virtual_address or
                rva >= section.header.virtual_address + section.header.size_of_raw_data)
                return error.OutOfBounds;

            return section.header.pointer_to_raw_data + (rva - section.header.virtual_address);
        }
    };

    const ArchiveHeader = struct {
        name: []const u8,
        date: u40,
        user_id: u20,
        group_id: u20,
        file_mode: u24,
        size: u34,

        pub fn fromRaw(d: *const DumpContext, raw_header: *const std.coff.ArchiveMemberHeader, opt_longnames: ?[]const u8) @This() {
            const name = raw_header.parseName(opt_longnames) catch |err| switch (err) {
                error.BadName => d.failParse("malformed member name: '{s}'", .{&raw_header.name}),
                error.NoLongNames => d.failParse("member uses a long name, but there was no longnames member", .{}),
            };

            return .{
                .name = name,
                .date = raw_header.parseDate() catch |err|
                    d.failParse("unable to parse date '{s}' in member '{s}': {t}", .{ raw_header.date, name, err }),
                .user_id = raw_header.parseUserId() catch |err|
                    d.failParse("unable to parse user_id '{s}' in member '{s}': {t}", .{ raw_header.user_id, name, err }),
                .group_id = raw_header.parseGroupId() catch |err|
                    d.failParse("unable to parse group_id '{s}' in member '{s}': {t}", .{ raw_header.group_id, name, err }),
                .file_mode = raw_header.parseFileMode() catch |err|
                    d.failParse("unable to parse file_mode '{s}' in member '{s}': {t}", .{ raw_header.file_mode, name, err }),
                .size = raw_header.parseSize() catch |err|
                    d.failParse("unable to parse size '{s}' in member '{s}': {t}", .{ raw_header.size, name, err }),
            };
        }
    };

    fn dumpArchive(d: *const DumpContext) !void {
        const gpa = d.gpa;
        const fr = d.fr;
        const w = d.w;

        const r = &fr.interface;
        r.toss(std.coff.archive_signature.len);

        const Member = struct {
            offset: u32,
            order: ?u32,
        };

        var members: std.ArrayList(Member) = .empty;
        defer members.deinit(gpa);
        var symbol_member_indices: std.ArrayList(u32) = .empty;
        defer symbol_member_indices.deinit(gpa);

        var opt_expected_kind: ?std.coff.ArchiveMemberHeader.Kind = .first_linker;
        var opt_longnames: ?[]const u8 = null;
        defer if (opt_longnames) |l| gpa.free(l);

        var pos = fr.logicalPos();
        const size = try fr.getSize();
        while (pos < size) : (pos = fr.logicalPos()) {
            if ((pos & 1) != 0) try r.discardAll(1);
            const raw_header = try r.takeStruct(std.coff.ArchiveMemberHeader, .little);
            const header: ArchiveHeader = .fromRaw(d, &raw_header, opt_longnames);

            if (!std.mem.eql(u8, &raw_header.end_of_header, std.coff.archive_end_of_header))
                return d.failParse("malformed end-of-header field in member '{s}': {x}", .{ header.name, raw_header.end_of_header });

            const dump_header =
                (d.opts.member_headers and filterMatches(d.opts.member_filters, header.name)) or
                (d.opts.linker_member == opt_expected_kind);

            if (dump_header)
                try dumpArchiveHeader(d, &header, @intCast(pos));

            const member_end = fr.logicalPos() + header.size;
            if (member_end > size)
                return d.failParse("out-of-bounds length 0x{x} in member '{s}'", .{ header.size, header.name });

            if (opt_expected_kind) |expected_kind| switch (expected_kind) {
                .first_linker => {
                    if (!std.mem.eql(u8, header.name, "/"))
                        return d.failParse("expected first linker member, found '{s}'", .{header.name});

                    const num_symbols = try r.takeInt(u32, .big);
                    if (dump_header)
                        try w.print(
                            \\{t: >16} type
                            \\               | {d} symbols
                            \\
                        , .{ expected_kind, num_symbols });

                    if (d.opts.linker_member == .first_linker) {
                        if (d.element(.@"table-header"))
                            try w.writeAll(
                                \\
                                \\Archive symbols:
                                \\& Member Symbol
                                \\
                            );

                        const offsets = try r.readAlloc(gpa, num_symbols * 4);
                        defer gpa.free(offsets);

                        for (0..num_symbols) |symbol_i| {
                            const symbol = r.takeDelimiter(0) catch |err|
                                return d.failParse("unable to read first linker member string table: {t}", .{err});

                            if (!filterMatches(d.opts.symbol_filters, symbol.?))
                                continue;

                            const offset = std.mem.readInt(u32, offsets[symbol_i * 4 ..][0..4], .big);
                            try w.print("{f} {s}\n", .{
                                fmtIntField(d, offset, .{ .kind = .va }),
                                symbol.?,
                            });
                        }
                    }
                    if (dump_header and d.element(.newlines)) try w.writeByte('\n');

                    try fr.seekTo(member_end);
                    opt_expected_kind = .second_linker;
                    continue;
                },
                .second_linker => {
                    if (!std.mem.eql(u8, header.name, "/"))
                        return d.failParse("expected second linker member, found '{s}'", .{header.name});

                    const num_members = try r.takeInt(u32, .little);
                    pos = fr.logicalPos();
                    if (pos + num_members * @sizeOf(u32) > member_end)
                        return d.failParse("invalid member count 0x{x} in second linker member", .{num_members});

                    try members.ensureTotalCapacity(gpa, num_members);
                    for (0..num_members) |_|
                        members.addOneAssumeCapacity().* = .{
                            .offset = try r.takeInt(u32, .little),
                            .order = null,
                        };

                    const num_symbols = try r.takeInt(u32, .little);
                    pos = fr.logicalPos();
                    if (pos + num_symbols * @sizeOf(u16) > member_end)
                        return d.failParse("invalid symbol count 0x{x} in second linker member", .{num_symbols});

                    if (dump_header)
                        try w.print(
                            \\{t: >16} type
                            \\               | {f} symbols
                            \\               | {f} members
                            \\
                        , .{
                            expected_kind,
                            fmtIntField(d, num_symbols, .{ .kind = .size, .width = .auto }),
                            fmtIntField(d, num_members, .{ .kind = .size, .width = .auto }),
                        });

                    try symbol_member_indices.ensureTotalCapacity(gpa, num_symbols);
                    for (0..num_symbols) |order| {
                        const index = (try r.takeInt(u16, .little)) - 1;
                        if (index >= members.items.len)
                            return d.failParse("invalid member index 0x{x} in seconds linker member indices array", .{index});

                        symbol_member_indices.addOneAssumeCapacity().* = index;

                        if (members.items[index].order == null)
                            members.items[index].order = @intCast(order);
                    }

                    if (d.opts.exports and d.opts.exports_sort) {
                        std.sort.pdq(Member, members.items, {}, struct {
                            fn lessThan(ctx: void, lhs: Member, rhs: Member) bool {
                                _ = ctx;
                                if (lhs.order == null and rhs.order == null)
                                    return lhs.offset < rhs.offset
                                else if (lhs.order) |lhs_order|
                                    return if (rhs.order) |rhs_order| lhs_order < rhs_order else false
                                else if (rhs.order) |rhs_order|
                                    return if (lhs.order) |lhs_order| lhs_order < rhs_order else true
                                else
                                    unreachable;
                            }
                        }.lessThan);
                    }

                    if (d.opts.linker_member == .second_linker) {
                        if (d.element(.@"table-header"))
                            try w.writeAll(
                                \\
                                \\Archive Symbols:
                                \\& Member Symbol
                                \\
                            );

                        pos = fr.logicalPos();
                        var symbol_i: u32 = 0;
                        while (pos < member_end and symbol_i < num_symbols) : ({
                            pos = fr.logicalPos();
                            symbol_i += 1;
                        }) {
                            const symbol_name = if (r.takeDelimiter(0) catch |err| switch (err) {
                                error.StreamTooLong => null,
                                else => |e| return e,
                            }) |n| n else return d.failParse("unterminated string found in second linker member", .{});

                            if (!filterMatches(d.opts.symbol_filters, symbol_name))
                                continue;

                            try w.print("{f} {s}\n", .{
                                fmtIntField(
                                    d,
                                    members.items[symbol_member_indices.items[symbol_i]].offset,
                                    .{ .kind = .va },
                                ),
                                symbol_name,
                            });
                        }

                        if (symbol_i != num_symbols)
                            return d.failParse(
                                " expected {d} entries in second linker member string table, but found {d}",
                                .{ num_symbols, symbol_i },
                            );
                    }

                    if (d.element(.newlines)) try w.writeByte('\n');
                    try fr.seekTo(member_end);
                    opt_expected_kind = .longnames;
                    continue;
                },
                .longnames => {
                    // This member is optional
                    if (std.mem.eql(u8, header.name, "//")) {
                        opt_longnames = try r.readAlloc(gpa, header.size);
                        if (dump_header)
                            try w.print("{t: >16} type\n", .{expected_kind});

                        if (d.opts.linker_member == .longnames) {
                            if (d.element(.@"table-header"))
                                try w.print(
                                    \\
                                    \\Longnames (0x{x} bytes):
                                    \\
                                , .{opt_longnames.?.len});

                            var lr = Io.Reader.fixed(opt_longnames.?);
                            while (try lr.takeDelimiter(0)) |str| {
                                try w.writeAll(str);
                                try w.writeByte('\n');
                            }
                        }

                        if (d.element(.newlines)) try w.writeByte('\n');
                    }

                    opt_expected_kind = null;
                    break;
                },
                else => unreachable,
            };
        }

        if (opt_expected_kind) |expected_kind| switch (expected_kind) {
            .first_linker => d.failParse("missing first linker member", .{}),
            .second_linker => d.failParse("missing second linker member", .{}),
            else => {},
        };

        for (members.items, 0..) |member, member_i| {
            fr.seekTo(member.offset) catch |err|
                d.failParse("unable to read member {d} at offset 0x{x}: {t}", .{ member_i, member.offset, err });

            const raw_header = try r.takeStruct(std.coff.ArchiveMemberHeader, .little);
            const header: ArchiveHeader = .fromRaw(d, &raw_header, opt_longnames);
            if (!filterMatches(d.opts.member_filters, header.name)) continue;

            const member_sig = try r.peek(4);
            const machine: std.coff.IMAGE.FILE.MACHINE =
                @fromBackingInt(@intCast(std.mem.readInt(u16, member_sig[0..2], .little)));
            const sig = std.mem.readInt(u16, member_sig[2..4], .little);

            const is_imp_lib = machine == std.coff.IMAGE.FILE.MACHINE.UNKNOWN and sig == 0xffff;
            if (d.opts.member_headers)
                try dumpArchiveHeader(d, &header, member.offset);

            if (d.opts.member_headers or (d.opts.exports and is_imp_lib)) {
                if (is_imp_lib) {
                    const imp_header = try r.takeStruct(std.coff.ImportHeader, .little);
                    const sym_name = (try r.takeDelimiter(0)).?;
                    const imp_dll = (try r.takeDelimiter(0)).?;

                    if (!filterMatches(d.opts.symbol_filters, sym_name))
                        continue;

                    if (d.element(.@"header-name"))
                        try w.writeAll("\nImport header:\n");

                    try dumpHeader(d, std.coff.ImportHeader, &imp_header, struct {
                        pub fn sig1(_: *const DumpContext, _: *const std.coff.ImportHeader) !void {}
                        pub fn sig2(_: *const DumpContext, _: *const std.coff.ImportHeader) !void {}
                        pub fn types(id: *const DumpContext, h: *const std.coff.ImportHeader) !void {
                            try id.w.print(
                                \\{t: >16} import_type 
                                \\{t: >16} name_type 
                                \\
                            , .{ h.types.type, h.types.name_type });
                        }
                    });

                    const imp_name = imp_name: switch (imp_header.types.name_type) {
                        .NAME_NOPREFIX,
                        .NAME_UNDECORATE,
                        => |tag| {
                            var imp_name = std.mem.trimStart(u8, sym_name, "?@_");
                            if (tag == .NAME_UNDECORATE)
                                imp_name = std.mem.sliceTo(imp_name, '@');
                            break :imp_name imp_name;
                        },
                        else => sym_name,
                    };

                    try w.print(
                        \\     symbol name | {s}
                        \\     import name | {s}
                        \\             dll | {s}
                        \\
                    , .{
                        sym_name,
                        imp_name,
                        imp_dll,
                    });
                } else {
                    try w.writeAll("     COFF object type\n");
                }
                if (d.element(.newlines)) try w.writeByte('\n');
            }

            if (is_imp_lib) continue;
            if (d.opts.section_headers or
                d.opts.file_headers or
                d.opts.relocs or
                d.opts.strings or
                d.opts.symbols)
            {
                const member_name = if (d.element(.@"member-path"))
                    header.name
                else
                    std.fs.path.basename(header.name);

                if (d.element(.@"file-type")) {
                    try w.print("{s}({s}): COFF object\n", .{
                        std.fs.path.basename(d.opts.input_path),
                        member_name,
                    });
                    if (d.element(.newlines)) try w.writeByte('\n');
                }
                try dumpObject(d, false, member_name);
            }
        }
    }

    fn dumpObject(
        d: *const DumpContext,
        is_image: bool,
        obj_name: []const u8,
    ) !void {
        const gpa = d.gpa;
        const fr = d.fr;
        const w = d.w;

        const file_location = fr.logicalPos();
        const r = &fr.interface;
        const header = r.takeStruct(std.coff.Header, .little) catch |err|
            return d.failParse("unable to read COFF header: {t}", .{err});

        if (d.opts.file_headers) {
            if (d.element(.@"header-name")) try w.writeAll("COFF Header:\n");
            try dumpHeader(d, std.coff.Header, &header, struct {});
            if (d.element(.newlines)) try w.writeByte('\n');
        }

        switch (header.machine) {
            _ => return d.failParse("unknown machine type: {x}", .{header.machine}),
            else => {},
        }

        var known_dirs: [DIRECTORY_ENTRY.len]std.coff.ImageDataDirectory = undefined;
        const needs_data_dirs =
            d.opts.exports or
            d.opts.imports or
            d.opts.tls;

        const ImageInfo = struct {
            data_dirs: []const std.coff.ImageDataDirectory,
            magic: std.coff.OptionalHeader.Magic,
            image_base: u64,
        };

        const image_info: ?ImageInfo = if (header.size_of_optional_header > 0) image_info: {
            if (!d.opts.file_headers and !needs_data_dirs) {
                try fr.seekBy(header.size_of_optional_header);
                break :image_info null;
            }

            if (d.opts.file_headers and d.element(.@"header-name"))
                try w.writeAll("COFF Optional Header:\n");

            const magic: std.coff.OptionalHeader.Magic = @fromBackingInt(@intCast(try r.peekInt(u16, .little)));
            const num_directory_entries, const image_base = switch (magic) {
                inline .PE32, .@"PE32+" => |v| num_data_dirs: {
                    const OptionalHeader = if (v == .PE32)
                        std.coff.OptionalHeader.PE32
                    else
                        std.coff.OptionalHeader.@"PE32+";

                    const optional_header = r.takeStruct(OptionalHeader, .little) catch |err|
                        return d.failParse("unable to read optional header: {t}", .{err});

                    if (d.opts.file_headers) {
                        try dumpHeader(d, OptionalHeader, &optional_header, struct {
                            pub fn base_of_code(id: *const DumpContext, h: *const std.coff.OptionalHeader) !void {
                                const base = @as(*const OptionalHeader, @ptrCast(@alignCast(h))).image_base;
                                try dumpRvaField(id, @src().fn_name, h.base_of_code, base);
                            }

                            pub fn address_of_entry_point(id: *const DumpContext, h: *const std.coff.OptionalHeader) !void {
                                const base = @as(*const OptionalHeader, @ptrCast(@alignCast(h))).image_base;
                                try dumpRvaField(id, @src().fn_name, h.base_of_code, base);
                            }

                            pub fn major_linker_version(id: *const DumpContext, h: *const std.coff.OptionalHeader) !void {
                                try dumpVersionField(id.w, "linker_version", h.major_linker_version, h.minor_linker_version);
                            }
                            pub fn minor_linker_version(_: *const DumpContext, _: *const std.coff.OptionalHeader) !void {}

                            pub fn major_operating_system_version(id: *const DumpContext, h: *const OptionalHeader) !void {
                                try dumpVersionField(
                                    id.w,
                                    "operating_system_version",
                                    h.major_operating_system_version,
                                    h.minor_operating_system_version,
                                );
                            }
                            pub fn minor_operating_system_version(_: *const DumpContext, _: *const OptionalHeader) !void {}

                            pub fn major_image_version(id: *const DumpContext, h: *const OptionalHeader) !void {
                                try dumpVersionField(id.w, "image_version", h.major_image_version, h.minor_image_version);
                            }
                            pub fn minor_image_version(_: *const DumpContext, _: *const OptionalHeader) !void {}

                            pub fn major_subsystem_version(id: *const DumpContext, h: *const OptionalHeader) !void {
                                try dumpVersionField(id.w, "subsystem_version", h.major_subsystem_version, h.minor_subsystem_version);
                            }
                            pub fn minor_subsystem_version(_: *const DumpContext, _: *const OptionalHeader) !void {}
                        });
                        if (d.element(.newlines)) try w.writeByte('\n');
                    }

                    break :num_data_dirs .{
                        optional_header.number_of_rva_and_sizes,
                        optional_header.image_base,
                    };
                },
                else => return d.failParse("invalid optional header magic number: {x}", .{magic}),
            };

            if (d.opts.file_headers and d.element(.@"header-name"))
                try w.writeAll("Data Directories:\n");

            for (0..num_directory_entries) |dir_i| {
                const dir = r.takeStruct(std.coff.ImageDataDirectory, .little) catch |err|
                    return d.failParse("unable to read data directory {x}: {t}", .{ dir_i, err });

                if (dir_i < known_dirs.len)
                    known_dirs[dir_i] = dir;

                if (d.opts.file_headers)
                    try w.print(
                        "{x: >16} {x: >8} {t}\n",
                        .{ dir.virtual_address, dir.size, @as(DIRECTORY_ENTRY, @fromBackingInt(@intCast(dir_i))) },
                    );
            }
            if (d.opts.file_headers and d.element(.newlines)) try w.writeByte('\n');

            break :image_info .{
                .data_dirs = known_dirs[0..@min(known_dirs.len, num_directory_entries)],
                .magic = magic,
                .image_base = image_base,
            };
        } else if (is_image) {
            return d.failParse("image did not contain an optional header", .{});
        } else null;

        // Section names in images don't use the string table, as they must fit inline in the header
        const load_string_table = (d.opts.strings or !is_image) and header.pointer_to_symbol_table > 0;
        const string_table = if (load_string_table) string_table: {
            const pos = fr.logicalPos();
            fr.seekTo(file_location + header.pointer_to_symbol_table + header.number_of_symbols * std.coff.Symbol.sizeOf()) catch |err|
                return d.failParse("unable to seek to string table: {t}", .{err});

            const string_table_len = r.peekInt(u32, .little) catch |err|
                return d.failParse("unable to read string table length: {t}", .{err});

            const table = r.readAlloc(gpa, string_table_len) catch |err|
                return d.failParse("unable to read string table: {t}", .{err});

            try fr.seekTo(pos);
            break :string_table table;
        } else &.{};
        defer gpa.free(string_table);

        if (d.opts.strings) {
            if (d.element(.@"table-header"))
                try w.print(
                    \\String Table (0x{x} bytes):
                    \\
                , .{string_table.len});

            var sr = Io.Reader.fixed(string_table[@sizeOf(u32)..]);
            while (try sr.takeDelimiter(0)) |str| {
                try w.writeAll(str);
                try w.writeByte('\n');
            }

            if (d.element(.newlines)) try w.writeByte('\n');
        }

        var sections: std.ArrayList(Section) = .empty;
        defer sections.deinit(gpa);
        var sections_with_data: u16 = 0;

        const load_sections =
            d.opts.section_headers or
            d.opts.symbols or
            d.opts.relocs or
            needs_data_dirs;

        if (load_sections) {
            if (d.opts.section_headers and d.element(.@"table-header"))
                try w.print(
                    \\Sections in '{s}':
                    \\Num Name          RVA Virt Size Data Size   & Data & Relocs  & Lines # Relocs  # Lines    Flags
                    \\
                , .{obj_name});

            try sections.resize(gpa, header.number_of_sections);
            for (sections.items, 0..) |*section, section_i| {
                section.header = r.takeStruct(std.coff.SectionHeader, .little) catch |err|
                    return d.failParse("unable to read section header {x}: {t}", .{ section_i, err });
                section.name = headerName(&section.header.name, string_table) catch |err| switch (err) {
                    error.Overflow,
                    error.InvalidCharacter,
                    => return d.failParse("unable to parse section name offset '{s}': {t}", .{
                        section.name,
                        err,
                    }),
                    error.OutOfBounds => return d.failParse("section name offset '{s}' was out of bounds (>= {x})", .{
                        section.name,
                        string_table.len,
                    }),
                };

                sections_with_data += @intFromBool(section.header.size_of_raw_data > 0);
                if (d.opts.section_headers) {
                    if (!filterMatches(d.opts.section_filters, section.name)) continue;
                    const raw_name = std.mem.sliceTo(&section.header.name, 0);
                    try w.print(
                        "{x: >3} {s: <8} {f} {f} {f} {f} {f} {f} {f} {f} {x:0>8} |",
                        .{
                            section_i + 1,
                            raw_name,
                            fmtIntField(d, section.header.virtual_address, .{ .kind = .va }),
                            fmtIntField(d, section.header.virtual_size, .{ .kind = .size, .width = .{ .explicit = 9 } }),
                            fmtIntField(d, section.header.size_of_raw_data, .{ .kind = .size, .width = .{ .explicit = 9 } }),
                            fmtIntField(d, section.header.pointer_to_raw_data, .{ .kind = .va }),
                            fmtIntField(d, section.header.pointer_to_relocations, .{ .kind = .va }),
                            fmtIntField(d, section.header.pointer_to_linenumbers, .{ .kind = .va }),
                            fmtIntField(d, section.header.number_of_relocations, .{ .kind = .va }),
                            fmtIntField(d, section.header.number_of_linenumbers, .{ .kind = .va }),
                            @as(u32, @bitCast(section.header.flags)),
                        },
                    );

                    try dumpFlags(w, "{s}", std.coff.SectionHeader.Flags, &section.header.flags, 1);
                    if (section.name.len > 8)
                        try w.print("\n  | {s}", .{section.name});

                    try w.writeByte('\n');
                }
            }

            if (d.opts.section_headers and d.element(.newlines)) try w.writeByte('\n');
        }

        var symbols: std.ArrayList(struct {
            name: []const u8,
            section_number: std.coff.SectionNumber,
        }) = .empty;
        defer symbols.deinit(gpa);

        var name_arena: std.heap.ArenaAllocator = .init(gpa);
        defer name_arena.deinit();

        if (d.opts.relocs)
            try symbols.ensureUnusedCapacity(gpa, header.number_of_symbols);

        if (d.opts.symbols or d.opts.relocs) {
            if (header.pointer_to_symbol_table > 0) {
                fr.seekTo(file_location + header.pointer_to_symbol_table) catch |err|
                    return d.failParse("unable to seek to symbol table: {t}", .{err});

                if (d.opts.symbols and d.element(.@"table-header"))
                    try w.print(
                        \\Symbols in '{s}':
                        \\ Ord    Value  Sect Type           Storage   Name
                        \\
                    , .{obj_name});

                const symbol_size = std.coff.Symbol.sizeOf();
                var symbol_i: u32 = 0;
                while (symbol_i < header.number_of_symbols) {
                    var symbol: std.coff.Symbol = undefined;
                    const symbol_bytes = r.take(symbol_size) catch |err|
                        return d.failParse("unable to read symbol {x}: {t}", .{ symbol_i, err });

                    @memcpy(std.mem.asBytes(&symbol)[0..symbol_size], symbol_bytes);
                    if (native_endian != .little)
                        std.mem.byteSwapAllFields(std.coff.Symbol, &symbol);

                    const aux_symbols = if (symbol.number_of_aux_symbols > 0)
                        try r.take(symbol_size * symbol.number_of_aux_symbols)
                    else
                        &.{};
                    defer symbol_i += symbol.number_of_aux_symbols + 1;

                    const name = if (std.mem.eql(u8, symbol.name[0..4], "\x00\x00\x00\x00")) name: {
                        const index = std.mem.readInt(u32, symbol.name[4..], .little);
                        if (index >= string_table.len)
                            return d.failParse("invalid name offset for symbol {x} ({x} >= {x})", .{
                                symbol_i,
                                index,
                                string_table.len,
                            });
                        break :name std.mem.sliceTo(string_table[index..], 0);
                    } else try name_arena.allocator().dupe(u8, std.mem.sliceTo(&symbol.name, 0));

                    if (d.opts.relocs)
                        symbols.appendNTimesAssumeCapacity(.{
                            .name = name,
                            .section_number = symbol.section_number,
                        }, 1 + symbol.number_of_aux_symbols);

                    if (!d.opts.symbols or !filterMatches(d.opts.symbol_filters, name))
                        continue;

                    try w.print("{f} {x:0>8} ", .{
                        fmtIntField(d, @as(u16, @intCast(symbol_i)), .{ .kind = .ord }),
                        symbol.value,
                    });
                    try switch (symbol.section_number) {
                        .UNDEFINED => w.writeAll("UNDEF"),
                        .ABSOLUTE => w.writeAll("  ABS"),
                        .DEBUG => w.writeAll("DEBUG"),
                        else => |v| {
                            const backing = @backingInt(v);
                            const fmt = "{x: >5}";
                            if (backing >= 0)
                                try w.print(fmt, .{@as(u15, @intCast(backing))})
                            else
                                try w.print(fmt, .{backing});
                        },
                    };

                    try w.print("{t: >5}", .{symbol.type.base_type});
                    if (switch (symbol.type.complex_type) {
                        .NULL => "  ",
                        .POINTER => "* ",
                        .FUNCTION => "()",
                        .ARRAY => "[]",
                        else => null,
                    }) |suffix| try w.writeAll(suffix) else try w.print("{x}", .{symbol.type.complex_type});

                    try w.print("{t: >16} | {s}\n", .{ symbol.storage_class, name });

                    for (0..symbol.number_of_aux_symbols) |aux_i| {
                        _ = aux_i;
                        try w.writeAll("   |");

                        if (symbol.storage_class == .EXTERNAL and
                            symbol.type == std.coff.SymType{
                                .complex_type = .FUNCTION,
                                .base_type = .NULL,
                            } and
                            @backingInt(symbol.section_number) > 0)
                        {
                            try w.writeAll("TODO function aux symbol");
                        } else if (symbol.type == std.coff.SymType{
                            .complex_type = .FUNCTION,
                            .base_type = .NULL,
                        } and
                            (std.mem.eql(u8, name, ".bf") or std.mem.eql(u8, name, ".ef")))
                        {
                            try w.writeAll("TODO bf / ef aux symbol");
                        } else if (symbol.storage_class == .WEAK_EXTERNAL and symbol.section_number == .UNDEFINED) {
                            if (symbol.value != 0)
                                return d.failParse(
                                    "invalid value 0x{x} for weak external symbol 0x{x}",
                                    .{ symbol.value, symbol_i },
                                );

                            var weak_external: std.coff.WeakExternalDefinition = undefined;
                            @memcpy(std.mem.asBytes(&weak_external)[0..symbol_size], aux_symbols[0..symbol_size]);
                            if (native_endian != .little)
                                std.mem.byteSwapAllFields(std.coff.WeakExternalDefinition, &weak_external);

                            if (weak_external.tag_index >= header.number_of_symbols)
                                return d.failParse(
                                    "invalid tag_index 0x{x} for weak external symbol 0x{x}",
                                    .{ weak_external.tag_index, symbol_i },
                                );

                            if (d.redacted(.ord))
                                try w.print("  Weak External [falls back to relative ordinal {x:0>8} via {t}]", .{
                                    @as(i64, weak_external.tag_index) - symbol_i,
                                    weak_external.flag,
                                })
                            else
                                try w.print("  Weak External [falls back to ordinal {x:0>8} via {t}]", .{
                                    weak_external.tag_index,
                                    weak_external.flag,
                                });
                        } else if (symbol.storage_class == .FILE) {
                            if (!std.mem.eql(u8, name, ".file")) {
                                try w.print(" !! unexpected symbol name '{s}' for file symbol 0x{x}", .{ name, symbol_i });
                                continue;
                            }

                            const filename = std.mem.sliceTo(aux_symbols, 0);
                            try w.print("     File       '{s}'", .{filename});
                            break;
                        } else if (symbol.storage_class == .STATIC and
                            symbol.type == std.coff.SymType{
                                .complex_type = .NULL,
                                .base_type = .NULL,
                            } and
                            symbol.value == 0 and
                            switch (symbol.section_number) {
                                .UNDEFINED, .DEBUG, .ABSOLUTE => false,
                                else => |sn| @backingInt(sn) > 0,
                            })
                        {
                            const section_i: u15 = @intCast(@backingInt(symbol.section_number) - 1);
                            try w.writeAll("  Section ");

                            if (section_i >= sections.items.len) {
                                try w.print(" !! invalid section number: {x}", .{section_i});
                                continue;
                            }

                            var section_def: std.coff.SectionDefinition = undefined;
                            @memcpy(std.mem.asBytes(&section_def)[0..symbol_size], aux_symbols[0..symbol_size]);
                            if (native_endian != .little)
                                std.mem.byteSwapAllFields(std.coff.SectionDefinition, &section_def);

                            const section = &sections.items[section_i];
                            if (section_def.number_of_relocations != section.header.number_of_relocations) {
                                try w.print(
                                    " !! relocation count did not match section header: {d} vs {d}",
                                    .{ section_def.number_of_relocations, section.header.number_of_relocations },
                                );
                                continue;
                            }

                            if (section_def.number_of_linenumbers != section.header.number_of_linenumbers) {
                                try w.print(
                                    " !! line number count did not match section header: {d} vs {d}",
                                    .{ section_def.number_of_linenumbers, section.header.number_of_linenumbers },
                                );
                                continue;
                            }

                            try w.print("      [size {f} chksum {x:0>8} relocs {x:0>4} lines {x:0>4}]", .{
                                fmtIntField(d, section_def.length, .{ .kind = .size, .zero_fill = true }),
                                section_def.checksum,
                                section_def.number_of_relocations,
                                section_def.number_of_linenumbers,
                            });

                            switch (section_def.selection) {
                                .NONE => {},
                                else => |selection| {
                                    try w.print(" COMDAT({t}", .{selection});
                                    if (selection == .ASSOCIATIVE)
                                        try w.print("->{x}", .{section_def.number});
                                    try w.writeAll(")");
                                },
                            }
                        }

                        try w.writeByte('\n');
                    }
                }

                if (d.opts.symbols and d.element(.newlines)) try w.writeByte('\n');
            } else if (d.opts.symbols) {
                try w.writeAll("No symbol table found\n");
            }
        }

        if (d.opts.relocs) {
            const relocation_size = std.coff.Relocation.sizeOf();

            for (sections.items, 0..) |section, section_i| {
                if (section.header.pointer_to_relocations == 0) continue;

                if (d.element(.@"table-header"))
                    try w.print(
                        \\Relocs for section {x} '{s}' in {s}:
                        \\  Offset Type                Symbol -> Sect   Name
                        \\
                    , .{ section_i + 1, section.name, obj_name });

                fr.seekTo(file_location + section.header.pointer_to_relocations) catch |err|
                    return d.failParse("unable to seek to section {x} relocation table: {t}", .{ section_i + 1, err });

                for (0..section.header.number_of_relocations) |reloc_i| {
                    var reloc: std.coff.Relocation = undefined;
                    @memcpy(std.mem.asBytes(&reloc)[0..relocation_size], try r.take(relocation_size));
                    if (native_endian != .little)
                        std.mem.byteSwapAllFields(std.coff.Relocation, &reloc);

                    const sym = &symbols.items[reloc.symbol_table_index];
                    if (!filterMatches(d.opts.symbol_filters, sym.name))
                        continue;

                    try w.print("{f} ", .{
                        fmtIntField(d, reloc.virtual_address, .{ .kind = .va, .zero_fill = true }),
                    });
                    switch (header.machine) {
                        _ => unreachable,
                        inline else => |m| switch (m.RelocationType()) {
                            void => try w.writeAll("(unknown arch)"),
                            else => |RelocationType| try w.print(
                                "{t: <17} ",
                                .{@as(RelocationType, @fromBackingInt(@intCast(reloc.type)))},
                            ),
                        },
                    }

                    if (reloc.symbol_table_index >= symbols.items.len)
                        return d.failParse(
                            "reloc {x} in section {x} has out-of-bounds symbol index {x}",
                            .{ reloc_i, section_i + 1, reloc.symbol_table_index },
                        );

                    try w.print("{f}   {f} | {s}\n", .{
                        fmtIntField(d, reloc.symbol_table_index, .{ .kind = .ord }),
                        fmtSectionNumber(sym.section_number),
                        sym.name,
                    });
                }
                if (d.element(.newlines)) try w.writeByte('\n');
            }
        }

        // Sections indices with raw data, sorted by RVA
        const rva_index = if (needs_data_dirs) rva_index: {
            const rva_index = try gpa.alloc(u16, sections_with_data);
            var indices_i: u16 = 0;
            for (sections.items, 0..) |*section, i| {
                if (section.header.size_of_raw_data == 0) continue;
                rva_index[indices_i] = @intCast(i);
                indices_i += 1;
            }

            const Context = struct {
                indices: []u16,
                sections: []const Section,

                pub fn lessThan(ctx: @This(), lhs: usize, rhs: usize) bool {
                    return ctx.sections[ctx.indices[lhs]].header.virtual_address <
                        ctx.sections[ctx.indices[rhs]].header.virtual_address;
                }

                pub fn swap(ctx: @This(), lhs: usize, rhs: usize) void {
                    std.mem.swap(u16, &ctx.indices[lhs], &ctx.indices[rhs]);
                }
            };

            std.sort.pdqContext(0, rva_index.len, Context{
                .indices = rva_index,
                .sections = sections.items,
            });

            break :rva_index rva_index;
        } else &.{};
        defer gpa.free(rva_index);

        if (d.opts.exports) exports: {
            if (try seekToDataDirectory(
                d,
                rva_index,
                sections.items,
                (image_info orelse {
                    try w.writeAll("COFF objects do not contain an export data directory");
                    break :exports;
                }).data_dirs,
                .EXPORT,
            )) |section_index| {
                const export_dir = r.takeStruct(std.coff.ExportDirectoryTable, .little) catch |err|
                    return d.failParse("unable to read export directory: {t}", .{err});

                try w.print("Export directory:\n", .{});
                try dumpHeader(d, std.coff.ExportDirectoryTable, &export_dir, struct {
                    pub fn major_version(id: *const DumpContext, h: *const std.coff.ExportDirectoryTable) !void {
                        try dumpVersionField(id.w, "version", h.major_version, h.minor_version);
                    }
                    pub fn minor_version(_: *const DumpContext, _: *const std.coff.ExportDirectoryTable) !void {}
                });

                const section = sections.items[section_index];
                const name_loc = section.rvaFileOffset(export_dir.name_rva) catch
                    return d.failParse(
                        "export name rva 0x{x} was not within the export section",
                        .{export_dir.name_rva},
                    );

                const eat_loc = section.rvaFileOffset(export_dir.export_address_table_rva) catch
                    return d.failParse(
                        "export address table rva 0x{x} was not within the export section",
                        .{export_dir.export_address_table_rva},
                    );

                const name_pointer_loc = section.rvaFileOffset(export_dir.name_pointer_table_rva) catch
                    return d.failParse(
                        "export name pointer table rva 0x{x} was not within the export section",
                        .{export_dir.name_pointer_table_rva},
                    );

                const ord_loc = section.rvaFileOffset(export_dir.ordinal_table_rva) catch
                    return d.failParse(
                        "export ordinal table rva 0x{x} was not within the export section",
                        .{export_dir.ordinal_table_rva},
                    );

                // All the variable length fields should be contained within this directory.
                // Read it entirely to avoid needing to seek per-name when iterating.
                const dir = image_info.?.data_dirs[@backingInt(DIRECTORY_ENTRY.EXPORT)];
                const dir_end_rva = dir.virtual_address + dir.size;
                const dir_loc = fr.logicalPos();
                const dir_slice = try r.readAlloc(gpa, dir.size);
                defer gpa.free(dir_slice);

                const dll_name = std.mem.sliceTo(dir_slice[name_loc - dir_loc ..], 0);
                if (d.element(.@"table-header"))
                    try w.print(
                        \\
                        \\Exports from {s}:
                        \\ Ord Hint      RVA   Name
                        \\
                    , .{dll_name});

                const name_pointers = dir_slice[name_pointer_loc - dir_loc ..][0 .. export_dir.number_of_names * @sizeOf(u32)];
                const ords = dir_slice[ord_loc - dir_loc ..][0 .. export_dir.number_of_names * @sizeOf(u16)];
                const addrs = dir_slice[eat_loc - dir_loc ..][0 .. export_dir.number_of_entries * @sizeOf(u32)];
                const name_rva_to_offset = dir.virtual_address + @sizeOf(std.coff.ExportDirectoryTable);
                for (0..export_dir.number_of_names) |name_i| {
                    const name_rva = std.mem.readInt(u32, name_pointers[name_i * @sizeOf(u32) ..][0..@sizeOf(u32)], .little);
                    const name = std.mem.sliceTo(dir_slice[name_rva - name_rva_to_offset ..], 0);
                    if (!filterMatches(d.opts.symbol_filters, name))
                        continue;

                    const ord = std.mem.readInt(u16, ords[name_i * @sizeOf(u16) ..][0..@sizeOf(u16)], .little);
                    const addr = std.mem.readInt(u32, addrs[@as(u32, ord) * @sizeOf(u32) ..][0..@sizeOf(u32)], .little);

                    try w.print("{f} {f} ", .{
                        fmtIntField(d, @as(u16, @intCast(export_dir.ordinal_base + ord)), .{ .kind = .ord }),
                        fmtIntField(d, @as(u16, @intCast(name_i)), .{ .kind = .ord }),
                    });
                    const is_forwarder = addr >= dir.virtual_address and addr < dir_end_rva;
                    if (is_forwarder) {
                        try w.writeAll("forwards");
                    } else {
                        try w.print("{f}", .{fmtIntField(d, addr, .{ .kind = .rva })});
                    }

                    try w.print(" | {s}", .{name});
                    if (is_forwarder)
                        try w.print(" -> {s}", .{std.mem.sliceTo(dir_slice[addr - name_rva_to_offset ..], 0)});
                    try w.writeByte('\n');
                }
            }
        }

        if (d.opts.imports) imports: {
            if (try seekToDataDirectory(
                d,
                rva_index,
                sections.items,
                (image_info orelse {
                    try w.writeAll("COFF objects do not contain an import data directory");
                    break :imports;
                }).data_dirs,
                .IMPORT,
            )) |_| {
                const Entry = std.coff.ImportDirectoryEntry;
                var directory_entries: std.ArrayList(Entry) = .empty;
                defer directory_entries.deinit(gpa);
                while (true) {
                    const entry = r.takeStruct(Entry, .little) catch |err|
                        return d.failParse(
                            "unable to read import directory entry {x}: {t}",
                            .{ directory_entries.items.len, err },
                        );

                    if (std.mem.allEqual(u8, std.mem.asBytes(&entry), 0)) break;
                    (try directory_entries.addOne(gpa)).* = entry;
                }

                for (directory_entries.items) |entry| {
                    const name_section = sectionContainingRva(
                        rva_index,
                        sections.items,
                        entry.name_rva,
                    ) orelse
                        return d.failParse(
                            "import directory entry name rva 0x{x} was not found in any section",
                            .{entry.name_rva},
                        );

                    const name_loc = sections.items[name_section].rvaFileOffset(
                        entry.name_rva,
                    ) catch unreachable;
                    fr.seekTo(name_loc) catch |err|
                        return d.failParse(
                            "unable to seek to import directory entry name at 0x{x}: {t}",
                            .{ name_loc, err },
                        );

                    const dll_name = (try r.takeDelimiter(0)).?;

                    if (d.element(.@"header-name"))
                        try w.print("Import table entry for {s}:\n", .{dll_name});
                    try dumpHeader(d, Entry, &entry, struct {});

                    if (d.element(.@"table-header"))
                        try w.print(
                            \\
                            \\ Ord Hint   Name
                            \\
                        , .{});

                    const ilt_section = sectionContainingRva(
                        rva_index,
                        sections.items,
                        entry.import_lookup_table_rva,
                    ) orelse
                        return d.failParse(
                            "import directory entry ilt rva 0x{x} was not found in any section",
                            .{entry.import_lookup_table_rva},
                        );

                    const ilt_loc = sections.items[ilt_section].rvaFileOffset(
                        entry.import_lookup_table_rva,
                    ) catch unreachable;
                    fr.seekTo(ilt_loc) catch |err|
                        return d.failParse(
                            "unable to seek to import directory ilt at 0x{x}: {t}",
                            .{ ilt_loc, err },
                        );

                    switch (image_info.?.magic) {
                        _ => try w.writeAll("(unknown magic)"),
                        inline else => |m| {
                            const TableEntry = std.coff.ImportLookupTableEntry(m);
                            const null_entry: TableEntry = @bitCast(@as(@typeInfo(TableEntry).@"struct".backing_integer.?, 0));

                            var ilt_entries: std.ArrayList(TableEntry) = .empty;
                            defer ilt_entries.deinit(gpa);
                            while (true) {
                                const table_entry = r.takeStruct(TableEntry, .little) catch |err|
                                    return d.failParse(
                                        "unable to read ilt entry {s}:{x}: {t}",
                                        .{ dll_name, ilt_entries.items.len, err },
                                    );
                                if (table_entry == null_entry) break;
                                (try ilt_entries.addOne(gpa)).* = table_entry;
                            }

                            for (ilt_entries.items, 0..) |ilt_entry, ilt_entry_i| {
                                if (ilt_entry.is_ordinal) {
                                    try w.print("{x: >4}", .{ilt_entry.payload.ordinal.ordinal});
                                } else {
                                    const hint_section = sectionContainingRva(
                                        rva_index,
                                        sections.items,
                                        ilt_entry.payload.hint_name_rva,
                                    ) orelse
                                        return d.failParse(
                                            "import directory ilt entry 0x{x}'s hint rva 0x{x} was not found in any section",
                                            .{ ilt_entry_i, ilt_entry.payload.hint_name_rva },
                                        );

                                    const hint_loc = sections.items[hint_section].rvaFileOffset(
                                        ilt_entry.payload.hint_name_rva,
                                    ) catch unreachable;
                                    fr.seekTo(hint_loc) catch |err|
                                        return d.failParse(
                                            "unable to seek to ilt entry 0x{x}'s hint at 0x{x}: {t}",
                                            .{ ilt_entry_i, hint_loc, err },
                                        );

                                    const hint = r.takeInt(u16, .little) catch |err|
                                        return d.failParse(
                                            "unable to read import directory ilt entry 0x{x}'s hint: {t}",
                                            .{ ilt_entry_i, err },
                                        );

                                    const name = r.takeDelimiter(0) catch |err|
                                        return d.failParse(
                                            "unable to read import directory ilt entry 0x{x}'s name: {t}",
                                            .{ ilt_entry_i, err },
                                        );

                                    try w.print("     {x: >4} | {s}\n", .{ hint, name.? });
                                }
                            }
                            if (d.element(.newlines)) try w.writeByte('\n');
                        },
                    }
                }
            }
        }

        if (d.opts.tls) tls: {
            if (try seekToDataDirectory(
                d,
                rva_index,
                sections.items,
                (image_info orelse {
                    try w.writeAll("COFF objects do not contain a TLS data directory");
                    break :tls;
                }).data_dirs,
                .TLS,
            )) |_| {
                switch (image_info.?.magic) {
                    _ => try w.writeAll("(unknown magic)"),
                    inline else => |m| {
                        const TlsDirectoryEntry = std.coff.TlsDirectoryEntry(m);
                        const tls_entry = r.takeStruct(TlsDirectoryEntry, .little) catch |err|
                            return d.failParse("unable to read tls directory: {t}", .{err});

                        try w.writeAll("TLS Directory:\n");
                        try dumpHeader(d, TlsDirectoryEntry, &tls_entry, struct {});

                        try w.writeAll("               | ");
                        if (tls_entry.characteristics.alignment == .NONE) {
                            try w.writeAll("Alignment not specified");
                        } else {
                            try w.print(
                                "Alignment: {d}",
                                .{tls_entry.characteristics.alignment.toByteUnits().?},
                            );
                        }

                        try w.writeAll(
                            \\
                            \\
                            \\TLS Callbacks:
                            \\         Address
                            \\
                        );

                        const callbacks_rva: u32 = @intCast(tls_entry.callbacks_va - image_info.?.image_base);
                        const section_index = sectionContainingRva(
                            rva_index,
                            sections.items,
                            callbacks_rva,
                        ) orelse
                            return d.failParse(
                                "tls callbacks rva 0x{x} was not found in any section",
                                .{callbacks_rva},
                            );

                        const callbacks_loc = sections.items[section_index]
                            .rvaFileOffset(callbacks_rva) catch unreachable;

                        fr.seekTo(callbacks_loc) catch |err|
                            return d.failParse(
                                "unable to seek to tls callbacks array at offset 0x{x}: {t}",
                                .{ callbacks_loc, err },
                            );

                        while (true) {
                            const callback_va = r.takeInt(@FieldType(TlsDirectoryEntry, "callbacks_va"), .little) catch |err|
                                return d.failParse(
                                    "unable to read tls callbacks array: {t}",
                                    .{err},
                                );

                            try w.print("{f}\n", .{fmtIntField(d, callback_va, .{ .kind = .va })});
                            if (callback_va == 0) break;
                        }
                        if (d.element(.newlines)) try w.writeByte('\n');
                    },
                }
            }
        }
    }

    fn seekToDataDirectory(
        d: *const DumpContext,
        rva_index: []const u16,
        sections: []const Section,
        data_dirs: []const std.coff.ImageDataDirectory,
        entry: DIRECTORY_ENTRY,
    ) !?u16 {
        if (@backingInt(entry) < data_dirs.len) blk: {
            const rva = data_dirs[@backingInt(entry)].virtual_address;
            if (rva == 0) break :blk;

            const section_index = sectionContainingRva(rva_index, sections, rva) orelse
                return d.failParse(
                    "{t} directory rva 0x{x} was not found in any section",
                    .{ entry, rva },
                );

            const file_offset = sections[section_index].rvaFileOffset(rva) catch unreachable;
            d.fr.seekTo(file_offset) catch |err|
                return d.failParse(
                    "unable to seek to {t} directory at offset 0x{x}: {t}",
                    .{ entry, file_offset, err },
                );

            return section_index;
        }

        try d.w.print("{t} directory was not present in optional header\n", .{entry});
        return null;
    }

    fn sectionContainingRva(
        /// Indices into `sections` sorted by rva
        indices: []const u16,
        sections: []const Section,
        rva: u32,
    ) ?u16 {
        const Context = struct {
            rva: u32,
            sections: []const Section,

            fn order(ctx: @This(), section_index: u16) std.math.Order {
                const h = &ctx.sections[section_index].header;
                if (ctx.rva < h.virtual_address) return .lt;
                const end = h.virtual_address + h.size_of_raw_data;
                if (ctx.rva >= end) return .gt;
                return .eq;
            }
        };

        const indices_index = std.sort.binarySearch(u16, indices, Context{
            .rva = rva,
            .sections = sections,
        }, Context.order) orelse return null;
        return @intCast(indices[indices_index]);
    }

    fn headerName(raw: *const [8]u8, string_table: []const u8) ![]const u8 {
        return if (raw[0] == '/') name: {
            const name_offset = try std.fmt.parseUnsigned(u24, std.mem.sliceTo(raw[1..], 0), 10);
            if (name_offset >= string_table.len)
                return error.OutOfBounds;

            break :name std.mem.sliceTo(string_table[name_offset..], 0);
        } else std.mem.sliceTo(raw, 0);
    }

    fn fmtSectionNumber(section_number: std.coff.SectionNumber) std.fmt.Alt(std.coff.SectionNumber, sectionNumberString) {
        return .{ .data = section_number };
    }

    fn sectionNumberString(section_number: std.coff.SectionNumber, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try switch (section_number) {
            .UNDEFINED => w.writeAll("UNDEF"),
            .ABSOLUTE => w.writeAll("  ABS"),
            .DEBUG => w.writeAll("DEBUG"),
            else => |v| {
                const backing = @backingInt(v);
                const fmt = "{x: >5}";
                if (backing >= 0)
                    try w.print(fmt, .{@as(u15, @intCast(backing))})
                else
                    try w.print(fmt, .{backing});
            },
        };
    }

    const FormatIntField = struct {
        val: ?u64,
        width: ?usize,
        zero_fill: bool,
    };

    fn fmtIntField(
        d: *const DumpContext,
        val: anytype,
        params: struct {
            kind: ?FieldKind = null,
            width: union(enum) {
                fit_max,
                auto,
                explicit: usize,
            } = .fit_max,
            zero_fill: bool = false,
        },
    ) std.fmt.Alt(FormatIntField, intFieldString) {
        return .{
            .data = .{
                .val = if (d.redacted(params.kind)) null else val,
                .width = switch (params.width) {
                    .fit_max => @typeInfo(@TypeOf(val)).int.bits / 4,
                    .auto => null,
                    .explicit => |w| w,
                },
                .zero_fill = params.zero_fill,
            },
        };
    }

    fn intFieldString(field: FormatIntField, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (field.val) |val| {
            try w.printInt(val, 16, .lower, .{
                .width = field.width,
                .alignment = .right,
                .fill = if (field.zero_fill) '0' else ' ',
            });
        } else try w.splatByteAll('x', field.width orelse 1);
    }

    fn dumpFlags(w: *Io.Writer, comptime fmt: []const u8, comptime T: type, flags: *const T, cols: u32) !void {
        const s = @typeInfo(T).@"struct";
        inline for (s.field_names, s.field_types) |field_name, field_type| {
            if (field_type == bool and @field(flags, field_name)) {
                try w.splatByteAll(' ', cols);
                try w.print(fmt, .{field_name});
            }
        }
    }

    fn dumpArchiveHeader(d: *const DumpContext, header: *const ArchiveHeader, pos: u32) !void {
        if (d.element(.@"header-name"))
            try d.w.print("Archive member at offset 0x{x}: '{s}'\n", .{ pos, header.name });
        try dumpHeader(d, ArchiveHeader, header, struct {
            pub fn name(_: *const DumpContext, _: *const ArchiveHeader) !void {}
            pub fn file_mode(id: *const DumpContext, h: *const ArchiveHeader) !void {
                try id.w.print("{o: >16} file_mode\n", .{h.file_mode});
            }
        });
    }

    fn fieldKind(name: []const u8) ?FieldKind {
        if (std.mem.endsWith(u8, name, "_rva"))
            return .rva;
        if (std.mem.endsWith(u8, name, "_va") or
            std.mem.endsWith(u8, name, "_address") or
            std.mem.startsWith(u8, name, "pointer_"))
            return .va;
        if (std.mem.startsWith(u8, name, "number_") or
            std.mem.startsWith(u8, name, "size"))
            return .size;
        if (std.mem.startsWith(u8, name, "hint"))
            return .ord;
        return null;
    }

    fn dumpHeader(
        d: *const DumpContext,
        comptime T: type,
        header: *const T,
        Custom: type,
    ) !void {
        const s = @typeInfo(T).@"struct";
        inline for (s.field_names, s.field_types) |field_name, field_type| {
            const val = &@field(header, field_name);
            if (@hasDecl(Custom, field_name)) {
                try @field(Custom, field_name)(d, header);
            } else {
                switch (@typeInfo(field_type)) {
                    .int => try d.w.print("{f} {s}\n", .{ fmtIntField(d, val.*, .{
                        .kind = comptime fieldKind(field_name),
                        .width = .{ .explicit = 16 },
                    }), field_name }),
                    .@"enum" => try d.w.print("{x: >16} {s} ({t})\n", .{ val.*, field_name, val.* }),
                    .@"struct" => |s_field| {
                        switch (s_field.layout) {
                            .auto,
                            .@"extern",
                            => try dumpHeader(d, field_type, val, Custom),
                            .@"packed" => {
                                try d.w.print("{x: >16} {s}\n", .{ @as(s_field.backing_integer.?, @bitCast(val.*)), field_name });
                                try dumpFlags(d.w, "| {s}\n", field_type, val, 15);
                            },
                        }
                    },
                    else => unreachable,
                }
            }
        }
    }

    fn dumpVersionField(w: *Io.Writer, name: []const u8, major: anytype, minor: anytype) !void {
        try w.print("{d: >13}.{x:0<2} {s}\n", .{ major, minor, name });
    }

    fn dumpRvaField(d: *const DumpContext, name: []const u8, rva: u64, base: u64) !void {
        try d.w.print("{f} {s} ({f})\n", .{
            fmtIntField(d, rva, .{ .kind = .rva }),
            name,
            fmtIntField(d, base + rva, .{ .kind = .va }),
        });
    }
};

fn filterMatches(filters: []const []const u8, val: []const u8) bool {
    return for (filters) |filter| {
        if (std.mem.containsAtLeast(u8, val, 1, filter)) break true;
    } else filters.len == 0;
}

const usage =
    \\Usage: Sig objdump [options] file
    \\
    \\Options:
    \\  -h, --help                         Print this help and exit
    \\  --all-headers                      Alias for --file-headers --linker-member=2 --member-headers --section-headers --relocs --symbols --program-headers --dynamic
    \\  --exports[=sort]                   Display exported symbols. 
    \\                                     In the case of COFF import libraries, displays the symbol list and import headers.
    \\                                     Specify =sort to optionally sort the import headers by symbol name.
    \\  --file-headers                     Display file-format specific headers
    \\  --imports                          Display imported symbols
    \\  --linker-member[=1|2|longnames]    (Coff) Display contents of the specified archive linker member (default 2)
    \\  --member-headers                   Display archive member headers
    \\  --elements=[e1],[e2],-[e3],...     Select which formatting elements are displayed. Intended for snapshot testing.
    \\      file-type                      File type summary
    \\      header-name                    Name that precedes a header block     
    \\      member-path                    Display full member paths. If removed, only basenames will be used.
    \\      newlines                       Newlines between output sections
    \\      table-header                   Table headers with column names
    \\      all                            (default) All of the above
    \\  --only-member=[name]               Only consider archive members names that contain [name]. Can be specified multiple times.
    \\  --only-section=[name]              Only consider section names that contain [name]. Can be specified multiple times.
    \\  --only-symbol=[name]               Only consider symbol names that contain [name]. Can be specified multiple times.
    \\  --redact=[kind]                    Redact the specified field kind. Intended for snapshot testing.
    \\      rva                            Relative virtual addresses
    \\      va                             Virtual addresses and file offsets
    \\      ord                            Symbol ordinals / hints
    \\      size                           Sizes and lengths
    \\      all                            All of the above
    \\  --relocs                           Display relocations
    \\  --dynamic-relocs                   (Elf) Display dynamic relocations
    \\  -s, --snapshot                     Alias for --redact=all --elements=-all
    \\  --section-headers                  Display section headers
    \\  --program-headers, --segments      (Elf) Display program headers / segments
    \\  --dynamic                          (Elf) Display the dynamic section
    \\  --dynamic-symbols                  (Elf) Display the dynamic symbol table
    \\  --summary                          (Elf) Print a one-line machine-parseable file summary
    \\  --strings                          Display string tables
    \\  --symbols                          Display symbol tables
    \\  --tls                              Display TLS information
    \\  -d, --disassemble                  Disassemble executable sections (sBPF only; other
    \\                                     machines print 'disassembly not implemented for <machine>')
    \\  --disassemble-all                  Disassemble all sections (sBPF only)
    \\  --disassemble=[symbol]             Disassemble only the named symbol (sBPF only)
    \\
;

test "murmur3_32 reference immediates" {
    // Pins the from-scratch murmur3_32 against the Solana static-syscall registry
    // reference immediates (SIMD-0178; same vectors as src/codegen/llvm.sig's
    // pinning test). These are the 32-bit keys an sBPF `call` immediate carries.
    const expect = std.testing.expectEqual;
    try expect(@as(u32, 0x207559bd), disasm.murmur3_32("sol_log_"));
    try expect(@as(u32, 0x717cc4a3), disasm.murmur3_32("sol_memcpy_"));
    try expect(@as(u32, 0x11f49d86), disasm.murmur3_32("sol_sha256"));
    try expect(@as(u32, 0xb6fc1a11), disasm.murmur3_32("abort"));
    try expect(@as(u32, 0x48504a38), disasm.murmur3_32("sol_try_find_program_address"));
    try expect(@as(u32, 0xd56b5fe9), disasm.murmur3_32("sol_get_clock_sysvar"));
    try expect(@as(u32, 0x00000000), disasm.murmur3_32(""));
}

test "sBPF decodeOne" {
    // Hand-encoded sBPF instructions (eBPF 64-bit little-endian layout:
    // opcode:u8, regs:u8 [low nibble dst, high nibble src], off:i16, imm:i32).
    // Opcodes follow the authoritative Solana sBPF table
    // (anza-xyz/sbpf doc/bytecode.md): ALU64 mov=0xb7/0xbf, add=0x07,
    // LDX ldxdw=0x79, lddw=0x18 (16-byte pair), call=0x85, exit=0x95.
    const expectEqualStrings = std.testing.expectEqualStrings;
    const expectEqual = std.testing.expectEqual;

    // A real syscall table so `call 0x207559bd` resolves to <sol_log_>; no
    // symbols needed for these cases.
    const ann: disasm.Annotator = .{
        .syms = &.{},
        .syscalls = disasm.syscalls,
        .machine = .BPF,
    };

    const Case = struct {
        code: []const u8,
        want: []const u8,
        stride: usize,
    };

    const cases = [_]Case{
        // mov r0, 0x2a  (ALU64 mov, immediate; opcode 0xb7, dst=r0)
        .{ .code = &.{ 0xb7, 0x00, 0x00, 0x00, 0x2a, 0x00, 0x00, 0x00 }, .want = "mov r0, 0x2a", .stride = 8 },
        // mov r0, r1    (ALU64 mov, src register; opcode 0xbf, dst=r0, src=r1)
        .{ .code = &.{ 0xbf, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, .want = "mov r0, r1", .stride = 8 },
        // add r1, 0x10  (ALU64 add, immediate; opcode 0x07, dst=r1)
        .{ .code = &.{ 0x07, 0x01, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00 }, .want = "add r1, 0x10", .stride = 8 },
        // ldxdw r0, [r1+0x8]  (LDX dw; opcode 0x79, dst=r0, src=r1, off=+8)
        .{ .code = &.{ 0x79, 0x10, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00 }, .want = "ldxdw r0, [r1+0x8]", .stride = 8 },
        // call 0x207559bd  (opcode 0x85, src=0 static syscall; imm == murmur3(sol_log_))
        .{ .code = &.{ 0x85, 0x00, 0x00, 0x00, 0xbd, 0x59, 0x75, 0x20 }, .want = "call 0x207559bd <sol_log_>", .stride = 8 },
        // exit  (opcode 0x95)
        .{ .code = &.{ 0x95, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, .want = "exit", .stride = 8 },
        // lddw r0, 0x1  (opcode 0x18, 16-byte pair; lo imm in bytes 4..8, hi in 12..16)
        .{ .code = &.{ 0x18, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, .want = "lddw r0, 0x1", .stride = 16 },
    };

    for (cases) |c| {
        var buf: [128]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        const stride = try disasm.decodeOne(c.code, 0, &ann, &w);
        try expectEqual(c.stride, stride);
        try expectEqualStrings(c.want, w.buffered());
    }

    // A short tail must be rejected before any out-of-bounds slice: emit
    // <truncated> plus the raw bytes and return error.ParseFailure.
    {
        var buf: [128]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try std.testing.expectError(error.ParseFailure, disasm.decodeOne(&.{ 0x95, 0x00 }, 0, &ann, &w));
        try expectEqualStrings("<truncated> 95 00", w.buffered());
    }
}
