const std = @import("std");
const Io = std.Io;
const fatal = std.process.fatal;
const mem = std.mem;
const assert = std.debug.assert;

const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

var stdout_buffer: [4000]u8 = undefined;

const Options = struct {
    input_path: []const u8,
    file_headers: bool,
    section_filters: []const []const u8 = &.{},
    section_table: bool,
    strings: bool,
    symbols: bool,
    compact: bool,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const arena = init.arena.allocator();

    var i: usize = 1;

    var opt_input_path: ?[]const u8 = null;
    var opt_file_headers: ?bool = null;
    var opt_section_table: ?bool = null;
    var opt_strings: ?bool = null;
    var opt_symbols: ?bool = null;
    var opt_relocs: ?bool = null;
    var opt_compact: ?bool = null;
    var section_filters: std.ArrayList([]const u8) = .empty;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (mem.startsWith(u8, arg, "-")) {
            if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
                return Io.File.stdout().writeStreamingAll(io, usage);
            } else if (mem.eql(u8, arg, "--all-headers")) {
                opt_file_headers = true;
                opt_section_table = true;
                opt_symbols = true;
                opt_relocs = true;
            } else if (mem.eql(u8, arg, "--compact")) {
                opt_compact = true;
            } else if (mem.eql(u8, arg, "--file-headers")) {
                opt_file_headers = true;
            } else if (mem.startsWith(u8, arg, "--only-section=")) {
                (try section_filters.addOne(arena)).* = try arena.dupe(u8, arg["--only-section=".len..]);
            } else if (mem.eql(u8, arg, "--relocs")) {
                opt_relocs = true;
            } else if (mem.eql(u8, arg, "--section-headers")) {
                opt_section_table = true;
            } else if (mem.eql(u8, arg, "--strings")) {
                opt_strings = true;
            } else if (mem.eql(u8, arg, "--symbols")) {
                opt_symbols = true;
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
        .compact = opt_compact orelse false,
        .file_headers = opt_file_headers orelse false,
        .section_filters = section_filters.items,
        .section_table = opt_section_table orelse false,
        .strings = opt_strings orelse false,
        .symbols = opt_symbols orelse false,
    };

    var file = std.Io.Dir.cwd().openFile(io, opts.input_path, .{}) catch |err|
        fatal("failed to open {s}: {t}", .{ opts.input_path, err });
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    dump(arena, &opts, &file_reader, &stdout_writer.interface) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
        error.WriteFailed => return stdout_writer.err.?,
        error.UnknownFile => fatal("unrecognized file: {s}", .{opts.input_path}),
        error.ParseFailure => {},
        else => |e| return e,
    };
    try stdout_writer.flush();
}

