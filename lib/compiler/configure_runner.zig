const builtin = @import("builtin");

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const fmt = std.fmt;
const mem = std.mem;
const process = std.process;
const File = std.Io.File;
const Step = std.Build.Step;
const Allocator = std.mem.Allocator;
const fatal = std.process.fatal;
const Writer = std.Io.Writer;
const Color = std.zig.Color;
const Configuration = std.Build.Configuration;

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
        .time_report = false,
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
            graph.system_library_options.put(arena, name, .user_enabled) catch @panic("OOM");
        } else if (mem.cutPrefix(u8, arg, "-fno-sys=")) |name| {
            graph.system_library_options.put(arena, name, .user_disabled) catch @panic("OOM");
        } else if (mem.eql(u8, arg, "--release")) {
            graph.release_mode = .any;
        } else if (mem.cutPrefix(u8, arg, "--release=")) |text| {
            graph.release_mode = std.meta.stringToEnum(std.Build.ReleaseMode, text) orelse {
                fatalWithHint("expected [off|any|fast|safe|small] in '{s}', found '{s}'", .{
                    arg, text,
                });
            };
        } else if (mem.eql(u8, arg, "--color")) {
            const next_arg = nextArg(args, &arg_idx) orelse
                fatalWithHint("expected [auto|on|off] after '{s}'", .{arg});
            color = std.meta.stringToEnum(Color, next_arg) orelse {
                fatalWithHint("expected [auto|on|off] after '{s}', found '{s}'", .{
                    arg, next_arg,
                });
            };
        } else if (mem.eql(u8, arg, "--error-style")) {
            const next_arg = nextArg(args, &arg_idx) orelse
                fatalWithHint("expected style after '{s}'", .{arg});
            error_style = std.meta.stringToEnum(ErrorStyle, next_arg) orelse {
                fatalWithHint("expected style after '{s}', found '{s}'", .{ arg, next_arg });
            };
        } else if (mem.eql(u8, arg, "--multiline-errors")) {
            const next_arg = nextArg(args, &arg_idx) orelse
                fatalWithHint("expected style after '{s}'", .{arg});
            multiline_errors = std.meta.stringToEnum(MultilineErrors, next_arg) orelse {
                fatalWithHint("expected style after '{s}', found '{s}'", .{ arg, next_arg });
            };
        } else if (mem.eql(u8, arg, "--build-id")) {
            builder.build_id = .fast;
        } else if (mem.cutPrefix(u8, arg, "--build-id=")) |style| {
            builder.build_id = std.zig.BuildId.parse(style) catch |err|
                fatal("unable to parse --build-id style '{s}': {t}", .{ style, err });
        } else if (mem.eql(u8, arg, "--debug-rt")) {
            graph.debug_compiler_runtime_libs = true;
        } else if (mem.eql(u8, arg, "--debug-compile-errors")) {
            builder.debug_compile_errors = true;
        } else if (mem.eql(u8, arg, "--debug-incremental")) {
            builder.debug_incremental = true;
        } else if (mem.eql(u8, arg, "--system")) {
            // The usage text shows another argument after this parameter
            // but it is handled by the parent process. The build runner
            // only sees this flag.
            graph.system_package_mode = true;
        } else {
            fatalWithHint("unrecognized argument: '{s}'", .{arg});
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

    var wc: Configuration.Wip = .init(gpa);
    defer wc.deinit();

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

fn serialize(b: *std.Build, wc: *Configuration.Wip, writer: *Io.Writer) !void {
    const graph = b.graph;
    const arena = graph.arena;
    const gpa = wc.gpa;

    // Starting from all top-level steps in `b`, traverse the entire step graph
    // and add all step dependencies implied by module graphs.
    const top_level_steps = b.top_level_steps.values();
    // Index corresponds to `Configuration.steps` index.
    var step_map: std.AutoArrayHashMapUnmanaged(*Step, void) = .empty;
    try step_map.ensureUnusedCapacity(arena, top_level_steps.len);
    for (top_level_steps) |tls| {
        step_map.putAssumeCapacityNoClobber(&tls.step, {});
    }
    {
        while (wc.steps.items.len < step_map.count()) {
            const step = step_map.keys()[wc.steps.items.len];

            // Set up any implied dependencies for this step. It's important that we do this first, so
            // that the loop below discovers steps implied by the module graph.
            try createModuleDependenciesForStep(step);

            try step_map.ensureUnusedCapacity(arena, step.dependencies.items.len);
            for (step.dependencies.items) |other_step| {
                step_map.putAssumeCapacity(other_step, {});
            }

            // Add and then de-duplicate dependencies.
            const deps = d: {
                const deps: Configuration.Deps = @enumFromInt(wc.extra.items.len);
                for (try wc.prepareDeps(step.dependencies.items.len), step.dependencies.items) |*dep, dep_step|
                    dep.* = @intCast(step_map.getIndex(dep_step).?);
                break :d try wc.dedupeDeps(deps);
            };

            try wc.steps.ensureTotalCapacity(gpa, step_map.entries.capacity);
            wc.steps.appendAssumeCapacity(.{
                .name = try wc.addString(step.name),
                .flags = .{ .tag = step.tag },
                .deps = deps,
                .max_rss = .fromBytes(step.max_rss),
                .extra_index = switch (step.tag) {
                    .top_level => e: {
                        const top_level: *Step.TopLevel = @fieldParentPtr("step", step);
                        break :e try wc.addExtra(@as(Configuration.Step.TopLevel, .{
                            .description = try wc.addString(top_level.description),
                        }));
                    },
                    .compile => @panic("TODO"),
                    .install_artifact => e: {
                        const ia: *Step.InstallArtifact = @fieldParentPtr("step", step);
                        break :e try wc.addExtra(@as(Configuration.Step.InstallArtifact, .{
                            .dest_dir = try addInstallDir(wc, ia.dest_dir),
                            .dest_sub_path = try wc.addString(ia.dest_sub_path),
                            .emitted_bin = try addOptionalLazyPath(wc, ia.emitted_bin),
                            .implib_dir = try addInstallDir(wc, ia.implib_dir),
                            .emitted_implib = try addOptionalLazyPath(wc, ia.emitted_implib),
                            .pdb_dir = try addInstallDir(wc, ia.pdb_dir),
                            .emitted_pdb = try addOptionalLazyPath(wc, ia.emitted_pdb),
                            .h_dir = try addInstallDir(wc, ia.h_dir),
                            .emitted_h = try addOptionalLazyPath(wc, ia.emitted_h),
                            .artifact = stepIndex(&step_map, &ia.artifact.step),
                        }));
                    },
                    .install_file => @panic("TODO"),
                    .install_dir => @panic("TODO"),
                    .remove_dir => @panic("TODO"),
                    .fail => @panic("TODO"),
                    .fmt => @panic("TODO"),
                    .translate_c => @panic("TODO"),
                    .write_file => @panic("TODO"),
                    .update_source_files => @panic("TODO"),
                    .run => @panic("TODO"),
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
        .default_step = stepIndex(&step_map, b.default_step),
    });
}

fn addOptionalLazyPath(wc: *Configuration.Wip, lp: ?std.Build.LazyPath) !Configuration.OptionalLazyPath {
    return @enumFromInt(switch (lp orelse return .none) {
        .src_path => |src_path| i: {
            const owner = builderToPackage(src_path.owner);
            const sub_path = try wc.addString(src_path.sub_path);
            break :i try wc.addExtra(@as(Configuration.OptionalLazyPath.SourcePath, .{
                .flags = .{},
                .owner = owner,
                .sub_path = sub_path,
            }));
        },
        .generated => |generated| i: {
            const sub_path = try wc.addString(generated.sub_path);
            break :i try wc.addExtra(@as(Configuration.OptionalLazyPath.Generated, .{
                .flags = .{ .up = @intCast(generated.up) },
                .sub_path = sub_path,
            }));
        },
        .cwd_relative => |cwd_relative_sub_path| i: {
            const sub_path = try wc.addString(cwd_relative_sub_path);
            break :i try wc.addExtra(@as(Configuration.OptionalLazyPath.Relative, .{
                .flags = .{ .base = .cwd },
                .sub_path = sub_path,
            }));
        },
        .dependency => |dependency| i: {
            const owner = builderToPackage(dependency.dependency.builder);
            const sub_path = try wc.addString(dependency.sub_path);
            break :i try wc.addExtra(@as(Configuration.OptionalLazyPath.SourcePath, .{
                .flags = .{},
                .owner = owner,
                .sub_path = sub_path,
            }));
        },
    });
}

fn builderToPackage(b: *std.Build) Configuration.Package {
    _ = b;
    @panic("TODO");
}

fn addInstallDir(wc: *Configuration.Wip, install_dir: ?std.Build.InstallDir) !Configuration.InstallDir {
    switch (install_dir orelse return .none) {
        .prefix => return .prefix,
        .lib => return .lib,
        .bin => return .bin,
        .header => return .header,
        .custom => |sub_path| return .initCustom(try wc.addString(sub_path)),
    }
}

fn stepIndex(step_map: *const std.AutoArrayHashMapUnmanaged(*Step, void), step: *Step) Configuration.Step.Index {
    return @enumFromInt(step_map.getIndex(step).?);
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
        fatal("expected argument after {q}\n  access the help menu with \"zig build -h\"", .{
            args[idx.* - 1],
        });
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
    fatal(f ++ "\n  access the help menu with \"zig build -h\"", args);
}
