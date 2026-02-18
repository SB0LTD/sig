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
zig_lib_directory: std.Build.Cache.Directory,

debug_compiler_runtime_libs: ?std.builtin.OptimizeMode = null,
incremental: ?bool = null,
random_seed: u32 = 0,
allow_so_scripts: ?bool = null,
time_report: bool = false,
/// Similar to the `Io.Terminal.Mode` returned by `Io.lockStderr`, but also
/// respects the '--color' flag.
stderr_mode: ?Io.Terminal.Mode = null,
