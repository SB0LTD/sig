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
const allocPrint = std.fmt.allocPrint;

const Step = @import("../Step.zig");
const Maker = @import("../../Maker.zig");

/// Populated during the make phase when there is a long-lived compiler process.
/// Managed by the build runner, not user build script.
zig_process: ?*Step.ZigProcess = null,
/// Persisted to reuse memory on subsequent make.
zig_args: std.ArrayList([]const u8) = .empty,

pub fn make(
    compile: *Compile,
    compile_index: Configuration.Step.Index,
    maker: *Maker,
    progress_node: std.Progress.Node,
) Step.ExtendedMakeError!void {
    const graph = maker.graph;
    const step = maker.stepByIndex(compile_index);

    // Reset / repopulate persistent state.
    compile.zig_args.clearRetainingCapacity();

    try lowerZigArgs(compile, compile_index, maker, &compile.zig_args, false);
    if (true) @panic("TODO implement compile.make()");
    const process_arena = graph.arena; // TODO don't leak into the process_arena

    const maybe_output_dir = step.evalZigProcess(
        compile.zig_args.items,
        progress_node,
        (graph.incremental == true) and (maker.watch or maker.web_server != null),
        maker,
    ) catch |err| switch (err) {
        error.NeedCompileErrorCheck => {
            assert(compile.expect_errors != null);
            try checkCompileErrors(compile, maker);
            return;
        },
        else => |e| return e,
    };

    // Update generated files
    if (maybe_output_dir) |output_dir| {
        if (compile.emit_directory) |lp| {
            lp.path = try allocPrint(process_arena, "{f}", .{output_dir});
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
            compile.getEmittedBin().getPath2(step),
            compile.major_only_filename.?,
            compile.name_only_filename.?,
        );
    }
}

/// List of importable modules in a compilation's module graph, including
/// the root module. The root module is guaranteed to be first.
const ModuleList = std.AutoArrayHashMapUnmanaged(Configuration.Module.Index, Configuration.String);
/// Keyed on the first key in the module list.
const ModuleGraph = std.ArrayHashMapUnmanaged(ModuleList, void, ModuleListContext, false);

const ModuleListContext = struct {
    pub fn eql(ctx: @This(), a: ModuleList, b: ModuleList) bool {
        _ = ctx;
        return a.keys()[0] == b.keys()[0];
    }

    pub fn hash(ctx: @This(), key: ModuleList) u32 {
        _ = ctx;
        return std.hash.int(@intFromEnum(key.keys()[0]));
    }

    const Adapter = struct {
        pub fn eql(ctx: @This(), a: Configuration.Module.Index, b: ModuleList, b_index: usize) bool {
            _ = ctx;
            _ = b_index;
            return a == b.keys()[0];
        }

        pub fn hash(ctx: @This(), key: Configuration.Module.Index) u32 {
            _ = ctx;
            return std.hash.int(@intFromEnum(key));
        }
    };
};

