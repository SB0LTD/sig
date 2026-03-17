const builtin = @import("builtin");

const std = @import("std");
const Allocator = std.mem.Allocator;
const Color = std.zig.Color;
const Configuration = std.Build.Configuration;
const File = std.Io.File;
const Io = std.Io;
const Step = std.Build.Step;
const Writer = std.Io.Writer;
const assert = std.debug.assert;
const fatal = std.process.fatal;
const fmt = std.fmt;
const log = std.log;
const mem = std.mem;
const process = std.process;

pub const root = @import("@build");
pub const dependencies = @import("@dependencies");

pub const std_options: std.Options = .{
    .side_channels_mitigations = .none,
    .http_disable_tls = true,
};

pub fn main(init: process.Init.Minimal) !void {
    // The build runner is often short-lived, but thanks to `--watch` and `--webui`, that's not
    // always the case. So, we do need a true gpa for some things.
    var debug_gpa_state: std.heap.DebugAllocator(.{
        // We'd rather have `zig build` run faster than catch harmless leaks in
        // the user's build.zig script.
        .stack_trace_frames = 0,
    }) = .init;
    defer _ = debug_gpa_state.deinit();
    const gpa = debug_gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    const io = threaded.io();

    // ...but we'll back our arena by `std.heap.page_allocator` for efficiency.
    var arena_allocator: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const args = try init.args.toSlice(arena);

    // skip my own exe name
    var arg_idx: usize = 1;

    const zig_exe = expectArgOrFatal(args, &arg_idx, "--zig");
    const zig_lib_dir = expectArgOrFatal(args, &arg_idx, "--zig-lib-dir");
    const build_root = expectArgOrFatal(args, &arg_idx, "--build-root");
    const local_cache_root = expectArgOrFatal(args, &arg_idx, "--local-cache");
    const global_cache_root = expectArgOrFatal(args, &arg_idx, "--global-cache");

    const cwd: Io.Dir = .cwd();

    const zig_lib_directory: std.Build.Cache.Directory = .{
        .path = zig_lib_dir,
        .handle = try cwd.openDir(io, zig_lib_dir, .{}),
    };

    const build_root_directory: std.Build.Cache.Directory = .{
        .path = build_root,
        .handle = try cwd.openDir(io, build_root, .{}),
    };

    const local_cache_directory: std.Build.Cache.Directory = .{
        .path = local_cache_root,
        .handle = try cwd.createDirPathOpen(io, local_cache_root, .{}),
    };

    const global_cache_directory: std.Build.Cache.Directory = .{
        .path = global_cache_root,
        .handle = try cwd.createDirPathOpen(io, global_cache_root, .{}),
    };

    var graph: std.Build.Graph = .{
        .io = io,
        .arena = arena,
        .cache = .{
            .io = io,
            .gpa = gpa,
            .manifest_dir = try local_cache_directory.handle.createDirPathOpen(io, "h", .{}),
            .cwd = try process.currentPathAlloc(io, arena),
        },
        .zig_exe = zig_exe,
        .environ_map = try init.environ.createMap(arena),
        .global_cache_root = global_cache_directory,
        .zig_lib_directory = zig_lib_directory,
        .host = .{
            .query = .{},
            .result = try std.zig.system.resolveTargetQuery(io, .{}),
        },
        .generated_files = .empty,
    };

    graph.cache.addPrefix(.{ .path = null, .handle = cwd });
    graph.cache.addPrefix(build_root_directory);
    graph.cache.addPrefix(local_cache_directory);
    graph.cache.addPrefix(global_cache_directory);
    graph.cache.hash.addBytes(builtin.zig_version_string);

    const builder = try std.Build.create(
        &graph,
        build_root_directory,
        local_cache_directory,
        dependencies.root_deps,
    );

    var error_style: ErrorStyle = .verbose;
    var multiline_errors: MultilineErrors = .indent;
    var color: Color = .auto;

    if (std.zig.EnvVar.ZIG_BUILD_ERROR_STYLE.get(&graph.environ_map)) |str| {
        if (std.meta.stringToEnum(ErrorStyle, str)) |style| {
            error_style = style;
        }
    }

    if (std.zig.EnvVar.ZIG_BUILD_MULTILINE_ERRORS.get(&graph.environ_map)) |str| {
        if (std.meta.stringToEnum(MultilineErrors, str)) |style| {
            multiline_errors = style;
        }
    }

    while (nextArg(args, &arg_idx)) |arg| {
        if (mem.cutPrefix(u8, arg, "-D")) |option_contents| {
            if (option_contents.len == 0)
                fatalWithHint("expected option name after '-D'", .{});
            if (mem.indexOfScalar(u8, option_contents, '=')) |name_end| {
                const option_name = option_contents[0..name_end];
                const option_value = option_contents[name_end + 1 ..];
                if (try builder.addUserInputOption(option_name, option_value))
                    fatal("  access the help menu with 'zig build -h'", .{});
            } else {
                if (try builder.addUserInputFlag(option_contents))
                    fatal("  access the help menu with 'zig build -h'", .{});
            }
        } else if (mem.cutPrefix(u8, arg, "-fsys=")) |name| {
            try graph.system_integration_options.put(arena, name, .user_enabled);
        } else if (mem.cutPrefix(u8, arg, "-fno-sys=")) |name| {
            try graph.system_integration_options.put(arena, name, .user_disabled);
        } else if (mem.eql(u8, arg, "--release")) {
            graph.release_mode = .any;
        } else if (mem.cutPrefix(u8, arg, "--release=")) |text| {
            graph.release_mode = std.meta.stringToEnum(std.Build.ReleaseMode, text) orelse {
                fatalWithHint("expected [off|any|fast|safe|small] in {q}, found {q}", .{
                    arg, text,
                });
            };
        } else if (mem.eql(u8, arg, "--color")) {
            const next_arg = nextArg(args, &arg_idx) orelse
                fatalWithHint("expected [auto|on|off] after {q}", .{arg});
            color = std.meta.stringToEnum(Color, next_arg) orelse {
                fatalWithHint("expected [auto|on|off] after {q}, found {q}", .{
                    arg, next_arg,
                });
            };
        } else if (mem.eql(u8, arg, "--error-style")) {
            const next_arg = nextArg(args, &arg_idx) orelse
                fatalWithHint("expected style after {q}", .{arg});
            error_style = std.meta.stringToEnum(ErrorStyle, next_arg) orelse {
                fatalWithHint("expected style after {q}, found {q}", .{ arg, next_arg });
            };
        } else if (mem.eql(u8, arg, "--multiline-errors")) {
            const next_arg = nextArg(args, &arg_idx) orelse
                fatalWithHint("expected style after {q}", .{arg});
            multiline_errors = std.meta.stringToEnum(MultilineErrors, next_arg) orelse {
                fatalWithHint("expected style after {q}, found {q}", .{ arg, next_arg });
            };
        } else if (mem.eql(u8, arg, "--system")) {
            // The usage text shows another argument after this parameter
            // but it is handled by the parent process. The build runner
            // only sees this flag.
            graph.system_package_mode = true;
        } else if (mem.eql(u8, arg, "--have-run-args")) {
            graph.have_run_args = true;
        } else {
            fatalWithHint("unrecognized argument: {q}", .{arg});
        }
    }

    const NO_COLOR = std.zig.EnvVar.NO_COLOR.isSet(&graph.environ_map);
    const CLICOLOR_FORCE = std.zig.EnvVar.CLICOLOR_FORCE.isSet(&graph.environ_map);

    graph.stderr_mode = switch (color) {
        .auto => try .detect(io, .stderr(), NO_COLOR, CLICOLOR_FORCE),
        .on => .escape_codes,
        .off => .no_color,
    };

    try builder.runBuild(root);

    if (builder.validateUserInputDidItFail()) {
        fatal("  access the help menu with 'zig build -h'", .{});
    }

    var wc: Configuration.Wip = .init(gpa);
    defer wc.deinit();
    assert(try wc.addString("") == .empty);
    assert(try wc.addString("root") == .root);

    try serializeSystemIntegrationOptions(&graph, &wc);

    var stdout_buffer: [1024]u8 = undefined;
    var file_writer = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    serialize(builder, &wc, &file_writer.interface) catch |err| switch (err) {
        error.WriteFailed => fatal("failed to write configuration output: {t}", .{file_writer.err.?}),
        error.OutOfMemory => |e| return e,
    };

    // This executable is short-lived and run in Debug mode, so we'd rather
    // have `zig build` run faster than catch resource leaks in the user's
    // build.zig script (or, frankly, this configure runner), therefore we call
    // exit directly here rather than cleanExit.
    process.exit(0);
}

