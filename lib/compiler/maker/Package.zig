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

fn determineAndApplyInstallPrefix(p: *Package) error{OutOfMemory}!void {
    // Create an installation directory local to this package. This will be used when
    // dependant packages require a standard prefix, such as include directories for C headers.
    var hash = p.graph.cache.hash;
    // Random bytes to make unique. Refresh this with new random bytes when
    // implementation is modified in a non-backwards-compatible way.
    hash.add(@as(u32, 0xd8cb0056));
    hash.addBytes(p.dep_prefix);

    var wyhash = std.hash.Wyhash.init(0);
    hashUserInputOptionsMap(p.allocator, p.user_input_options, &wyhash);
    hash.add(wyhash.final());

    const digest = hash.final();
    const install_prefix = try p.cache_root.join(p.allocator, &.{ "i", &digest });
    p.resolveInstallPrefix(install_prefix, .{});
}
