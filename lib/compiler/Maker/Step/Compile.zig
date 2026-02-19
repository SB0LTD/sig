const Compile = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Configuration = std.Build.Configuration;
const Dir = std.Io.Dir;
const Path = std.Build.Cache.Path;
const Module = std.Build.Configuration.Module;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const assert = std.debug.assert;
const mem = std.mem;

const Step = @import("../Step.zig");
const Maker = @import("../../Maker.zig");

/// Populated during the make phase when there is a long-lived compiler process.
/// Managed by the build runner, not user build script.
zig_process: ?*Step.ZigProcess = null,

pub fn make(
    compile: *Compile,
    step_index: Configuration.Step.Index,
    maker: *Maker,
    progress_node: std.Progress.Node,
) Step.ExtendedMakeError!void {
    if (true) @panic("TODO implement compile.make()");
    const graph = maker.graph;
    const step = maker.stepByIndex(step_index);
    const zig_args = try getZigArgs(compile, maker, false);
    const process_arena = graph.arena; // TODO don't leak into the process_arena

    const maybe_output_dir = step.evalZigProcess(
        zig_args,
        progress_node,
        (graph.incremental == true) and (maker.watch or maker.web_server != null),
        maker,
    ) catch |err| switch (err) {
        error.NeedCompileErrorCheck => {
            assert(compile.expect_errors != null);
            try checkCompileErrors(compile);
            return;
        },
        else => |e| return e,
    };

    // Update generated files
    if (maybe_output_dir) |output_dir| {
        if (compile.emit_directory) |lp| {
            lp.path = try std.fmt.allocPrint(process_arena, "{f}", .{output_dir});
        }

        // zig fmt: off
        if (compile.generated_bin)     |lp| lp.path = compile.outputPath(output_dir, .bin);
        if (compile.generated_pdb)     |lp| lp.path = compile.outputPath(output_dir, .pdb);
        // hack for stage2_x86_64 + coff
        if (compile.generated_compiler_rt_dyn_lib) |lp| lp.path = compile.outputPath(output_dir, .compiler_rt_dyn_lib);
        if (compile.generated_implib)  |lp| lp.path = compile.outputPath(output_dir, .implib);
        if (compile.generated_h)       |lp| lp.path = compile.outputPath(output_dir, .h);
        if (compile.generated_docs)    |lp| lp.path = compile.outputPath(output_dir, .docs);
        if (compile.generated_asm)     |lp| lp.path = compile.outputPath(output_dir, .@"asm");
        if (compile.generated_llvm_ir) |lp| lp.path = compile.outputPath(output_dir, .llvm_ir);
        if (compile.generated_llvm_bc) |lp| lp.path = compile.outputPath(output_dir, .llvm_bc);
        // zig fmt: on
    }

    if (compile.kind == .lib and compile.linkage != null and compile.linkage.? == .dynamic and
        compile.version != null and compile.generated_bin != null and
        std.Build.wantSharedLibSymLinks(compile.rootModuleTarget()))
    {
        try doAtomicSymLinks(
            step,
            compile.getEmittedBin().getPath2(step.owner, step),
            compile.major_only_filename.?,
            compile.name_only_filename.?,
        );
    }
}