const Serialize = struct {
    arena: Allocator,
    wc: *Configuration.Wip,
    module_map: std.AutoArrayHashMapUnmanaged(*std.Build.Module, Configuration.Module.Index) = .empty,
    package_map: std.AutoArrayHashMapUnmanaged(*std.Build, Configuration.Package.Index) = .empty,
    /// Index corresponds to `Configuration.steps` index.
    step_map: std.AutoArrayHashMapUnmanaged(*Step, void) = .empty,

    fn builderToPackage(s: *Serialize, b: *std.Build) !Configuration.Package.Index {
        if (b.pkg_hash.len == 0) return .root;
        const arena = s.arena;
        const wc = s.wc;
        const gop = try s.package_map.getOrPut(arena, b);
        if (!gop.found_existing) {
            gop.value_ptr.* = @enumFromInt(try wc.addExtra(@as(Configuration.Package, .{
                .hash = try wc.addString(b.pkg_hash),
                .dep_prefix = try wc.addString(b.dep_prefix),
            })));
        }
        return gop.value_ptr.*;
    }

    fn addOptionalLazyPathEnum(s: *Serialize, lp: ?std.Build.LazyPath) !Configuration.LazyPath.OptionalIndex {
        const wc = s.wc;
        return @enumFromInt(switch (lp orelse return .none) {
            .src_path => |src_path| i: {
                const sub_path = try wc.addString(src_path.sub_path);
                break :i try wc.addExtra(@as(Configuration.LazyPath.SourcePath, .{
                    .flags = .{},
                    .owner = try s.builderToPackage(src_path.owner),
                    .sub_path = sub_path,
                }));
            },
            .generated => |generated| i: {
                const sub_path = try wc.addString(generated.sub_path);
                break :i try wc.addExtra(@as(Configuration.LazyPath.Generated, .{
                    .flags = .{ .up = @intCast(generated.up) },
                    .index = generated.index,
                    .sub_path = sub_path,
                }));
            },
            .cwd_relative => |cwd_relative_sub_path| i: {
                const sub_path = try wc.addString(cwd_relative_sub_path);
                break :i try wc.addExtra(@as(Configuration.LazyPath.Relative, .{
                    .flags = .{ .base = .cwd },
                    .sub_path = sub_path,
                }));
            },
            .dependency => |dependency| i: {
                const sub_path = try wc.addString(dependency.sub_path);
                break :i try wc.addExtra(@as(Configuration.LazyPath.SourcePath, .{
                    .flags = .{},
                    .owner = try s.builderToPackage(dependency.dependency.builder),
                    .sub_path = sub_path,
                }));
            },
        });
    }

    fn addOptionalLazyPath(s: *Serialize, lp: ?std.Build.LazyPath) !?Configuration.LazyPath.Index {
        return (try addOptionalLazyPathEnum(s, lp)).unwrap();
    }

    fn addLazyPath(s: *Serialize, lp: std.Build.LazyPath) !Configuration.LazyPath.Index {
        return @enumFromInt(@intFromEnum(try addOptionalLazyPathEnum(s, lp)));
    }

    fn addOptionalSemVer(s: *Serialize, sem_ver: ?std.SemanticVersion) !?Configuration.String {
        return if (sem_ver) |sv| try s.wc.addSemVer(sv) else null;
    }

    fn addOptionalString(s: *Serialize, opt_slice: ?[]const u8) !?Configuration.String {
        return if (opt_slice) |slice| try s.wc.addString(slice) else null;
    }

    fn addSystemLib(s: *Serialize, sl: *const std.Build.Module.SystemLib) !Configuration.SystemLib.Index {
        const wc = s.wc;
        return @enumFromInt(try wc.addDeduped(@as(Configuration.SystemLib, .{
            .flags = .{
                .needed = sl.needed,
                .weak = sl.weak,
                .use_pkg_config = sl.use_pkg_config,
                .preferred_link_mode = sl.preferred_link_mode,
                .search_strategy = sl.search_strategy,
            },
            .name = try wc.addString(sl.name),
        })));
    }

    fn addCSourceFile(s: *Serialize, csf: *const std.Build.Module.CSourceFile) !Configuration.CSourceFile.Index {
        const wc = s.wc;
        const args = try initStringList(s, csf.flags);
        return @enumFromInt(try wc.addExtra(@as(Configuration.CSourceFile, .{
            .flags = .{
                .args_len = @intCast(args.len),
                .lang = .init(csf.language),
            },
            .file = try addLazyPath(s, csf.file),
            .args = .{ .slice = args },
        })));
    }

    fn addCSourceFiles(s: *Serialize, csf: *const std.Build.Module.CSourceFiles) !Configuration.CSourceFiles.Index {
        const wc = s.wc;
        const sub_paths = try initStringList(s, csf.files);
        const args = try initStringList(s, csf.flags);
        return @enumFromInt(try wc.addExtra(@as(Configuration.CSourceFiles, .{
            .flags = .{
                .args_len = @intCast(args.len),
                .lang = .init(csf.language),
            },
            .root = try addLazyPath(s, csf.root),
            .sub_paths = .{ .slice = sub_paths },
            .args = .{ .slice = args },
        })));
    }

    fn addRcSourceFile(s: *Serialize, rsf: *const std.Build.Module.RcSourceFile) !Configuration.RcSourceFile.Index {
        const wc = s.wc;
        const include_paths = try initLazyPathList(s, rsf.include_paths);
        const args = try initStringList(s, rsf.flags);
        return @enumFromInt(try wc.addExtra(@as(Configuration.RcSourceFile, .{
            .flags = .{
                .args_len = @intCast(args.len),
                .include_paths = include_paths.len != 0,
            },
            .file = try addLazyPath(s, rsf.file),
            .include_paths = .{ .slice = include_paths },
            .args = .{ .slice = args },
        })));
    }

    fn initLazyPathList(s: *Serialize, list: []const std.Build.LazyPath) ![]const Configuration.LazyPath.Index {
        const result = try s.arena.alloc(Configuration.LazyPath.Index, list.len);
        for (result, list) |*dest, src| dest.* = try addLazyPath(s, src);
        return result;
    }

    fn initStringList(s: *Serialize, list: []const []const u8) ![]const Configuration.String {
        const wc = s.wc;
        const result = try s.arena.alloc(Configuration.String, list.len);
        for (result, list) |*dest, src| dest.* = try wc.addString(src);
        return result;
    }

    fn initOptionalStringList(s: *Serialize, list: []const ?[]const u8) ![]const Configuration.OptionalString {
        const wc = s.wc;
        const result = try s.arena.alloc(Configuration.OptionalString, list.len);
        for (result, list) |*dest, src| dest.* = try wc.addOptionalString(src);
        return result;
    }

    fn addModule(s: *Serialize, m: *std.Build.Module) !Configuration.Module.Index {
        if (s.module_map.get(m)) |index| return index;

        const wc = s.wc;
        const arena = s.arena;

        const include_dirs = try arena.alloc(Configuration.Module.IncludeDir, m.include_dirs.items.len);
        for (include_dirs, m.include_dirs.items) |*dest, src| dest.* = switch (src) {
            .path => |lp| .{ .path = try addLazyPath(s, lp) },
            .path_system => |lp| .{ .path_system = try addLazyPath(s, lp) },
            .path_after => |lp| .{ .path_after = try addLazyPath(s, lp) },
            .framework_path => |lp| .{ .framework_path = try addLazyPath(s, lp) },
            .framework_path_system => |lp| .{ .framework_path_system = try addLazyPath(s, lp) },
            .embed_path => |lp| .{ .embed_path = try addLazyPath(s, lp) },
            .other_step => |cs| .{ .other_step = stepIndex(s, &cs.step) },
            .config_header_step => |chs| .{ .config_header_step = stepIndex(s, &chs.step) },
        };

        const rpaths = try arena.alloc(Configuration.Module.RPath, m.rpaths.items.len);
        for (rpaths, m.rpaths.items) |*dest, src| dest.* = switch (src) {
            .lazy_path => |lp| .{ .lazy_path = try addLazyPath(s, lp) },
            .special => |slice| .{ .special = try wc.addString(slice) },
        };

        const link_objects = try arena.alloc(Configuration.Module.LinkObject, m.link_objects.items.len);
        for (link_objects, m.link_objects.items) |*dest, *src| dest.* = switch (src.*) {
            .static_path => |lp| .{ .static_path = try addLazyPath(s, lp) },
            .other_step => |cs| .{ .other_step = stepIndex(s, &cs.step) },
            .system_lib => |*sl| .{ .system_lib = try addSystemLib(s, sl) },
            .assembly_file => |lp| .{ .assembly_file = try addLazyPath(s, lp) },
            .c_source_file => |csf| .{ .c_source_file = try addCSourceFile(s, csf) },
            .c_source_files => |csf| .{ .c_source_files = try addCSourceFiles(s, csf) },
            .win32_resource_file => |wrf| .{ .win32_resource_file = try addRcSourceFile(s, wrf) },
        };

        const frameworks = try arena.alloc(Configuration.Module.Framework, m.frameworks.entries.len);
        for (frameworks, m.frameworks.keys(), m.frameworks.values()) |*dest, name, options| dest.* = .{
            .flags = .{
                .needed = options.needed,
                .weak = options.weak,
            },
            .name = try wc.addString(name),
        };

        const lib_paths = try initLazyPathList(s, m.lib_paths.items);
        const c_macros = try initStringList(s, m.c_macros.items);
        const export_symbol_names = try initStringList(s, m.export_symbol_names);

        const module_index: Configuration.Module.Index = @enumFromInt(try wc.addExtra(@as(Configuration.Module, .{
            .flags = .{
                .optimize = .init(m.optimize),
                .strip = .init(m.strip),
                .unwind_tables = .init(m.unwind_tables),
                .dwarf_format = .init(m.dwarf_format),
                .single_threaded = .init(m.single_threaded),
                .stack_protector = .init(m.stack_protector),
                .stack_check = .init(m.stack_check),
                .sanitize_c = .init(m.sanitize_c),
                .sanitize_thread = .init(m.sanitize_thread),
                .fuzz = .init(m.fuzz),
                .code_model = m.code_model,
                .c_macros = c_macros.len != 0,
                .include_dirs = include_dirs.len != 0,
                .lib_paths = lib_paths.len != 0,
                .rpaths = rpaths.len != 0,
                .frameworks = frameworks.len != 0,
                .link_objects = link_objects.len != 0,
                .export_symbol_names = export_symbol_names.len != 0,
            },
            .flags2 = .{
                .valgrind = .init(m.valgrind),
                .pic = .init(m.pic),
                .red_zone = .init(m.red_zone),
                .omit_frame_pointer = .init(m.omit_frame_pointer),
                .error_tracing = .init(m.error_tracing),
                .link_libc = .init(m.link_libc),
                .link_libcpp = .init(m.link_libcpp),
                .no_builtin = .init(m.no_builtin),
            },
            .owner = try s.builderToPackage(m.owner),
            .root_source_file = try s.addOptionalLazyPathEnum(m.root_source_file),
            .import_table = .invalid,
            .resolved_target = try addOptionalResolvedTarget(wc, m.resolved_target),
            .c_macros = .{ .slice = c_macros },
            .lib_paths = .{ .slice = lib_paths },
            .export_symbol_names = .{ .slice = export_symbol_names },
            .include_dirs = .init(include_dirs),
            .rpaths = .init(rpaths),
            .link_objects = .init(link_objects),
            .frameworks = .{ .slice = frameworks },
        })));

        // The import table is the only place that modules can form dependency
        // loops. Therefore, we populate the module indexes only after adding
        // the module to module_map.
        try s.module_map.putNoClobber(arena, m, module_index);

        var imports = try std.MultiArrayList(Configuration.ImportTable.Import).initCapacity(arena, m.import_table.entries.len);
        imports.len = m.import_table.entries.len;
        for (
            imports.items(.name),
            imports.items(.module),
            m.import_table.keys(),
            m.import_table.values(),
        ) |*dest_name, *dest_module, src_name, src_module| {
            dest_name.* = try wc.addString(src_name);
            dest_module.* = try addModule(s, src_module);
        }

        comptime assert(std.mem.eql(u8, @typeInfo(Configuration.Module).@"struct".fields[2].name, "import_table"));
        comptime assert(@typeInfo(Configuration.Module).@"struct".fields[2].type == Configuration.ImportTable.Index);
        assert(wc.extra.items[@intFromEnum(module_index) + 2] == @intFromEnum(Configuration.ImportTable.Index.invalid));
        wc.extra.items[@intFromEnum(module_index) + 2] = try wc.addDeduped(@as(Configuration.ImportTable, .{
            .imports = .{ .mal = imports },
        }));

        return module_index;
    }

    fn stepIndex(s: *const Serialize, step: *Step) Configuration.Step.Index {
        return @enumFromInt(s.step_map.getIndex(step).?);
    }
};

