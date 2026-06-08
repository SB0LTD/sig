/// CLI Argument Parser — tools/sig_build/cli.sig
///
/// Dedicated module for parsing argv into Runner_Args + Cli_Config.
/// Extracts the CLI parsing logic from build_host.sig and main.sig into
/// a reusable, testable module.
///
/// Argv layout (from compiler's sigBuildDelegate):
///   [0] = runner binary path
///   [1] = sig compiler path
///   [2] = zig lib directory
///   [3] = build root directory
///   [4] = local cache directory
///   [5] = global cache directory
///   [6..] = user arguments: step names, -Dkey=value, -jN, --prefix, etc.
///
/// All stack buffers, no allocator.
const std = @import("std");
const sig = @import("sig");
const sig_build = @import("sig_build");

// ── Re-exports from sig_build for convenience ───────────────────────────────
const Runner_Args = sig_build.Runner_Args;
const Cli_Config = sig_build.Cli_Config;
const Option_Map = sig_build.Option_Map;
const PATH_BUF_SIZE = sig_build.PATH_BUF_SIZE;
const MAX_OPTIONS = sig_build.MAX_OPTIONS;

/// Result of parsing the full argv: fixed positional args + user config.
pub const Parse_Result = struct {
    runner_args: Runner_Args = .{},
    config: Cli_Config = .{},
};

/// Error conditions during CLI parsing. All are recoverable (no panics).
pub const Parse_Error = error{
    /// A positional path argument exceeded PATH_BUF_SIZE.
    PathTooLong,
    /// Fewer than 6 positional arguments were provided.
    InsufficientArgs,
    /// The -D option map is full (MAX_OPTIONS exceeded).
    TooManyOptions,
    /// Too many step names (max 32).
    TooManySteps,
    /// -j flag missing its numeric argument.
    MissingThreadCount,
    /// -j value is not a valid integer.
    InvalidThreadCount,
    /// --prefix missing its path argument.
    MissingPrefixPath,
    /// --zig-lib-dir missing its path argument.
    MissingZigLibDir,
    /// --search-prefix missing its path argument.
    MissingSearchPrefix,
    /// --cache-dir missing its path argument.
    MissingCacheDir,
    /// An unknown long option was encountered.
    UnknownOption,
    /// Iterator returned a decode error.
    DecodeError,
};

/// Parse the full argv into a Parse_Result.
///
/// Takes a sig.process.Argv_Iterator (already initialized with the raw
/// argv vector and a stack decode buffer). Consumes all arguments.
///
/// Returns Parse_Error on failure — caller decides how to report
/// (fatal, stderr message, etc.).
pub fn parse(args_it: anytype) Parse_Error!Parse_Result {
    var result: Parse_Result = .{};

    var arg_count: usize = 0;

    // ── Fixed positional args [0..6) ────────────────────────────────────

    // argv[0]: runner binary path
    if (args_it.next() catch return error.DecodeError) |arg| {
        if (arg.len > PATH_BUF_SIZE) return error.PathTooLong;
        @memcpy(result.runner_args.runner_binary[0..arg.len], arg);
        result.runner_args.runner_binary_len = arg.len;
        arg_count += 1;
    }

    // argv[1]: sig compiler path
    if (args_it.next() catch return error.DecodeError) |arg| {
        if (arg.len > PATH_BUF_SIZE) return error.PathTooLong;
        @memcpy(result.runner_args.compiler_path[0..arg.len], arg);
        result.runner_args.compiler_path_len = arg.len;
        arg_count += 1;
    }

    // argv[2]: zig lib directory
    if (args_it.next() catch return error.DecodeError) |arg| {
        if (arg.len > PATH_BUF_SIZE) return error.PathTooLong;
        @memcpy(result.runner_args.zig_lib_dir[0..arg.len], arg);
        result.runner_args.zig_lib_dir_len = arg.len;
        arg_count += 1;
    }

    // argv[3]: build root directory
    if (args_it.next() catch return error.DecodeError) |arg| {
        if (arg.len > PATH_BUF_SIZE) return error.PathTooLong;
        @memcpy(result.runner_args.build_root[0..arg.len], arg);
        result.runner_args.build_root_len = arg.len;
        arg_count += 1;
    }

    // argv[4]: local cache directory
    if (args_it.next() catch return error.DecodeError) |arg| {
        if (arg.len > PATH_BUF_SIZE) return error.PathTooLong;
        @memcpy(result.runner_args.local_cache_dir[0..arg.len], arg);
        result.runner_args.local_cache_dir_len = arg.len;
        arg_count += 1;
    }

    // argv[5]: global cache directory
    if (args_it.next() catch return error.DecodeError) |arg| {
        if (arg.len > PATH_BUF_SIZE) return error.PathTooLong;
        @memcpy(result.runner_args.global_cache_dir[0..arg.len], arg);
        result.runner_args.global_cache_dir_len = arg.len;
        arg_count += 1;
    }

    if (arg_count < 6) return error.InsufficientArgs;

    // ── User args [6..]: flags, options, step names ─────────────────────

    try parseUserArgs(args_it, &result.config);

    return result;
}

