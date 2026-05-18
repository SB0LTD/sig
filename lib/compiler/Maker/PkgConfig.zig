const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const assert = std.debug.assert;

const Maker = @import("../Maker.zig");
const Step = @import("Step.zig");
const Graph = @import("Graph.zig");

pub const Pkg = struct {
    name: []const u8,
    desc: []const u8,
};

mutex: Io.Mutex = .init,
list: ?[]const Pkg = null,
debug: bool = false,

pub const RunError = error{
    PackageNotFound,
    PkgConfigUnavailable,
} || Step.ExtendedMakeError;

pub const Result = struct {
    cflags: []const []const u8,
    libs: []const []const u8,
};

/// Run pkg-config for the given library name and parse the output, returning the arguments
/// that should be passed to zig to link the given library.
pub fn run(
    maker: *Maker,
    step: *Step,
    progress_node: std.Progress.Node,
    lib_name: []const u8,
    /// If true, reports failure error messages on step rather than returning
    /// error.PackageNotFound or error.PkgConfigInvalidOutput,
    force: bool,
) RunError!Result {
    const pc = &maker.pkg_config;
    const graph = maker.graph;
    const arena = graph.arena; // TODO don't leak into process arena

    const pkg_name = match: {
        // First we have to map the library name to pkg config name. Unfortunately,
        // there are several examples where this is not straightforward:
        // -lSDL2 -> pkg-config sdl2
        // -lgdk-3 -> pkg-config gdk-3.0
        // -latk-1.0 -> pkg-config atk
        // -lpulse -> pkg-config libpulse
        const pkgs = try getList(maker, step, progress_node, force);

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

        if (force) return step.fail(maker, "{s}: package not found: {s}", .{
            getExe(graph), lib_name,
        });

        return error.PackageNotFound;
    };

    const pkg_config_exe = getExe(graph);
    const stdout = try captureChildProcess(maker, step, .{
        .argv = &.{ pkg_config_exe, pkg_name, "--cflags", "--libs" },
        .progress_node = progress_node,
        .allow_failure = !force,
    });

    var zig_cflags: std.ArrayList([]const u8) = .empty;
    var zig_libs: std.ArrayList([]const u8) = .empty;
    var arg_it = mem.tokenizeAny(u8, stdout, " \r\n\t");

    while (arg_it.next()) |arg| {
        if (mem.eql(u8, arg, "-I")) {
            const dir = arg_it.next() orelse return missingArg(maker, step, pkg_config_exe, lib_name, arg, force);
            try zig_cflags.appendSlice(arena, &.{ "-I", dir });
        } else if (mem.startsWith(u8, arg, "-I")) {
            try zig_cflags.append(arena, arg);
        } else if (mem.eql(u8, arg, "-L")) {
            const dir = arg_it.next() orelse return missingArg(maker, step, pkg_config_exe, lib_name, arg, force);
            try zig_libs.appendSlice(arena, &.{ "-L", dir });
        } else if (mem.startsWith(u8, arg, "-L")) {
            try zig_libs.append(arena, arg);
        } else if (mem.eql(u8, arg, "-l")) {
            const lib = arg_it.next() orelse return missingArg(maker, step, pkg_config_exe, lib_name, arg, force);
            try zig_libs.appendSlice(arena, &.{ "-l", lib });
        } else if (mem.startsWith(u8, arg, "-l")) {
            try zig_libs.append(arena, arg);
        } else if (mem.eql(u8, arg, "-D")) {
            const macro = arg_it.next() orelse return missingArg(maker, step, pkg_config_exe, lib_name, arg, force);
            try zig_cflags.appendSlice(arena, &.{ "-D", macro });
        } else if (mem.startsWith(u8, arg, "-D")) {
            try zig_cflags.append(arena, arg);
        } else if (mem.cutPrefix(u8, arg, "-Wl,-rpath,")) |rest| {
            try zig_cflags.appendSlice(arena, &.{ "-rpath", rest });
        } else if (force or pc.debug) {
            return step.fail(maker, "{s} package {s} unknown flag: {s}", .{ pkg_config_exe, lib_name, arg });
        }
    }

    try zig_cflags.shrinkToLen(arena);
    try zig_libs.shrinkToLen(arena);

    return .{
        .cflags = zig_cflags.toOwnedSliceAssert(),
        .libs = zig_libs.toOwnedSliceAssert(),
    };
}

fn missingArg(
    maker: *Maker,
    step: *Step,
    pkg_config_exe: []const u8,
    lib_name: []const u8,
    arg: []const u8,
    force: bool,
) RunError {
    if (force) return step.fail(maker, "{s} package {s} missing arg after flag: {s}", .{
        pkg_config_exe, lib_name, arg,
    });
    return error.PkgConfigUnavailable;
}

fn getExe(graph: *const Graph) []const u8 {
    return std.zig.EnvVar.PKG_CONFIG.get(&graph.environ_map) orelse "pkg-config";
}

fn getList(maker: *Maker, step: *Step, progress_node: std.Progress.Node, force: bool) RunError![]const Pkg {
    const graph = maker.graph;
    const arena = graph.arena; // TODO don't leak into process arena
    const io = graph.io;
    const pc = &maker.pkg_config;

    try pc.mutex.lock(io);
    defer pc.mutex.unlock(io);

    if (pc.list) |list| return list;

    const pkg_config_exe = getExe(graph);
    const stdout = try captureChildProcess(maker, step, .{
        .argv = &.{ pkg_config_exe, "--list-all" },
        .progress_node = progress_node,
        .allow_failure = !force,
    });

    var list: std.ArrayList(Pkg) = .empty;
    var line_it = mem.tokenizeAny(u8, stdout, "\r\n");
    while (line_it.next()) |line| {
        if (mem.trim(u8, line, " \t").len == 0) continue;
        var tok_it = mem.tokenizeAny(u8, line, " \t");
        try list.append(arena, .{
            .name = tok_it.next() orelse {
                if (force) return step.fail(maker, "{s}: invalid line: {s}", .{
                    pkg_config_exe, line,
                });
                return error.PkgConfigUnavailable;
            },
            .desc = tok_it.rest(),
        });
    }
    try list.shrinkToLen(arena);

    const result = list.toOwnedSliceAssert();
    pc.list = result;
    return result;
}

fn captureChildProcess(maker: *Maker, step: *Step, options: Step.CaptureChildProcessOptions) ![]const u8 {
    const captured = step.captureChildProcess(maker, options) catch |err| switch (err) {
        error.FileNotFound => return error.PkgConfigUnavailable,
        else => |e| return e,
    };
    assert(step.result_failed_command != null);
    if (captured.term.success()) return captured.stdout;
    if (!options.allow_failure) return step.fail(maker, "{s} {f}", .{ options.argv[0], captured.term });
    return error.PkgConfigUnavailable;
}