fn serialize(b: *std.Build, wc: *Configuration.Wip, writer: *Io.Writer) !void {
    const graph = b.graph;
    const arena = graph.arena;
    const gpa = wc.gpa;

    var s: Serialize = .{ .wc = wc, .arena = arena };

    // Starting from all top-level steps in `b`, traverse the entire step graph
    // and add all step dependencies implied by module graphs.
    const top_level_steps = b.top_level_steps.values();
    try s.step_map.ensureUnusedCapacity(arena, top_level_steps.len);
    for (top_level_steps) |tls| {
        s.step_map.putAssumeCapacityNoClobber(&tls.step, {});
    }
    {
        while (wc.steps.items.len < s.step_map.count()) {
            const step = s.step_map.keys()[wc.steps.items.len];

            // Set up any implied dependencies for this step. It's important that we do this first, so
            // that the loop below discovers steps implied by the module graph.
            try createModuleDependenciesForStep(step);

            try s.step_map.ensureUnusedCapacity(arena, step.dependencies.items.len);
            for (step.dependencies.items) |other_step| {
                s.step_map.putAssumeCapacity(other_step, {});
            }

            // Add and then de-duplicate dependencies.
            const dep_steps = try arena.alloc(Configuration.Step.Index, step.dependencies.items.len);
            for (dep_steps, step.dependencies.items) |*dest, src|
                dest.* = @enumFromInt(s.step_map.getIndex(src).?);

            const deps: Configuration.Deps.Index = @enumFromInt(try wc.addDeduped(@as(Configuration.Deps, .{
                .steps = .{ .slice = dep_steps },
            })));

            try wc.steps.ensureTotalCapacity(gpa, s.step_map.entries.capacity);
            wc.steps.appendAssumeCapacity(.{
                .name = try wc.addString(step.name),
                .owner = try s.builderToPackage(step.owner),
                .deps = deps,
                .max_rss = .fromBytes(step.max_rss),
                .extended = switch (step.tag) {
                    .top_level => e: {
                        const top_level: *Step.TopLevel = @fieldParentPtr("step", step);
                        break :e @enumFromInt(try wc.addExtra(@as(Configuration.Step.TopLevel, .{
                            .description = try wc.addString(top_level.description),
                        })));
                    },
                    .compile => e: {
                        const c: *Step.Compile = @fieldParentPtr("step", step);
                        const exec_cmd_args: []const ?[]const u8 = c.exec_cmd_args orelse &.{};
                        const installed_headers: []u32 = try arena.alloc(u32, c.installed_headers.items.len);
                        for (installed_headers, c.installed_headers.items) |*dst, src| switch (src) {
                            .file => |file| {
                                dst.* = try wc.addExtra(@as(Configuration.Step.Compile.InstalledHeader.File, .{
                                    .source = try s.addLazyPath(file.source),
                                    .dest_sub_path = try wc.addString(file.dest_rel_path),
                                }));
                            },
                            .directory => |directory| {
                                const include_extensions = directory.options.include_extensions orelse &.{};
                                dst.* = try wc.addExtra(@as(Configuration.Step.Compile.InstalledHeader.Directory, .{
                                    .flags = .{
                                        .include_extensions = include_extensions.len != 0,
                                        .exclude_extensions = directory.options.exclude_extensions.len != 0,
                                    },
                                    .source = try s.addLazyPath(directory.source),
                                    .dest_sub_path = try wc.addString(directory.dest_rel_path),
                                    .exclude_extensions = .{ .slice = try s.initStringList(directory.options.exclude_extensions) },
                                    .include_extensions = .{ .slice = try s.initStringList(include_extensions) },
                                }));
                            },
                        };

                        const extra_index = try wc.addExtra(@as(Configuration.Step.Compile, .{
                            .flags = .{
                                .filters_len = c.filters.len != 0,
                                .exec_cmd_args_len = exec_cmd_args.len != 0,
                                .installed_headers_len = installed_headers.len != 0,
                                .force_undefined_symbols_len = c.force_undefined_symbols.entries.len != 0,

                                .verbose_link = c.verbose_link,
                                .verbose_cc = c.verbose_cc,
                                .rdynamic = c.rdynamic,
                                .import_memory = c.import_memory,
                                .export_memory = c.export_memory,
                                .import_symbols = c.import_symbols,
                                .import_table = c.import_table,
                                .export_table = c.export_table,
                                .shared_memory = c.shared_memory,
                                .link_eh_frame_hdr = c.link_eh_frame_hdr,
                                .link_emit_relocs = c.link_emit_relocs,
                                .link_function_sections = c.link_function_sections,
                                .link_data_sections = c.link_data_sections,
                                .linker_dynamicbase = c.linker_dynamicbase,
                                .link_z_notext = c.link_z_notext,
                                .link_z_relro = c.link_z_relro,
                                .link_z_lazy = c.link_z_lazy,
                                .link_z_defs = c.link_z_defs,
                                .headerpad_max_install_names = c.headerpad_max_install_names,
                                .dead_strip_dylibs = c.dead_strip_dylibs,
                                .force_load_objc = c.force_load_objc,
                                .discard_local_symbols = c.discard_local_symbols,
                                .mingw_unicode_entry_point = c.mingw_unicode_entry_point,
                            },
                            .flags2 = .{
                                .pie = .init(c.pie),
                                .formatted_panics = .init(c.formatted_panics),
                                .bundle_compiler_rt = .init(c.bundle_compiler_rt),
                                .bundle_ubsan_rt = .init(c.bundle_ubsan_rt),
                                .each_lib_rpath = .init(c.each_lib_rpath),
                                .link_gc_sections = .init(c.link_gc_sections),
                                .linker_allow_shlib_undefined = .init(c.linker_allow_shlib_undefined),
                                .linker_allow_undefined_version = .init(c.linker_allow_undefined_version),
                                .linker_enable_new_dtags = .init(c.linker_enable_new_dtags),
                                .dll_export_fns = .init(c.dll_export_fns),
                                .use_llvm = .init(c.use_llvm),
                                .use_lld = .init(c.use_lld),
                                .use_new_linker = .init(c.use_new_linker),
                                .allow_so_scripts = .init(c.allow_so_scripts),
                                .sanitize_coverage_trace_pc_guard = .init(c.sanitize_coverage_trace_pc_guard),
                                .linkage = .init(c.linkage),
                            },
                            .flags3 = .{
                                .is_linking_libc = c.is_linking_libc,
                                .is_linking_libcpp = c.is_linking_libcpp,
                                .version = c.version != null,
                                .compress_debug_sections = c.compress_debug_sections,
                                .initial_memory = c.initial_memory != null,
                                .max_memory = c.max_memory != null,
                                .kind = c.kind,
                                .global_base = c.global_base != null,
                                .test_runner = if (c.test_runner) |tr| switch (tr.mode) {
                                    .simple => .simple,
                                    .server => .server,
                                } else .default,
                                .wasi_exec_model = .init(c.wasi_exec_model),
                                .win32_manifest = c.win32_manifest != null,
                                .win32_module_definition = c.win32_module_definition != null,
                                .zig_lib_dir = c.zig_lib_dir != null,
                                .rc_includes = c.rc_includes,
                                .image_base = c.image_base != null,
                                .build_id = .init(c.build_id),
                                .entry = switch (c.entry) {
                                    .default => .default,
                                    .disabled => .disabled,
                                    .enabled => .enabled,
                                    .symbol_name => .symbol_name,
                                },
                                .lto = .init(c.lto),
                                .subsystem = .init(c.subsystem),
                            },
                            .flags4 = .{
                                .libc_file = c.libc_file != null,
                                .link_z_common_page_size = c.link_z_common_page_size != null,
                                .link_z_max_page_size = c.link_z_max_page_size != null,
                                .pagezero_size = c.pagezero_size != null,
                                .stack_size = c.stack_size != null,
                                .headerpad_size = c.headerpad_size != null,
                                .error_limit = c.error_limit != null,
                                .install_name = c.install_name != null,
                                .entitlements = c.entitlements != null,
                                .expect_errors = if (c.expect_errors) |x| switch (x) {
                                    .contains => .contains,
                                    .exact => .exact,
                                    .starts_with => .starts_with,
                                    .stderr_contains => .stderr_contains,
                                } else .none,
                                .linker_script = c.linker_script != null,
                                .version_script = c.version_script != null,
                                .emit_directory = c.emit_directory != .none,
                                .generated_docs = c.generated_docs != .none,
                                .generated_asm = c.generated_asm != .none,
                                .generated_bin = c.generated_bin != .none,
                                .generated_pdb = c.generated_pdb != .none,
                                .generated_implib = c.generated_implib != .none,
                                .generated_llvm_bc = c.generated_llvm_bc != .none,
                                .generated_llvm_ir = c.generated_llvm_ir != .none,
                                .generated_h = c.generated_h != .none,
                            },
                            .root_module = try s.addModule(c.root_module),
                            .root_name = try wc.addString(c.name),
                            .linker_script = .{ .value = try s.addOptionalLazyPath(c.linker_script) },
                            .version_script = .{ .value = try s.addOptionalLazyPath(c.version_script) },
                            .zig_lib_dir = .{ .value = try s.addOptionalLazyPath(c.zig_lib_dir) },
                            .libc_file = .{ .value = try s.addOptionalLazyPath(c.libc_file) },
                            .win32_manifest = .{ .value = try s.addOptionalLazyPath(c.win32_manifest) },
                            .win32_module_definition = .{ .value = try s.addOptionalLazyPath(c.win32_module_definition) },
                            .entitlements = .{ .value = try s.addOptionalLazyPath(c.entitlements) },
                            .version = .{ .value = try s.addOptionalSemVer(c.version) },
                            .install_name = .{ .value = try s.addOptionalString(c.install_name) },
                            .initial_memory = .{ .value = c.initial_memory },
                            .max_memory = .{ .value = c.max_memory },
                            .global_base = .{ .value = c.global_base },
                            .image_base = .{ .value = c.image_base },
                            .link_z_common_page_size = .{ .value = c.link_z_common_page_size },
                            .link_z_max_page_size = .{ .value = c.link_z_max_page_size },
                            .pagezero_size = .{ .value = c.pagezero_size },
                            .stack_size = .{ .value = c.stack_size },
                            .headerpad_size = .{ .value = c.headerpad_size },
                            .error_limit = .{ .value = c.error_limit },
                            .entry = .{ .value = switch (c.entry) {
                                .symbol_name => |name| try wc.addString(name),
                                .default, .disabled, .enabled => null,
                            } },
                            .build_id = .{ .value = if (c.build_id) |id| switch (id) {
                                .hexstring => |*hexstring| try wc.addString(hexstring.toSlice()),
                                .none, .fast, .uuid, .sha1, .md5 => null,
                            } else null },
                            .filters = .{ .slice = try s.initStringList(c.filters) },
                            .exec_cmd_args = .{ .slice = try s.initOptionalStringList(exec_cmd_args) },
                            .installed_headers = .initErased(installed_headers),
                            .force_undefined_symbols = .{ .slice = try s.initStringList(c.force_undefined_symbols.keys()) },
                            .expect_errors = .{ .u = if (c.expect_errors) |x| switch (x) {
                                .contains => |slice| .{ .contains = try wc.addString(slice) },
                                .exact => |exact| .{ .exact = .{ .slice = try s.initStringList(exact) } },
                                .starts_with => |slice| .{ .starts_with = try wc.addString(slice) },
                                .stderr_contains => |slice| .{ .stderr_contains = try wc.addString(slice) },
                            } else .none },
                            .test_runner = .{ .u = if (c.test_runner) |tr| switch (tr.mode) {
                                .simple => .{ .simple = try s.addLazyPath(tr.path) },
                                .server => .{ .server = try s.addLazyPath(tr.path) },
                            } else .default },

                            .emit_directory = .{ .value = c.emit_directory.unwrap() },
                            .generated_docs = .{ .value = c.generated_docs.unwrap() },
                            .generated_asm = .{ .value = c.generated_asm.unwrap() },
                            .generated_bin = .{ .value = c.generated_bin.unwrap() },
                            .generated_pdb = .{ .value = c.generated_pdb.unwrap() },
                            .generated_implib = .{ .value = c.generated_implib.unwrap() },
                            .generated_llvm_bc = .{ .value = c.generated_llvm_bc.unwrap() },
                            .generated_llvm_ir = .{ .value = c.generated_llvm_ir.unwrap() },
                            .generated_h = .{ .value = c.generated_h.unwrap() },
                        }));

                        break :e @enumFromInt(extra_index);
                    },
                    .install_artifact => e: {
                        const ia: *Step.InstallArtifact = @fieldParentPtr("step", step);
                        break :e @enumFromInt(try wc.addExtra(@as(Configuration.Step.InstallArtifact, .{
                            .flags = .{
                                .dylib_symlinks = ia.dylib_symlinks,
                                .bin_dir = ia.dest_dir != null,
                                .implib_dir = ia.implib_dir != null,
                                .pdb_dir = ia.pdb_dir != null,
                                .h_dir = ia.h_dir != null,
                                .bin_sub_path = ia.dest_sub_path != null,
                            },
                            .bin_dir = .{ .value = try addInstallDirDefaultNull(wc, ia.dest_dir) },
                            .implib_dir = .{ .value = try addInstallDirDefaultNull(wc, ia.implib_dir) },
                            .pdb_dir = .{ .value = try addInstallDirDefaultNull(wc, ia.pdb_dir) },
                            .h_dir = .{ .value = try addInstallDirDefaultNull(wc, ia.h_dir) },
                            .bin_sub_path = .{ .value = try s.addOptionalString(ia.dest_sub_path) },
                        })));
                    },
                    .install_file => e: {
                        const sif: *Step.InstallFile = @fieldParentPtr("step", step);
                        break :e @enumFromInt(try wc.addExtra(@as(Configuration.Step.InstallFile, .{
                            .source = try s.addLazyPath(sif.source),
                            .dest_dir = try addInstallDir(wc, sif.dir),
                            .dest_sub_path = try wc.addString(sif.dest_rel_path),
                        })));
                    },
                    .install_dir => @panic("TODO"),
                    .remove_dir => @panic("TODO"),
                    .fail => @panic("TODO"),
                    .fmt => @panic("TODO"),
                    .translate_c => @panic("TODO"),
                    .write_file => @panic("TODO"),
                    .update_source_files => @panic("TODO"),
                    .run => e: {
                        const run: *Step.Run = @fieldParentPtr("step", step);

                        const captured_stdout: Configuration.OptionalString = if (run.captured_stdout) |cs|
                            .init(try wc.addString(cs.output.basename))
                        else
                            .none;

                        const captured_stderr: Configuration.OptionalString = if (run.captured_stderr) |cs|
                            .init(try wc.addString(cs.output.basename))
                        else
                            .none;

                        const extra_index = try wc.addExtra(@as(Configuration.Step.Run, .{
                            .flags = .{
                                .disable_zig_progress = run.disable_zig_progress,
                                .skip_foreign_checks = run.skip_foreign_checks,
                                .failing_to_execute_foreign_is_an_error = run.failing_to_execute_foreign_is_an_error,
                                .has_side_effects = run.has_side_effects,
                                .test_runner_mode = run.test_runner_mode,
                                .color = run.color,
                                .stdio = switch (run.stdio) {
                                    .infer_from_args => .infer_from_args,
                                    .inherit => .inherit,
                                    .check => .check,
                                    .zig_test => .zig_test,
                                },
                                .stdin = switch (run.stdin) {
                                    .none => .none,
                                    .bytes => .bytes,
                                    .lazy_path => .lazy_path,
                                },
                                .stdout_trim_whitespace = if (run.captured_stdout) |cs| cs.trim_whitespace else .none,
                                .stderr_trim_whitespace = if (run.captured_stderr) |cs| cs.trim_whitespace else .none,
                                .stdio_limit = run.stdio_limit != .unlimited,
                                .producer = run.producer != null,
                            },
                            .file_inputs_len = @intCast(run.file_inputs.items.len),
                            .args_len = @intCast(run.argv.items.len),
                            .cwd = try s.addOptionalLazyPathEnum(run.cwd),
                            .captured_stdout = captured_stdout,
                            .captured_stderr = captured_stderr,
                        }));

                        log.err("TODO serialize the trailing Run step data", .{});

                        break :e @enumFromInt(extra_index);
                    },
                    .check_file => @panic("TODO"),
                    .check_object => @panic("TODO"),
                    .config_header => @panic("TODO"),
                    .objcopy => @panic("TODO"),
                    .options => @panic("TODO"),
                },
            });
        }
    }

    try wc.unlazy_deps.ensureUnusedCapacity(gpa, graph.needed_lazy_dependencies.keys().len);
    for (graph.needed_lazy_dependencies.keys()) |k| {
        wc.unlazy_deps.appendAssumeCapacity(try wc.addString(k));
    }

    try wc.write(writer, .{
        .default_step = s.stepIndex(b.default_step),
        .generated_files_len = @intCast(graph.generated_files.items.len),
    });
}

