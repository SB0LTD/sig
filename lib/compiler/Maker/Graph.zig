//! Shared maker state among all steps.
const Graph = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Configuration = std.Build.Configuration;

io: Io,
/// Process lifetime.
arena: Allocator,
cache: std.Build.Cache,
zig_exe: []const u8,
environ_map: std.process.Environ.Map,
global_cache_root: std.Build.Cache.Directory,
local_cache_root: std.Build.Cache.Directory,
zig_lib_directory: std.Build.Cache.Directory,
build_root_directory: std.Build.Cache.Directory,
pkg_root: std.Build.Cache.Path,

debug_compiler_runtime_libs: ?std.builtin.OptimizeMode = null,
incremental: ?bool = null,
random_seed: u32 = 0,
allow_so_scripts: ?bool = null,
time_report: bool = false,
/// Similar to the `Io.Terminal.Mode` returned by `Io.lockStderr`, but also
/// respects the '--color' flag.
stderr_mode: ?Io.Terminal.Mode = null,
reference_trace: ?u32 = null,
debug_log_scopes: std.ArrayList([]const u8) = .empty,
debug_compile_errors: bool = false,
debug_incremental: bool = false,
verbose: bool = false,
verbose_air: bool = false,
verbose_cc: bool = false,
verbose_link: bool = false,
verbose_llvm_cpu_features: bool = false,
verbose_llvm_ir: bool = false,
libc_file: ?[]const u8 = null,
/// What does this do? Nobody bothered to document it, and I think it's a
/// smelly option. So unless somebody deletes these passive aggressive comments
/// and replaces them with actual documentation, I'm going to delete this
/// option from the build system in a future release. In other words, this is
/// deprecated due to lack of test coverage, lack of documentation, and a hunch
/// that it's a bad option that should be avoided.
sysroot: ?[]const u8 = null,
search_prefixes: std.ArrayList([]const u8) = .empty,
build_id: ?std.zig.BuildId = null,
error_limit: ?u32 = null,

/// Intention of verbose is to print all sub-process command lines to stderr
/// before spawning them.
pub fn handleVerbose(
    graph: *const Graph,
    cwd: std.process.Child.Cwd,
    opt_env: ?*const std.process.Environ.Map,
    argv: []const []const u8,
) error{OutOfMemory}!void {
    if (!graph.verbose) return;
    const arena = graph.arena;
    const text = try std.zig.allocPrintCmd(arena, cwd, if (opt_env) |env| .{
        .child = env,
        .parent = &graph.environ_map,
    } else null, argv);
    defer arena.free(text);
    std.log.scoped(.verbose).info("{s}", .{text});
}
