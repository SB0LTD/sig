const InstallDir = @This();

const std = @import("std");
const Configuration = std.Build.Configuration;

const Step = @import("../Step.zig");
const Maker = @import("../../Maker.zig");

pub fn make(
    install_dir: *InstallDir,
    step_index: Configuration.Step.Index,
    maker: *Maker,
    progress_node: std.Progress.Node,
) !void {
    const graph = maker.graph;
    const arena = maker.graph.arena; // TODO don't leak into process arena
    const io = graph.io;
    const step = maker.stepByIndex(step_index);

    step.clearWatchInputs();
    const dest_prefix = b.getInstallPath(install_dir.options.install_dir, install_dir.options.install_subdir);
    const src_dir_path = install_dir.options.source_dir.getPath3(b, step);
    const need_derived_inputs = try step.addDirectoryWatchInput(install_dir.options.source_dir);
    var src_dir = src_dir_path.root_dir.handle.openDir(io, src_dir_path.subPathOrDot(), .{ .iterate = true }) catch |err| {
        return step.fail("unable to open source directory '{f}': {t}", .{ src_dir_path, err });
    };
    defer src_dir.close(io);
    var it = try src_dir.walk(arena);
    var all_cached = true;
    next_entry: while (try it.next(io)) |entry| {
        for (install_dir.options.exclude_extensions) |ext| {
            if (std.mem.endsWith(u8, entry.path, ext)) continue :next_entry;
        }
        if (install_dir.options.include_extensions) |incs| {
            for (incs) |inc| {
                if (std.mem.endsWith(u8, entry.path, inc)) break;
            } else {
                continue :next_entry;
            }
        }

        const src_path = try install_dir.options.source_dir.join(arena, entry.path);
        const dest_path = b.pathJoin(&.{ dest_prefix, entry.path });
        switch (entry.kind) {
            .directory => {
                if (need_derived_inputs) _ = try step.addDirectoryWatchInput(src_path);
                const p = try step.installDir(dest_path);
                all_cached = all_cached and p == .existed;
            },
            .file => {
                for (install_dir.options.blank_extensions) |ext| {
                    if (std.mem.endsWith(u8, entry.path, ext)) {
                        try b.truncateFile(dest_path);
                        continue :next_entry;
                    }
                }

                const p = try step.installFile(src_path, dest_path);
                all_cached = all_cached and p == .fresh;
            },
            else => continue,
        }
    }

    step.result_cached = all_cached;
}
