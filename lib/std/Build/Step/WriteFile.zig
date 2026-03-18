//! WriteFile is used to create a directory in an appropriate location inside
//! the local cache which has a set of files that have either been generated
//! during the build, or are copied from the source package.
const WriteFile = @This();

const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const Step = std.Build.Step;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;
const Configuration = std.Build.Configuration;

step: Step,

files: std.ArrayList(File),
directories: std.ArrayList(Directory),
generated_directory: Configuration.GeneratedFileIndex,
mode: Mode = .whole_cached,

pub const base_tag: Step.Tag = .write_file;

pub const Mode = union(enum) {
    /// Default mode. Integrates with the cache system. The directory should be
    /// read-only during the make phase. Any different inputs result in
    /// different "o" subdirectory.
    whole_cached,
    /// In this mode, the directory will be placed inside "tmp" rather than
    /// "o", and caching will be skipped. During the `make` phase, the step
    /// will always do all the file system operations, and on successful build
    /// completion, the dir will be deleted along with all other tmp
    /// directories. The directory is therefore eligible to be used for
    /// mutations by other steps.
    tmp,
    /// The operations will not be performed against a freshly created
    /// directory, but instead act against a temporary directory.
    mutate: std.Build.LazyPath,
};

pub const File = struct {
    sub_path: []const u8,
    contents: Contents,
};

pub const Directory = struct {
    source: std.Build.LazyPath,
    sub_path: []const u8,
    options: Options,

    pub const Options = struct {
        /// File paths that end in any of these suffixes will be excluded from copying.
        exclude_extensions: []const []const u8 = &.{},
        /// Only file paths that end in any of these suffixes will be included in copying.
        /// `null` means that all suffixes will be included.
        /// `exclude_extensions` takes precedence over `include_extensions`.
        include_extensions: ?[]const []const u8 = null,

        pub fn dupe(opts: Options, graph: *std.Build.Graph) Options {
            return .{
                .exclude_extensions = graph.dupeStrings(opts.exclude_extensions),
                .include_extensions = if (opts.include_extensions) |incs| graph.dupeStrings(incs) else null,
            };
        }

        pub fn pathIncluded(opts: Options, path: []const u8) bool {
            for (opts.exclude_extensions) |ext| {
                if (std.mem.endsWith(u8, path, ext))
                    return false;
            }
            if (opts.include_extensions) |incs| {
                for (incs) |inc| {
                    if (std.mem.endsWith(u8, path, inc))
                        return true;
                } else {
                    return false;
                }
            }
            return true;
        }
    };
};

pub const Contents = union(enum) {
    bytes: []const u8,
    copy: std.Build.LazyPath,
};

pub fn create(owner: *std.Build) *WriteFile {
    const graph = owner.graph;
    const arena = graph.arena;
    const write_file = arena.create(WriteFile) catch @panic("OOM");
    write_file.* = .{
        .step = Step.init(.{
            .tag = base_tag,
            .name = "WriteFile",
            .owner = owner,
        }),
        .files = .empty,
        .directories = .empty,
        .generated_directory = graph.addGeneratedFile(&write_file.step),
    };
    return write_file;
}

pub fn add(write_file: *WriteFile, sub_path: []const u8, bytes: []const u8) std.Build.LazyPath {
    const graph = write_file.step.owner.graph;
    const arena = graph.arena;
    const file: File = .{
        .sub_path = graph.dupePath(sub_path),
        .contents = .{ .bytes = graph.dupeString(bytes) },
    };
    write_file.files.append(arena, file) catch @panic("OOM");
    write_file.maybeUpdateName();
    return .{
        .generated = .{
            .index = write_file.generated_directory,
            .sub_path = file.sub_path,
        },
    };
}

/// Place the file into the generated directory within the local cache,
/// along with all the rest of the files added to this step. The parameter
/// here is the destination path relative to the local cache directory
/// associated with this WriteFile. It may be a basename, or it may
/// include sub-directories, in which case this step will ensure the
/// required sub-path exists.
/// This is the option expected to be used most commonly with `addCopyFile`.
pub fn addCopyFile(write_file: *WriteFile, source: std.Build.LazyPath, sub_path: []const u8) std.Build.LazyPath {
    const b = write_file.step.owner;
    const gpa = b.allocator;
    const file = File{
        .sub_path = b.dupePath(sub_path),
        .contents = .{ .copy = source },
    };
    write_file.files.append(gpa, file) catch @panic("OOM");

    write_file.maybeUpdateName();
    source.addStepDependencies(&write_file.step);
    return .{
        .generated = .{
            .index = write_file.generated_directory,
            .sub_path = file.sub_path,
        },
    };
}

/// Copy files matching the specified exclude/include patterns to the specified subdirectory
/// relative to this step's generated directory.
/// The returned value is a lazy path to the generated subdirectory.
pub fn addCopyDirectory(
    write_file: *WriteFile,
    source: std.Build.LazyPath,
    sub_path: []const u8,
    options: Directory.Options,
) std.Build.LazyPath {
    const graph = write_file.step.owner.graph;
    const arena = graph.arena;
    const dir = Directory{
        .source = source.dupe(graph),
        .sub_path = graph.dupePath(sub_path),
        .options = options.dupe(graph),
    };
    write_file.directories.append(arena, dir) catch @panic("OOM");

    write_file.maybeUpdateName();
    source.addStepDependencies(&write_file.step);
    return .{
        .generated = .{
            .index = write_file.generated_directory,
            .sub_path = dir.sub_path,
        },
    };
}

/// Returns a `LazyPath` representing the base directory that contains all the
/// files from this `WriteFile`.
pub fn getDirectory(write_file: *WriteFile) std.Build.LazyPath {
    return .{ .generated = .{ .index = write_file.generated_directory } };
}

fn maybeUpdateName(write_file: *WriteFile) void {
    if (write_file.files.items.len == 1 and write_file.directories.items.len == 0) {
        // First time adding a file; update name.
        if (std.mem.eql(u8, write_file.step.name, "WriteFile")) {
            write_file.step.name = write_file.step.owner.fmt("WriteFile {s}", .{write_file.files.items[0].sub_path});
        }
    } else if (write_file.directories.items.len == 1 and write_file.files.items.len == 0) {
        // First time adding a directory; update name.
        if (std.mem.eql(u8, write_file.step.name, "WriteFile")) {
            write_file.step.name = write_file.step.owner.fmt("WriteFile {s}", .{write_file.directories.items[0].sub_path});
        }
    }
}
