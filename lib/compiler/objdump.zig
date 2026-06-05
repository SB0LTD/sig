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
    file_headers: bool,
    imports: bool,
    input_path: []const u8,
    member_filters: []const []const u8 = &.{},
    member_headers: bool,
    relocs: bool,
    section_filters: []const []const u8 = &.{},
    section_headers: bool,
    strings: bool,
    symbols: bool,
    tls: bool,

    // Coff-specific
    linker_member: ?std.coff.ArchiveMemberHeader.Kind,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const arena = init.arena.allocator();

    var i: usize = 1;

    var opt_exports: ?bool = null;
    var opt_file_headers: ?bool = null;
    var opt_imports: ?bool = null;
    var opt_input_path: ?[]const u8 = null;
    var opt_linker_member: ?std.coff.ArchiveMemberHeader.Kind = null;
    var opt_member_headers: ?bool = null;
    var opt_relocs: ?bool = null;
    var opt_section_headers: ?bool = null;
    var opt_strings: ?bool = null;
    var opt_symbols: ?bool = null;
    var opt_tls: ?bool = null;
    var section_filters: std.ArrayList([]const u8) = .empty;
    var member_filters: std.ArrayList([]const u8) = .empty;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (mem.startsWith(u8, arg, "-")) {
            if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
                return Io.File.stdout().writeStreamingAll(io, usage);
            } else if (mem.eql(u8, arg, "--all-headers")) {
                opt_file_headers = true;
                opt_member_headers = true;
                opt_section_headers = true;
                opt_symbols = true;
                opt_relocs = true;
            } else if (mem.eql(u8, arg, "--exports")) {
                opt_exports = true;
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
            } else if (mem.startsWith(u8, arg, "--only-section=")) {
                (try section_filters.addOne(arena)).* = try arena.dupe(u8, arg["--only-section=".len..]);
            } else if (mem.startsWith(u8, arg, "--only-member=")) {
                (try member_filters.addOne(arena)).* = try arena.dupe(u8, arg["--only-member=".len..]);
            } else if (mem.eql(u8, arg, "--relocs")) {
                opt_relocs = true;
            } else if (mem.eql(u8, arg, "--section-headers")) {
                opt_section_headers = true;
            } else if (mem.eql(u8, arg, "--strings")) {
                opt_strings = true;
            } else if (mem.eql(u8, arg, "--symbols")) {
                opt_symbols = true;
            } else if (mem.eql(u8, arg, "--tls")) {
                opt_tls = true;
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
        .file_headers = opt_file_headers orelse false,
        .imports = opt_imports orelse false,
        .linker_member = opt_linker_member,
        .member_filters = member_filters.items,
        .member_headers = opt_member_headers orelse false,
        .section_filters = section_filters.items,
        .section_headers = opt_section_headers orelse false,
        .relocs = opt_relocs orelse false,
        .strings = opt_strings orelse false,
        .symbols = opt_symbols orelse false,
        .tls = opt_tls orelse false,
    };

    var file = std.Io.Dir.cwd().openFile(io, opts.input_path, .{}) catch |err|
        fatal("failed to open {s}: {t}", .{ opts.input_path, err });
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    dump(init.gpa, &opts, &file_reader, &stdout_writer.interface) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
        error.WriteFailed => return stdout_writer.err.?,
        error.UnknownFile => fatal("unrecognized file: {s}", .{opts.input_path}),
        error.ParseFailure => {},
        else => |e| return e,
    };
    try stdout_writer.flush();
}

fn dump(gpa: std.mem.Allocator, opts: *const Options, fr: *Io.File.Reader, w: *Io.Writer) !void {
    const r = &fr.interface;
    try r.fill(4);
    elf: {
        if (!mem.eql(u8, r.buffered()[0..4], std.elf.MAGIC)) break :elf;
        return elf.dump(r, w);
    }
    macho: {
        if (mem.readInt(u32, r.buffered()[0..4], .little) != std.macho.MH_MAGIC_64) break :macho;
        return macho.dump(r, w);
    }
    wasm: {
        comptime assert(std.wasm.magic.len == 4);
        if (!mem.eql(u8, r.buffered()[0..4], &std.wasm.magic)) break :wasm;
        return wasm.dump(r, w);
    }
    coff: {
        const ext = std.fs.path.extension(opts.input_path);
        const basename = std.fs.path.basename(opts.input_path);
        if (std.mem.eql(u8, ext, ".exe") or std.mem.eql(u8, ext, ".dll")) {
            if (!mem.eql(u8, r.buffered()[0..2], "MZ")) break :coff;
            try r.discardAll(std.coff.pe_pointer_offset);
            const sig_offset = try r.takeInt(u32, .little);
            try fr.seekTo(sig_offset);
            const sig = try r.take(4);

            if (!std.mem.eql(u8, sig, std.coff.pe_signature)) {
                try w.print("invalid PE signature: {x}", .{sig});
                return error.ParseFailure;
            }

            try w.print("{s}: PE/COFF image\n\n", .{basename});
            return coff.dumpObject(gpa, opts, true, basename, fr, w);
        } else if (std.mem.eql(u8, ext, ".lib")) {
            r.fill(std.coff.archive_signature.len) catch break :coff;
            if (!mem.eql(u8, r.buffered()[0..std.coff.archive_signature.len], std.coff.archive_signature)) break :coff;
            try w.print("{s}: COFF archive\n\n", .{basename});
            return coff.dumpArchive(gpa, opts, fr, w);
        } else if (std.mem.eql(u8, ext, ".obj")) {
            try w.print("{s}: COFF object\n\n", .{basename});
            return coff.dumpObject(gpa, opts, false, basename, fr, w);
        }
    }
    return error.UnknownFile;
}