fn getZigArgs(compile: *Compile, maker: *Maker, fuzz: bool) ![][]const u8 {
    const step = &compile.step;
    const b = step.owner;
    const graph = maker.graph;
    const arena = graph.arena; // TODO don't leak into the process arena

    var zig_args = std.array_list.Managed([]const u8).init(arena);
    defer zig_args.deinit();

    try zig_args.append(graph.zig_exe);

    const cmd = switch (compile.kind) {
        .lib => "build-lib",
        .exe => "build-exe",
        .obj => "build-obj",
        .@"test" => "test",
        .test_obj => "test-obj",
    };
    try zig_args.append(cmd);

    if (b.reference_trace) |some| {
        try zig_args.append(try std.fmt.allocPrint(arena, "-freference-trace={d}", .{some}));
    }
    try addFlag(&zig_args, "allow-so-scripts", compile.allow_so_scripts orelse graph.allow_so_scripts);

    try addFlag(&zig_args, "llvm", compile.use_llvm);
    try addFlag(&zig_args, "lld", compile.use_lld);
    try addFlag(&zig_args, "new-linker", compile.use_new_linker);

    if (compile.root_module.resolved_target.?.query.ofmt) |ofmt| {
        try zig_args.append(try std.fmt.allocPrint(arena, "-ofmt={s}", .{@tagName(ofmt)}));
    }

    switch (compile.entry) {
        .default => {},
        .disabled => try zig_args.append("-fno-entry"),
        .enabled => try zig_args.append("-fentry"),
        .symbol_name => |entry_name| {
            try zig_args.append(try std.fmt.allocPrint(arena, "-fentry={s}", .{entry_name}));
        },
    }

    {
        for (compile.force_undefined_symbols.keys()) |symbol_name| {
            try zig_args.append("--force_undefined");
            try zig_args.append(symbol_name.*);
        }
    }

    if (compile.stack_size) |stack_size| {
        try zig_args.append("--stack");
        try zig_args.append(try std.fmt.allocPrint(arena, "{}", .{stack_size}));
    }

    if (fuzz) {
        try zig_args.append("-ffuzz");
    }

    {
        // Stores system libraries that have already been seen for at least one
        // module, along with any arguments that need to be passed to the
        // compiler for each module individually.
        var seen_system_libs: std.StringHashMapUnmanaged([]const []const u8) = .empty;
        var frameworks: std.StringArrayHashMapUnmanaged(Module.FrameworkFlags) = .empty;

        var prev_has_cflags = false;
        var prev_has_rcflags = false;
        var prev_search_strategy: Module.SystemLib.SearchStrategy = .paths_first;
        var prev_preferred_link_mode: std.builtin.LinkMode = .dynamic;
        // Track the number of positional arguments so that a nice error can be
        // emitted if there is nothing to link.
        var total_linker_objects: usize = @intFromBool(compile.root_module.root_source_file != null);

        // Fully recursive iteration including dynamic libraries to detect
        // libc and libc++ linkage.
        for (getCompileDependencies(true)) |some_compile| {
            for (some_compile.root_module.getGraph().modules) |mod| {
                if (mod.link_libc == true) compile.is_linking_libc = true;
                if (mod.link_libcpp == true) compile.is_linking_libcpp = true;
            }
        }

        var cli_named_modules = try CliNamedModules.init(arena, compile.root_module);

        // For this loop, don't chase dynamic libraries because their link
        // objects are already linked.
        for (getCompileDependencies(false)) |dep_compile| {
            for (dep_compile.root_module.getGraph().modules) |mod| {
                // While walking transitive dependencies, if a given link object is
                // already included in a library, it should not redundantly be
                // placed on the linker line of the dependee.
                const my_responsibility = dep_compile == compile;
                const already_linked = !my_responsibility and dep_compile.isDynamicLibrary();

                // Inherit dependencies on darwin frameworks.
                if (!already_linked) {
                    for (mod.frameworks.keys(), mod.frameworks.values()) |name, info| {
                        try frameworks.put(arena, name, info);
                    }
                }

                // Inherit dependencies on system libraries and static libraries.
                for (mod.link_objects.items) |link_object| {
                    switch (link_object) {
                        .static_path => |static_path| {
                            if (my_responsibility) {
                                try zig_args.append(static_path.getPath2(mod.owner, step));
                                total_linker_objects += 1;
                            }
                        },
                        .system_lib => |system_lib| {
                            const system_lib_gop = try seen_system_libs.getOrPut(arena, system_lib.name);
                            if (system_lib_gop.found_existing) {
                                try zig_args.appendSlice(system_lib_gop.value_ptr.*);
                                continue;
                            } else {
                                system_lib_gop.value_ptr.* = &.{};
                            }

                            if (already_linked)
                                continue;

                            if ((system_lib.search_strategy != prev_search_strategy or
                                system_lib.preferred_link_mode != prev_preferred_link_mode) and
                                compile.linkage != .static)
                            {
                                switch (system_lib.search_strategy) {
                                    .no_fallback => switch (system_lib.preferred_link_mode) {
                                        .dynamic => try zig_args.append("-search_dylibs_only"),
                                        .static => try zig_args.append("-search_static_only"),
                                    },
                                    .paths_first => switch (system_lib.preferred_link_mode) {
                                        .dynamic => try zig_args.append("-search_paths_first"),
                                        .static => try zig_args.append("-search_paths_first_static"),
                                    },
                                    .mode_first => switch (system_lib.preferred_link_mode) {
                                        .dynamic => try zig_args.append("-search_dylibs_first"),
                                        .static => try zig_args.append("-search_static_first"),
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
                                .no => try zig_args.append(b.fmt("{s}{s}", .{ prefix, system_lib.name })),
                                .yes, .force => {
                                    if (compile.runPkgConfig(maker, system_lib.name)) |result| {
                                        try zig_args.appendSlice(result.cflags);
                                        try zig_args.appendSlice(result.libs);
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
                                                try zig_args.append(b.fmt("{s}{s}", .{
                                                    prefix,
                                                    system_lib.name,
                                                }));
                                            },
                                            .force => {
                                                return step.fail("pkg-config failed for library {s}", .{system_lib.name});
                                            },
                                            .no => unreachable,
                                        },

                                        else => |e| return e,
                                    }
                                },
                            }
                        },
                        .other_step => |other| {
                            switch (other.kind) {
                                .exe => return step.fail("cannot link with an executable build artifact", .{}),
                                .@"test" => return step.fail("cannot link with a test", .{}),
                                .obj, .test_obj => {
                                    const included_in_lib_or_obj = !my_responsibility and
                                        (dep_compile.kind == .lib or dep_compile.kind == .obj or dep_compile.kind == .test_obj);
                                    if (!already_linked and !included_in_lib_or_obj) {
                                        try zig_args.append(other.getEmittedBin().getPath2(b, step));
                                        total_linker_objects += 1;
                                    }
                                },
                                .lib => l: {
                                    const other_produces_implib = other.producesImplib();
                                    const other_is_static = other_produces_implib or other.isStaticLibrary();

                                    if (compile.isStaticLibrary() and other_is_static) {
                                        // Avoid putting a static library inside a static library.
                                        break :l;
                                    }

                                    // For DLLs, we must link against the implib.
                                    // For everything else, we directly link
                                    // against the library file.
                                    const full_path_lib = if (other_produces_implib)
                                        try other.getGeneratedFilePath("generated_implib", &compile.step)
                                    else
                                        try other.getGeneratedFilePath("generated_bin", &compile.step);

                                    try zig_args.append(full_path_lib);
                                    total_linker_objects += 1;

                                    if (other.linkage == .dynamic and
                                        compile.rootModuleTarget().os.tag != .windows)
                                    {
                                        if (Dir.path.dirname(full_path_lib)) |dirname| {
                                            try zig_args.append("-rpath");
                                            try zig_args.append(dirname);
                                        }
                                    }
                                },
                            }
                        },
                        .assembly_file => |asm_file| l: {
                            if (!my_responsibility) break :l;

                            if (prev_has_cflags) {
                                try zig_args.append("-cflags");
                                try zig_args.append("--");
                                prev_has_cflags = false;
                            }
                            try zig_args.append(asm_file.getPath2(mod.owner, step));
                            total_linker_objects += 1;
                        },

                        .c_source_file => |c_source_file| l: {
                            if (!my_responsibility) break :l;

                            if (prev_has_cflags or c_source_file.flags.len != 0) {
                                try zig_args.append("-cflags");
                                for (c_source_file.flags) |arg| {
                                    try zig_args.append(arg);
                                }
                                try zig_args.append("--");
                            }
                            prev_has_cflags = (c_source_file.flags.len != 0);

                            if (c_source_file.language) |lang| {
                                try zig_args.append("-x");
                                try zig_args.append(lang.internalIdentifier());
                            }

                            try zig_args.append(c_source_file.file.getPath2(mod.owner, step));

                            if (c_source_file.language != null) {
                                try zig_args.append("-x");
                                try zig_args.append("none");
                            }
                            total_linker_objects += 1;
                        },

                        .c_source_files => |c_source_files| l: {
                            if (!my_responsibility) break :l;

                            if (prev_has_cflags or c_source_files.flags.len != 0) {
                                try zig_args.append("-cflags");
                                for (c_source_files.flags) |arg| {
                                    try zig_args.append(arg);
                                }
                                try zig_args.append("--");
                            }
                            prev_has_cflags = (c_source_files.flags.len != 0);

                            if (c_source_files.language) |lang| {
                                try zig_args.append("-x");
                                try zig_args.append(lang.internalIdentifier());
                            }

                            const root_path = c_source_files.root.getPath2(mod.owner, step);
                            for (c_source_files.files) |file| {
                                try zig_args.append(b.pathJoin(&.{ root_path, file }));
                            }

                            if (c_source_files.language != null) {
                                try zig_args.append("-x");
                                try zig_args.append("none");
                            }

                            total_linker_objects += c_source_files.files.len;
                        },

                        .win32_resource_file => |rc_source_file| l: {
                            if (!my_responsibility) break :l;

                            if (rc_source_file.flags.len == 0 and rc_source_file.include_paths.len == 0) {
                                if (prev_has_rcflags) {
                                    try zig_args.append("-rcflags");
                                    try zig_args.append("--");
                                    prev_has_rcflags = false;
                                }
                            } else {
                                try zig_args.append("-rcflags");
                                for (rc_source_file.flags) |arg| {
                                    try zig_args.append(arg);
                                }
                                for (rc_source_file.include_paths) |include_path| {
                                    try zig_args.append("/I");
                                    try zig_args.append(include_path.getPath2(mod.owner, step));
                                }
                                try zig_args.append("--");
                                prev_has_rcflags = true;
                            }
                            try zig_args.append(rc_source_file.file.getPath2(mod.owner, step));
                            total_linker_objects += 1;
                        },
                    }
                }

                // We need to emit the --mod argument here so that the above link objects
                // have the correct parent module, but only if the module is part of
                // this compilation.
                if (!my_responsibility) continue;
                if (cli_named_modules.modules.getIndex(mod)) |module_cli_index| {
                    const module_cli_name = cli_named_modules.names.keys()[module_cli_index];
                    try mod.appendZigProcessFlags(&zig_args, step);

                    // --dep arguments
                    try zig_args.ensureUnusedCapacity(mod.import_table.count() * 2);
                    for (mod.import_table.keys(), mod.import_table.values()) |name, import| {
                        const import_index = cli_named_modules.modules.getIndex(import).?;
                        const import_cli_name = cli_named_modules.names.keys()[import_index];
                        zig_args.appendAssumeCapacity("--dep");
                        if (std.mem.eql(u8, import_cli_name, name)) {
                            zig_args.appendAssumeCapacity(import_cli_name);
                        } else {
                            zig_args.appendAssumeCapacity(b.fmt("{s}={s}", .{ name, import_cli_name }));
                        }
                    }

                    // When the CLI sees a -M argument, it determines whether it
                    // implies the existence of a Zig compilation unit based on
                    // whether there is a root source file. If there is no root
                    // source file, then this is not a zig compilation unit - it is
                    // perhaps a set of linker objects, or C source files instead.
                    // Linker objects are added to the CLI globally, while C source
                    // files must have a module parent.
                    if (mod.root_source_file) |lp| {
                        const src = lp.getPath2(mod.owner, step);
                        try zig_args.append(b.fmt("-M{s}={s}", .{ module_cli_name, src }));
                    } else if (moduleNeedsCliArg(mod)) {
                        try zig_args.append(b.fmt("-M{s}", .{module_cli_name}));
                    }
                }
            }
        }

        if (total_linker_objects == 0) {
            return step.fail("the linker needs one or more objects to link", .{});
        }

        for (frameworks.keys(), frameworks.values()) |name, info| {
            if (info.needed) {
                try zig_args.append("-needed_framework");
            } else if (info.weak) {
                try zig_args.append("-weak_framework");
            } else {
                try zig_args.append("-framework");
            }
            try zig_args.append(name);
        }

        if (compile.is_linking_libcpp) {
            try zig_args.append("-lc++");
        }

        if (compile.is_linking_libc) {
            try zig_args.append("-lc");
        }
    }

    if (compile.win32_manifest) |manifest_file| {
        try zig_args.append(manifest_file.getPath2(b, step));
    }

    if (compile.win32_module_definition) |module_file| {
        try zig_args.append(module_file.getPath2(b, step));
    }

    if (compile.image_base) |image_base| {
        try zig_args.append("--image-base");
        try zig_args.append(b.fmt("0x{x}", .{image_base}));
    }

    for (compile.filters) |filter| {
        try zig_args.append("--test-filter");
        try zig_args.append(filter);
    }

    if (compile.test_runner) |test_runner| {
        try zig_args.append("--test-runner");
        try zig_args.append(test_runner.path.getPath2(b, step));
    }

    for (b.debug_log_scopes) |log_scope| {
        try zig_args.append("--debug-log");
        try zig_args.append(log_scope);
    }

    if (b.debug_compile_errors) {
        try zig_args.append("--debug-compile-errors");
    }

    if (b.debug_incremental) {
        try zig_args.append("--debug-incremental");
    }

    if (b.verbose_air) try zig_args.append("--verbose-air");
    if (b.verbose_llvm_ir) |path| try zig_args.append(b.fmt("--verbose-llvm-ir={s}", .{path}));
    if (b.verbose_llvm_bc) |path| try zig_args.append(b.fmt("--verbose-llvm-bc={s}", .{path}));
    if (b.verbose_link or compile.verbose_link) try zig_args.append("--verbose-link");
    if (b.verbose_cc or compile.verbose_cc) try zig_args.append("--verbose-cc");
    if (b.verbose_llvm_cpu_features) try zig_args.append("--verbose-llvm-cpu-features");
    if (graph.time_report) try zig_args.append("--time-report");

    if (compile.generated_asm != null) try zig_args.append("-femit-asm");
    if (compile.generated_bin == null) try zig_args.append("-fno-emit-bin");
    if (compile.generated_docs != null) try zig_args.append("-femit-docs");
    if (compile.generated_implib != null) try zig_args.append("-femit-implib");
    if (compile.generated_llvm_bc != null) try zig_args.append("-femit-llvm-bc");
    if (compile.generated_llvm_ir != null) try zig_args.append("-femit-llvm-ir");
    if (compile.generated_h != null) try zig_args.append("-femit-h");

    try addFlag(&zig_args, "formatted-panics", compile.formatted_panics);

    switch (compile.compress_debug_sections) {
        .none => {},
        .zlib => try zig_args.append("--compress-debug-sections=zlib"),
        .zstd => try zig_args.append("--compress-debug-sections=zstd"),
    }

    if (compile.link_eh_frame_hdr) {
        try zig_args.append("--eh-frame-hdr");
    }
    if (compile.link_emit_relocs) {
        try zig_args.append("--emit-relocs");
    }
    if (compile.link_function_sections) {
        try zig_args.append("-ffunction-sections");
    }
    if (compile.link_data_sections) {
        try zig_args.append("-fdata-sections");
    }
    if (compile.link_gc_sections) |x| {
        try zig_args.append(if (x) "--gc-sections" else "--no-gc-sections");
    }
    if (!compile.linker_dynamicbase) {
        try zig_args.append("--no-dynamicbase");
    }
    if (compile.linker_allow_shlib_undefined) |x| {
        try zig_args.append(if (x) "-fallow-shlib-undefined" else "-fno-allow-shlib-undefined");
    }
    if (compile.link_z_notext) {
        try zig_args.append("-z");
        try zig_args.append("notext");
    }
    if (!compile.link_z_relro) {
        try zig_args.append("-z");
        try zig_args.append("norelro");
    }
    if (compile.link_z_lazy) {
        try zig_args.append("-z");
        try zig_args.append("lazy");
    }
    if (compile.link_z_common_page_size) |size| {
        try zig_args.append("-z");
        try zig_args.append(b.fmt("common-page-size={d}", .{size}));
    }
    if (compile.link_z_max_page_size) |size| {
        try zig_args.append("-z");
        try zig_args.append(b.fmt("max-page-size={d}", .{size}));
    }
    if (compile.link_z_defs) {
        try zig_args.append("-z");
        try zig_args.append("defs");
    }

    if (compile.libc_file) |libc_file| {
        try zig_args.append("--libc");
        try zig_args.append(libc_file.getPath2(b, step));
    } else if (b.libc_file) |libc_file| {
        try zig_args.append("--libc");
        try zig_args.append(libc_file);
    }

    try zig_args.append("--cache-dir");
    try zig_args.append(b.cache_root.path orelse ".");

    try zig_args.append("--global-cache-dir");
    try zig_args.append(graph.global_cache_root.path orelse ".");

    if (graph.debug_compiler_runtime_libs) |mode|
        try zig_args.append(b.fmt("--debug-rt={t}", .{mode}));

    try zig_args.append("--name");
    try zig_args.append(compile.name);

    if (compile.linkage) |some| switch (some) {
        .dynamic => try zig_args.append("-dynamic"),
        .static => try zig_args.append("-static"),
    };
    if (compile.kind == .lib and compile.linkage != null and compile.linkage.? == .dynamic) {
        if (compile.version) |version| {
            try zig_args.append("--version");
            try zig_args.append(b.fmt("{f}", .{version}));
        }

        if (compile.rootModuleTarget().os.tag.isDarwin()) {
            const install_name = compile.install_name orelse b.fmt("@rpath/{s}{s}{s}", .{
                compile.rootModuleTarget().libPrefix(),
                compile.name,
                compile.rootModuleTarget().dynamicLibSuffix(),
            });
            try zig_args.append("-install_name");
            try zig_args.append(install_name);
        }
    }

    if (compile.entitlements) |entitlements| {
        try zig_args.appendSlice(&[_][]const u8{ "--entitlements", entitlements });
    }
    if (compile.pagezero_size) |pagezero_size| {
        const size = try std.fmt.allocPrint(arena, "{x}", .{pagezero_size});
        try zig_args.appendSlice(&[_][]const u8{ "-pagezero_size", size });
    }
    if (compile.headerpad_size) |headerpad_size| {
        const size = try std.fmt.allocPrint(arena, "{x}", .{headerpad_size});
        try zig_args.appendSlice(&[_][]const u8{ "-headerpad", size });
    }
    if (compile.headerpad_max_install_names) {
        try zig_args.append("-headerpad_max_install_names");
    }
    if (compile.dead_strip_dylibs) {
        try zig_args.append("-dead_strip_dylibs");
    }
    if (compile.force_load_objc) {
        try zig_args.append("-ObjC");
    }
    if (compile.discard_local_symbols) {
        try zig_args.append("--discard-all");
    }

    try addFlag(&zig_args, "compiler-rt", compile.bundle_compiler_rt);
    try addFlag(&zig_args, "ubsan-rt", compile.bundle_ubsan_rt);
    try addFlag(&zig_args, "dll-export-fns", compile.dll_export_fns);
    if (compile.rdynamic) {
        try zig_args.append("-rdynamic");
    }
    if (compile.import_memory) {
        try zig_args.append("--import-memory");
    }
    if (compile.export_memory) {
        try zig_args.append("--export-memory");
    }
    if (compile.import_symbols) {
        try zig_args.append("--import-symbols");
    }
    if (compile.import_table) {
        try zig_args.append("--import-table");
    }
    if (compile.export_table) {
        try zig_args.append("--export-table");
    }
    if (compile.initial_memory) |initial_memory| {
        try zig_args.append(b.fmt("--initial-memory={d}", .{initial_memory}));
    }
    if (compile.max_memory) |max_memory| {
        try zig_args.append(b.fmt("--max-memory={d}", .{max_memory}));
    }
    if (compile.shared_memory) {
        try zig_args.append("--shared-memory");
    }
    if (compile.global_base) |global_base| {
        try zig_args.append(b.fmt("--global-base={d}", .{global_base}));
    }

    if (compile.wasi_exec_model) |model| {
        try zig_args.append(b.fmt("-mexec-model={s}", .{@tagName(model)}));
    }
    if (compile.linker_script) |linker_script| {
        try zig_args.append("--script");
        try zig_args.append(linker_script.getPath2(b, step));
    }

    if (compile.version_script) |version_script| {
        try zig_args.append("--version-script");
        try zig_args.append(version_script.getPath2(b, step));
    }
    if (compile.linker_allow_undefined_version) |x| {
        try zig_args.append(if (x) "--undefined-version" else "--no-undefined-version");
    }

    if (compile.linker_enable_new_dtags) |enabled| {
        try zig_args.append(if (enabled) "--enable-new-dtags" else "--disable-new-dtags");
    }

    if (compile.kind == .@"test") {
        if (compile.exec_cmd_args) |exec_cmd_args| {
            for (exec_cmd_args) |cmd_arg| {
                if (cmd_arg) |arg| {
                    try zig_args.append("--test-cmd");
                    try zig_args.append(arg);
                } else {
                    try zig_args.append("--test-cmd-bin");
                }
            }
        }
    }

    if (b.sysroot) |sysroot| {
        try zig_args.appendSlice(&[_][]const u8{ "--sysroot", sysroot });
    }

    // -I and -L arguments that appear after the last --mod argument apply to all modules.
    const cwd: Io.Dir = .cwd();
    const io = graph.io;

    for (b.search_prefixes.items) |search_prefix| {
        var prefix_dir = cwd.openDir(io, search_prefix, .{}) catch |err| {
            return step.fail("unable to open prefix directory '{s}': {s}", .{
                search_prefix, @errorName(err),
            });
        };
        defer prefix_dir.close(io);

        // Avoid passing -L and -I flags for nonexistent directories.
        // This prevents a warning, that should probably be upgraded to an error in Zig's
        // CLI parsing code, when the linker sees an -L directory that does not exist.

        if (prefix_dir.access(io, "lib", .{})) |_| {
            try zig_args.appendSlice(&.{
                "-L", b.pathJoin(&.{ search_prefix, "lib" }),
            });
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return step.fail("unable to access '{s}/lib' directory: {s}", .{
                search_prefix, @errorName(e),
            }),
        }

        if (prefix_dir.access(io, "include", .{})) |_| {
            try zig_args.appendSlice(&.{
                "-I", b.pathJoin(&.{ search_prefix, "include" }),
            });
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return step.fail("unable to access '{s}/include' directory: {s}", .{
                search_prefix, @errorName(e),
            }),
        }
    }

    if (compile.rc_includes != .any) {
        try zig_args.append("-rcincludes");
        try zig_args.append(@tagName(compile.rc_includes));
    }

    try addFlag(&zig_args, "each-lib-rpath", compile.each_lib_rpath);

    if (compile.build_id orelse b.build_id) |build_id| {
        try zig_args.append(switch (build_id) {
            .hexstring => |hs| b.fmt("--build-id=0x{x}", .{hs.toSlice()}),
            .none, .fast, .uuid, .sha1, .md5 => b.fmt("--build-id={s}", .{@tagName(build_id)}),
        });
    }

    const opt_zig_lib_dir = if (compile.zig_lib_dir) |dir|
        dir.getPath2(b, step)
    else if (graph.zig_lib_directory.path) |_|
        b.fmt("{f}", .{graph.zig_lib_directory})
    else
        null;

    if (opt_zig_lib_dir) |zig_lib_dir| {
        try zig_args.append("--zig-lib-dir");
        try zig_args.append(zig_lib_dir);
    }

    try addFlag(&zig_args, "PIE", compile.pie);

    if (compile.lto) |lto| {
        try zig_args.append(switch (lto) {
            .full => "-flto=full",
            .thin => "-flto=thin",
            .none => "-fno-lto",
        });
    }

    try addFlag(&zig_args, "sanitize-coverage-trace-pc-guard", compile.sanitize_coverage_trace_pc_guard);

    if (compile.subsystem) |subsystem| {
        try zig_args.append("--subsystem");
        try zig_args.append(@tagName(subsystem));
    }

    if (compile.mingw_unicode_entry_point) {
        try zig_args.append("-municode");
    }

    if (compile.error_limit) |err_limit| try zig_args.appendSlice(&.{
        "--error-limit", b.fmt("{d}", .{err_limit}),
    });

    try addFlag(&zig_args, "incremental", graph.incremental);

    try zig_args.append("--listen=-");

    // Windows has an argument length limit of 32,766 characters, macOS 262,144 and Linux
    // 2,097,152. If our args exceed 30 KiB, we instead write them to a "response file" and
    // pass that to zig, e.g. via 'zig build-lib @args.rsp'
    // See @file syntax here: https://gcc.gnu.org/onlinedocs/gcc/Overall-Options.html
    var args_length: usize = 0;
    for (zig_args.items) |arg| {
        args_length += arg.len + 1; // +1 to account for null terminator
    }
    if (args_length >= 30 * 1024) {
        try b.cache_root.handle.createDirPath(io, "args");

        const args_to_escape = zig_args.items[2..];
        var escaped_args = try std.array_list.Managed([]const u8).initCapacity(arena, args_to_escape.len);
        arg_blk: for (args_to_escape) |arg| {
            for (arg, 0..) |c, arg_idx| {
                if (c == '\\' or c == '"') {
                    // Slow path for arguments that need to be escaped. We'll need to allocate and copy
                    var escaped: std.ArrayList(u8) = .empty;
                    try escaped.ensureTotalCapacityPrecise(arena, arg.len + 1);
                    try escaped.appendSlice(arena, arg[0..arg_idx]);
                    for (arg[arg_idx..]) |to_escape| {
                        if (to_escape == '\\' or to_escape == '"') try escaped.append(arena, '\\');
                        try escaped.append(arena, to_escape);
                    }
                    escaped_args.appendAssumeCapacity(escaped.items);
                    continue :arg_blk;
                }
            }
            escaped_args.appendAssumeCapacity(arg); // no escaping needed so just use original argument
        }

        // Write the args to zig-cache/args/<SHA256 hash of args> to avoid conflicts with
        // other zig build commands running in parallel.
        const partially_quoted = try std.mem.join(arena, "\" \"", escaped_args.items);
        const args = try std.mem.concat(arena, u8, &[_][]const u8{ "\"", partially_quoted, "\"" });

        var args_hash: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(args, &args_hash, .{});
        var args_hex_hash: [Sha256.digest_length * 2]u8 = undefined;
        _ = try std.fmt.bufPrint(&args_hex_hash, "{x}", .{&args_hash});

        const args_file = "args" ++ Dir.path.sep_str ++ args_hex_hash;
        if (b.cache_root.handle.access(io, args_file, .{})) |_| {
            // The args file is already present from a previous run.
        } else |err| switch (err) {
            error.FileNotFound => {
                var af = b.cache_root.handle.createFileAtomic(io, args_file, .{
                    .replace = false,
                    .make_path = true,
                }) catch |e| return step.fail("failed creating tmp args file {f}{s}: {t}", .{
                    b.cache_root, args_file, e,
                });
                defer af.deinit(io);

                af.file.writeStreamingAll(io, args) catch |e| {
                    return step.fail("failed writing args data to tmp file {f}{s}: {t}", .{
                        b.cache_root, args_file, e,
                    });
                };
                // Note we can't clean up this file, not even after build
                // success, because that might interfere with another build
                // process that needs the same file.
                af.link(io) catch |e| switch (e) {
                    error.PathAlreadyExists => {
                        // The args file was created by another concurrent build process.
                    },
                    else => |other_err| return step.fail("failed linking tmp file {f}{s}: {t}", .{
                        b.cache_root, args_file, other_err,
                    }),
                };
            },
            else => |other_err| return other_err,
        }

        const resolved_args_file = try mem.concat(arena, u8, &.{
            "@",
            try b.cache_root.join(arena, &.{args_file}),
        });

        zig_args.shrinkRetainingCapacity(2);
        try zig_args.append(resolved_args_file);
    }

    return try zig_args.toOwnedSlice();
}

