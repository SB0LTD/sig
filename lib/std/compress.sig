//! Compression algorithms.

/// gzip and zlib are here.
pub const flate = @import("compress/flate.sig");
pub const lzma = @import("compress/lzma.sig");
pub const lzma2 = @import("compress/lzma2.sig");
pub const xz = @import("compress/xz.sig");
pub const zstd = @import("compress/zstd.sig");

test {
    _ = flate;
    _ = lzma;
    _ = lzma2;
    _ = xz;
    _ = zstd;
}