fn failParse(
    opts: *const Options,
    comptime fmt: []const u8,
    args: anytype,
) noreturn {
    std.log.err("error parsing '{s}'", .{std.fs.path.basename(opts.input_path)});
    fatal(fmt, args);
}

const elf = struct {
    fn dump(r: *Io.Reader, w: *Io.Writer) !void {
        _ = r;
        try w.writeAll("TODO dump elf file\n");
    }
};

const macho = struct {
    fn dump(r: *Io.Reader, w: *Io.Writer) !void {
        _ = r;
        try w.writeAll("TODO dump macho file\n");
    }
};

const wasm = struct {
    fn dump(r: *Io.Reader, w: *Io.Writer) !void {
        _ = r;
        try w.writeAll("TODO dump wasm file\n");
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

        pub fn fromRaw(opts: *const Options, raw_header: *const std.coff.ArchiveMemberHeader, opt_longnames: ?[]const u8) @This() {
            const name = raw_header.parseName(opt_longnames) catch |err| switch (err) {
                error.BadName => failParse(opts, "malformed member name: '{s}'", .{&raw_header.name}),
                error.NoLongNames => failParse(opts, "member uses a long name, but there was no longnames member", .{}),
            };

            return .{
                .name = name,
                .date = raw_header.parseDate() catch |err|
                    failParse(opts, "unable to parse date '{s}' in member '{s}': {t}", .{ raw_header.date, name, err }),
                .user_id = raw_header.parseUserId() catch |err|
                    failParse(opts, "unable to parse user_id '{s}' in member '{s}': {t}", .{ raw_header.user_id, name, err }),
                .group_id = raw_header.parseGroupId() catch |err|
                    failParse(opts, "unable to parse group_id '{s}' in member '{s}': {t}", .{ raw_header.group_id, name, err }),
                .file_mode = raw_header.parseFileMode() catch |err|
                    failParse(opts, "unable to parse file_mode '{s}' in member '{s}': {t}", .{ raw_header.file_mode, name, err }),
                .size = raw_header.parseSize() catch |err|
                    failParse(opts, "unable to parse size '{s}' in member '{s}': {t}", .{ raw_header.size, name, err }),
            };
        }
    };

    fn dumpArchive(gpa: std.mem.Allocator, opts: *const Options, fr: *Io.File.Reader, w: *Io.Writer) !void {
        const r = &fr.interface;
        r.toss(std.coff.archive_signature.len);

        var members: std.ArrayList(struct {
            offset: u32,
        }) = .empty;
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
            const header: ArchiveHeader = .fromRaw(opts, &raw_header, opt_longnames);

            if (!std.mem.eql(u8, &raw_header.end_of_header, std.coff.archive_end_of_header))
                return failParse(opts, "malformed end-of-header field in member '{s}': {x}", .{ header.name, raw_header.end_of_header });

            const dump_header =
                (opts.member_headers and filterMatches(opts.member_filters, header.name)) or
                (opts.linker_member == opt_expected_kind);

            if (dump_header)
                try dumpArchiveHeader(w, &header, @intCast(pos));

            const member_end = fr.logicalPos() + header.size;
            if (member_end > size)
                return failParse(opts, "out-of-bounds length 0x{x} in member '{s}'", .{ header.size, header.name });

            if (opt_expected_kind) |expected_kind| switch (expected_kind) {
                .first_linker => {
                    if (!std.mem.eql(u8, header.name, "/"))
                        return failParse(opts, "expected first linker member, found '{s}'", .{header.name});

                    const num_symbols = try r.takeInt(u32, .big);
                    if (dump_header)
                        try w.print(
                            \\{t: >16} type
                            \\               | {d} symbols
                            \\
                        , .{ expected_kind, num_symbols });

                    if (opts.linker_member == .first_linker) {
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
                                return failParse(opts, "unable to read first linker member string table: {t}", .{err});
                            try w.print("{x: >8} {s}\n", .{ std.mem.readInt(u32, offsets[symbol_i * 4 ..][0..4], .big), symbol.? });
                        }
                    }
                    if (dump_header) try w.writeByte('\n');

                    try fr.seekTo(member_end);
                    opt_expected_kind = .second_linker;
                    continue;
                },
                .second_linker => {
                    if (!std.mem.eql(u8, header.name, "/"))
                        return failParse(opts, "expected second linker member, found '{s}'", .{header.name});

                    const num_members = try r.takeInt(u32, .little);
                    pos = fr.logicalPos();
                    if (pos + num_members * @sizeOf(u32) > member_end)
                        return failParse(opts, "invalid member count 0x{x} in second linker member", .{num_members});

                    try members.ensureTotalCapacity(gpa, num_members);
                    for (0..num_members) |_|
                        members.addOneAssumeCapacity().* = .{
                            .offset = try r.takeInt(u32, .little),
                        };

                    const num_symbols = try r.takeInt(u32, .little);
                    pos = fr.logicalPos();
                    if (pos + num_symbols * @sizeOf(u16) > member_end)
                        return failParse(opts, "invalid symbol count 0x{x} in second linker member", .{num_symbols});

                    if (dump_header)
                        try w.print(
                            \\{t: >16} type
                            \\               | {d} symbols
                            \\               | {d} members
                            \\
                        , .{ expected_kind, num_symbols, num_members });

                    try symbol_member_indices.ensureTotalCapacity(gpa, num_symbols);
                    for (0..num_symbols) |_|
                        symbol_member_indices.addOneAssumeCapacity().* = (try r.takeInt(u16, .little)) - 1;

                    if (opts.linker_member == .second_linker) {
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
                            }) |n| n else return failParse(opts, "unterminated string found in second linker member", .{});

                            try w.print("{x: >8} {s}\n", .{
                                members.items[symbol_member_indices.items[symbol_i]].offset,
                                symbol_name,
                            });
                        }

                        if (symbol_i != num_symbols)
                            return failParse(
                                opts,
                                " expected {d} entries in second linker member string table, but found {d}",
                                .{ num_symbols, symbol_i },
                            );
                    }

                    try w.writeByte('\n');
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

                        if (opts.linker_member == .longnames) {
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
                            try w.writeByte('\n');
                        }
                    }

                    opt_expected_kind = null;
                    break;
                },
                else => unreachable,
            };
        }

        if (opt_expected_kind) |expected_kind| switch (expected_kind) {
            .first_linker => failParse(opts, "missing first linker member", .{}),
            .second_linker => failParse(opts, "missing second linker member", .{}),
            else => {},
        };

        for (members.items, 0..) |member, member_i| {
            fr.seekTo(member.offset) catch |err|
                failParse(opts, "unable to read member {d} at offset 0x{x}: {t}", .{ member_i, member.offset, err });

            const raw_header = try r.takeStruct(std.coff.ArchiveMemberHeader, .little);
            const header: ArchiveHeader = .fromRaw(opts, &raw_header, opt_longnames);
            if (!filterMatches(opts.member_filters, header.name)) continue;

            const member_sig = try r.peek(4);
            const machine: std.coff.IMAGE.FILE.MACHINE =
                @enumFromInt(std.mem.readInt(u16, member_sig[0..2], .little));
            const sig = std.mem.readInt(u16, member_sig[2..4], .little);

            const is_imp_lib = machine == std.coff.IMAGE.FILE.MACHINE.UNKNOWN and sig == 0xffff;

            if (opts.member_headers or (opts.exports and is_imp_lib)) {
                try dumpArchiveHeader(w, &header, member.offset);
                if (is_imp_lib) {
                    try w.writeAll("\nImport header:\n");

                    const imp_header = try r.takeStruct(std.coff.ImportHeader, .little);
                    try dumpHeader(w, std.coff.ImportHeader, &imp_header, struct {
                        pub fn sig1(_: *const std.coff.ImportHeader, _: *Io.Writer) !void {}
                        pub fn sig2(_: *const std.coff.ImportHeader, _: *Io.Writer) !void {}
                        pub fn types(h: *const std.coff.ImportHeader, cw: *Io.Writer) !void {
                            try cw.print(
                                \\{t: >16} import_type 
                                \\{t: >16} name_type 
                                \\
                            , .{ h.types.type, h.types.name_type });
                        }
                    });

                    const sym_name = (try r.takeDelimiter(0)).?;
                    const imp_dll = (try r.takeDelimiter(0)).?;
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
                try w.writeByte('\n');
            }

            if (opts.section_headers or
                opts.file_headers or
                opts.relocs or
                opts.strings or
                opts.symbols)
            {
                try w.print("{s}({s}): COFF object\n\n", .{ std.fs.path.basename(opts.input_path), header.name });
                try dumpObject(gpa, opts, false, header.name, fr, w);
            }
        }
    }

    fn dumpObject(
        gpa: std.mem.Allocator,
        opts: *const Options,
        is_image: bool,
        obj_name: []const u8,
        fr: *Io.File.Reader,
        w: *Io.Writer,
    ) !void {
        const file_location = fr.logicalPos();
        const r = &fr.interface;
        const header = r.takeStruct(std.coff.Header, .little) catch |err|
            return failParse(opts, "unable to read COFF header: {t}", .{err});

        if (opts.file_headers) {
            try w.writeAll("COFF Header:\n");
            try dumpHeader(w, std.coff.Header, &header, struct {});
            try w.writeByte('\n');
        }

        switch (header.machine) {
            _ => return failParse(opts, "unknown machine type: {x}", .{header.machine}),
            else => {},
        }

        var known_dirs: [DIRECTORY_ENTRY.len]std.coff.ImageDataDirectory = undefined;
        const needs_data_dirs =
            opts.exports or
            opts.imports or
            opts.tls;

        const data_dirs, const magic = if (header.size_of_optional_header > 0) optional_header: {
            if (!opts.file_headers and !needs_data_dirs) {
                try fr.seekBy(header.size_of_optional_header);
                break :optional_header .{ &.{}, null };
            }

            if (opts.file_headers) try w.writeAll("COFF Optional Header:\n");
            const magic: std.coff.OptionalHeader.Magic = @enumFromInt(try r.peekInt(u16, .little));
            const num_directory_entries = switch (magic) {
                inline .PE32, .@"PE32+" => |v| num_data_dirs: {
                    const OptionalHeader = if (v == .PE32)
                        std.coff.OptionalHeader.PE32
                    else
                        std.coff.OptionalHeader.@"PE32+";

                    const optional_header = r.takeStruct(OptionalHeader, .little) catch |err|
                        return failParse(opts, "unable to read optional header: {t}", .{err});

                    if (opts.file_headers) {
                        try dumpHeader(w, OptionalHeader, &optional_header, struct {
                            pub fn base_of_code(h: *const std.coff.OptionalHeader, cw: *Io.Writer) !void {
                                const base = @as(*const OptionalHeader, @ptrCast(@alignCast(h))).image_base;
                                try dumpRvaField(cw, @src().fn_name, h.base_of_code, base);
                            }

                            pub fn address_of_entry_point(h: *const std.coff.OptionalHeader, cw: *Io.Writer) !void {
                                const base = @as(*const OptionalHeader, @ptrCast(@alignCast(h))).image_base;
                                try dumpRvaField(cw, @src().fn_name, h.base_of_code, base);
                            }

                            pub fn major_linker_version(h: *const std.coff.OptionalHeader, cw: *Io.Writer) !void {
                                try dumpVersionField(cw, "linker_version", h.major_linker_version, h.minor_linker_version);
                            }
                            pub fn minor_linker_version(_: *const std.coff.OptionalHeader, _: *Io.Writer) !void {}

                            pub fn major_operating_system_version(h: *const OptionalHeader, cw: *Io.Writer) !void {
                                try dumpVersionField(
                                    cw,
                                    "operating_system_version",
                                    h.major_operating_system_version,
                                    h.minor_operating_system_version,
                                );
                            }
                            pub fn minor_operating_system_version(_: *const OptionalHeader, _: *Io.Writer) !void {}

                            pub fn major_image_version(h: *const OptionalHeader, cw: *Io.Writer) !void {
                                try dumpVersionField(cw, "image_version", h.major_image_version, h.minor_image_version);
                            }
                            pub fn minor_image_version(_: *const OptionalHeader, _: *Io.Writer) !void {}

                            pub fn major_subsystem_version(h: *const OptionalHeader, cw: *Io.Writer) !void {
                                try dumpVersionField(cw, "subsystem_version", h.major_subsystem_version, h.minor_subsystem_version);
                            }
                            pub fn minor_subsystem_version(_: *const OptionalHeader, _: *Io.Writer) !void {}
                        });
                        try w.writeByte('\n');
                    }

                    break :num_data_dirs optional_header.number_of_rva_and_sizes;
                },
                else => return failParse(opts, "invalid optional header magic number: {x}", .{magic}),
            };

            if (opts.file_headers) try w.writeAll("Data Directories:\n");
            for (0..num_directory_entries) |dir_i| {
                const dir = r.takeStruct(std.coff.ImageDataDirectory, .little) catch |err|
                    return failParse(opts, "unable to read data directory {x}: {t}", .{ dir_i, err });

                if (dir_i < known_dirs.len)
                    known_dirs[dir_i] = dir;

                if (opts.file_headers)
                    try w.print(
                        "{x: >16} {x: >8} {t}\n",
                        .{ dir.virtual_address, dir.size, @as(DIRECTORY_ENTRY, @enumFromInt(dir_i)) },
                    );
            }
            if (opts.file_headers) try w.writeByte('\n');

            break :optional_header .{ known_dirs[0..@min(known_dirs.len, num_directory_entries)], magic };
        } else if (is_image) {
            return failParse(opts, "image did not contain an optional header", .{});
        } else .{ &.{}, null };

        // Section names in images don't use the string table, as they must fit inline in the header
        const load_string_table = (opts.strings or !is_image) and header.pointer_to_symbol_table > 0;
        const string_table = if (load_string_table) string_table: {
            const pos = fr.logicalPos();
            fr.seekTo(file_location + header.pointer_to_symbol_table + header.number_of_symbols * std.coff.Symbol.sizeOf()) catch |err|
                return failParse(opts, "unable to seek to string table: {t}", .{err});

            const string_table_len = r.peekInt(u32, .little) catch |err|
                return failParse(opts, "unable to read string table length: {t}", .{err});

            const table = r.readAlloc(gpa, string_table_len) catch |err|
                return failParse(opts, "unable to read string table: {t}", .{err});

            try fr.seekTo(pos);
            break :string_table table;
        } else &.{};
        defer gpa.free(string_table);

        if (opts.strings) {
            try w.print(
                \\String Table (0x{x} bytes):
                \\
            , .{string_table.len});

            var sr = Io.Reader.fixed(string_table[4..]);
            while (try sr.takeDelimiter(0)) |str| {
                try w.writeAll(str);
                try w.writeByte('\n');
            }

            try w.writeByte('\n');
        }

        var sections: std.ArrayList(Section) = .empty;
        defer sections.deinit(gpa);
        var sections_with_data: u16 = 0;

        const load_sections =
            opts.section_headers or
            opts.symbols or
            opts.relocs or
            needs_data_dirs;

        if (load_sections) {
            if (opts.section_headers)
                try w.print(
                    \\Sections in {s}:
                    \\Num Name          RVA Virt Size Data Size   & Data & Relocs  & Lines # Relocs  # Lines    Flags
                    \\
                , .{obj_name});

            try sections.resize(gpa, header.number_of_sections);
            for (sections.items, 0..) |*section, section_i| {
                section.header = r.takeStruct(std.coff.SectionHeader, .little) catch |err|
                    return failParse(opts, "unable to read section header {x}: {t}", .{ section_i, err });
                section.name = headerName(&section.header.name, string_table) catch |err| switch (err) {
                    error.Overflow,
                    error.InvalidCharacter,
                    => return failParse(opts, "unable to parse section name offset '{s}': {t}", .{
                        section.name,
                        err,
                    }),
                    error.OutOfBounds => return failParse(opts, "section name offset '{s}' was out of bounds (>= {x})", .{
                        section.name,
                        string_table.len,
                    }),
                };

                sections_with_data += @intFromBool(section.header.size_of_raw_data > 0);
                if (opts.section_headers) {
                    if (!filterMatches(opts.section_filters, section.name)) continue;
                    const raw_name = std.mem.sliceTo(&section.header.name, 0);
                    try w.print(
                        "{x: >3} {s: <8} {x: >8} {x: >9} {x: >9} {x: >8} {x: >8} {x: >8} {x: >8} {x: >8} {x:0>8} |",
                        .{
                            section_i + 1,
                            raw_name,
                            section.header.virtual_address,
                            section.header.virtual_size,
                            section.header.size_of_raw_data,
                            section.header.pointer_to_raw_data,
                            section.header.pointer_to_relocations,
                            section.header.pointer_to_linenumbers,
                            section.header.number_of_relocations,
                            section.header.number_of_linenumbers,
                            @as(u32, @bitCast(section.header.flags)),
                        },
                    );

                    try dumpFlags(w, "{s}", std.coff.SectionHeader.Flags, &section.header.flags, 1);
                    if (section.name.len > 8)
                        try w.print("| {s}", .{section.name});

                    try w.writeByte('\n');
                }
            }

            if (opts.section_headers) try w.writeByte('\n');
        }

        var symbols: std.ArrayList(struct {
            name: []const u8,
            section_number: std.coff.SectionNumber,
        }) = .empty;
        defer symbols.deinit(gpa);
        if (opts.relocs)
            try symbols.ensureUnusedCapacity(gpa, header.number_of_symbols);

        if (opts.symbols or opts.relocs) {
            if (header.pointer_to_symbol_table > 0) {
                fr.seekTo(file_location + header.pointer_to_symbol_table) catch |err|
                    return failParse(opts, "unable to seek to symbol table: {t}", .{err});

                if (opts.symbols)
                    try w.print(
                        \\Symbols in {s}:
                        \\ Ord    Value  Sect Type           Storage   Name
                        \\
                    , .{obj_name});

                const symbol_size = std.coff.Symbol.sizeOf();
                var symbol_i: u32 = 0;
                while (symbol_i < header.number_of_symbols) {
                    var symbol: std.coff.Symbol = undefined;
                    const symbol_bytes = r.take(symbol_size) catch |err|
                        return failParse(opts, "unable to read symbol {x}: {t}", .{ symbol_i, err });

                    @memcpy(std.mem.asBytes(&symbol)[0..symbol_size], symbol_bytes);
                    if (native_endian != .little)
                        std.mem.byteSwapAllFields(std.coff.Symbol, &symbol);

                    const aux_symbols = if (symbol.number_of_aux_symbols > 0)
                        try r.take(symbol_size * symbol.number_of_aux_symbols)
                    else
                        &.{};
                    defer symbol_i += symbol.number_of_aux_symbols + 1;

                    const name = std.mem.sliceTo(if (std.mem.eql(u8, symbol.name[0..4], "\x00\x00\x00\x00")) name: {
                        const index = std.mem.readInt(u32, symbol.name[4..], .little);
                        if (index >= string_table.len)
                            return failParse(opts, "invalid name offset for symbol {x} ({x} >= {x})", .{
                                symbol_i,
                                index,
                                string_table.len,
                            });
                        break :name string_table[index..];
                    } else &symbol.name, 0);

                    if (opts.relocs)
                        symbols.appendNTimesAssumeCapacity(.{
                            .name = name,
                            .section_number = symbol.section_number,
                        }, 1 + symbol.number_of_aux_symbols);

                    if (!opts.symbols)
                        continue;

                    try w.print("{x: >4} {x:0>8} ", .{ symbol_i, symbol.value });
                    try switch (symbol.section_number) {
                        .UNDEFINED => w.writeAll("UNDEF"),
                        .ABSOLUTE => w.writeAll("  ABS"),
                        .DEBUG => w.writeAll("DEBUG"),
                        else => |v| {
                            const backing = @intFromEnum(v);
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

                    try w.print("{t: >16} | {s}", .{ symbol.storage_class, name });
                    try w.writeByte('\n');

                    for (0..symbol.number_of_aux_symbols) |aux_i| {
                        _ = aux_i;
                        try w.writeAll("   |");

                        if (symbol.storage_class == .EXTERNAL and
                            symbol.type == std.coff.SymType{
                                .complex_type = .FUNCTION,
                                .base_type = .NULL,
                            } and
                            @intFromEnum(symbol.section_number) > 0)
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
                                return failParse(
                                    opts,
                                    "invalid value 0x{x} for weak external symbol 0x{x}",
                                    .{ symbol.value, symbol_i },
                                );

                            var weak_external: std.coff.WeakExternalDefinition = undefined;
                            @memcpy(std.mem.asBytes(&weak_external)[0..symbol_size], aux_symbols[0..symbol_size]);
                            if (native_endian != .little)
                                std.mem.byteSwapAllFields(std.coff.SectionDefinition, &weak_external);

                            if (weak_external.tag_index >= header.number_of_symbols)
                                return failParse(
                                    opts,
                                    "invalid tag_index 0x{x} for weak external symbol 0x{x}",
                                    .{ weak_external.tag_index, symbol_i },
                                );

                            // TODO

                            try w.print("  Weak External [falls back to {x:0>8} via {t}]", .{
                                weak_external.tag_index,
                                weak_external.flag,
                            });
                        } else if (symbol.storage_class == .FILE) {
                            if (!std.mem.eql(u8, name, ".file")) {
                                try w.print(" !! unexpected symbol name '{s}' for file symbol 0x{x}", .{ name, symbol_i });
                                continue;
                            }

                            var file: std.coff.FileDefinition = undefined;
                            @memcpy(std.mem.asBytes(&file)[0..symbol_size], aux_symbols[0..symbol_size]);

                            // TODO
                            _ = file.getFileName();
                        } else if (symbol.storage_class == .STATIC and
                            symbol.type == std.coff.SymType{
                                .complex_type = .NULL,
                                .base_type = .NULL,
                            } and
                            symbol.value == 0 and
                            switch (symbol.section_number) {
                                .UNDEFINED, .DEBUG, .ABSOLUTE => false,
                                else => |sn| @intFromEnum(sn) > 0,
                            })
                        {
                            const section_i: u15 = @intCast(@intFromEnum(symbol.section_number) - 1);
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

                            try w.print("      [size {x:0>8} chksum {x:0>8} relocs {x:0>4} lines {x:0>4}]", .{
                                section_def.length,
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
                        } else {}

                        try w.writeByte('\n');
                    }
                }

                if (opts.symbols) try w.writeByte('\n');
            } else if (opts.symbols) {
                try w.writeAll("No symbol table found\n");
            }
        }

        if (opts.relocs) {
            const relocation_size = std.coff.Relocation.sizeOf();

            for (sections.items, 0..) |section, section_i| {
                if (section.header.pointer_to_relocations == 0) continue;

                try w.print(
                    \\Relocs for section {x} '{s}' in {s}:
                    \\  Offset Type                Symbol -> Sect   Name
                    \\
                , .{ section_i + 1, section.name, obj_name });

                fr.seekTo(file_location + section.header.pointer_to_relocations) catch |err|
                    return failParse(opts, "unable to seek to section {x} relocation table: {t}", .{ section_i + 1, err });

                for (0..section.header.number_of_relocations) |reloc_i| {
                    var reloc: std.coff.Relocation = undefined;
                    @memcpy(std.mem.asBytes(&reloc)[0..relocation_size], try r.take(relocation_size));
                    if (native_endian != .little)
                        std.mem.byteSwapAllFields(std.coff.Relocation, &reloc);

                    try w.print("{x:0>8} ", .{reloc.virtual_address});
                    switch (header.machine) {
                        _ => unreachable,
                        inline else => |m| switch (m.RelocationType()) {
                            void => try w.writeAll("(unknown arch)"),
                            else => |RelocationType| try w.print(
                                "{t: <17} ",
                                .{@as(RelocationType, @enumFromInt(reloc.type))},
                            ),
                        },
                    }

                    if (reloc.symbol_table_index >= symbols.items.len)
                        return failParse(
                            opts,
                            "reloc {x} in section {x} has out-of-bounds symbol index {x}",
                            .{ reloc_i, section_i + 1, reloc.symbol_table_index },
                        );

                    const sym = &symbols.items[reloc.symbol_table_index];
                    try w.print("{x: >8}   {f} | {s}\n", .{
                        reloc.symbol_table_index,
                        fmtSectionNumber(sym.section_number),
                        sym.name,
                    });
                }
                try w.writeByte('\n');
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

        if (opts.exports) {
            if (try seekToDataDirectory(opts, fr, w, rva_index, sections.items, data_dirs, .EXPORT)) |section_index| {
                const export_dir = r.takeStruct(std.coff.ExportDirectoryTable, .little) catch |err|
                    return failParse(opts, "unable to read export directory: {t}", .{err});

                try w.print("Export directory:\n", .{});
                try dumpHeader(w, std.coff.ExportDirectoryTable, &export_dir, struct {
                    pub fn major_version(h: *const std.coff.ExportDirectoryTable, cw: *Io.Writer) !void {
                        try dumpVersionField(cw, "version", h.major_version, h.minor_version);
                    }
                    pub fn minor_version(_: *const std.coff.ExportDirectoryTable, _: *Io.Writer) !void {}
                });

                const section = sections.items[section_index];
                const name_loc = section.rvaFileOffset(export_dir.name_rva) catch
                    return failParse(
                        opts,
                        "export name rva 0x{x} was not within the export section",
                        .{export_dir.name_rva},
                    );

                const eat_loc = section.rvaFileOffset(export_dir.export_address_table_rva) catch
                    return failParse(
                        opts,
                        "export address table rva 0x{x} was not within the export section",
                        .{export_dir.export_address_table_rva},
                    );

                const name_pointer_loc = section.rvaFileOffset(export_dir.name_pointer_table_rva) catch
                    return failParse(
                        opts,
                        "export name pointer table rva 0x{x} was not within the export section",
                        .{export_dir.name_pointer_table_rva},
                    );

                const ord_loc = section.rvaFileOffset(export_dir.ordinal_table_rva) catch
                    return failParse(
                        opts,
                        "export ordinal table rva 0x{x} was not within the export section",
                        .{export_dir.ordinal_table_rva},
                    );

                // All the variable length fields should be contained within this directory.
                // Read it entirely to avoid needing to seek per-name when iterating.
                const dir = data_dirs[@intFromEnum(DIRECTORY_ENTRY.EXPORT)];
                const dir_end_rva = dir.virtual_address + dir.size;
                const dir_loc = fr.logicalPos();
                const dir_slice = try r.readAlloc(gpa, dir.size);
                defer gpa.free(dir_slice);

                const dll_name = std.mem.sliceTo(dir_slice[name_loc - dir_loc ..], 0);
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
                    const ord = std.mem.readInt(u16, ords[name_i * @sizeOf(u16) ..][0..@sizeOf(u16)], .little);
                    const addr = std.mem.readInt(u32, addrs[@as(u32, ord) * @sizeOf(u32) ..][0..@sizeOf(u32)], .little);

                    try w.print("{x: >4} {x: >4} ", .{ export_dir.ordinal_base + ord, name_i });
                    const is_forwarder = addr >= dir.virtual_address and addr < dir_end_rva;
                    if (is_forwarder) {
                        try w.writeAll("forwards");
                    } else {
                        try w.print("{x: >8}", .{addr});
                    }

                    const name = std.mem.sliceTo(dir_slice[name_rva - name_rva_to_offset ..], 0);
                    try w.print(" | {s}", .{name});
                    if (is_forwarder)
                        try w.print(" -> {s}", .{std.mem.sliceTo(dir_slice[addr - name_rva_to_offset ..], 0)});
                    try w.writeByte('\n');
                }
            }
        }

        if (opts.imports) {
            if (try seekToDataDirectory(opts, fr, w, rva_index, sections.items, data_dirs, .IMPORT)) |_| {
                const Entry = std.coff.ImportDirectoryEntry;
                var directory_entries: std.ArrayList(Entry) = .empty;
                defer directory_entries.deinit(gpa);
                while (true) {
                    const entry = r.takeStruct(Entry, .little) catch |err|
                        return failParse(
                            opts,
                            "unable to read import directory entry {x}: {t}",
                            .{ directory_entries.items.len, err },
                        );

                    if (std.mem.allEqual(u8, std.mem.asBytes(&entry), 0)) break;
                    (try directory_entries.addOne(gpa)).* = entry;
                }

                for (directory_entries.items) |entry| {
                    const name_section = sectionContainingRva(rva_index, sections.items, entry.name_rva) orelse
                        return failParse(
                            opts,
                            "import directory entry name rva 0x{x} was not found in any section",
                            .{entry.name_rva},
                        );

                    const name_loc = sections.items[name_section].rvaFileOffset(entry.name_rva) catch unreachable;
                    fr.seekTo(name_loc) catch |err|
                        return failParse(
                            opts,
                            "unable to seek to import directory entry name at 0x{x}: {t}",
                            .{ name_loc, err },
                        );

                    const dll_name = (try r.takeDelimiter(0)).?;

                    try w.print("Import table entry for {s}:\n", .{dll_name});
                    try dumpHeader(w, Entry, &entry, struct {});

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
                        return failParse(
                            opts,
                            "import directory entry ilt rva 0x{x} was not found in any section",
                            .{entry.import_lookup_table_rva},
                        );

                    const ilt_loc = sections.items[ilt_section].rvaFileOffset(
                        entry.import_lookup_table_rva,
                    ) catch unreachable;
                    fr.seekTo(ilt_loc) catch |err|
                        return failParse(
                            opts,
                            "unable to seek to import directory ilt at 0x{x}: {t}",
                            .{ ilt_loc, err },
                        );

                    switch (magic.?) {
                        _ => try w.writeAll("(unknown magic)"),
                        inline else => |m| {
                            const TableEntry = std.coff.ImportLookupTableEntry(m);
                            const null_entry: TableEntry = @bitCast(@as(@typeInfo(TableEntry).@"struct".backing_integer.?, 0));

                            var ilt_entries: std.ArrayList(TableEntry) = .empty;
                            defer ilt_entries.deinit(gpa);
                            while (true) {
                                const table_entry = r.takeStruct(TableEntry, .little) catch |err|
                                    return failParse(
                                        opts,
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
                                        return failParse(
                                            opts,
                                            "import directory ilt entry 0x{x}'s hint rva 0x{x} was not found in any section",
                                            .{ ilt_entry_i, ilt_entry.payload.hint_name_rva },
                                        );

                                    const hint_loc = sections.items[hint_section].rvaFileOffset(
                                        ilt_entry.payload.hint_name_rva,
                                    ) catch unreachable;
                                    fr.seekTo(hint_loc) catch |err|
                                        return failParse(
                                            opts,
                                            "unable to seek to ilt entry 0x{x}'s hint at 0x{x}: {t}",
                                            .{ ilt_entry_i, hint_loc, err },
                                        );

                                    const hint = r.takeInt(u16, .little) catch |err|
                                        return failParse(
                                            opts,
                                            "unable to read import directory ilt entry 0x{x}'s hint: {t}",
                                            .{ ilt_entry_i, err },
                                        );

                                    const name = r.takeDelimiter(0) catch |err|
                                        return failParse(
                                            opts,
                                            "unable to read import directory ilt entry 0x{x}'s name: {t}",
                                            .{ ilt_entry_i, err },
                                        );

                                    try w.print("     {x: >4} | {s}\n", .{ hint, name.? });
                                }
                            }
                            try w.writeByte('\n');
                        },
                    }
                }
            }
        }

        if (opts.tls) {
            if (try seekToDataDirectory(opts, fr, w, rva_index, sections.items, data_dirs, .TLS)) |_| {
                // TODO
            }
        }
    }

    fn seekToDataDirectory(
        opts: *const Options,
        fr: *Io.File.Reader,
        w: *Io.Writer,
        rva_index: []const u16,
        sections: []const Section,
        data_dirs: []const std.coff.ImageDataDirectory,
        entry: DIRECTORY_ENTRY,
    ) !?u16 {
        if (@intFromEnum(entry) < data_dirs.len) {
            const rva = data_dirs[@intFromEnum(entry)].virtual_address;
            const section_index = sectionContainingRva(rva_index, sections, rva) orelse
                return failParse(
                    opts,
                    "{t} directory rva 0x{x} was not found in any section",
                    .{ entry, rva },
                );

            const file_offset = sections[section_index].rvaFileOffset(rva) catch unreachable;
            fr.seekTo(file_offset) catch |err|
                return failParse(
                    opts,
                    "unable to seek to {t} directory at offset 0x{x}: {t}",
                    .{ entry, file_offset, err },
                );

            return section_index;
        }

        try w.print("{t} directory was not present in optional header\n", .{entry});
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
                const start = h.virtual_address;
                if (ctx.rva < start) return .lt;
                const end = h.virtual_address + h.size_of_raw_data;
                if (ctx.rva >= end) return .gt;
                return .eq;
            }
        };

        const index = std.sort.binarySearch(u16, indices, Context{
            .rva = rva,
            .sections = sections,
        }, Context.order) orelse return null;
        return @intCast(index);
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
                const backing = @intFromEnum(v);
                const fmt = "{x: >5}";
                if (backing >= 0)
                    try w.print(fmt, .{@as(u15, @intCast(backing))})
                else
                    try w.print(fmt, .{backing});
            },
        };
    }

    fn dumpFlags(w: *Io.Writer, comptime fmt: []const u8, comptime T: type, flags: *const T, cols: u32) !void {
        const s = @typeInfo(T).@"struct";
        inline for (s.fields) |flag_field| {
            if (flag_field.type == bool and @field(flags, flag_field.name)) {
                try w.splatByteAll(' ', cols);
                try w.print(fmt, .{flag_field.name});
            }
        }
    }

    fn dumpArchiveHeader(w: *Io.Writer, header: *const ArchiveHeader, pos: u32) !void {
        try w.print("Archive member at offset 0x{x}: '{s}'\n", .{ pos, header.name });
        try dumpHeader(w, ArchiveHeader, header, struct {
            pub fn name(_: *const ArchiveHeader, _: *Io.Writer) !void {}
            pub fn file_mode(h: *const ArchiveHeader, cw: *Io.Writer) !void {
                try cw.print("{o: >16} file_mode\n", .{h.file_mode});
            }
        });
    }

    fn dumpHeader(w: *Io.Writer, comptime T: type, header: *const T, Custom: type) !void {
        inline for (@typeInfo(T).@"struct".fields) |field| {
            const val = &@field(header, field.name);
            if (@hasDecl(Custom, field.name)) {
                try @field(Custom, field.name)(header, w);
            } else {
                switch (@typeInfo(field.type)) {
                    .int => try w.print("{x: >16} {s}\n", .{ val.*, field.name }),
                    .@"enum" => try w.print("{x: >16} {s} ({t})\n", .{ val.*, field.name, val.* }),
                    .@"struct" => |s| {
                        switch (s.layout) {
                            .auto,
                            .@"extern",
                            => try dumpHeader(w, field.type, val, Custom),
                            .@"packed" => {
                                try w.print("{x: >16} {s}\n", .{ @as(s.backing_integer.?, @bitCast(val.*)), field.name });
                                try dumpFlags(w, "| {s}\n", field.type, val, 15);
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

    fn dumpRvaField(w: *Io.Writer, name: []const u8, rva: u64, base: u64) !void {
        try w.print("{x: >16} {s} ({x})\n", .{ rva, name, base + rva });
    }
};

fn filterMatches(filters: []const []const u8, val: []const u8) bool {
    return for (filters) |filter| {
        if (std.mem.containsAtLeast(u8, val, 1, filter)) break true;
    } else filters.len == 0;
}

const usage =
    \\Usage: zig objdump [options] file
    \\
    \\Options:
    \\  -h, --help                              Print this help and exit
    \\  --all-headers                           Alias for --file-headers --member-headers --section-headers --relocs --symbols
    \\  --file-headers                          Display file-format specific headers
    \\  --imports                               Display imported symbols
    \\  --exports                               Display exported symbols
    \\  --linker-member[=1|2|longnames]         (Coff) Display contents of the specified linker member (default 2)
    \\  --member-headers                        Display archive member headers
    \\  --only-member=[name]                    Only consider archive members names that contain [name]. Can be specified multiple times.
    \\  --only-section=[name]                   Only consider section names that contain [name]. Can be specified multiple times.
    \\  --relocs                                Display relocations
    \\  --section-headers                       Display section headers
    \\  --strings                               Display string tables
    \\  --symbols                               Display symbol tables
    \\  --tls                                   Display TLS information
;