fn addOptionalResolvedTarget(
    wc: *Configuration.Wip,
    optional_resolved_target: ?std.Build.ResolvedTarget,
) !Configuration.ResolvedTarget.OptionalIndex {
    const resolved_target = optional_resolved_target orelse return .none;
    return @enumFromInt(try wc.addDeduped(@as(Configuration.ResolvedTarget, .{
        .query = try wc.addTargetQuery(resolved_target.query),
        .result = try wc.addTarget(resolved_target.result),
    })));
}

fn addInstallDir(wc: *Configuration.Wip, install_dir: ?std.Build.InstallDir) !Configuration.InstallDestDir {
    switch (install_dir orelse return .none) {
        .prefix => return .prefix,
        .lib => return .lib,
        .bin => return .bin,
        .header => return .header,
        .custom => |sub_path| return .initCustom(try wc.addString(sub_path)),
    }
}

fn addInstallDirDefaultNull(wc: *Configuration.Wip, install_dir: ?std.Build.InstallDir) !?Configuration.InstallDestDir {
    return try addInstallDir(wc, install_dir orelse return null);
}

/// If the given `Step` is a `Step.Compile`, adds any dependencies for that step which
/// are implied by the module graph rooted at `step.cast(Step.Compile).?.root_module`.
fn createModuleDependenciesForStep(step: *Step) Allocator.Error!void {
    const root_module = if (step.cast(Step.Compile)) |cs| root: {
        break :root cs.root_module;
    } else return; // not a compile step so no module dependencies

    // Starting from `root_module`, discover all modules in this graph.
    const modules = root_module.getGraph().modules;

    // For each of those modules, set up the implied step dependencies.
    for (modules) |mod| {
        if (mod.root_source_file) |lp| lp.addStepDependencies(step);
        for (mod.include_dirs.items) |include_dir| switch (include_dir) {
            .path,
            .path_system,
            .path_after,
            .framework_path,
            .framework_path_system,
            .embed_path,
            => |lp| lp.addStepDependencies(step),

            .other_step => |other| {
                other.getEmittedIncludeTree().addStepDependencies(step);
                step.dependOn(&other.step);
            },

            .config_header_step => |other| step.dependOn(&other.step),
        };
        for (mod.lib_paths.items) |lp| lp.addStepDependencies(step);
        for (mod.rpaths.items) |rpath| switch (rpath) {
            .lazy_path => |lp| lp.addStepDependencies(step),
            .special => {},
        };
        for (mod.link_objects.items) |link_object| switch (link_object) {
            .static_path,
            .assembly_file,
            => |lp| lp.addStepDependencies(step),
            .other_step => |other| step.dependOn(&other.step),
            .system_lib => {},
            .c_source_file => |source| source.file.addStepDependencies(step),
            .c_source_files => |source_files| source_files.root.addStepDependencies(step),
            .win32_resource_file => |rc_source| {
                rc_source.file.addStepDependencies(step);
                for (rc_source.include_paths) |lp| lp.addStepDependencies(step);
            },
        };
    }
}