pub fn rebuildInFuzzMode(c: *Compile, maker: *Maker, progress_node: std.Progress.Node) !Path {
    const gpa = maker.graph.gpa;

    c.step.result_error_msgs.clearRetainingCapacity();
    c.step.result_stderr = "";

    c.step.result_error_bundle.deinit(gpa);
    c.step.result_error_bundle = std.zig.ErrorBundle.empty;

    if (c.step.result_failed_command) |cmd| {
        gpa.free(cmd);
        c.step.result_failed_command = null;
    }

    const zig_args = try getZigArgs(c, maker, true);
    const maybe_output_bin_path = try c.step.evalZigProcess(zig_args, progress_node, false, null, gpa);
    return maybe_output_bin_path.?;
}

pub fn doAtomicSymLinks(
    step: *Step,
    maker: *Maker,
    output_path: []const u8,
    filename_major_only: []const u8,
    filename_name_only: []const u8,
) !void {
    const b = step.owner;
    const graph = maker.graph;
    const io = graph.io;
    const out_dir = Dir.path.dirname(output_path) orelse ".";
    const out_basename = Dir.path.basename(output_path);
    // sym link for libfoo.so.1 to libfoo.so.1.2.3
    const major_only_path = b.pathJoin(&.{ out_dir, filename_major_only });
    const cwd: Io.Dir = .cwd();
    cwd.symLinkAtomic(io, out_basename, major_only_path, .{}) catch |err| {
        return step.fail("unable to symlink {s} -> {s}: {s}", .{
            major_only_path, out_basename, @errorName(err),
        });
    };
    // sym link for libfoo.so to libfoo.so.1
    const name_only_path = b.pathJoin(&.{ out_dir, filename_name_only });
    cwd.symLinkAtomic(io, filename_major_only, name_only_path, .{}) catch |err| {
        return step.fail("Unable to symlink {s} -> {s}: {s}", .{
            name_only_path, filename_major_only, @errorName(err),
        });
    };
}