fn lowerZigArgs(
    compile: *const Compile,
    compile_index: Configuration.Step.Index,
    maker: *const Maker,
    zig_args: *std.ArrayList([]const u8),
    fuzz: bool,
) error{ OutOfMemory, MakeFailed }!void {
    const step = maker.stepByIndex(compile_index);
    const graph = maker.graph;
    const arena = graph.arena; // TODO don't leak into the process arena
    const gpa = maker.gpa;
    const conf = &maker.scanned_config.configuration;
    const conf_step = compile_index.ptr(conf);
    const conf_comp = conf_step.extended.get(conf.extra).compile;

    try zig_args.append(gpa, graph.zig_exe);

    const cmd = switch (conf_comp.flags3.kind) {
        .lib => "build-lib",
        .exe => "build-exe",
        .obj => "build-obj",
        .@"test" => "test",
        .test_obj => "test-obj",
    };
    try zig_args.append(gpa, cmd);

    if (graph.reference_trace) |some| {
        try zig_args.append(gpa, try allocPrint(arena, "-freference-trace={d}", .{some}));
    }
    try addFlag(gpa, zig_args, "allow-so-scripts", conf_comp.flags2.allow_so_scripts.toBool() orelse graph.allow_so_scripts);

    try addFlag(gpa, zig_args, "llvm", conf_comp.flags2.use_llvm.toBool());
    try addFlag(gpa, zig_args, "lld", conf_comp.flags2.use_lld.toBool());
    try addFlag(gpa, zig_args, "new-linker", conf_comp.flags2.use_new_linker.toBool());

    const root_module = conf_comp.root_module.get(conf);

    if (root_module.resolved_target.get(conf).?.query.unwrap()) |query| {
        if (query.get(conf).flags.object_format.get()) |ofmt| {
            try zig_args.append(gpa, try allocPrint(arena, "-ofmt={t}", .{ofmt}));
        }
    }

    switch (conf_comp.flags3.entry) {
        .default => {},
        .disabled => try zig_args.append(gpa, "-fno-entry"),
        .enabled => try zig_args.append(gpa, "-fentry"),
        .symbol_name => {
            const symbol_name = conf_comp.entry.value.?.slice(conf);
            try zig_args.append(gpa, try allocPrint(arena, "-fentry={s}", .{symbol_name}));
        },
    }

    for (conf_comp.force_undefined_symbols.slice) |symbol_name| {
        try zig_args.appendSlice(gpa, &.{ "--force_undefined", symbol_name.slice(conf) });
    }

    if (conf_comp.stack_size.value) |stack_size| {
        try zig_args.appendSlice(gpa, &.{ "--stack", try allocPrint(arena, "{d}", .{stack_size}) });
    }

    try addBool(gpa, zig_args, "-ffuzz", fuzz);

    {
        var is_linking_libc = conf_comp.flags3.is_linking_libc;
        var is_linking_libcpp = conf_comp.flags3.is_linking_libcpp;

        // Stores system libraries that have already been seen for at least one
        // module, along with any C compiler arguments that need to be passed
        // to the compiler for each module individually as reported by
        // pkg-config.
        var seen_system_libs: std.AutoArrayHashMapUnmanaged(Configuration.String, []const []const u8) = .empty;
        var frameworks: std.AutoArrayHashMapUnmanaged(Configuration.String, Configuration.Module.Framework.Flags) = .empty;
        var module_graph: ModuleGraph = .empty;

        var prev_has_cflags = false;
        var prev_has_rcflags = false;
        var prev_search_strategy: Configuration.SystemLib.SearchStrategy = .paths_first;
        var prev_preferred_link_mode: std.builtin.LinkMode = .dynamic;
        // Track the number of positional arguments so that a nice error can be
        // emitted if there is nothing to link.
        var total_linker_objects: usize = @intFromBool(root_module.root_source_file != .none);

        // Fully recursive iteration including dynamic libraries to detect
        // libc and libc++ linkage.
        for (try getCompileDependencies(arena, &module_graph, conf, compile_index, true)) |some_compile_index| {
            const some_compile = some_compile_index.ptr(conf).extended.get(conf.extra).compile;
            const modules = try getModuleList(arena, &module_graph, some_compile.root_module, conf);
            for (modules.keys()) |mod_index| {
                const mod = mod_index.get(conf);
                is_linking_libc = is_linking_libc or mod.flags2.link_libc == .true;
                is_linking_libcpp = is_linking_libcpp or mod.flags2.link_libcpp == .true;
            }
        }

        var cli_named_modules = try CliNamedModules.init(arena, &module_graph, compile_index, maker);

        // For this loop, don't chase dynamic libraries because their link
        // objects are already linked.
        for (try getCompileDependencies(arena, &module_graph, conf, compile_index, false)) |dep_compile_index| {
            const dep_compile = dep_compile_index.ptr(conf).extended.get(conf.extra).compile;
            const modules = try getModuleList(arena, &module_graph, dep_compile.root_module, conf);
            for (modules.keys()) |mod_index| {
                const mod = mod_index.get(conf);
                // While walking transitive dependencies, if a given link object is
                // already included in a library, it should not redundantly be
                // placed on the linker line of the dependee.
                const my_responsibility = dep_compile_index == compile_index;
                const already_linked = !my_responsibility and dep_compile.isDynamicLibrary();

                // Inherit dependencies on darwin frameworks.
                if (!already_linked) {
                    for (mod.frameworks.slice) |framework| {
                        try frameworks.put(arena, framework.name, framework.flags);
                    }
                }

                if (true) @panic("TODO");

                // Inherit dependencies on system libraries and static libraries.
                for (0..mod.link_objects.len) |lo_i| switch (mod.link_objects.get(conf.extra, lo_i)) {
                    .static_path => |static_path| {
                        if (my_responsibility) {
                            try zig_args.append(gpa, static_path.getPath2(step));
                            total_linker_objects += 1;
                        }
                    },
                    .system_lib => |system_lib| {
                        const system_lib_gop = try seen_system_libs.getOrPut(arena, system_lib.name);
                        if (system_lib_gop.found_existing) {
                            try zig_args.appendSlice(gpa, system_lib_gop.value_ptr.*);
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
                                    .dynamic => try zig_args.append(gpa, "-search_dylibs_only"),
                                    .static => try zig_args.append(gpa, "-search_static_only"),
                                },
                                .paths_first => switch (system_lib.preferred_link_mode) {
                                    .dynamic => try zig_args.append(gpa, "-search_paths_first"),
                                    .static => try zig_args.append(gpa, "-search_paths_first_static"),
                                },
                                .mode_first => switch (system_lib.preferred_link_mode) {
                                    .dynamic => try zig_args.append(gpa, "-search_dylibs_first"),
                                    .static => try zig_args.append(gpa, "-search_static_first"),
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
                            .no => try zig_args.append(gpa, try allocPrint(arena, "{s}{s}", .{ prefix, system_lib.name })),
                            .yes, .force => {
                                if (compile.runPkgConfig(maker, system_lib.name)) |result| {
                                    try zig_args.appendSlice(gpa, result.cflags);
                                    try zig_args.appendSlice(gpa, result.libs);
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
                                            try zig_args.append(gpa, try allocPrint(arena, "{s}{s}", .{
                                                prefix,
                                                system_lib.name,
                                            }));
                                        },
                                        .force => {
                                            return step.fail(maker, "pkg-config failed for library {s}", .{system_lib.name});
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
                            .exe => return step.fail(maker, "cannot link with an executable build artifact", .{}),
                            .@"test" => return step.fail(maker, "cannot link with a test", .{}),
                            .obj, .test_obj => {
                                const included_in_lib_or_obj = !my_responsibility and
                                    (dep_compile.kind == .lib or dep_compile.kind == .obj or dep_compile.kind == .test_obj);
                                if (!already_linked and !included_in_lib_or_obj) {
                                    try zig_args.append(gpa, other.getEmittedBin().getPath2(step));
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

                                try zig_args.append(gpa, full_path_lib);
                                total_linker_objects += 1;

                                if (other.linkage == .dynamic and
                                    compile.rootModuleTarget().os.tag != .windows)
                                {
                                    if (Dir.path.dirname(full_path_lib)) |dirname| {
                                        try zig_args.append(gpa, "-rpath");
                                        try zig_args.append(gpa, dirname);
                                    }
                                }
                            },
                        }
                    },
                    .assembly_file => |asm_file| l: {
                        if (!my_responsibility) break :l;

                        if (prev_has_cflags) {
                            try zig_args.append(gpa, "-cflags");
                            try zig_args.append(gpa, "--");
                            prev_has_cflags = false;
                        }
                        try zig_args.append(gpa, asm_file.getPath2(mod.owner, step));
                        total_linker_objects += 1;
                    },

                    .c_source_file => |c_source_file| l: {
                        if (!my_responsibility) break :l;

                        if (prev_has_cflags or c_source_file.flags.len != 0) {
                            try zig_args.append(gpa, "-cflags");
                            for (c_source_file.flags) |arg| {
                                try zig_args.append(gpa, arg);
                            }
                            try zig_args.append(gpa, "--");
                        }
                        prev_has_cflags = (c_source_file.flags.len != 0);

                        if (c_source_file.language) |lang| {
                            try zig_args.append(gpa, "-x");
                            try zig_args.append(gpa, lang.internalIdentifier());
                        }

                        try zig_args.append(gpa, c_source_file.file.getPath2(mod.owner, step));

                        if (c_source_file.language != null) {
                            try zig_args.append(gpa, "-x");
                            try zig_args.append(gpa, "none");
                        }
                        total_linker_objects += 1;
                    },

                    .c_source_files => |c_source_files| l: {
                        if (!my_responsibility) break :l;

                        if (prev_has_cflags or c_source_files.flags.len != 0) {
                            try zig_args.append(gpa, "-cflags");
                            for (c_source_files.flags) |arg| {
                                try zig_args.append(gpa, arg);
                            }
                            try zig_args.append(gpa, "--");
                        }
                        prev_has_cflags = (c_source_files.flags.len != 0);

                        if (c_source_files.language) |lang| {
                            try zig_args.append(gpa, "-x");
                            try zig_args.append(gpa, lang.internalIdentifier());
                        }

                        const root_path = c_source_files.root.getPath2(mod.owner, step);
                        for (c_source_files.files) |file| {
                            try zig_args.append(gpa, try Dir.path.join(arena, &.{ root_path, file }));
                        }

                        if (c_source_files.language != null) {
                            try zig_args.append(gpa, "-x");
                            try zig_args.append(gpa, "none");
                        }

                        total_linker_objects += c_source_files.files.len;
                    },

                    .win32_resource_file => |rc_source_file| l: {
                        if (!my_responsibility) break :l;

                        if (rc_source_file.flags.len == 0 and rc_source_file.include_paths.len == 0) {
                            if (prev_has_rcflags) {
                                try zig_args.append(gpa, "-rcflags");
                                try zig_args.append(gpa, "--");
                                prev_has_rcflags = false;
                            }
                        } else {
                            try zig_args.append(gpa, "-rcflags");
                            for (rc_source_file.flags) |arg| {
                                try zig_args.append(gpa, arg);
                            }
                            for (rc_source_file.include_paths) |include_path| {
                                try zig_args.append(gpa, "/I");
                                try zig_args.append(gpa, include_path.getPath2(mod.owner, step));
                            }
                            try zig_args.append(gpa, "--");
                            prev_has_rcflags = true;
                        }
                        try zig_args.append(gpa, rc_source_file.file.getPath2(mod.owner, step));
                        total_linker_objects += 1;
                    },
                };

                // We need to emit the --mod argument here so that the above link objects
                // have the correct parent module, but only if the module is part of
                // this compilation.
                if (!my_responsibility) continue;
                if (cli_named_modules.modules.getIndex(mod)) |module_cli_index| {
                    const module_cli_name = cli_named_modules.names.keys()[module_cli_index];
                    try mod.appendZigProcessFlags(zig_args, step);

                    // --dep arguments
                    try zig_args.ensureUnusedCapacity(mod.import_table.count() * 2);
                    for (mod.import_table.keys(), mod.import_table.values()) |name, import| {
                        const import_index = cli_named_modules.modules.getIndex(import).?;
                        const import_cli_name = cli_named_modules.names.keys()[import_index];
                        zig_args.appendAssumeCapacity("--dep");
                        if (std.mem.eql(u8, import_cli_name, name)) {
                            zig_args.appendAssumeCapacity(import_cli_name);
                        } else {
                            zig_args.appendAssumeCapacity(try allocPrint(arena, "{s}={s}", .{ name, import_cli_name }));
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
                        try zig_args.append(gpa, try allocPrint(arena, "-M{s}={s}", .{ module_cli_name, src }));
                    } else if (moduleNeedsCliArg(mod)) {
                        try zig_args.append(gpa, try allocPrint(arena, "-M{s}", .{module_cli_name}));
                    }
                }
            }
        }

        if (total_linker_objects == 0) {
            return step.fail(maker, "the linker needs one or more objects to link", .{});
        }

        for (frameworks.keys(), frameworks.values()) |name, info| {
            try zig_args.ensureUnusedCapacity(gpa, 2);
            if (info.needed) {
                zig_args.appendAssumeCapacity("-needed_framework");
            } else if (info.weak) {
                zig_args.appendAssumeCapacity("-weak_framework");
            } else {
                zig_args.appendAssumeCapacity("-framework");
            }
            zig_args.appendAssumeCapacity(name.slice(conf));
        }

        try zig_args.ensureUnusedCapacity(gpa, 2);
        if (is_linking_libcpp) zig_args.appendAssumeCapacity("-lc++");
        if (is_linking_libc) zig_args.appendAssumeCapacity("-lc");
    }

    if (true) @panic("TODO");

    if (conf_comp.win32_manifest) |manifest_file| {
        try zig_args.append(gpa, manifest_file.getPath2(step));
    }

    if (conf_comp.win32_module_definition) |module_file| {
        try zig_args.append(gpa, module_file.getPath2(step));
    }

    if (conf_comp.image_base) |image_base| {
        try zig_args.appendSlice(gpa, &.{
            "--image-base", try allocPrint(arena, "0x{x}", .{image_base}),
        });
    }

    for (conf_comp.filters) |filter| {
        try zig_args.appendSlice(gpa, &.{ "--test-filter", filter });
    }

    if (conf_comp.test_runner) |test_runner| {
        try zig_args.appendSlice(gpa, &.{ "--test-runner", test_runner.path.getPath2(step) });
    }

    for (graph.debug_log_scopes) |log_scope| {
        try zig_args.appendSlice(gpa, &.{ "--debug-log", log_scope });
    }

    try addBool(gpa, zig_args, "--debug-compile-errors", graph.debug_compile_errors);
    try addBool(gpa, zig_args, "--debug-incremental", graph.debug_incremental);
    try addBool(gpa, zig_args, "--verbose-air", graph.verbose_air);
    try addBool(gpa, zig_args, "--verbose-llvm-ir", graph.verbose_llvm_ir);
    try addBool(gpa, zig_args, "--verbose-link", graph.verbose_link or conf_comp.flags.verbose_link);
    try addBool(gpa, zig_args, "--verbose-cc", graph.verbose_cc or conf_comp.flags.verbose_cc);
    try addBool(gpa, zig_args, "--verbose-llvm-cpu-features", graph.verbose_llvm_cpu_features);
    try addBool(gpa, zig_args, "--time-report", graph.time_report);

    if (compile.generated_asm != null) try zig_args.append(gpa, "-femit-asm");
    if (compile.generated_bin == null) try zig_args.append(gpa, "-fno-emit-bin");
    if (compile.generated_docs != null) try zig_args.append(gpa, "-femit-docs");
    if (compile.generated_implib != null) try zig_args.append(gpa, "-femit-implib");
    if (compile.generated_llvm_bc != null) try zig_args.append(gpa, "-femit-llvm-bc");
    if (compile.generated_llvm_ir != null) try zig_args.append(gpa, "-femit-llvm-ir");
    if (compile.generated_h != null) try zig_args.append(gpa, "-femit-h");

    try addFlag(gpa, zig_args, "formatted-panics", conf_comp.flags.formatted_panics);

    switch (conf_comp.compress_debug_sections) {
        .none => {},
        .zlib => try zig_args.append(gpa, "--compress-debug-sections=zlib"),
        .zstd => try zig_args.append(gpa, "--compress-debug-sections=zstd"),
    }

    if (conf_comp.flags.link_eh_frame_hdr) {
        try zig_args.append(gpa, "--eh-frame-hdr");
    }
    if (conf_comp.flags.link_emit_relocs) {
        try zig_args.append(gpa, "--emit-relocs");
    }
    if (conf_comp.flags.link_function_sections) {
        try zig_args.append(gpa, "-ffunction-sections");
    }
    if (conf_comp.flags.link_data_sections) {
        try zig_args.append(gpa, "-fdata-sections");
    }
    if (conf_comp.flags.link_gc_sections) |x| {
        try zig_args.append(gpa, if (x) "--gc-sections" else "--no-gc-sections");
    }
    if (!conf_comp.flags.linker_dynamicbase) {
        try zig_args.append(gpa, "--no-dynamicbase");
    }
    if (conf_comp.flags.linker_allow_shlib_undefined) |x| {
        try zig_args.append(gpa, if (x) "-fallow-shlib-undefined" else "-fno-allow-shlib-undefined");
    }
    if (conf_comp.flags.link_z_notext) try zig_args.appendSlice(gpa, &.{ "-z", "notext" });
    if (!conf_comp.flags.link_z_relro) try zig_args.appendSlice(gpa, &.{ "-z", "norelro" });
    if (conf_comp.flags.link_z_lazy) try zig_args.appendSlice(gpa, &.{ "-z", "lazy" });
    if (conf_comp.flags.link_z_common_page_size) |size| try zig_args.appendSlice(gpa, &.{
        "-z",
        try allocPrint(arena, "common-page-size={d}", .{size}),
    });
    if (conf_comp.flags.link_z_max_page_size) |size| try zig_args.appendSlice(gpa, &.{
        "-z",
        try allocPrint(arena, "max-page-size={d}", .{size}),
    });
    if (conf_comp.flags.link_z_defs) try zig_args.appendSlice(gpa, &.{ "-z", "defs" });

    if (conf_comp.flags.libc_file) |libc_file| {
        try zig_args.appendSlice(gpa, &.{ "--libc", libc_file.getPath2(step) });
    } else if (graph.libc_file) |libc_file| {
        try zig_args.appendSlice(gpa, &.{ "--libc", libc_file });
    }

    try zig_args.append(gpa, "--cache-dir");
    try zig_args.append(gpa, graph.cache_root.path orelse ".");

    try zig_args.append(gpa, "--global-cache-dir");
    try zig_args.append(gpa, graph.global_cache_root.path orelse ".");

    if (graph.debug_compiler_runtime_libs) |mode|
        try zig_args.append(gpa, try allocPrint(arena, "--debug-rt={t}", .{mode}));

    try zig_args.appendSlice(gpa, &.{ "--name", conf_comp.root_name.slice(conf) });

    if (compile.linkage) |some| switch (some) {
        .dynamic => try zig_args.append(gpa, "-dynamic"),
        .static => try zig_args.append(gpa, "-static"),
    };
    if (compile.kind == .lib and compile.linkage != null and compile.linkage.? == .dynamic) {
        if (compile.version) |version| try zig_args.appendSlice(gpa, &.{
            "--version", try allocPrint(arena, "{f}", .{version}),
        });

        if (compile.rootModuleTarget().os.tag.isDarwin()) {
            const install_name = compile.install_name orelse try allocPrint(arena, "@rpath/{s}{s}{s}", .{
                compile.rootModuleTarget().libPrefix(),
                compile.name,
                compile.rootModuleTarget().dynamicLibSuffix(),
            });
            try zig_args.append(gpa, "-install_name");
            try zig_args.append(gpa, install_name);
        }
    }

    if (compile.entitlements) |entitlements| {
        try zig_args.appendSlice(gpa, &[_][]const u8{ "--entitlements", entitlements });
    }
    if (compile.pagezero_size) |pagezero_size| {
        const size = try allocPrint(arena, "{x}", .{pagezero_size});
        try zig_args.appendSlice(gpa, &[_][]const u8{ "-pagezero_size", size });
    }
    if (compile.headerpad_size) |headerpad_size| {
        const size = try allocPrint(arena, "{x}", .{headerpad_size});
        try zig_args.appendSlice(gpa, &[_][]const u8{ "-headerpad", size });
    }
    if (compile.headerpad_max_install_names) {
        try zig_args.append(gpa, "-headerpad_max_install_names");
    }
    if (compile.dead_strip_dylibs) {
        try zig_args.append(gpa, "-dead_strip_dylibs");
    }
    if (compile.force_load_objc) {
        try zig_args.append(gpa, "-ObjC");
    }
    if (compile.discard_local_symbols) {
        try zig_args.append(gpa, "--discard-all");
    }

    try addFlag(gpa, zig_args, "compiler-rt", compile.bundle_compiler_rt);
    try addFlag(gpa, zig_args, "ubsan-rt", compile.bundle_ubsan_rt);
    try addFlag(gpa, zig_args, "dll-export-fns", compile.dll_export_fns);
    if (compile.rdynamic) {
        try zig_args.append(gpa, "-rdynamic");
    }
    if (compile.import_memory) {
        try zig_args.append(gpa, "--import-memory");
    }
    if (compile.export_memory) {
        try zig_args.append(gpa, "--export-memory");
    }
    if (compile.import_symbols) {
        try zig_args.append(gpa, "--import-symbols");
    }
    if (compile.import_table) {
        try zig_args.append(gpa, "--import-table");
    }
    if (compile.export_table) {
        try zig_args.append(gpa, "--export-table");
    }
    if (compile.initial_memory) |initial_memory| {
        try zig_args.append(gpa, try allocPrint(arena, "--initial-memory={d}", .{initial_memory}));
    }
    if (compile.max_memory) |max_memory| {
        try zig_args.append(gpa, try allocPrint(arena, "--max-memory={d}", .{max_memory}));
    }
    if (compile.shared_memory) {
        try zig_args.append(gpa, "--shared-memory");
    }
    if (compile.global_base) |global_base| {
        try zig_args.append(gpa, try allocPrint(arena, "--global-base={d}", .{global_base}));
    }

    if (compile.wasi_exec_model) |model| {
        try zig_args.append(gpa, try allocPrint(arena, "-mexec-model={t}", .{model}));
    }
    if (compile.linker_script) |linker_script| {
        try zig_args.append(gpa, "--script");
        try zig_args.append(gpa, linker_script.getPath2(step));
    }

    if (compile.version_script) |version_script| {
        try zig_args.append(gpa, "--version-script");
        try zig_args.append(gpa, version_script.getPath2(step));
    }
    if (compile.linker_allow_undefined_version) |x| {
        try zig_args.append(gpa, if (x) "--undefined-version" else "--no-undefined-version");
    }

    if (compile.linker_enable_new_dtags) |enabled| {
        try zig_args.append(gpa, if (enabled) "--enable-new-dtags" else "--disable-new-dtags");
    }

    if (compile.kind == .@"test") {
        if (compile.exec_cmd_args) |exec_cmd_args| {
            for (exec_cmd_args) |cmd_arg| {
                if (cmd_arg) |arg| {
                    try zig_args.append(gpa, "--test-cmd");
                    try zig_args.append(gpa, arg);
                } else {
                    try zig_args.append(gpa, "--test-cmd-bin");
                }
            }
        }
    }

    if (graph.sysroot) |sysroot| try zig_args.appendSlice(gpa, &.{ "--sysroot", sysroot });

    // -I and -L arguments that appear after the last --mod argument apply to all modules.
    const cwd: Io.Dir = .cwd();
    const io = graph.io;

    for (graph.search_prefixes.items) |search_prefix| {
        var prefix_dir = cwd.openDir(io, search_prefix, .{}) catch |err| {
            return step.fail(maker, "unable to open prefix directory '{s}': {t}", .{ search_prefix, err });
        };
        defer prefix_dir.close(io);

        // Avoid passing -L and -I flags for nonexistent directories.
        // This prevents a warning, that should probably be upgraded to an error in Zig's
        // CLI parsing code, when the linker sees an -L directory that does not exist.

        if (prefix_dir.access(io, "lib", .{})) |_| {
            try zig_args.appendSlice(gpa, &.{
                "-L", try Dir.path.join(arena, &.{ search_prefix, "lib" }),
            });
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return step.fail(maker, "unable to access '{s}/lib' directory: {t}", .{ search_prefix, e }),
        }

        if (prefix_dir.access(io, "include", .{})) |_| {
            try zig_args.appendSlice(gpa, &.{
                "-I", try Dir.path.join(arena, &.{ search_prefix, "include" }),
            });
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return step.fail(maker, "unable to access '{s}/include' directory: {t}", .{ search_prefix, e }),
        }
    }

    if (compile.rc_includes != .any) {
        try zig_args.appendSlice(gpa, &.{ "-rcincludes", @tagName(compile.rc_includes) });
    }

    try addFlag(gpa, zig_args, "each-lib-rpath", compile.each_lib_rpath);

    if (compile.build_id orelse graph.build_id) |build_id| {
        try zig_args.append(gpa, switch (build_id) {
            .hexstring => |hs| try allocPrint(arena, "--build-id=0x{x}", .{hs.toSlice()}),
            .none, .fast, .uuid, .sha1, .md5 => try allocPrint(arena, "--build-id={t}", .{build_id}),
        });
    }

    const opt_zig_lib_dir = if (compile.zig_lib_dir) |dir|
        dir.getPath2(step)
    else if (graph.zig_lib_directory.path) |_|
        try allocPrint(arena, "{f}", .{graph.zig_lib_directory})
    else
        null;

    if (opt_zig_lib_dir) |zig_lib_dir| {
        try zig_args.append(gpa, "--zig-lib-dir");
        try zig_args.append(gpa, zig_lib_dir);
    }

    try addFlag(gpa, zig_args, "PIE", compile.pie);

    if (compile.lto) |lto| {
        try zig_args.append(gpa, switch (lto) {
            .full => "-flto=full",
            .thin => "-flto=thin",
            .none => "-fno-lto",
        });
    }

    try addFlag(gpa, zig_args, "sanitize-coverage-trace-pc-guard", compile.sanitize_coverage_trace_pc_guard);

    if (compile.subsystem) |subsystem| {
        try zig_args.appendSlice(gpa, &.{ "--subsystem", @tagName(subsystem) });
    }

    if (compile.mingw_unicode_entry_point) {
        try zig_args.append(gpa, "-municode");
    }

    if (compile.error_limit orelse graph.error_limit) |err_limit| try zig_args.appendSlice(gpa, &.{
        "--error-limit", try allocPrint(arena, "{d}", .{err_limit}),
    });

    try addFlag(gpa, zig_args, "incremental", graph.incremental);

    try zig_args.append(gpa, "--listen=-");

    // Windows has an argument length limit of 32,766 characters, macOS 262,144 and Linux
    // 2,097,152. If our args exceed 30 KiB, we instead write them to a "response file" and
    // pass that to zig, e.g. via 'zig build-lib @args.rsp'
    // See @file syntax here: https://gcc.gnu.org/onlinedocs/gcc/Overall-Options.html
    var args_length: usize = 0;
    for (zig_args.items) |arg| {
        args_length += arg.len + 1; // +1 to account for null terminator
    }
    if (args_length >= 30 * 1024) {
        try graph.cache_root.handle.createDirPath(io, "args");

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
        if (graph.cache_root.handle.access(io, args_file, .{})) |_| {
            // The args file is already present from a previous run.
        } else |err| switch (err) {
            error.FileNotFound => {
                var af = graph.cache_root.handle.createFileAtomic(io, args_file, .{
                    .replace = false,
                    .make_path = true,
                }) catch |e| return step.fail(maker, "failed creating tmp args file {f}{s}: {t}", .{
                    graph.cache_root, args_file, e,
                });
                defer af.deinit(io);

                af.file.writeStreamingAll(io, args) catch |e| {
                    return step.fail(maker, "failed writing args data to tmp file {f}{s}: {t}", .{
                        graph.cache_root, args_file, e,
                    });
                };
                // Note we can't clean up this file, not even after build
                // success, because that might interfere with another build
                // process that needs the same file.
                af.link(io) catch |e| switch (e) {
                    error.PathAlreadyExists => {
                        // The args file was created by another concurrent build process.
                    },
                    else => |other_err| return step.fail(maker, "failed linking tmp file {f}{s}: {t}", .{
                        graph.cache_root, args_file, other_err,
                    }),
                };
            },
            else => |other_err| return other_err,
        }

        const resolved_args_file = try mem.concat(arena, u8, &.{
            "@",
            try graph.cache_root.join(arena, &.{args_file}),
        });

        zig_args.shrinkRetainingCapacity(2);
        try zig_args.append(gpa, resolved_args_file);
    }

    return try zig_args.toOwnedSlice();
}

pub fn rebuildInFuzzMode(compile: *Compile, maker: *Maker, progress_node: std.Progress.Node) !Path {
    const gpa = maker.graph.gpa;

    compile.step.result_error_msgs.clearRetainingCapacity();
    compile.step.result_stderr = "";

    compile.step.result_error_bundle.deinit(gpa);
    compile.step.result_error_bundle = std.zig.ErrorBundle.empty;

    if (compile.step.result_failed_command) |cmd| {
        gpa.free(cmd);
        compile.step.result_failed_command = null;
    }

    const zig_args = &compile.zig_args;
    zig_args.clearRetainingCapacity();
    try lowerZigArgs(compile, maker, zig_args, true);
    const maybe_output_bin_path = try compile.step.evalZigProcess(zig_args.items, progress_node, false, maker);
    return maybe_output_bin_path.?;
}

pub fn doAtomicSymLinks(
    step: *Step,
    maker: *Maker,
    output_path: []const u8,
    filename_major_only: []const u8,
    filename_name_only: []const u8,
) !void {
    const graph = maker.graph;
    const arena = graph.arena; // TODO don't leak into process arena
    const io = graph.io;
    const out_dir = Dir.path.dirname(output_path) orelse ".";
    const out_basename = Dir.path.basename(output_path);
    // sym link for libfoo.so.1 to libfoo.so.1.2.3
    const major_only_path = try Dir.path.join(arena, &.{ out_dir, filename_major_only });
    const cwd: Io.Dir = .cwd();
    cwd.symLinkAtomic(io, out_basename, major_only_path, .{}) catch |err| {
        return step.fail(maker, "unable to symlink {s} -> {s}: {t}", .{
            major_only_path, out_basename, err,
        });
    };
    // sym link for libfoo.so to libfoo.so.1
    const name_only_path = try Dir.path.join(arena, &.{ out_dir, filename_name_only });
    cwd.symLinkAtomic(io, filename_major_only, name_only_path, .{}) catch |err| {
        return step.fail(maker, "unable to symlink {s} -> {s}: {t}", .{
            name_only_path, filename_major_only, err,
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

fn addBool(gpa: Allocator, args: *std.ArrayList([]const u8), arg: []const u8, opt: bool) !void {
    if (opt) try args.append(gpa, arg);
}

fn addFlag(gpa: Allocator, args: *std.ArrayList([]const u8), comptime name: []const u8, opt: ?bool) !void {
    const cond = opt orelse return;
    try args.append(gpa, if (cond) "-f" ++ name else "-fno-" ++ name);
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
            return compile.step.fail(maker, "unknown pkg-config flag '{s}'", .{arg});
        }
    }

    try zig_cflags.shrinkToLen(arena);
    try zig_libs.shrinkToLen(arena);

    return .{
        .cflags = zig_cflags.toOwnedSliceAssert(),
        .libs = zig_libs.toOwnedSliceAssert(),
    };
}

fn checkCompileErrors(compile: *Compile, maker: *Maker) !void {
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
            return compile.step.fail(maker,
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

            return compile.step.fail(maker,
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

            return compile.step.fail(maker,
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

            return compile.step.fail(maker,
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
    modules: std.AutoArrayHashMapUnmanaged(Configuration.Module.Index, void),
    names: std.StringArrayHashMapUnmanaged(void),

    /// Traverse the whole dependency graph and give every module a unique
    /// name, ideally one named after what it's called somewhere in the graph.
    /// It will help here to have both a mapping from module to name and a set
    /// of all the currently-used names.
    fn init(
        arena: Allocator,
        module_graph: *ModuleGraph,
        compile_index: Configuration.Step.Index,
        maker: *const Maker,
    ) Allocator.Error!CliNamedModules {
        const conf = &maker.scanned_config.configuration;
        const conf_compile = compile_index.ptr(conf).extended.get(conf.extra).compile;

        var result: CliNamedModules = .{
            .modules = .{},
            .names = .{},
        };
        const modules = try getModuleList(arena, module_graph, conf_compile.root_module, conf);
        {
            assert(conf_compile.root_module == modules.keys()[0]);
            try result.modules.put(arena, conf_compile.root_module, {});
            try result.names.put(arena, "root", {});
        }
        for (modules.keys()[1..], modules.values()[1..]) |mod, orig_name| {
            const orig_name_slice = orig_name.slice(conf);
            var name: []const u8 = orig_name_slice;
            var n: usize = 0;
            while (true) {
                const gop = try result.names.getOrPut(arena, name);
                if (!gop.found_existing) {
                    try result.modules.putNoClobber(arena, mod, {});
                    break;
                }
                name = try allocPrint(arena, "{s}{d}", .{ orig_name_slice, n });
                n += 1;
            }
        }
        return result;
    }
};

fn getCompileDependencies(
    arena: Allocator,
    module_graph: *ModuleGraph,
    conf: *const Configuration,
    start: Configuration.Step.Index,
    chase_dynamic: bool,
) ![]const Configuration.Step.Index {
    var compiles: std.AutoArrayHashMapUnmanaged(Configuration.Step.Index, void) = .empty;
    var compiles_i: usize = 0;

    try compiles.putNoClobber(arena, start, {});

    while (compiles_i < compiles.count()) : (compiles_i += 1) {
        const step = compiles.keys()[compiles_i].ptr(conf);
        const compile = step.extended.get(conf.extra).compile;
        const modules = try getModuleList(arena, module_graph, compile.root_module, conf);

        for (modules.keys()) |mod_index| {
            const mod = mod_index.get(conf);
            for (0..mod.link_objects.len) |i| {
                switch (mod.link_objects.get(conf.extra, i)) {
                    .other_step => |other_compile_index| {
                        const other_compile = other_compile_index.ptr(conf).extended.get(conf.extra).compile;
                        if (!chase_dynamic and other_compile.isDynamicLibrary()) continue;
                        try compiles.put(arena, other_compile_index, {});
                    },
                    else => {},
                }
            }
        }
    }

    return compiles.keys();
}

/// Returned pointer expires upon next call to `getModuleList`.
fn getModuleList(
    arena: Allocator,
    module_graph: *ModuleGraph,
    root_module: Configuration.Module.Index,
    conf: *const Configuration,
) !*ModuleList {
    const gop = try module_graph.getOrPutAdapted(arena, root_module, @as(ModuleListContext.Adapter, .{}));
    const modules = gop.key_ptr;

    if (gop.found_existing) return modules;
    modules.* = .empty;
    try modules.putNoClobber(arena, root_module, .root);

    var i: usize = 0;

    while (i < modules.entries.len) : (i += 1) {
        const dep_index = modules.keys()[i];
        const dep = dep_index.get(conf);
        const imports = dep.import_table.get(conf).imports;
        try modules.ensureUnusedCapacity(arena, imports.mal.len);
        for (imports.mal.items(.name), imports.mal.items(.module)) |import_name, other_mod|
            modules.putAssumeCapacity(other_mod, import_name);
    }

    return modules;
}