fn nextArg(args: []const [:0]const u8, idx: *usize) ?[:0]const u8 {
    if (idx.* >= args.len) return null;
    defer idx.* += 1;
    return args[idx.*];
}

fn nextArgOrFatal(args: []const [:0]const u8, idx: *usize) [:0]const u8 {
    return nextArg(args, idx) orelse {
        fatalWithHint("expected argument after: {s}", .{args[idx.* - 1]});
    };
}

fn expectArgOrFatal(args: []const [:0]const u8, index_ptr: *usize, first: []const u8) []const u8 {
    const next_arg = nextArg(args, index_ptr) orelse fatal("missing {q} argument", .{first});
    if (!mem.eql(u8, first, next_arg)) fatal("expected {q} instead of {q}", .{ first, next_arg });
    const arg = nextArg(args, index_ptr) orelse fatal("expected argument after {q}", .{first});
    return arg;
}

const ErrorStyle = enum {
    verbose,
    minimal,
    verbose_clear,
    minimal_clear,
    fn verboseContext(s: ErrorStyle) bool {
        return switch (s) {
            .verbose, .verbose_clear => true,
            .minimal, .minimal_clear => false,
        };
    }
    fn clearOnUpdate(s: ErrorStyle) bool {
        return switch (s) {
            .verbose, .minimal => false,
            .verbose_clear, .minimal_clear => true,
        };
    }
};
const MultilineErrors = enum { indent, newline, none };
const Summary = enum { all, new, failures, line, none };

fn fatalWithHint(comptime f: []const u8, args: anytype) noreturn {
    log.info("to access the help menu: zig build -h", .{});
    fatal(f, args);
}

fn serializeSystemIntegrationOptions(graph: *std.Build.Graph, wc: *Configuration.Wip) Allocator.Error!void {
    const gpa = wc.gpa;

    var bad = false;
    try wc.system_integrations.ensureTotalCapacityPrecise(gpa, graph.system_integration_options.entries.len);
    for (graph.system_integration_options.keys(), graph.system_integration_options.values()) |k, v| {
        wc.system_integrations.appendAssumeCapacity(.{
            .name = try wc.addString(k),
            .status = switch (v) {
                .user_disabled, .user_enabled => x: {
                    // The user tried to enable or disable a system library integration, but
                    // the configure script did not recognize that option.
                    log.err("system integration name not recognized by configure script: {s}", .{k});
                    bad = true;
                    break :x .disabled;
                },
                .declared_disabled => .disabled,
                .declared_enabled => .enabled,
            },
        });
    }
    if (bad) {
        log.info("help menu contains available options: zig build -h", .{});
        process.exit(1);
    }
}
