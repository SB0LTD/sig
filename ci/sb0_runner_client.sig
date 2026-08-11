//! Allocator-free response validator/extractor for the SB0 native compiler.

const std = @import("std");
const linux = std.os.linux;

const MAX_OUTPUT_BYTES: usize = 64 * 1024;
var output: [MAX_OUTPUT_BYTES]u8 = undefined;

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next() orelse return error.MissingProgramName;
    const output_path = args.next() orelse return error.MissingOutputPath;
    if (args.next() != null) return error.UnexpectedArgument;

    var response: [16]u8 = undefined;
    try readExact(linux.STDIN_FILENO, response[0..]);
    if (!equal(response[0..4], "SB0R")) return error.InvalidRunnerResponseMagic;
    if (readU16Le(response[4..6]) != 1) return error.InvalidRunnerResponseVersion;
    if (readU16Le(response[6..8]) != 0) return error.NativeCompilationFailed;
    const output_len_u32 = readU32Le(response[8..12]);
    if (readU32Le(response[12..16]) != 0) return error.NativeCompilationFailed;
    if (output_len_u32 < 4 or output_len_u32 > MAX_OUTPUT_BYTES) return error.InvalidRunnerOutputSize;
    const output_len: usize = @intCast(output_len_u32);
    try readExact(linux.STDIN_FILENO, output[0..output_len]);
    if (!equal(output[0..4], "SB0X")) return error.ForeignRunnerOutput;

    const output_fd = try openOutput(output_path);
    defer close(output_fd);
    try writeAll(output_fd, output[0..output_len]);
}

fn openOutput(path: [:0]const u8) !linux.fd_t {
    const result = linux.open(path.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    }, 0o644);
    if (linux.errno(result) != .SUCCESS) return error.OpenOutputFailed;
    return @intCast(result);
}

fn close(fd: linux.fd_t) void {
    _ = linux.close(fd);
}

fn readExact(fd: linux.fd_t, destination: []u8) !void {
    var received: usize = 0;
    while (received < destination.len) {
        const result = linux.read(fd, destination[received..].ptr, destination.len - received);
        if (linux.errno(result) != .SUCCESS) return error.ReadFailed;
        if (result == 0) return error.InputClosed;
        received += result;
    }
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

fn readU16Le(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn readU32Le(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (left != right) return false;
    return true;
}
