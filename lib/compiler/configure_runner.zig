const builtin = @import("builtin");

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const fmt = std.fmt;
const mem = std.mem;
const process = std.process;
const File = std.Io.File;
const Step = std.Build.Step;
const Watch = std.Build.Watch;
const WebServer = std.Build.WebServer;
const Allocator = std.mem.Allocator;
const fatal = std.process.fatal;
const Writer = std.Io.Writer;
const Color = std.zig.Color;

pub const root = @import("@build");
pub const dependencies = @import("@dependencies");

pub const std_options: std.Options = .{
    .side_channels_mitigations = .none,
    .http_disable_tls = true,
};

pub fn main(init: process.Init.Minimal) !void {
    // The build runner is often short-lived, but thanks to `--watch` and `--webui`, that's not
    // always the case. So, we do need a true gpa for some things.
    var debug_gpa_state: std.heap.DebugAllocator(.{}) = .init;
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

    const zig_exe = nextArg(args, &arg_idx) orelse fatal("missing zig compiler path", .{});
    const zig_lib_dir = nextArg(args, &arg_idx) orelse fatal("missing zig lib directory path", .{});
    const build_root = nextArg(args, &arg_idx) orelse fatal("missing build root directory path", .{});
    const cache_root = nextArg(args, &arg_idx) orelse fatal("missing cache root directory path", .{});
    const global_cache_root = nextArg(args, &arg_idx) orelse fatal("missing global cache root directory path", .{});

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
        .path = cache_root,
        .handle = try cwd.createDirPathOpen(io, cache_root, .{}),
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
        } else if (mem.eql(u8, arg, "--verbose")) {
            builder.verbose = true;
        } else if (mem.startsWith(u8, arg, "-fsys=")) {
            const name = arg["-fsys=".len..];
            graph.system_library_options.put(arena, name, .user_enabled) catch @panic("OOM");
        } else if (mem.startsWith(u8, arg, "-fno-sys=")) {
            const name = arg["-fno-sys=".len..];
            graph.system_library_options.put(arena, name, .user_disabled) catch @panic("OOM");
        } else if (mem.eql(u8, arg, "--release")) {
            builder.release_mode = .any;
        } else if (mem.startsWith(u8, arg, "--release=")) {
            const text = arg["--release=".len..];
            builder.release_mode = std.meta.stringToEnum(std.Build.ReleaseMode, text) orelse {
                fatalWithHint("expected [off|any|fast|safe|small] in '{s}', found '{s}'", .{
                    arg, text,
                });
            };
        } else if (mem.eql(u8, arg, "--search-prefix")) {
            const search_prefix = nextArgOrFatal(args, &arg_idx);
            builder.addSearchPrefix(search_prefix);
        } else if (mem.eql(u8, arg, "--libc")) {
            builder.libc_file = nextArgOrFatal(args, &arg_idx);
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
        } else if (mem.eql(u8, arg, "--seed")) {
            const next_arg = nextArg(args, &arg_idx) orelse
                fatalWithHint("expected u32 after '{s}'", .{arg});
            graph.random_seed = std.fmt.parseUnsigned(u32, next_arg, 0) catch |err| {
                fatal("unable to parse seed '{s}' as unsigned 32-bit integer: {s}\n", .{
                    next_arg, @errorName(err),
                });
            };
        } else if (mem.eql(u8, arg, "--build-id")) {
            builder.build_id = .fast;
        } else if (mem.startsWith(u8, arg, "--build-id=")) {
            const style = arg["--build-id=".len..];
            builder.build_id = std.zig.BuildId.parse(style) catch |err| {
                fatal("unable to parse --build-id style '{s}': {s}", .{
                    style, @errorName(err),
                });
            };
        } else if (mem.eql(u8, arg, "--debug-pkg-config")) {
            builder.debug_pkg_config = true;
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
        } else if (mem.eql(u8, arg, "--libc-runtimes") or mem.eql(u8, arg, "--glibc-runtimes")) {
            // --glibc-runtimes was the old name of the flag; kept for compatibility for now.
            builder.libc_runtimes_dir = nextArgOrFatal(args, &arg_idx);
        } else if (mem.eql(u8, arg, "--verbose-link")) {
            builder.verbose_link = true;
        } else if (mem.eql(u8, arg, "--verbose-air")) {
            builder.verbose_air = true;
        } else if (mem.eql(u8, arg, "--verbose-llvm-ir")) {
            builder.verbose_llvm_ir = "-";
        } else if (mem.startsWith(u8, arg, "--verbose-llvm-ir=")) {
            builder.verbose_llvm_ir = arg["--verbose-llvm-ir=".len..];
        } else if (mem.startsWith(u8, arg, "--verbose-llvm-bc=")) {
            builder.verbose_llvm_bc = arg["--verbose-llvm-bc=".len..];
        } else if (mem.eql(u8, arg, "--verbose-cimport")) {
            builder.verbose_cimport = true;
        } else if (mem.eql(u8, arg, "--verbose-cc")) {
            builder.verbose_cc = true;
        } else if (mem.eql(u8, arg, "--verbose-llvm-cpu-features")) {
            builder.verbose_llvm_cpu_features = true;
        } else if (mem.eql(u8, arg, "-fincremental")) {
            graph.incremental = true;
        } else if (mem.eql(u8, arg, "-fno-incremental")) {
            graph.incremental = false;
        } else if (mem.eql(u8, arg, "-fwine")) {
            builder.enable_wine = true;
        } else if (mem.eql(u8, arg, "-fno-wine")) {
            builder.enable_wine = false;
        } else if (mem.eql(u8, arg, "-fqemu")) {
            builder.enable_qemu = true;
        } else if (mem.eql(u8, arg, "-fno-qemu")) {
            builder.enable_qemu = false;
        } else if (mem.eql(u8, arg, "-fwasmtime")) {
            builder.enable_wasmtime = true;
        } else if (mem.eql(u8, arg, "-fno-wasmtime")) {
            builder.enable_wasmtime = false;
        } else if (mem.eql(u8, arg, "-frosetta")) {
            builder.enable_rosetta = true;
        } else if (mem.eql(u8, arg, "-fno-rosetta")) {
            builder.enable_rosetta = false;
        } else if (mem.eql(u8, arg, "-fdarling")) {
            builder.enable_darling = true;
        } else if (mem.eql(u8, arg, "-fno-darling")) {
            builder.enable_darling = false;
        } else if (mem.eql(u8, arg, "-fallow-so-scripts")) {
            graph.allow_so_scripts = true;
        } else if (mem.eql(u8, arg, "-fno-allow-so-scripts")) {
            graph.allow_so_scripts = false;
        } else if (mem.eql(u8, arg, "-freference-trace")) {
            builder.reference_trace = 256;
        } else if (mem.startsWith(u8, arg, "-freference-trace=")) {
            const num = arg["-freference-trace=".len..];
            builder.reference_trace = std.fmt.parseUnsigned(u32, num, 10) catch |err| {
                std.debug.print("unable to parse reference_trace count '{s}': {s}", .{ num, @errorName(err) });
                process.exit(1);
            };
        } else if (mem.eql(u8, arg, "-fno-reference-trace")) {
            builder.reference_trace = null;
        } else if (mem.cutPrefix(u8, arg, "-j")) |text| {
            const n = std.fmt.parseUnsigned(u32, text, 10) catch |err|
                fatal("unable to parse jobs count '{s}': {t}", .{ text, err });
            if (n < 1) fatal("number of jobs must be at least 1", .{});
            threaded.setAsyncLimit(.limited(n));
        } else if (mem.eql(u8, arg, "--")) {
            builder.args = argsRest(args, arg_idx);
            break;
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
}

fn nextArg(args: []const [:0]const u8, idx: *usize) ?[:0]const u8 {
    if (idx.* >= args.len) return null;
    defer idx.* += 1;
    return args[idx.*];
}

fn nextArgOrFatal(args: []const [:0]const u8, idx: *usize) [:0]const u8 {
    return nextArg(args, idx) orelse {
        std.debug.print("expected argument after '{s}'\n  access the help menu with 'zig build -h'\n", .{args[idx.* - 1]});
        process.exit(1);
    };
}

fn argsRest(args: []const [:0]const u8, idx: usize) ?[]const [:0]const u8 {
    if (idx >= args.len) return null;
    return args[idx..];
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
    std.debug.print(f ++ "\n  access the help menu with 'zig build -h'\n", args);
    process.exit(1);
}
