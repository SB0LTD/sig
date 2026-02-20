const ScannedConfig = @This();

const std = @import("std");
const Configuration = std.Build.Configuration;
const Writer = std.Io.Writer;

const Graph = @import("Graph.zig");

configuration: Configuration,
top_level_steps: std.StringArrayHashMapUnmanaged(Configuration.Step.Index),

pub fn print(sc: *const ScannedConfig, w: *Writer) Writer.Error!void {
    const c = &sc.configuration;
    var serializer: std.zon.Serializer = .{ .writer = w };
    var s = try serializer.beginStruct(.{});

    try s.field("default_step", @intFromEnum(c.default_step), .{});
    {
        var ss = try s.beginStructField("top_level_steps", .{});
        for (sc.top_level_steps.keys(), sc.top_level_steps.values()) |name, step| {
            try ss.field(name, @intFromEnum(step), .{});
        }
        try ss.end();
    }

    try s.end();
}

pub fn printSteps(sc: *const ScannedConfig, graph: *Graph, w: *Writer) !void {
    const arena = graph.arena;
    const c = &sc.configuration;
    for (sc.top_level_steps.keys(), sc.top_level_steps.values()) |name, step_index| {
        const step = step_index.ptr(c);
        const decorated_name = if (step_index == c.default_step)
            try std.fmt.allocPrint(arena, "{s} (default)", .{name})
        else
            name;
        const top_level = c.extraData(Configuration.Step.TopLevel, step.extra_index);
        const description = top_level.description.slice(c);
        try w.print("  {s:<28} {s}\n", .{ decorated_name, description });
    }
}

