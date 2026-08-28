const sig_io = @import("io.sig");
const os = @import("os.sig");
const builtin = @import("builtin");
const SigError = @import("errors.sig").SigError;

/// Directory entry for bounded directory listing.
/// Name is stored inline in a fixed buffer — no allocation needed.
pub const DirEntry = os.DirEntry;

/// Read an entire file into a caller-provided buffer.
/// Returns the filled slice, or `BufferTooSmall` if the file exceeds the buffer.
pub fn readFile(io: sig_io.Io, path: []const u8, buf: []u8) SigError![]u8 {
    const cwd: sig_io.Dir = .cwd();
    var file = cwd.openFile(io, path, .{}) catch return error.BufferTooSmall;
    defer file.close(io);

    var reader = file.reader(io, &.{});
    var total: usize = 0;
    while (total < buf.len) {
        const n = reader.interface.readSliceShort(buf[total..]) catch return error.BufferTooSmall;
        if (n == 0) break;
        total += n;
    }

    // If we filled the buffer, probe for more data.
    if (total == buf.len) {
        var probe: [1]u8 = undefined;
        const extra = reader.interface.readSliceShort(&probe) catch 0;
        if (extra != 0) return error.BufferTooSmall;
    }

    return buf[0..total];
}

/// Write a caller-provided slice to a file (creates or truncates).
pub fn writeFile(io: sig_io.Io, path: []const u8, data: []const u8) SigError!void {
    const cwd: sig_io.Dir = .cwd();
    var file = cwd.createFile(io, path, .{}) catch return error.BufferTooSmall;
    defer file.close(io);
    file.writeStreamingAll(io, data) catch return error.BufferTooSmall;
}

/// Copy a file from src_path to dst_path using a fixed-size chunk buffer.
/// Handles files of any size without requiring the whole file in memory.
pub fn copyFile(io: sig_io.Io, src_path: []const u8, dst_path: []const u8) SigError!void {
    const cwd: sig_io.Dir = .cwd();
    var src = cwd.openFile(io, src_path, .{}) catch return error.BufferTooSmall;
    defer src.close(io);
    var dst = cwd.createFile(io, dst_path, .{}) catch return error.BufferTooSmall;
    defer dst.close(io);

    var chunk: [8192]u8 = undefined;
    var reader = src.reader(io, &.{});
    while (true) {
        const n = reader.interface.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        dst.writeStreamingAll(io, chunk[0..n]) catch return error.BufferTooSmall;
    }
}

/// Join path segments into a caller-provided buffer using the platform separator.
/// Returns the joined path slice, or `BufferTooSmall` if the buffer is insufficient.
pub fn joinPath(buf: []u8, segments: []const []const u8) SigError![]u8 {
    const sep = if (builtin.os.tag == .windows) '\\' else '/';
    var offset: usize = 0;
    for (segments, 0..) |seg, i| {
        // Strip trailing separators from segment (except for root "/").
        var s = seg;
        while (s.len > 1 and s[s.len - 1] == sep) {
            s = s[0 .. s.len - 1];
        }

        // Strip leading separators from non-first segments.
        if (i > 0) {
            while (s.len > 0 and s[0] == sep) {
                s = s[1..];
            }
        }

        if (s.len == 0) continue;

        // Add separator between segments.
        if (i > 0 and offset > 0 and buf[offset - 1] != sep) {
            if (offset >= buf.len) return error.BufferTooSmall;
            buf[offset] = sep;
            offset += 1;
        }

        if (offset + s.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[offset..][0..s.len], s);
        offset += s.len;
    }
    return buf[0..offset];
}

/// List directory entries into a caller-provided array of DirEntry.
/// Returns the filled slice, or `BufferTooSmall` if there are more entries than the buffer holds.
pub fn listDir(io: sig_io.Io, path: []const u8, entries: []DirEntry) SigError![]DirEntry {
    _ = io;
    const count = os.listDir(path, entries) orelse return error.BufferTooSmall;
    return entries[0..count];
}