pub const PkgConfigError = error{
    PkgConfigCrashed,
    PkgConfigFailed,
    PkgConfigNotInstalled,
    PkgConfigInvalidOutput,
};

pub const PkgConfigPkg = struct {
    name: []const u8,
    desc: []const u8,
};

fn execPkgConfigList(maker: *Maker, out_code: *u8) (PkgConfigError || Maker.RunError)![]const PkgConfigPkg {
    const graph = maker.graph;
    const process_arena = graph.arena; // TODO don't leak into process arena
    const pkg_config_exe = graph.environ_map.get("PKG_CONFIG") orelse "pkg-config";
    const stdout = try maker.runAllowFail(&[_][]const u8{ pkg_config_exe, "--list-all" }, out_code, .ignore);
    var list = std.array_list.Managed(PkgConfigPkg).init(process_arena);
    errdefer list.deinit();
    var line_it = mem.tokenizeAny(u8, stdout, "\r\n");
    while (line_it.next()) |line| {
        if (mem.trim(u8, line, " \t").len == 0) continue;
        var tok_it = mem.tokenizeAny(u8, line, " \t");
        try list.append(PkgConfigPkg{
            .name = tok_it.next() orelse return error.PkgConfigInvalidOutput,
            .desc = tok_it.rest(),
        });
    }
    return list.toOwnedSlice();
}

