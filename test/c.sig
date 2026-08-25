const builtin = @import("builtin");
const std = @import("std");
const c = std.c;

test {
    _ = @import("c/inttypes.sig");
    _ = @import("c/math.sig");
    _ = @import("c/pthread.sig");
    _ = @import("c/search.sig");
    _ = @import("c/stdlib.sig");
    _ = @import("c/string.sig");
    _ = @import("c/strings.sig");
    _ = @import("c/unistd.sig");
    _ = @import("c/wchar.sig");
}

pub fn expectErrno(expected_errno: c.E) !void {
    try std.testing.expectEqual(expected_errno, @as(c.E, @fromBackingInt(@intCast(c._errno().*))));
    c._errno().* = @backingInt(c.E.SUCCESS);
}

pub fn expectErrnoAny(expected_errnos: []const c.E) !void {
    const errno = c._errno().*;
    for (expected_errnos) |expected_errno| {
        if (errno == @backingInt(expected_errno)) break;
    } else {
        var buffer: [64]u8 = undefined;
        const stderr = std.debug.lockStderr(&buffer);
        defer std.debug.unlockStderr();
        try stderr.file_writer.interface.print("expected one of {t}", .{expected_errnos[0]});
        for (expected_errnos[1..]) |expected_errno| {
            try stderr.file_writer.interface.print(", {t}", .{expected_errno});
        }
        try stderr.file_writer.interface.print(", found {t}\n", .{@as(c.E, @fromBackingInt(@intCast(errno)))});
        return error.TestExpectedEqual;
    }
    c._errno().* = @backingInt(c.E.SUCCESS);
}