/// Parse only user arguments (argv[6+]) into a Cli_Config.
///
/// This is the inner loop extracted so both the full-parse path and
/// callers that already consumed positional args can reuse it.
///
/// Handles:
///   - `-Dkey=value` / `-Dkey` (boolean shorthand)
///   - `-jN` / `-j N`
///   - `--prefix <path>`
///   - `--zig-lib-dir <path>`
///   - `--search-prefix <path>`
///   - `--cache-dir <path>`
///   - `--verbose`
///   - `--benchmark`
///   - `--self-test[=compiler]`
///   - Positional step names (anything not starting with `-`)
pub fn parseUserArgs(args_it: anytype, config: *Cli_Config) Parse_Error!void {
    while (args_it.next() catch return error.DecodeError) |arg| {
        if (arg.len >= 2 and arg[0] == '-' and arg[1] == 'D') {
            // -Dname=value or -Dname (boolean shorthand)
            sig_build.parseOption(&config.options, arg) catch {
                return error.TooManyOptions;
            };
        } else if (arg.len >= 2 and arg[0] == '-' and arg[1] == 'j') {
            // -jN or -j N
            if (sig_build.parseThreadCount(arg)) |count| {
                config.thread_count = count;
            } else {
                // -j N form: next arg is the count.
                if (args_it.next() catch return error.DecodeError) |next_arg| {
                    config.thread_count = std.fmt.parseInt(usize, next_arg, 10) catch {
                        return error.InvalidThreadCount;
                    };
                } else {
                    return error.MissingThreadCount;
                }
            }
        } else if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            // Long options
            try parseLongOption(args_it, config, arg);
        } else {
            // Positional argument: step name.
            config.requested_steps.push(arg) catch {
                return error.TooManySteps;
            };
        }
    }
}

/// Parse a single long option (arg starts with "--").
fn parseLongOption(args_it: anytype, config: *Cli_Config, arg: []const u8) Parse_Error!void {
    if (std.mem.eql(u8, arg, "--prefix")) {
        if (args_it.next() catch return error.DecodeError) |value| {
            if (value.len > PATH_BUF_SIZE) return error.PathTooLong;
            @memcpy(config.install_prefix[0..value.len], value);
            config.install_prefix_len = value.len;
        } else {
            return error.MissingPrefixPath;
        }
    } else if (std.mem.eql(u8, arg, "--zig-lib-dir")) {
        // Override zig lib directory (user-facing flag for release workflows).
        // This user-level --zig-lib-dir is distinct from argv[2] which is the
        // positional zig_lib_dir passed by the compiler. The user-level flag
        // allows release workflows to override it (R17).
        // Stored in the option map under "zig-lib-dir" — populateContext reads
        // it and overrides the positional value when present.
        if (args_it.next() catch return error.DecodeError) |value| {
            if (value.len > PATH_BUF_SIZE) return error.PathTooLong;
            config.options.put("zig-lib-dir", value) catch {};
        } else {
            return error.MissingZigLibDir;
        }
    } else if (std.mem.eql(u8, arg, "--search-prefix")) {
        // Additional search prefix for LLVM discovery, headers, etc.
        if (args_it.next() catch return error.DecodeError) |value| {
            if (value.len > PATH_BUF_SIZE) return error.PathTooLong;
            // Store as a known -D option so discovery steps can read it.
            config.options.put("search-prefix", value) catch {};
        } else {
            return error.MissingSearchPrefix;
        }
    } else if (std.mem.eql(u8, arg, "--cache-dir")) {
        // Override local cache directory.
        if (args_it.next() catch return error.DecodeError) |value| {
            if (value.len > PATH_BUF_SIZE) return error.PathTooLong;
            config.options.put("cache-dir", value) catch {};
        } else {
            return error.MissingCacheDir;
        }
    } else if (std.mem.eql(u8, arg, "--verbose")) {
        config.verbose = true;
    } else if (std.mem.eql(u8, arg, "--benchmark")) {
        config.benchmark = true;
    } else if (std.mem.eql(u8, arg, "--self-test") or std.mem.startsWith(u8, arg, "--self-test=")) {
        config.self_test = true;
        if (sig_build.parseLongOptionValue(arg)) |value| {
            if (value.len > PATH_BUF_SIZE) return error.PathTooLong;
            @memcpy(config.self_test_compiler[0..value.len], value);
            config.self_test_compiler_len = value.len;
        }
    } else if (std.mem.eql(u8, arg, "--maxrss")) {
        // --maxrss: skip the value (zig compat, ignored).
        _ = args_it.next() catch {};
    } else {
        return error.UnknownOption;
    }
}

