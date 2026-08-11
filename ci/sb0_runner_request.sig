//! Allocator-free request generator for the SB0 native compiler service.

const std = @import("std");
const linux = std.os.linux;

const MAX_SOURCE_BYTES: usize = 64 * 1024;
var source: [MAX_SOURCE_BYTES]u8 = undefined;

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next() orelse return error.MissingProgramName;
    const source_path = args.next() orelse return error.MissingSourcePath;
    if (args.next() != null) return error.UnexpectedArgument;

    const source_fd = try openRead(source_path);
    defer close(source_fd);
    const source_len = try readBounded(source_fd, source[0..]);
    if (source_len == 0) return error.EmptySource;

    var header: [10]u8 = .{ 'S', 'B', '0', 'C', 1, 0, 0, 0, 0, 0 };
    writeU32Le(header[6..10], source_len);
    try writeAll(linux.STDOUT_FILENO, header[0..]);
    try writeAll(linux.STDOUT_FILENO, source[0..source_len]);
}

fn openRead(path: [:0]const u8) !linux.fd_t {
    const result = linux.open(path.ptr, .{ .CLOEXEC = true }, 0);
    if (linux.errno(result) != .SUCCESS) return error.OpenSourceFailed;
    return @intCast(result);
}

fn close(fd: linux.fd_t) void {
    _ = linux.close(fd);
}

fn readBounded(fd: linux.fd_t, destination: []u8) !usize {
    var received: usize = 0;
    while (received < destination.len) {
        const result = linux.read(fd, destination[received..].ptr, destination.len - received);
        if (linux.errno(result) != .SUCCESS) return error.ReadSourceFailed;
        if (result == 0) return received;
        received += result;
    }

    var extra: [1]u8 = undefined;
    const result = linux.read(fd, extra[0..].ptr, 1);
    if (linux.errno(result) != .SUCCESS) return error.ReadSourceFailed;
    if (result != 0) return error.SourceTooLarge;
    return received;
}

fn writeAll(fd: linux.fd_t, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const result = linux.write(fd, bytes[sent..].ptr, bytes.len - sent);
        if (linux.errno(result) != .SUCCESS) return error.WriteFailed;
        if (result == 0) return error.OutputClosed;
        sent += result;
    }
}

fn writeU32Le(bytes: []u8, value: usize) void {
    const narrowed: u32 = @intCast(value);
    bytes[0] = @truncate(narrowed);
    bytes[1] = @truncate(narrowed >> 8);
    bytes[2] = @truncate(narrowed >> 16);
    bytes[3] = @truncate(narrowed >> 24);
}
