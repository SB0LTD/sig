//! Shared maker state among all steps.
const Graph = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Configuration = std.Build.Configuration;

const Step = @import("Step.zig");
const Package = @import("Package.zig");

io: Io,
/// Process lifetime.
arena: Allocator,
system_library_options: std.StringArrayHashMapUnmanaged(std.Build.SystemLibraryMode),
system_package_mode: bool,
debug_compiler_runtime_libs: ?std.builtin.OptimizeMode = null,
cache: std.Build.Cache,
zig_exe: [:0]const u8,
environ_map: std.process.Environ.Map,
global_cache_root: std.Build.Cache.Directory,
zig_lib_directory: std.Build.Cache.Directory,
incremental: ?bool,
random_seed: u32,
allow_so_scripts: ?bool,
time_report: bool,
/// Similar to the `Io.Terminal.Mode` returned by `Io.lockStderr`, but also
/// respects the '--color' flag.
stderr_mode: ?Io.Terminal.Mode,

configuration: *const Configuration,
top_level_steps: std.AutoArrayHashMapUnmanaged(Configuration.String, Configuration.Step.Index),

pub const DirList = struct {
    lib_dir: ?[]const u8 = null,
    exe_dir: ?[]const u8 = null,
    include_dir: ?[]const u8 = null,
};

/// This function is intended to be called by lib/build_runner.zig, not a build.zig file.
pub fn resolveInstallPrefix(graph: *Graph, p: *Package, install_prefix: ?[]const u8, dir_list: DirList) !void {
    if (p.dest_dir) |dest_dir| {
        p.install_prefix = install_prefix orelse "/usr";
        p.install_path = b.pathJoin(&.{ dest_dir, p.install_prefix });
    } else {
        p.install_prefix = install_prefix orelse
            (p.build_root.join(b.allocator, &.{"zig-out"}) catch @panic("unhandled error"));
        b.install_path = b.install_prefix;
    }

    var lib_list = [_][]const u8{ b.install_path, "lib" };
    var exe_list = [_][]const u8{ b.install_path, "bin" };
    var h_list = [_][]const u8{ b.install_path, "include" };

    if (dir_list.lib_dir) |dir| {
        if (fs.path.isAbsolute(dir)) lib_list[0] = b.dest_dir orelse "";
        lib_list[1] = dir;
    }

    if (dir_list.exe_dir) |dir| {
        if (fs.path.isAbsolute(dir)) exe_list[0] = b.dest_dir orelse "";
        exe_list[1] = dir;
    }

    if (dir_list.include_dir) |dir| {
        if (fs.path.isAbsolute(dir)) h_list[0] = b.dest_dir orelse "";
        h_list[1] = dir;
    }

    b.lib_dir = b.pathJoin(&lib_list);
    b.exe_dir = b.pathJoin(&exe_list);
    b.h_dir = b.pathJoin(&h_list);
}

fn determineAndApplyInstallPrefix(b: *Build) error{OutOfMemory}!void {
    // Create an installation directory local to this package. This will be used when
    // dependant packages require a standard prefix, such as include directories for C headers.
    var hash = b.graph.cache.hash;
    // Random bytes to make unique. Refresh this with new random bytes when
    // implementation is modified in a non-backwards-compatible way.
    hash.add(@as(u32, 0xd8cb0056));
    hash.addBytes(b.dep_prefix);

    var wyhash = std.hash.Wyhash.init(0);
    hashUserInputOptionsMap(b.allocator, b.user_input_options, &wyhash);
    hash.add(wyhash.final());

    const digest = hash.final();
    const install_prefix = try b.cache_root.join(b.allocator, &.{ "i", &digest });
    b.resolveInstallPrefix(install_prefix, .{});
}

