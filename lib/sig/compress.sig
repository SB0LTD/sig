//! Capacity-first streaming compression and decompression.
//!
//! All operations use caller-provided buffers. No allocator parameters.
//! Zero std dependency — calls system zlib (libz) and zstd (libzstd) C APIs directly.
//!
//! Supported formats:
//! - deflate: raw deflate (compress + decompress)
//! - gzip: gzip-wrapped deflate (compress + decompress)
//! - zstd: Zstandard (decompress only)

const SigError = @import("errors.sig").SigError;

pub const Format = enum { deflate, gzip, zstd };

// ══════════════════════════════════════════════════════════════════════════════
// zlib C API
// ══════════════════════════════════════════════════════════════════════════════

const z_stream = extern struct {
    next_in: ?[*]const u8 = null,
    avail_in: c_uint = 0,
    total_in: c_ulong = 0,
    next_out: ?[*]u8 = null,
    avail_out: c_uint = 0,
    total_out: c_ulong = 0,
    msg: ?[*:0]const u8 = null,
    internal_state: ?*anyopaque = null,
    zalloc: ?*const anyopaque = null,
    zfree: ?*const anyopaque = null,
    @"opaque": ?*anyopaque = null,
    data_type: c_int = 0,
    adler: c_ulong = 0,
    reserved: c_ulong = 0,
};

const Z_OK: c_int = 0;
const Z_STREAM_END: c_int = 1;
const Z_NO_FLUSH: c_int = 0;
const Z_FINISH: c_int = 4;
const Z_DEFAULT_COMPRESSION: c_int = -1;
const Z_DEFLATED: c_int = 8;
const Z_DEFAULT_STRATEGY: c_int = 0;
const ZLIB_VERSION: [*:0]const u8 = "1.3.1";

// windowBits: -15 = raw deflate, 15+16 = gzip
const WINDOW_RAW_DEFLATE: c_int = -15;
const WINDOW_GZIP: c_int = 15 + 16;

extern "c" fn inflateInit2_(strm: *z_stream, windowBits: c_int, version: [*:0]const u8, stream_size: c_int) callconv(.c) c_int;
extern "c" fn inflate(strm: *z_stream, flush: c_int) callconv(.c) c_int;
extern "c" fn inflateEnd(strm: *z_stream) callconv(.c) c_int;
extern "c" fn deflateInit2_(strm: *z_stream, level: c_int, method: c_int, windowBits: c_int, memLevel: c_int, strategy: c_int, version: [*:0]const u8, stream_size: c_int) callconv(.c) c_int;
extern "c" fn deflate(strm: *z_stream, flush: c_int) callconv(.c) c_int;
extern "c" fn deflateEnd(strm: *z_stream) callconv(.c) c_int;

// ══════════════════════════════════════════════════════════════════════════════
// zstd C API
// ══════════════════════════════════════════════════════════════════════════════

extern "c" fn ZSTD_decompress(dst: [*]u8, dstCapacity: usize, src: [*]const u8, compressedSize: usize) callconv(.c) usize;
extern "c" fn ZSTD_isError(code: usize) callconv(.c) c_uint;

// ══════════════════════════════════════════════════════════════════════════════
// Public API — Streaming Types
// ══════════════════════════════════════════════════════════════════════════════

/// Streaming decompressor. Reads compressed input and writes decompressed
/// output into caller-provided buffers.
pub fn Decompressor(comptime format: Format) type {
    return struct {
        finished: bool = false,

        const Self = @This();

        /// Feed compressed input and write decompressed output into `output`.
        /// Returns the slice of decompressed bytes written.
        /// Returns `BufferTooSmall` if the output buffer cannot hold the result.
        pub fn feed(self: *Self, input: []const u8, output: []u8) SigError![]u8 {
            _ = self;
            return decompressImpl(format, input, output);
        }

        /// Signal end of input. No-op for single-shot usage.
        pub fn finish(self: *Self, output: []u8) SigError![]u8 {
            self.finished = true;
            return output[0..0];
        }
    };
}

/// Streaming compressor (deflate and gzip only).
pub fn Compressor(comptime format: Format) type {
    if (format == .zstd) @compileError("zstd compression not available");
    return struct {
        finished: bool = false,

        const Self = @This();

        /// Feed uncompressed input and write compressed output into `output`.
        pub fn feed(self: *Self, input: []const u8, output: []u8) SigError![]u8 {
            _ = self;
            return compressImpl(format, input, output);
        }

        /// Signal end of input. No-op for single-shot usage.
        pub fn finish(self: *Self, output: []u8) SigError![]u8 {
            self.finished = true;
            return output[0..0];
        }
    };
}

