const ObjCopy = @This();

const std = @import("std");
const Step = std.Build.Step;
const Configuration = std.Build.Configuration;

step: Step,
input_file: std.Build.LazyPath,
basename: ?[]const u8,
output_file: Configuration.GeneratedFileIndex,
output_file_debug: Configuration.OptionalGeneratedFileIndex,

format: ?Format,
only_section: ?[]const u8,
pad_to: ?u64,
strip: Strip,
compress_debug: bool,

add_section: ?AddSection,
set_section_alignment: ?SetSectionAlignment,
set_section_flags: ?SetSectionFlags,

pub const base_tag: Step.Tag = .obj_copy;

pub const Format = enum { binary, hex, elf };
pub const Strip = Configuration.Step.ObjCopy.Strip;
pub const SectionFlags = Configuration.Step.ObjCopy.SectionFlags;

pub const AddSection = struct {
    section_name: []const u8,
    file_path: std.Build.LazyPath,
};

pub const SetSectionAlignment = struct {
    section_name: []const u8,
    alignment: u32,
};

pub const SetSectionFlags = struct {
    section_name: []const u8,
    flags: SectionFlags,
};

pub const Options = struct {
    basename: ?[]const u8 = null,
    format: ?Format = null,
    only_section: ?[]const u8 = null,
    pad_to: ?u64 = null,

    compress_debug: bool = false,
    strip: Strip = .none,

    /// Put the stripped out debug sections in a separate file.
    /// note: the `basename` is baked into the elf file to specify the link to the separate debug file.
    /// see https://sourceware.org/gdb/onlinedocs/gdb/Separate-Debug-Files.html
    extract_to_separate_file: bool = false,

    add_section: ?AddSection = null,
    set_section_alignment: ?SetSectionAlignment = null,
    set_section_flags: ?SetSectionFlags = null,
};

pub fn create(
    owner: *std.Build,
    input_file: std.Build.LazyPath,
    options: Options,
) *ObjCopy {
    const graph = owner.graph;
    const obj_copy = graph.create(ObjCopy);
    obj_copy.* = .{
        .step = .init(.{
            .tag = base_tag,
            .name = owner.fmt("objcopy {f}", .{input_file.fmt(graph)}),
            .owner = owner,
        }),
        .input_file = input_file,
        .basename = options.basename,
        .output_file = graph.addGeneratedFile(&obj_copy.step),
        .output_file_debug = if (options.strip != .none and options.extract_to_separate_file)
            .init(graph.addGeneratedFile(&obj_copy.step))
        else
            .none,
        .format = options.format,
        .only_section = options.only_section,
        .pad_to = options.pad_to,
        .strip = options.strip,
        .compress_debug = options.compress_debug,
        .add_section = options.add_section,
        .set_section_alignment = options.set_section_alignment,
        .set_section_flags = options.set_section_flags,
    };
    input_file.addStepDependencies(&obj_copy.step);
    return obj_copy;
}

pub fn getOutput(obj_copy: *const ObjCopy) std.Build.LazyPath {
    return .{ .generated = .{ .index = obj_copy.output_file } };
}

pub fn getOutputSeparatedDebug(obj_copy: *const ObjCopy) ?std.Build.LazyPath {
    return if (obj_copy.output_file_debug.unwrap()) |index| .{ .generated = .{ .index = index } } else null;
}
