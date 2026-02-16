const Package = @This();

const std = @import("std");

install_prefix: []const u8,
install_path: []const u8,
dest_dir: ?[]const u8,
lib_dir: []const u8,
exe_dir: []const u8,
h_dir: []const u8,
/// Path to the directory containing build.zig.
build_root: std.Build.Cache.Path,