fn getPkgConfigList(b: *std.Build) ![]const PkgConfigPkg {
    if (b.pkg_config_pkg_list) |res| {
        return res;
    }
    var code: u8 = undefined;
    if (execPkgConfigList(b, &code)) |list| {
        b.pkg_config_pkg_list = list;
        return list;
    } else |err| {
        const result = switch (err) {
            error.ProcessTerminated => error.PkgConfigCrashed,
            error.ExecNotSupported => error.PkgConfigFailed,
            error.ExitCodeFailure => error.PkgConfigFailed,
            error.FileNotFound => error.PkgConfigNotInstalled,
            error.InvalidName => error.PkgConfigNotInstalled,
            error.PkgConfigInvalidOutput => error.PkgConfigInvalidOutput,
            else => return err,
        };
        b.pkg_config_pkg_list = result;
        return result;
    }
}

fn addFlag(args: *std.array_list.Managed([]const u8), comptime name: []const u8, opt: ?bool) !void {
    const cond = opt orelse return;
    try args.ensureUnusedCapacity(1);
    if (cond) {
        args.appendAssumeCapacity("-f" ++ name);
    } else {
        args.appendAssumeCapacity("-fno-" ++ name);
    }
}

const PkgConfigResult = struct {
    cflags: []const []const u8,
    libs: []const []const u8,
};

