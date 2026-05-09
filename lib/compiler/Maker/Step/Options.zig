const Options = @This();

const std = @import("std");
const Configuration = std.Build.Configuration;

const Step = @import("../Step.zig");
const Maker = @import("../../Maker.zig");

pub fn make(
    options: *Options,
    step_index: Configuration.Step.Index,
    maker: *Maker,
    progress_node: std.Progress.Node,
) Step.ExtendedMakeError!void {
    // This step completes so quickly that no progress reporting is necessary.
    _ = progress_node;

    const graph = maker.graph;
    const step = maker.stepByIndex(step_index);
    const io = graph.io;
    const cache_root = graph.local_cache_root;

    for (options.args.items) |arg| {
        options.addOption(
            []const u8,
            arg.name,
            arg.path.getPath2(b, step),
        );
    }
    if (!step.inputs.populated()) for (options.args.items) |arg| {
        try step.addWatchInput(arg.path);
    };

    const basename = "options.zig";

    // Hash contents to file name.
    var hash = graph.cache.hash;
    // Random bytes to make unique. Refresh this with new random bytes when
    // implementation is modified in a non-backwards-compatible way.
    hash.add(@as(u32, 0xad95e922));
    hash.addBytes(options.contents.items);
    const sub_path = "c" ++ fs.path.sep_str ++ hash.final() ++ fs.path.sep_str ++ basename;

    options.generated_file.path = try cache_root.join(arena, &.{sub_path});

    // Optimize for the hot path. Stat the file, and if it already exists,
    // cache hit.
    if (cache_root.handle.access(io, sub_path, .{})) |_| {
        // This is the hot path, success.
        step.result_cached = true;
        return;
    } else |outer_err| switch (outer_err) {
        error.FileNotFound => {
            var atomic_file = cache_root.handle.createFileAtomic(io, sub_path, .{
                .replace = false,
                .make_path = true,
            }) catch |err| return step.fail("failed to create temporary path for '{f}{s}': {t}", .{
                cache_root, sub_path, err,
            });
            defer atomic_file.deinit(io);

            atomic_file.file.writeStreamingAll(io, options.contents.items) catch |err| {
                return step.fail("failed to write options to temporary path for '{f}{s}': {t}", .{
                    cache_root, sub_path, err,
                });
            };

            atomic_file.link(io) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    step.result_cached = true;
                    return;
                },
                else => return step.fail("failed to link temporary file into '{f}{s}': {t}", .{
                    cache_root, sub_path, err,
                }),
            };
        },
        else => |e| return step.fail("unable to access options file '{f}{s}': {t}", .{
            cache_root, sub_path, e,
        }),
    }
}