fn dump(arena: std.mem.Allocator, opts: *const Options, fr: *Io.File.Reader, w: *Io.Writer) !void {
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

            if (!opts.compact) try w.print("{s}: PE/COFF image\n\n", .{std.fs.path.basename(opts.input_path)});
            return coff.dumpObject(arena, opts, true, fr, w);
        } else if (std.mem.eql(u8, ext, ".lib")) {
            r.fill(std.coff.archive_signature.len) catch break :coff;
            if (!mem.eql(u8, r.buffered()[0..std.coff.archive_signature.len], std.coff.archive_signature)) break :coff;
            if (!opts.compact) try w.print("{s}: COFF archive\n\n", .{std.fs.path.basename(opts.input_path)});
            return coff.dumpArchive(opts, fr, w);
        } else if (std.mem.eql(u8, ext, ".obj")) {
            if (!opts.compact) try w.print("{s}: COFF object\n\n", .{std.fs.path.basename(opts.input_path)});
            return coff.dumpObject(arena, opts, false, fr, w);
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
    fn dumpArchive(opt: *const Options, fr: *Io.File.Reader, w: *Io.Writer) !void {
        _ = opt;
        _ = fr;
        try w.writeAll("TODO dump coff archive\n");
    }

    fn headerName(raw: *[8]u8, string_table: []const u8) ![]const u8 {
        return if (raw[0] == '/') name: {
            const name_offset = try std.fmt.parseUnsigned(u24, raw[1..], 10);
            if (name_offset >= string_table.len)
                return error.OutOfBounds;

            break :name std.mem.sliceTo(string_table[name_offset..], 0);
        } else std.mem.sliceTo(raw, 0);
    }

    fn dumpObject(arena: std.mem.Allocator, opts: *const Options, is_image: bool, fr: *Io.File.Reader, w: *Io.Writer) !void {
        const r = &fr.interface;
        const header = r.takeStruct(std.coff.Header, .little) catch |err|
            return failParse(opts, "unable to read COFF header: {t}", .{err});

        if (opts.file_headers) {
            if (!opts.compact) try w.writeAll("COFF Header:\n");
            try dumpHeader(w, std.coff.Header, &header, struct {});
            if (!opts.compact) try w.writeByte('\n');
        }

        if (header.size_of_optional_header > 0) opt_header: {
            if (!opts.file_headers) {
                try fr.seekBy(header.size_of_optional_header);
                break :opt_header;
            }

            if (!opts.compact) try w.writeAll("COFF Optional Header:\n");
            const magic: std.coff.OptionalHeader.Magic = @enumFromInt(try r.peekInt(u16, .little));
            const num_directory_entries = switch (magic) {
                inline .PE32, .@"PE32+" => |v| data_dirs: {
                    const OptionalHeader = if (v == .PE32)
                        std.coff.OptionalHeader.PE32
                    else
                        std.coff.OptionalHeader.@"PE32+";

                    const optional_header = r.takeStruct(OptionalHeader, .little) catch |err|
                        return failParse(opts, "unable to read optional header: {t}", .{err});

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
                    if (!opts.compact) try w.writeByte('\n');

                    break :data_dirs optional_header.number_of_rva_and_sizes;
                },
                else => return failParse(opts, "invalid optional header magic number: {x}", .{magic}),
            };

            if (!opts.compact) try w.writeAll("Data Directories:\n");
            for (0..num_directory_entries) |dir_i| {
                const dir = r.takeStruct(std.coff.ImageDataDirectory, .little) catch |err|
                    return failParse(opts, "unable to read data directory {x}: {t}", .{ dir_i, err });

                try w.print(
                    "{x: >16} {x: >8} {t}\n",
                    .{ dir.virtual_address, dir.size, @as(std.coff.IMAGE.DIRECTORY_ENTRY, @enumFromInt(dir_i)) },
                );
            }
            if (!opts.compact) try w.writeByte('\n');
        } else if (is_image) {
            return failParse(opts, "image did not contain an optional header", .{});
        }

        // Section names in images don't use the string table, as they must fit inline in the header
        const load_string_table = (opts.strings or !is_image) and header.pointer_to_symbol_table > 0;

        const string_table = if (load_string_table) string_table: {
            const pos = fr.logicalPos();
            fr.seekTo(header.pointer_to_symbol_table + header.number_of_symbols * std.coff.Symbol.sizeOf()) catch |err|
                return failParse(opts, "unable to seek to string table: {t}", .{err});

            const string_table_len = r.peekInt(u32, .little) catch |err|
                return failParse(opts, "unable to read string table length: {t}", .{err});

            const table = r.readAlloc(arena, string_table_len) catch |err|
                return failParse(opts, "unable to read string table: {t}", .{err});

            try fr.seekTo(pos);
            break :string_table table;
        } else &.{};

        var sections: std.ArrayList(std.coff.SectionHeader) = .empty;
        const load_sections = opts.section_table or opts.symbols;
        if (load_sections) {
            if (!opts.compact and opts.section_table)
                try w.writeAll(
                    \\Section Table:
                    \\Num Name          RVA Virtual Size Data Size File Offset Relocs Offset Lines Offset # Relocs  # Lines    Flags
                    \\
                );

            try sections.resize(arena, header.number_of_sections);
            for (sections.items, 0..) |*section, section_i| {
                section.* = r.takeStruct(std.coff.SectionHeader, .little) catch |err|
                    return failParse(opts, "unable to read section header {x}: {t}", .{ section_i, err });

                if (opts.section_table) {
                    const name = headerName(&section.name, string_table) catch |err| switch (err) {
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

                    const matched = for (opts.section_filters) |filter| {
                        if (std.mem.containsAtLeast(u8, name, 1, filter)) break true;
                    } else opts.section_filters.len == 0;
                    if (!matched) continue;

                    try w.print(
                        "{x: >3} {s: <8} {x: >8} {x: >12} {x: >9} {x: >10} {x: >13} {x: >12} {x: >8} {x: >8} {x:0>8} ",
                        .{
                            section_i + 1,
                            std.mem.sliceTo(&section.name, 0),
                            section.virtual_address,
                            section.virtual_size,
                            section.size_of_raw_data,
                            section.pointer_to_raw_data,
                            section.pointer_to_relocations,
                            section.pointer_to_linenumbers,
                            section.number_of_relocations,
                            section.number_of_linenumbers,
                            @as(u32, @bitCast(section.flags)),
                        },
                    );

                    if (name.len > 8)
                        try w.print("  | {s}", .{name});

                    try dumpFlags(w, "{s} ", std.coff.SectionHeader.Flags, &section.flags, 0);
                    try w.writeByte('\n');
                }
            }

            if (!opts.compact and opts.section_table) try w.writeByte('\n');
        }

        if (opts.symbols) {
            if (header.pointer_to_symbol_table > 0) {
                fr.seekTo(header.pointer_to_symbol_table) catch |err|
                    return failParse(opts, "unable to seek to symbol table: {t}", .{err});

                if (!opts.compact and opts.symbols)
                    try w.writeAll(
                        \\Symbol Table:
                        \\ Ord    Value  Sect Type           Storage   Name
                        \\
                    );

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
                            return failParse(opts, "invalid name offset for symbol {x} ({x} >= {x})", .{ symbol_i, index, string_table.len });
                        break :name string_table[index..];
                    } else &symbol.name, 0);

                    try w.print("{x:0>4} {x:0>8} ", .{ symbol_i, symbol.value });
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
                        try w.writeAll(" AUX");

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
                        } else if (symbol.storage_class == .EXTERNAL and
                            symbol.section_number == .UNDEFINED and
                            symbol.value == 0)
                        {
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

                        } else if (symbol.storage_class == .FILE) {
                            if (!std.mem.eql(u8, name, ".file")) {
                                try w.print(" !! unexpected symbol name '{s}' for file symbol 0x{x}", .{ name, symbol_i });
                                continue;
                            }

                            var file: std.coff.FileDefinition = undefined;
                            @memcpy(std.mem.asBytes(&file)[0..symbol_size], aux_symbols[0..symbol_size]);

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
                            if (section_def.number_of_relocations != section.number_of_relocations) {
                                try w.print(
                                    " !! relocation count did not match section header: {d} vs {d}",
                                    .{ section_def.number_of_relocations, section.number_of_relocations },
                                );
                                continue;
                            }

                            if (section_def.number_of_linenumbers != section.number_of_linenumbers) {
                                try w.print(
                                    " !! line number count did not match section header: {d} vs {d}",
                                    .{ section_def.number_of_linenumbers, section.number_of_linenumbers },
                                );
                                continue;
                            }

                            try w.print("      [size: {x:0>8} chksum: {x:0>8} relocs: {x:0>4} lines: {x:0>4}]", .{
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
            } else {
                if (!opts.compact) try w.writeAll("No symbol table found\n");
            }
        }
    }

    fn fmtSymbolType(sym_type: std.coff.SymType) std.fmt.Alt(std.coff.SymType, symbolTypeString) {
        return .{ .data = sym_type };
    }

    fn symbolTypeString(sym_type: std.coff.SymType, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{t: >5}", .{sym_type.base_type});
        if (try switch (sym_type.complex_type) {
            .NULL => "  ",
            .POINTER => "* ",
            .FUNCTION => "()",
            .ARRAY => "[]",
            else => null,
        }) |suffix| try .printAll(suffix) else w.print("{x}", .{sym_type.complex_type});
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

const usage =
    \\Usage: zig objdump [options] file
    \\
    \\Options:
    \\  -h, --help                              Print this help and exit
    \\  --all-headers                           Alias for --file-headers --section-headers --relocs --symbols
    \\  --compact                               Minimal output mode that excludes extra newlines and headings. Intended for snapshot testing.
    \\  --file-headers                          Display file-format specific headers
    \\  --only-member=[name]                    Only consider archive members that contain [name]. Can be specified multiple times.
    \\  --only-section=[name]                   Only consider sections that contain [name]. Can be specified multiple times.
    \\  --section-headers                       Display section headers
    \\  --strings                               Display string table
    \\  --symbols                               Display symbol tables
    \\  --relocs                                Display relocations
;