/// Run pkg-config for the given library name and parse the output, returning the arguments
/// that should be passed to zig to link the given library.
fn runPkgConfig(compile: *Compile, maker: *Maker, lib_name: []const u8) !PkgConfigResult {
    const graph = maker.graph;
    const wl_rpath_prefix = "-Wl,-rpath,";

    const b = compile.step.owner;
    const arena = b.allocator;
    const pkg_name = match: {
        // First we have to map the library name to pkg config name. Unfortunately,
        // there are several examples where this is not straightforward:
        // -lSDL2 -> pkg-config sdl2
        // -lgdk-3 -> pkg-config gdk-3.0
        // -latk-1.0 -> pkg-config atk
        // -lpulse -> pkg-config libpulse
        const pkgs = try getPkgConfigList(b);

        // Exact match means instant winner.
        for (pkgs) |pkg| {
            if (mem.eql(u8, pkg.name, lib_name)) {
                break :match pkg.name;
            }
        }

        // Next we'll try ignoring case.
        for (pkgs) |pkg| {
            if (std.ascii.eqlIgnoreCase(pkg.name, lib_name)) {
                break :match pkg.name;
            }
        }

        // Prefixed "lib" or suffixed ".0".
        for (pkgs) |pkg| {
            if (std.ascii.findIgnoreCase(pkg.name, lib_name)) |pos| {
                const prefix = pkg.name[0..pos];
                const suffix = pkg.name[pos + lib_name.len ..];
                if (prefix.len > 0 and !mem.eql(u8, prefix, "lib")) continue;
                if (suffix.len > 0 and !mem.eql(u8, suffix, ".0")) continue;
                break :match pkg.name;
            }
        }

        // Trimming "-1.0".
        if (mem.endsWith(u8, lib_name, "-1.0")) {
            const trimmed_lib_name = lib_name[0 .. lib_name.len - "-1.0".len];
            for (pkgs) |pkg| {
                if (std.ascii.eqlIgnoreCase(pkg.name, trimmed_lib_name)) {
                    break :match pkg.name;
                }
            }
        }

        return error.PackageNotFound;
    };

    var code: u8 = undefined;
    const pkg_config_exe = graph.environ_map.get("PKG_CONFIG") orelse "pkg-config";
    const stdout = if (b.runAllowFail(&[_][]const u8{
        pkg_config_exe,
        pkg_name,
        "--cflags",
        "--libs",
    }, &code, .ignore)) |stdout| stdout else |err| switch (err) {
        error.ProcessTerminated => return error.PkgConfigCrashed,
        error.ExecNotSupported => return error.PkgConfigFailed,
        error.ExitCodeFailure => return error.PkgConfigFailed,
        error.FileNotFound => return error.PkgConfigNotInstalled,
        else => return err,
    };

    var zig_cflags: std.ArrayList([]const u8) = .empty;
    defer zig_cflags.deinit(arena);
    var zig_libs: std.ArrayList([]const u8) = .empty;
    defer zig_libs.deinit(arena);

    var arg_it = mem.tokenizeAny(u8, stdout, " \r\n\t");
    while (arg_it.next()) |arg| {
        if (mem.eql(u8, arg, "-I")) {
            const dir = arg_it.next() orelse return error.PkgConfigInvalidOutput;
            try zig_cflags.appendSlice(arena, &.{ "-I", dir });
        } else if (mem.startsWith(u8, arg, "-I")) {
            try zig_cflags.append(arena, arg);
        } else if (mem.eql(u8, arg, "-L")) {
            const dir = arg_it.next() orelse return error.PkgConfigInvalidOutput;
            try zig_libs.appendSlice(arena, &.{ "-L", dir });
        } else if (mem.startsWith(u8, arg, "-L")) {
            try zig_libs.append(arena, arg);
        } else if (mem.eql(u8, arg, "-l")) {
            const lib = arg_it.next() orelse return error.PkgConfigInvalidOutput;
            try zig_libs.appendSlice(arena, &.{ "-l", lib });
        } else if (mem.startsWith(u8, arg, "-l")) {
            try zig_libs.append(arena, arg);
        } else if (mem.eql(u8, arg, "-D")) {
            const macro = arg_it.next() orelse return error.PkgConfigInvalidOutput;
            try zig_cflags.appendSlice(arena, &.{ "-D", macro });
        } else if (mem.startsWith(u8, arg, "-D")) {
            try zig_cflags.append(arena, arg);
        } else if (mem.startsWith(u8, arg, wl_rpath_prefix)) {
            try zig_cflags.appendSlice(arena, &.{ "-rpath", arg[wl_rpath_prefix.len..] });
        } else if (b.debug_pkg_config) {
            return compile.step.fail("unknown pkg-config flag '{s}'", .{arg});
        }
    }

    try zig_cflags.shrinkToLen(arena);
    try zig_libs.shrinkToLen(arena);

    return .{
        .cflags = zig_cflags.toOwnedSliceAssert(),
        .libs = zig_libs.toOwnedSliceAssert(),
    };
}

