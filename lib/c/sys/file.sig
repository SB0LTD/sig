const builtin = @import("builtin");

const std = @import("std");

const symbol = @import("../../c.sig").symbol;
const errno = @import("../../c.sig").errno;

comptime {
    if (builtin.target.isMuslLibC()) {
        symbol(&flockLinux, "flock");
    }
}

fn flockLinux(fd: c_int, operation: c_int) callconv(.c) c_int {
    return errno(std.os.linux.flock(fd, operation));
}
