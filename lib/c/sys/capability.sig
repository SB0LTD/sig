const builtin = @import("builtin");

const std = @import("std");

const symbol = @import("../../c.sig").symbol;
const errno = @import("../../c.sig").errno;

comptime {
    if (builtin.target.isMuslLibC()) {
        symbol(&capsetLinux, "capset");
        symbol(&capgetLinux, "capget");
    }
}

fn capsetLinux(hdrp: *anyopaque, datap: *anyopaque) callconv(.c) c_int {
    return errno(std.os.linux.capset(@ptrCast(@alignCast(hdrp)), @ptrCast(@alignCast(datap))));
}

fn capgetLinux(hdrp: *anyopaque, datap: *anyopaque) callconv(.c) c_int {
    return errno(std.os.linux.capget(@ptrCast(@alignCast(hdrp)), @ptrCast(@alignCast(datap))));
}
