//! Writes data to paths relative to the package root, effectively mutating the
//! package's source files. Be careful with the latter functionality; it should
//! not be used during the normal build process, but as a utility run by a
//! developer with intention to update source files, which will then be
//! committed to version control.
const UpdateSourceFiles = @This();

const std = @import("std");
const Io = std.Io;
const Step = std.Build.Step;
const fs = std.fs;
const ArrayList = std.ArrayList;

step: Step,
output_source_files: std.ArrayList(OutputSourceFile),

pub const base_tag: Step.Tag = .update_source_files;

pub const OutputSourceFile = struct {
    contents: Contents,
    sub_path: []const u8,
};

pub const Contents = union(enum) {
    bytes: []const u8,
    copy: std.Build.LazyPath,
};

pub fn create(owner: *std.Build) *UpdateSourceFiles {
    const usf = owner.allocator.create(UpdateSourceFiles) catch @panic("OOM");
    usf.* = .{
        .step = .init(.{
            .tag = base_tag,
            .name = "UpdateSourceFiles",
            .owner = owner,
        }),
        .output_source_files = .empty,
    };
    return usf;
}

/// A path relative to the package root.
///
/// Be careful with this because it updates source files. This should not be
/// used as part of the normal build process, but as a utility occasionally
/// run by a developer with intent to modify source files and then commit
/// those changes to version control.
pub fn addCopyFileToSource(usf: *UpdateSourceFiles, source: std.Build.LazyPath, sub_path: []const u8) void {
    const b = usf.step.owner;
    usf.output_source_files.append(b.allocator, .{
        .contents = .{ .copy = source },
        .sub_path = sub_path,
    }) catch @panic("OOM");
    source.addStepDependencies(&usf.step);
}

/// A path relative to the package root.
///
/// Be careful with this because it updates source files. This should not be
/// used as part of the normal build process, but as a utility occasionally
/// run by a developer with intent to modify source files and then commit
/// those changes to version control.
pub fn addBytesToSource(usf: *UpdateSourceFiles, bytes: []const u8, sub_path: []const u8) void {
    const b = usf.step.owner;
    usf.output_source_files.append(b.allocator, .{
        .contents = .{ .bytes = bytes },
        .sub_path = sub_path,
    }) catch @panic("OOM");
}