// ══════════════════════════════════════════════════════════════════════════════
// Public API — One-shot functions
// ══════════════════════════════════════════════════════════════════════════════

/// One-shot decompress: decompress `input` into `output`.
pub fn decompress(comptime format: Format, input: []const u8, output: []u8) SigError![]u8 {
    return decompressImpl(format, input, output);
}

/// One-shot compress: compress `input` into `output` (deflate/gzip only).
pub fn compress(comptime format: Format, input: []const u8, output: []u8) SigError![]u8 {
    return compressImpl(format, input, output);
}

// ══════════════════════════════════════════════════════════════════════════════
// Internal — zlib inflate/deflate
// ══════════════════════════════════════════════════════════════════════════════

fn windowBitsForFormat(comptime format: Format) c_int {
    return switch (format) {
        .deflate => WINDOW_RAW_DEFLATE,
        .gzip => WINDOW_GZIP,
        .zstd => unreachable,
    };
}

fn decompressImpl(comptime format: Format, input: []const u8, output: []u8) SigError![]u8 {
    switch (format) {
        .deflate, .gzip => return decompressZlib(windowBitsForFormat(format), input, output),
        .zstd => return decompressZstd(input, output),
    }
}

fn compressImpl(comptime format: Format, input: []const u8, output: []u8) SigError![]u8 {
    if (format == .zstd) @compileError("zstd compression not available");
    return compressZlib(windowBitsForFormat(format), input, output);
}

fn decompressZlib(windowBits: c_int, input: []const u8, output: []u8) SigError![]u8 {
    var strm: z_stream = .{};
    strm.next_in = input.ptr;
    strm.avail_in = truncateToUint(input.len);
    strm.next_out = output.ptr;
    strm.avail_out = truncateToUint(output.len);

    var ret = inflateInit2_(&strm, windowBits, ZLIB_VERSION, @sizeOf(z_stream));
    if (ret != Z_OK) return error.BufferTooSmall;

    ret = inflate(&strm, Z_NO_FLUSH);
    _ = inflateEnd(&strm);

    if (ret != Z_OK and ret != Z_STREAM_END) return error.BufferTooSmall;

    // If stream didn't finish, keep feeding until done or out of space.
    if (ret == Z_OK) {
        // Partial decompression — output full or needs more input.
        // For single-shot, treat unfinished as buffer too small.
        if (strm.avail_out == 0 and strm.avail_in > 0) return error.BufferTooSmall;
    }

    const written: usize = @intCast(strm.total_out);
    return output[0..written];
}

fn compressZlib(windowBits: c_int, input: []const u8, output: []u8) SigError![]u8 {
    var strm: z_stream = .{};
    strm.next_in = input.ptr;
    strm.avail_in = truncateToUint(input.len);
    strm.next_out = output.ptr;
    strm.avail_out = truncateToUint(output.len);

    var ret = deflateInit2_(
        &strm,
        Z_DEFAULT_COMPRESSION,
        Z_DEFLATED,
        windowBits,
        8, // memLevel
        Z_DEFAULT_STRATEGY,
        ZLIB_VERSION,
        @sizeOf(z_stream),
    );
    if (ret != Z_OK) return error.BufferTooSmall;

    ret = deflate(&strm, Z_FINISH);
    _ = deflateEnd(&strm);

    if (ret != Z_STREAM_END) return error.BufferTooSmall;

    const written: usize = @intCast(strm.total_out);
    return output[0..written];
}

// ══════════════════════════════════════════════════════════════════════════════
// Internal — zstd decompression
// ══════════════════════════════════════════════════════════════════════════════

fn decompressZstd(input: []const u8, output: []u8) SigError![]u8 {
    const result = ZSTD_decompress(output.ptr, output.len, input.ptr, input.len);
    if (ZSTD_isError(result) != 0) return error.BufferTooSmall;
    return output[0..result];
}

// ══════════════════════════════════════════════════════════════════════════════
// Utility
// ══════════════════════════════════════════════════════════════════════════════

/// Truncate usize to c_uint, capping at max value.
fn truncateToUint(len: usize) c_uint {
    const max: usize = @as(usize, @intCast(@as(c_uint, @truncate(@as(u64, 0xFFFFFFFF)))));
    if (len > max) return @intCast(max);
    return @intCast(len);
}
