const CheckFile = @This();

const std = @import("std");
const Io = std.Io;
const Configuration = std.Build.Configuration;

const Step = @import("../Step.zig");
const Maker = @import("../../Maker.zig");

pub fn make(
    check_file: *CheckFile,
    step_index: Configuration.Step.Index,
    maker: *Maker,
    progress_node: std.Progress.Node,
) Step.ExtendedMakeError!void {
    _ = progress_node;
    const graph = maker.graph;
    const arena = maker.graph.arena; // TODO don't leak into process arena
    const io = graph.io;
    const step = maker.stepByIndex(step_index);
    const conf = &maker.scanned_config.configuration;
    const conf_step = step_index.ptr(conf);
    const conf_cf = conf_step.extended.get(conf.extra).install_file;
    const lazy_path = conf_cf.file.get(conf);

    try step.singleUnchangingWatchInput(maker, arena, lazy_path);

    const src_path = try maker.resolveLazyPath(arena, lazy_path, step_index);
    const limit: Io.Limit = if (conf_cf.max_bytes.value) |x| .limited(x) else .unlimited;

    const contents = src_path.root_dir.handle.readFileAlloc(io, src_path.sub_path, arena, limit) catch |err|
        return step.fail("failed to read {f}: {t}", .{ src_path, err });

    for (check_file.expected_matches) |expected_match| {
        if (std.mem.find(u8, contents, expected_match) == null) {
            return step.fail(
                \\
                \\========= expected to find: ===================
                \\{s}
                \\========= but file does not contain it: =======
                \\{s}
                \\===============================================
            , .{ expected_match, contents });
        }
    }

    if (check_file.expected_exact) |expected_exact| {
        if (!std.mem.eql(u8, expected_exact, contents)) {
            return step.fail(
                \\
                \\========= expected: =====================
                \\{s}
                \\========= but found: ====================
                \\{s}
                \\========= from the following file: ======
                \\{s}
            , .{ expected_exact, contents, src_path });
        }
    }
}