/// Populate a Build_Context from parsed Runner_Args + Cli_Config.
///
/// This bridges the CLI parse results into the Build_Context that gets
/// passed to build.sig. Handles:
///   - Compiler path, zig lib dir from Runner_Args
///   - Build root, cache dir from Runner_Args
///   - Install prefix (--prefix override or default: build_root/sig-out)
///   - Target triple and optimize level from -D options
///   - Option map transfer
///   - --zig-lib-dir override (from user args, takes precedence over argv[2])
///
/// The io parameter is needed for fatal error reporting during path construction.
pub fn populateContext(ctx: *sig_build.Build_Context, result: *const Parse_Result, io: std.Io) void {
    const runner_args = &result.runner_args;
    const config = &result.config;

    // Build root
    const build_root = runner_args.build_root[0..runner_args.build_root_len];
    @memcpy(ctx.build_root[0..build_root.len], build_root);
    ctx.build_root_len = build_root.len;

    // Cache dir
    const cache_dir = runner_args.local_cache_dir[0..runner_args.local_cache_dir_len];
    @memcpy(ctx.cache_dir[0..cache_dir.len], cache_dir);
    ctx.cache_dir_len = cache_dir.len;

    // Compiler path
    const cp = runner_args.compiler_path[0..runner_args.compiler_path_len];
    @memcpy(ctx.compiler_path[0..cp.len], cp);
    ctx.compiler_path_len = cp.len;

    // Zig lib dir: user --zig-lib-dir override takes precedence over argv[2]
    if (sig_build.getOption([]const u8, &config.options, "zig-lib-dir")) |override| {
        @memcpy(ctx.zig_lib_dir[0..override.len], override);
        ctx.zig_lib_dir_len = override.len;
    } else {
        const ld = runner_args.zig_lib_dir[0..runner_args.zig_lib_dir_len];
        @memcpy(ctx.zig_lib_dir[0..ld.len], ld);
        ctx.zig_lib_dir_len = ld.len;
    }

    // Install prefix: --prefix override or build_root/sig-out
    if (config.install_prefix_len > 0) {
        @memcpy(ctx.install_prefix[0..config.install_prefix_len], config.install_prefix[0..config.install_prefix_len]);
        ctx.install_prefix_len = config.install_prefix_len;
    } else {
        var prefix_buf: [PATH_BUF_SIZE]u8 = undefined;
        const prefix_segs = [_][]const u8{ build_root, "sig-out" };
        const prefix = sig.fs.joinPath(&prefix_buf, &prefix_segs) catch {
            sig_build.fatal(io, "failed to construct install prefix path", .{});
        };
        @memcpy(ctx.install_prefix[0..prefix.len], prefix);
        ctx.install_prefix_len = prefix.len;
    }

    // Options map
    ctx.options = config.options;

    // I/O context
    ctx.io_ctx = io;

    // Target triple from -Dtarget=
    if (sig_build.getOption([]const u8, &ctx.options, "target")) |triple_str| {
        ctx.target = sig_build.Target_Triple.parse(triple_str) catch {
            sig_build.fatal(io, "invalid target triple: '{s}'", .{triple_str});
        };
    }

    // Optimize level from -Doptimize=
    if (sig_build.getOption(sig_build.Optimize_Mode, &ctx.options, "optimize")) |mode| {
        ctx.optimize = mode;
    }
}
