
fn make(step: *Step, options: Step.MakeOptions) !void {
    _ = options;
    const b = step.owner;
    const graph = b.graph;
    const io = graph.io;
    const arena = b.allocator;
    const gpa = graph.cache.gpa;
    const write_file: *WriteFile = @fieldParentPtr("step", step);

    const open_dir_cache = try arena.alloc(Io.Dir, write_file.directories.items.len);
    var open_dirs_count: usize = 0;
    defer Io.Dir.closeMany(io, open_dir_cache[0..open_dirs_count]);

    switch (write_file.mode) {
        .whole_cached => {
            step.clearWatchInputs();

            // The cache is used here not really as a way to speed things up - because writing
            // the data to a file would probably be very fast - but as a way to find a canonical
            // location to put build artifacts.

            // If, for example, a hard-coded path was used as the location to put WriteFile
            // files, then two WriteFiles executing in parallel might clobber each other.

            var man = b.graph.cache.obtain();
            defer man.deinit();

            for (write_file.files.items) |file| {
                man.hash.addBytes(file.sub_path);

                switch (file.contents) {
                    .bytes => |bytes| {
                        man.hash.addBytes(bytes);
                    },
                    .copy => |lazy_path| {
                        const path = lazy_path.getPath3(b, step);
                        _ = try man.addFilePath(path, null);
                        try step.addWatchInput(lazy_path);
                    },
                }
            }

            for (write_file.directories.items, open_dir_cache) |dir, *open_dir_cache_elem| {
                man.hash.addBytes(dir.sub_path);
                for (dir.options.exclude_extensions) |ext| man.hash.addBytes(ext);
                if (dir.options.include_extensions) |incs| for (incs) |inc| man.hash.addBytes(inc);

                const need_derived_inputs = try step.addDirectoryWatchInput(dir.source);
                const src_dir_path = dir.source.getPath3(b, step);

                var src_dir = src_dir_path.root_dir.handle.openDir(io, src_dir_path.subPathOrDot(), .{ .iterate = true }) catch |err| {
                    return step.fail("unable to open source directory '{f}': {s}", .{
                        src_dir_path, @errorName(err),
                    });
                };
                open_dir_cache_elem.* = src_dir;
                open_dirs_count += 1;

                var it = try src_dir.walk(gpa);
                defer it.deinit();
                while (try it.next(io)) |entry| {
                    if (!dir.options.pathIncluded(entry.path)) continue;

                    switch (entry.kind) {
                        .directory => {
                            if (need_derived_inputs) {
                                const entry_path = try src_dir_path.join(arena, entry.path);
                                try step.addDirectoryWatchInputFromPath(entry_path);
                            }
                        },
                        .file => {
                            const entry_path = try src_dir_path.join(arena, entry.path);
                            _ = try man.addFilePath(entry_path, null);
                        },
                        else => continue,
                    }
                }
            }

            if (try step.cacheHit(&man)) {
                const digest = man.final();
                write_file.generated_directory.path = try b.cache_root.join(arena, &.{ "o", &digest });
                assert(step.result_cached);
                return;
            }

            const digest = man.final();
            const cache_path = "o" ++ Dir.path.sep_str ++ digest;

            write_file.generated_directory.path = try b.cache_root.join(arena, &.{cache_path});

            try operate(write_file, open_dir_cache, .{
                .root_dir = b.cache_root,
                .sub_path = cache_path,
            });

            try step.writeManifest(&man);
        },
        .tmp => {
            step.result_cached = false;

            var rand_int: u64 = undefined;
            io.random(@ptrCast(&rand_int));
            const tmp_dir_sub_path = "tmp" ++ Dir.path.sep_str ++ std.fmt.hex(rand_int);

            write_file.generated_directory.path = try b.cache_root.join(arena, &.{tmp_dir_sub_path});

            try operate(write_file, open_dir_cache, .{
                .root_dir = b.cache_root,
                .sub_path = tmp_dir_sub_path,
            });
        },
        .mutate => |lp| {
            step.result_cached = false;
            const root_path = try lp.getPath4(b, step);
            write_file.generated_directory.path = try root_path.toString(arena);
            try operate(write_file, open_dir_cache, root_path);
        },
    }
}

fn operate(write_file: *WriteFile, open_dir_cache: []const Io.Dir, root_path: std.Build.Cache.Path) !void {
    const step = &write_file.step;
    const b = step.owner;
    const io = b.graph.io;
    const gpa = b.graph.cache.gpa;
    const arena = b.allocator;

    var cache_dir = root_path.root_dir.handle.createDirPathOpen(io, root_path.sub_path, .{}) catch |err|
        return step.fail("unable to make path {f}: {t}", .{ root_path, err });
    defer cache_dir.close(io);

    for (write_file.files.items) |file| {
        if (Dir.path.dirname(file.sub_path)) |dirname| {
            cache_dir.createDirPath(io, dirname) catch |err| {
                return step.fail("unable to make path '{f}{c}{s}': {t}", .{
                    root_path, Dir.path.sep, dirname, err,
                });
            };
        }
        switch (file.contents) {
            .bytes => |bytes| {
                cache_dir.writeFile(io, .{ .sub_path = file.sub_path, .data = bytes }) catch |err| {
                    return step.fail("unable to write file '{f}{c}{s}': {t}", .{
                        root_path, Dir.path.sep, file.sub_path, err,
                    });
                };
            },
            .copy => |file_source| {
                const source_path = file_source.getPath2(b, step);
                const prev_status = Io.Dir.updateFile(.cwd(), io, source_path, cache_dir, file.sub_path, .{}) catch |err| {
                    return step.fail("unable to update file from '{s}' to '{f}{c}{s}': {t}", .{
                        source_path, root_path, Dir.path.sep, file.sub_path, err,
                    });
                };
                // At this point we already will mark the step as a cache miss.
                // But this is kind of a partial cache hit since individual
                // file copies may be avoided. Oh well, this information is
                // discarded.
                _ = prev_status;
            },
        }
    }

    for (write_file.directories.items, open_dir_cache) |dir, already_open_dir| {
        const src_dir_path = dir.source.getPath3(b, step);
        const dest_dirname = dir.sub_path;

        if (dest_dirname.len != 0) {
            cache_dir.createDirPath(io, dest_dirname) catch |err| {
                return step.fail("unable to make path '{f}{c}{s}': {t}", .{
                    root_path, Dir.path.sep, dest_dirname, err,
                });
            };
        }

        var it = try already_open_dir.walk(gpa);
        defer it.deinit();
        while (try it.next(io)) |entry| {
            if (!dir.options.pathIncluded(entry.path)) continue;

            const src_entry_path = try src_dir_path.join(arena, entry.path);
            const dest_path = b.pathJoin(&.{ dest_dirname, entry.path });
            switch (entry.kind) {
                .directory => try cache_dir.createDirPath(io, dest_path),
                .file => {
                    const prev_status = Io.Dir.updateFile(
                        src_entry_path.root_dir.handle,
                        io,
                        src_entry_path.sub_path,
                        cache_dir,
                        dest_path,
                        .{},
                    ) catch |err| {
                        return step.fail("unable to update file from '{f}' to '{f}{c}{s}': {t}", .{
                            src_entry_path, root_path, Dir.path.sep, dest_path, err,
                        });
                    };
                    _ = prev_status;
                },
                else => continue,
            }
        }
    }
}
