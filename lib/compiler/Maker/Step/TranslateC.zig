
fn make(step: *Step, options: Step.MakeOptions) !void {
    const prog_node = options.progress_node;
    const b = step.owner;
    const translate_c: *TranslateC = @fieldParentPtr("step", step);
    const arena = b.graph.arena;

    var argv_list = std.array_list.Managed([]const u8).init(b.allocator);
    try argv_list.append(b.graph.zig_exe);
    try argv_list.append("translate-c");
    if (translate_c.link_libc) {
        try argv_list.append("-lc");
    }

    try argv_list.append("--cache-dir");
    try argv_list.append(b.cache_root.path orelse ".");

    try argv_list.append("--global-cache-dir");
    try argv_list.append(b.graph.global_cache_root.path orelse ".");

    if (!translate_c.target.query.isNative()) {
        try argv_list.append("-target");
        try argv_list.append(try translate_c.target.query.zigTriple(b.allocator));
    }

    switch (translate_c.optimize) {
        .Debug => {}, // Skip since it's the default.
        else => try argv_list.append(b.fmt("-O{s}", .{@tagName(translate_c.optimize)})),
    }

    for (translate_c.include_dirs.items) |include_dir| {
        try include_dir.appendZigProcessFlags(b, &argv_list, step);
    }

    for (translate_c.c_macros.items) |c_macro| {
        try argv_list.append("-D");
        try argv_list.append(c_macro);
    }

    var prev_search_strategy: std.Build.Module.SystemLib.SearchStrategy = .paths_first;
    var prev_preferred_link_mode: std.builtin.LinkMode = .dynamic;

    for (translate_c.system_libs.items) |*system_lib| {
        var seen_system_libs: std.StringHashMapUnmanaged([]const []const u8) = .empty;
        const system_lib_gop = try seen_system_libs.getOrPut(arena, system_lib.name);
        if (system_lib_gop.found_existing) {
            try argv_list.appendSlice(system_lib_gop.value_ptr.*);
            continue;
        } else {
            system_lib_gop.value_ptr.* = &.{};
        }

        if (system_lib.search_strategy != prev_search_strategy or
            system_lib.preferred_link_mode != prev_preferred_link_mode)
        {
            switch (system_lib.search_strategy) {
                .no_fallback => switch (system_lib.preferred_link_mode) {
                    .dynamic => try argv_list.append("-search_dylibs_only"),
                    .static => try argv_list.append("-search_static_only"),
                },
                .paths_first => switch (system_lib.preferred_link_mode) {
                    .dynamic => try argv_list.append("-search_paths_first"),
                    .static => try argv_list.append("-search_paths_first_static"),
                },
                .mode_first => switch (system_lib.preferred_link_mode) {
                    .dynamic => try argv_list.append("-search_dylibs_first"),
                    .static => try argv_list.append("-search_static_first"),
                },
            }
            prev_search_strategy = system_lib.search_strategy;
            prev_preferred_link_mode = system_lib.preferred_link_mode;
        }

        const prefix: []const u8 = prefix: {
            if (system_lib.needed) break :prefix "-needed-l";
            if (system_lib.weak) break :prefix "-weak-l";
            break :prefix "-l";
        };
        switch (system_lib.use_pkg_config) {
            .no => try argv_list.append(b.fmt("{s}{s}", .{ prefix, system_lib.name })),
            .yes, .force => {
                if (Step.Compile.runPkgConfig(&translate_c.step, system_lib.name)) |result| {
                    try argv_list.appendSlice(result.cflags);
                    try argv_list.appendSlice(result.libs);
                    try seen_system_libs.put(arena, system_lib.name, result.cflags);
                } else |err| switch (err) {
                    error.PkgConfigInvalidOutput,
                    error.PkgConfigCrashed,
                    error.PkgConfigFailed,
                    error.PkgConfigNotInstalled,
                    error.PackageNotFound,
                    => switch (system_lib.use_pkg_config) {
                        .yes => {
                            // pkg-config failed, so fall back to linking the library
                            // by name directly.
                            try argv_list.append(b.fmt("{s}{s}", .{
                                prefix,
                                system_lib.name,
                            }));
                        },
                        .force => {
                            std.debug.panic("pkg-config failed for library {s}", .{system_lib.name});
                        },
                        .no => unreachable,
                    },

                    else => |e| return e,
                }
            },
        }
    }

    const c_source_path = translate_c.source.getPath2(b, step);
    try argv_list.append(c_source_path);

    try argv_list.append("--listen=-");
    const output_dir = try step.evalZigProcess(argv_list.items, prog_node, false, options.web_server, options.gpa);

    const basename = std.fs.path.stem(std.fs.path.basename(c_source_path));
    translate_c.out_basename = b.fmt("{s}.zig", .{basename});
    translate_c.output_file.path = output_dir.?.joinString(b.allocator, translate_c.out_basename) catch @panic("OOM");
}