fn checkCompileErrors(compile: *Compile) !void {
    // Clear this field so that it does not get printed by the build runner.
    const actual_eb = compile.step.result_error_bundle;
    compile.step.result_error_bundle = .empty;

    const arena = compile.step.owner.allocator;

    const actual_errors = ae: {
        var aw: std.Io.Writer.Allocating = .init(arena);
        defer aw.deinit();
        try actual_eb.renderToWriter(.{
            .include_reference_trace = false,
            .include_source_line = false,
        }, &aw.writer);
        break :ae try aw.toOwnedSlice();
    };

    // Render the expected lines into a string that we can compare verbatim.
    var expected_generated: std.ArrayList(u8) = .empty;
    const expect_errors = compile.expect_errors.?;

    var actual_line_it = mem.splitScalar(u8, actual_errors, '\n');

    // TODO merge this with the testing.expectEqualStrings logic, and also CheckFile
    switch (expect_errors) {
        .starts_with => |expect_starts_with| {
            if (std.mem.startsWith(u8, actual_errors, expect_starts_with)) return;
            return compile.step.fail(
                \\
                \\========= should start with: ============
                \\{s}
                \\========= but not found: ================
                \\{s}
                \\=========================================
            , .{ expect_starts_with, actual_errors });
        },
        .contains => |expect_line| {
            while (actual_line_it.next()) |actual_line| {
                if (!matchCompileError(actual_line, expect_line)) continue;
                return;
            }

            return compile.step.fail(
                \\
                \\========= should contain: ===============
                \\{s}
                \\========= but not found: ================
                \\{s}
                \\=========================================
            , .{ expect_line, actual_errors });
        },
        .stderr_contains => |expect_line| {
            const actual_stderr: []const u8 = if (compile.step.result_error_msgs.items.len > 0)
                compile.step.result_error_msgs.items[0]
            else
                &.{};
            compile.step.result_error_msgs.clearRetainingCapacity();

            var stderr_line_it = mem.splitScalar(u8, actual_stderr, '\n');

            while (stderr_line_it.next()) |actual_line| {
                if (!matchCompileError(actual_line, expect_line)) continue;
                return;
            }

            return compile.step.fail(
                \\
                \\========= should contain: ===============
                \\{s}
                \\========= but not found: ================
                \\{s}
                \\=========================================
            , .{ expect_line, actual_stderr });
        },
        .exact => |expect_lines| {
            for (expect_lines) |expect_line| {
                const actual_line = actual_line_it.next() orelse {
                    try expected_generated.appendSlice(arena, expect_line);
                    try expected_generated.append(arena, '\n');
                    continue;
                };
                if (matchCompileError(actual_line, expect_line)) {
                    try expected_generated.appendSlice(arena, actual_line);
                    try expected_generated.append(arena, '\n');
                    continue;
                }
                try expected_generated.appendSlice(arena, expect_line);
                try expected_generated.append(arena, '\n');
            }

            if (mem.eql(u8, expected_generated.items, actual_errors)) return;

            return compile.step.fail(
                \\
                \\========= expected: =====================
                \\{s}
                \\========= but found: ====================
                \\{s}
                \\=========================================
            , .{ expected_generated.items, actual_errors });
        },
    }
}

