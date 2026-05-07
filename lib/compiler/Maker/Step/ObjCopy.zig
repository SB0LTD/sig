const ObjCopy = @This();

const std = @import("std");
const Io = std.Io;
const allocPrint = std.fmt.allocPrint;
const Configuration = std.Build.Configuration;

const Step = @import("../Step.zig");
const Maker = @import("../../Maker.zig");

pub fn make(
    obj_copy: *ObjCopy,
    step_index: Configuration.Step.Index,
    maker: *Maker,
    progress_node: std.Progress.Node,
) Step.ExtendedMakeError!void {
    _ = obj_copy;
    const graph = maker.graph;
    const arena = maker.graph.arena; // TODO don't leak into process arena
    const io = graph.io;
    const step = maker.stepByIndex(step_index);
    const conf = &maker.scanned_config.configuration;
    const conf_step = step_index.ptr(conf);
    const conf_oc = conf_step.extended.get(conf.extra).obj_copy;
    const cache_root = graph.local_cache_root;

    try step.singleUnchangingWatchInput(maker, arena, conf_oc.input_file);

    var man = graph.cache.obtain();
    defer man.deinit();

    const src_path = try maker.resolveLazyPathIndex(arena, conf_oc.input_file, step_index);
    _ = try man.addFilePath(src_path, null);
    man.hash.addOptionalBytes(conf_oc.only_section);
    man.hash.addOptional(conf_oc.pad_to);
    man.hash.addOptional(conf_oc.format);
    man.hash.add(conf_oc.compress_debug);
    man.hash.add(conf_oc.strip);
    man.hash.add(conf_oc.output_file_debug != null);

    if (try step.cacheHit(&man)) {
        // Cache hit, skip subprocess execution.
        const digest = man.final();
        conf_oc.output_file.path = try cache_root.join(arena, &.{
            "o", &digest, conf_oc.basename,
        });
        if (conf_oc.output_file_debug) |*file| {
            file.path = try cache_root.join(arena, &.{
                "o", &digest, try allocPrint(arena, "{s}.debug", .{conf_oc.basename}),
            });
        }
        return;
    }

    const digest = man.final();
    const cache_path = "o" ++ Io.Dir.path.sep_str ++ digest;
    const full_dest_path = try cache_root.join(arena, &.{ cache_path, conf_oc.basename });
    const full_dest_path_debug = try cache_root.join(arena, &.{
        cache_path, try allocPrint(arena, "{s}.debug", .{conf_oc.basename}),
    });
    cache_root.handle.createDirPath(io, cache_path) catch |err|
        return step.fail("unable to make path {s}: {t}", .{ cache_path, err });

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.ensureUnusedCapacity(arena, 11);

    argv.addManyAsArrayAssumeCapacity(2).* = .{ graph.zig_exe, "objcopy" };

    if (conf_oc.only_section) |only_section|
        argv.addManyAsArrayAssumeCapacity(2).* = .{ "-j", only_section };

    switch (conf_oc.strip) {
        .none => {},
        .debug => argv.appendAssumeCapacity("--strip-debug"),
        .debug_and_symbols => argv.appendAssumeCapacity("--strip-all"),
    }

    if (conf_oc.pad_to) |pad_to| {
        argv.addManyAsArrayAssumeCapacity(2).* = .{
            "--pad-to", try allocPrint(arena, "{d}", .{pad_to}),
        };
    }

    if (conf_oc.format) |format| {
        argv.addManyAsArrayAssumeCapacity(2).* = .{
            "-O",
            switch (format) {
                .bin => "binary",
                .hex => "hex",
                .elf => "elf",
            },
        };
    }

    if (conf_oc.compress_debug)
        argv.appendAssumeCapacity("--compress-debug-sections");

    if (conf_oc.output_file_debug != null)
        argv.appendAssumeCapacity(try allocPrint(arena, "--extract-to={s}", .{full_dest_path_debug}));

    try argv.ensureUnusedCapacity(arena, 9);

    if (conf_oc.add_section) |section| {
        argv.appendAssumeCapacity("--add-section");
        argv.appendAssumeCapacity(try allocPrint(arena, "{s}={f}", .{
            section.section_name, try maker.resolveLazyPathIndex(arena, section.file_path, step_index),
        }));
    }

    if (conf_oc.set_section_alignment) |set_align| {
        argv.appendAssumeCapacity("--set-section-alignment");
        argv.appendAssumeCapacity(try allocPrint(arena, "{s}={d}", .{ set_align.section_name, set_align.alignment }));
    }

    if (conf_oc.set_section_flags) |set_flags| {
        const f = set_flags.flags;
        // trailing comma is allowed
        argv.appendAssumeCapacity("--set-section-flags");
        argv.appendAssumeCapacity(try allocPrint(arena, "{s}={s}{s}{s}{s}{s}{s}{s}{s}{s}", .{
            set_flags.section_name,
            if (f.alloc) "alloc," else "",
            if (f.contents) "contents," else "",
            if (f.load) "load," else "",
            if (f.readonly) "readonly," else "",
            if (f.code) "code," else "",
            if (f.exclude) "exclude," else "",
            if (f.large) "large," else "",
            if (f.merge) "merge," else "",
            if (f.strings) "strings," else "",
        }));
    }

    argv.appendAssumeCapacity(src_path);
    argv.appendAssumeCapacity(full_dest_path);

    argv.appendAssumeCapacity("--listen=-");
    _ = try Step.evalZigProcess(step_index, maker, argv.items, progress_node, false);

    conf_oc.output_file.path = full_dest_path;
    if (conf_oc.output_file_debug) |*file| file.path = full_dest_path_debug;
    try man.writeManifest();
}