pub fn printUsage(sc: *const ScannedConfig, graph: *Graph, w: *Writer) !void {
    const arena = graph.arena;

    try w.print(
        \\Usage: {s} build [steps] [options]
        \\
        \\Steps:
        \\
    , .{graph.zig_exe});
    try printSteps(sc, graph, w);
    try w.writeAll(
        \\
        \\Project-Specific Options:
        \\
    );

    const available_options = sc.configuration.available_options;
    if (available_options.len == 0) {
        try w.print("  (none)\n", .{});
    } else {
        for (available_options) |option| {
            const name = option.name.slice(&sc.configuration);
            const description = option.description.slice(&sc.configuration);
            const help = try std.fmt.allocPrint(arena, "  -D{s}=[{t}]", .{ name, option.type });
            try w.print("{s:<30} {s}\n", .{ help, description });
            if (option.enum_options.slice(&sc.configuration)) |enum_options| {
                const padding: [33]u8 = @splat(' ');
                try w.writeAll(padding ++ "Supported Values:\n");
                for (enum_options) |enum_option_index| {
                    const enum_option = enum_option_index.slice(&sc.configuration);
                    try w.print(padding ++ "  {s}\n", .{enum_option});
                }
            }
        }
    }

    try w.writeAll(
        \\
        \\System Integration Options:
        \\  --search-prefix [path]       Add a path to look for binaries, libraries, headers
        \\  --sysroot [path]             Set the system root directory (usually /)
        \\  --libc [file]                Provide a file which specifies libc paths
        \\
        \\  --system [pkgdir]            Disable package fetching; enable all integrations
        \\  -fsys=[name]                 Enable a system integration
        \\  -fno-sys=[name]              Disable a system integration
        \\
        \\  -fdarling,  -fno-darling     Integration with system-installed Darling to
        \\                               execute macOS programs on Linux hosts
        \\                               (default: no)
        \\  -fqemu,     -fno-qemu        Integration with system-installed QEMU to execute
        \\                               foreign-architecture programs on Linux hosts
        \\                               (default: no)
        \\  --libc-runtimes [path]       Enhances QEMU integration by providing dynamic libc
        \\                               (e.g. glibc or musl) built for multiple foreign
        \\                               architectures, allowing execution of non-native
        \\                               programs that link with libc.
        \\  -frosetta,  -fno-rosetta     Rely on Rosetta to execute x86_64 programs on
        \\                               ARM64 macOS hosts. (default: no)
        \\  -fwasmtime, -fno-wasmtime    Integration with system-installed wasmtime to
        \\                               execute WASI binaries. (default: no)
        \\  -fwine,     -fno-wine        Integration with system-installed Wine to execute
        \\                               Windows programs on Linux hosts. (default: no)
        \\
        \\  Available System Integrations:                Enabled:
        \\
    );
    if (sc.configuration.system_integrations.len == 0) {
        try w.writeAll("  (none)                                        -\n");
    } else {
        for (sc.configuration.system_integrations) |system_integration| {
            const name = system_integration.name.slice(&sc.configuration);
            const status = switch (system_integration.status) {
                .disabled => "no",
                .enabled => "yes",
            };
            try w.print("    {s:<43} {s}\n", .{ name, status });
        }
    }

    try w.writeAll(
        \\
        \\General Options:
        \\  -h, --help                   Print this help to stdout and exit
        \\  -l, --list-steps             Print available steps to stdout and exit
        \\
        \\  -p, --prefix [path]          Where to install files (default: zig-out)
        \\  --prefix-lib-dir [path]      Where to install libraries
        \\  --prefix-exe-dir [path]      Where to install executables
        \\  --prefix-include-dir [path]  Where to install C header files
        \\  --release[=mode]             Request release mode, optionally specifying a
        \\                               preferred optimization mode: fast, safe, small
        \\
        \\  --verbose                    Print commands before executing them
        \\  --color [auto|off|on]        Enable or disable colored error messages
        \\  --error-style [style]        Control how build errors are printed
        \\    verbose                    (Default) Report errors with full context
        \\    minimal                    Report errors after summary, excluding context like command lines
        \\    verbose_clear              Like 'verbose', but clear the terminal at the start of each update
        \\    minimal_clear              Like 'minimal', but clear the terminal at the start of each update
        \\  --multiline-errors [style]   Control how multi-line error messages are printed
        \\    indent                     (Default) Indent non-initial lines to align with initial line
        \\    newline                    Include a leading newline so that the error message is on its own lines
        \\    none                       Print as usual so the first line is misaligned
        \\  --summary [mode]             Control the printing of the build summary
        \\    all                        Print the build summary in its entirety
        \\    new                        Omit cached steps
        \\    failures                   (Default if short-lived) Only print failed steps
        \\    line                       (Default if long-lived) Only print the single-line summary
        \\    none                       Do not print the build summary
        \\  -j<N>                        Limit concurrent jobs (default is to use all CPU cores)
        \\  --maxrss <bytes>             Limit memory usage (default is to use available memory)
        \\  --skip-oom-steps             Instead of failing, skip steps that would exceed --maxrss
        \\  --test-timeout <timeout>     Limit execution time of unit tests, terminating if exceeded.
        \\                               The timeout must include a unit: ns, us, ms, s, m, h
        \\  --watch                      Continuously rebuild when source files are modified
        \\  --debounce <ms>              Delay before rebuilding after changed file detected
        \\  --webui[=ip]                 Enable the web interface on the given IP address
        \\  --fuzz[=limit]               Continuously search for unit test failures with an optional 
        \\                               limit to the max number of iterations. The argument supports
        \\                               an optional 'K', 'M', or 'G' suffix (e.g. '10K'). Implies
        \\                               '--webui' when no limit is specified.
        \\  --time-report                Force full rebuild and provide detailed information on
        \\                               compilation time of Zig source code (implies '--webui')
        \\     -fincremental             Enable incremental compilation
        \\  -fno-incremental             Disable incremental compilation
        \\
        \\Package Management Options:
        \\  --fetch[=mode]               Fetch dependency tree (optionally choose laziness) and exit
        \\    needed                     (Default) Lazy dependencies are fetched as needed
        \\    all                        Lazy dependencies are always fetched
        \\  --fork=[path]                Override one or more projects from dependency tree
        \\
        \\Advanced Options:
        \\  -freference-trace[=num]      How many lines of reference trace should be shown per compile error
        \\  -fno-reference-trace         Disable reference trace
        \\  -fallow-so-scripts           Allows .so files to be GNU ld scripts
        \\  -fno-allow-so-scripts        (default) .so files must be ELF files
        \\  --error-limit [num]          Set the maximum amount of distinct error values
        \\  --build-file [file]          Override path to build.zig
        \\  --cache-dir [path]           Override path to local Zig cache directory
        \\  --global-cache-dir [path]    Override path to global Zig cache directory
        \\  --zig-lib-dir [arg]          Override path to Zig lib directory
        \\  --build-runner [file]        Override path to build runner
        \\  --seed [integer]             For shuffling dependency traversal order (default: random)
        \\  --build-id[=style]           At a minor link-time expense, embeds a build ID in binaries
        \\      fast                     8-byte non-cryptographic hash (COFF, ELF, WASM)
        \\      sha1, tree               20-byte cryptographic hash (ELF, WASM)
        \\      md5                      16-byte cryptographic hash (ELF)
        \\      uuid                     16-byte random UUID (ELF, WASM)
        \\      0x[hexstring]            Constant ID, maximum 32 bytes (ELF, WASM)
        \\      none                     (default) No build ID
        \\  --debug-log [scope]          Enable debugging the compiler
        \\  --debug-pkg-config           Fail if unknown pkg-config flags encountered
        \\  --debug-rt                   Debug compiler runtime libraries
        \\  --verbose-link               Enable compiler debug output for linking
        \\  --verbose-air                Enable compiler debug output for Zig AIR
        \\  --verbose-llvm-ir            Enable compiler debug output for LLVM IR
        \\  --verbose-cimport            Enable compiler debug output for C imports
        \\  --verbose-cc                 Enable compiler debug output for C compilation
        \\  --verbose-llvm-cpu-features  Enable compiler debug output for LLVM CPU features
        \\
    );
}
