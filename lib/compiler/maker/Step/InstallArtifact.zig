
fn make(step: *Step, options: Step.MakeOptions) !void {
    _ = options;
    const install_artifact: *InstallArtifact = @fieldParentPtr("step", step);
    const b = step.owner;
    const io = b.graph.io;

    var all_cached = true;

    if (install_artifact.dest_dir) |dest_dir| {
        const full_dest_path = b.getInstallPath(dest_dir, install_artifact.dest_sub_path);
        const p = try step.installFile(install_artifact.emitted_bin.?, full_dest_path);
        all_cached = all_cached and p == .fresh;

        if (install_artifact.dylib_symlinks) |dls| {
            try Step.Compile.doAtomicSymLinks(step, full_dest_path, dls.major_only_filename, dls.name_only_filename);
        }

        install_artifact.artifact.installed_path = full_dest_path;
    }

    if (install_artifact.compiler_rt_dyn_lib_dir) |compiler_rt_dir| {
        const full_compiler_rt_path = b.getInstallPath(compiler_rt_dir, install_artifact.emitted_compiler_rt_dyn_lib.?.basename(b, step));
        const p = try step.installFile(install_artifact.emitted_compiler_rt_dyn_lib.?, full_compiler_rt_path);
        all_cached = all_cached and p == .fresh;
    }

    if (install_artifact.implib_dir) |implib_dir| {
        const full_implib_path = b.getInstallPath(implib_dir, install_artifact.emitted_implib.?.basename(b, step));
        const p = try step.installFile(install_artifact.emitted_implib.?, full_implib_path);
        all_cached = all_cached and p == .fresh;
    }

    if (install_artifact.pdb_dir) |pdb_dir| {
        const full_pdb_path = b.getInstallPath(pdb_dir, install_artifact.emitted_pdb.?.basename(b, step));
        const p = try step.installFile(install_artifact.emitted_pdb.?, full_pdb_path);
        all_cached = all_cached and p == .fresh;
    }

    if (install_artifact.h_dir) |h_dir| {
        if (install_artifact.emitted_h) |emitted_h| {
            const full_h_path = b.getInstallPath(h_dir, emitted_h.basename(b, step));
            const p = try step.installFile(emitted_h, full_h_path);
            all_cached = all_cached and p == .fresh;
        }

        for (install_artifact.artifact.installed_headers.items) |installation| switch (installation) {
            .file => |file| {
                const full_h_path = b.getInstallPath(h_dir, file.dest_rel_path);
                const p = try step.installFile(file.source, full_h_path);
                all_cached = all_cached and p == .fresh;
            },
            .directory => |dir| {
                const src_dir_path = dir.source.getPath3(b, step);
                const full_h_prefix = b.getInstallPath(h_dir, dir.dest_rel_path);

                var src_dir = src_dir_path.root_dir.handle.openDir(io, src_dir_path.subPathOrDot(), .{ .iterate = true }) catch |err| {
                    return step.fail("unable to open source directory '{f}': {s}", .{
                        src_dir_path, @errorName(err),
                    });
                };
                defer src_dir.close(io);

                var it = try src_dir.walk(b.allocator);
                next_entry: while (try it.next(io)) |entry| {
                    for (dir.options.exclude_extensions) |ext| {
                        if (std.mem.endsWith(u8, entry.path, ext)) continue :next_entry;
                    }
                    if (dir.options.include_extensions) |incs| {
                        for (incs) |inc| {
                            if (std.mem.endsWith(u8, entry.path, inc)) break;
                        } else {
                            continue :next_entry;
                        }
                    }

                    const full_dest_path = b.pathJoin(&.{ full_h_prefix, entry.path });
                    switch (entry.kind) {
                        .directory => {
                            try Step.handleVerbose(b, .inherit, &.{ "install", "-d", full_dest_path });
                            const p = try step.installDir(full_dest_path);
                            all_cached = all_cached and p == .existed;
                        },
                        .file => {
                            const p = try step.installFile(try dir.source.join(b.allocator, entry.path), full_dest_path);
                            all_cached = all_cached and p == .fresh;
                        },
                        else => continue,
                    }
                }
            },
        };
    }

    step.result_cached = all_cached;
}
