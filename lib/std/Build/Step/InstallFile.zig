const std = @import("std");
const Step = std.Build.Step;
const LazyPath = std.Build.LazyPath;
const InstallDir = std.Build.InstallDir;
const InstallFile = @This();
const assert = std.debug.assert;

pub const base_tag: Step.Tag = .install_file;

step: Step,
source: LazyPath,
dir: InstallDir,
dest_rel_path: []const u8,

pub fn create(
    owner: *std.Build,
    source: LazyPath,
    dir: InstallDir,
    dest_rel_path: []const u8,
) *InstallFile {
    assert(dest_rel_path.len != 0);
    const install_file = owner.allocator.create(InstallFile) catch @panic("OOM");
    install_file.* = .{
        .step = Step.init(.{
            .tag = base_tag,
            .name = owner.fmt("install {s} to {s}", .{ source.getDisplayName(), dest_rel_path }),
            .owner = owner,
        }),
        .source = source.dupe(owner),
        .dir = dir.dupe(owner),
        .dest_rel_path = owner.dupePath(dest_rel_path),
    };
    source.addStepDependencies(&install_file.step);
    return install_file;
}