fn matchCompileError(actual: []const u8, expected: []const u8) bool {
    if (mem.endsWith(u8, actual, expected)) return true;
    if (mem.startsWith(u8, expected, ":?:?: ")) {
        if (mem.endsWith(u8, actual, expected[":?:?: ".len..])) return true;
    }
    // We scan for /?/ in expected line and if there is a match, we match everything
    // up to and after /?/.
    const expected_trim = mem.trim(u8, expected, " ");
    if (mem.find(u8, expected_trim, "/?/")) |index| {
        const actual_trim = mem.trim(u8, actual, " ");
        const lhs = expected_trim[0..index];
        const rhs = expected_trim[index + "/?/".len ..];
        if (mem.startsWith(u8, actual_trim, lhs) and mem.endsWith(u8, actual_trim, rhs)) return true;
    }
    return false;
}

fn moduleNeedsCliArg(mod: *const Module) bool {
    return for (mod.link_objects.items) |o| switch (o) {
        .c_source_file, .c_source_files, .assembly_file, .win32_resource_file => break true,
        else => continue,
    } else false;
}

const CliNamedModules = struct {
    modules: std.AutoArrayHashMapUnmanaged(*Module, void),
    names: std.StringArrayHashMapUnmanaged(void),

    /// Traverse the whole dependency graph and give every module a unique
    /// name, ideally one named after what it's called somewhere in the graph.
    /// It will help here to have both a mapping from module to name and a set
    /// of all the currently-used names.
    fn init(arena: Allocator, root_module: *Module) Allocator.Error!CliNamedModules {
        var compile: CliNamedModules = .{
            .modules = .{},
            .names = .{},
        };
        const graph = root_module.getGraph();
        {
            assert(graph.modules[0] == root_module);
            try compile.modules.put(arena, root_module, {});
            try compile.names.put(arena, "root", {});
        }
        for (graph.modules[1..], graph.names[1..]) |mod, orig_name| {
            var name = orig_name;
            var n: usize = 0;
            while (true) {
                const gop = try compile.names.getOrPut(arena, name);
                if (!gop.found_existing) {
                    try compile.modules.putNoClobber(arena, mod, {});
                    break;
                }
                name = try std.fmt.allocPrint(arena, "{s}{d}", .{ orig_name, n });
                n += 1;
            }
        }
        return compile;
    }
};

fn getCompileDependencies(chase_dynamic: bool) void {
    _ = chase_dynamic;
    @panic("TODO");
}
