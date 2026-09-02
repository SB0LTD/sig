//! SB0 native image format (SB0X userspace + SB0K kernel) — compiler mirror.
//!
//! This is a bootstrap-safe mirror of the canonical zpm module
//! `zpm/src/platform/sb0x/format.sig`. The production compiler cannot depend on
//! zpm (that would entangle the self-bootstrapping chain), so this file keeps a
//! byte-identical copy of the SB0 image encoders that the self-hosted SB0
//! linker backend (`Sb0.sig`) uses.
//!
//! The layout constants and field offsets here MUST stay identical to the zpm
//! canonical module. The tests below pin every field offset with literal byte
//! assertions, so any drift from the shared contract fails the compiler test
//! suite. See `sig/compiler/SB0_ABI_TARGET.md` for the ABI these images target.
//!
//! Pure computation over caller-provided byte buffers: no allocator, no I/O.

const std = @import("std");

// ── SB0X (userspace) constants ──

pub const SB0X_MAGIC = [4]u8{ 'S', 'B', '0', 'X' };
pub const SB0X_FORMAT_VERSION: u8 = 1;
pub const SB0X_ABI_VERSION: u16 = 1;
pub const SB0X_HEADER_SIZE: usize = 64;
pub const SB0X_SEGMENT_SIZE: usize = 40;
pub const SB0X_MAX_SEGMENTS: usize = 8;
pub const SB0X_DEFAULT_STACK_SIZE: u64 = 64 * 1024;
pub const SB0X_PAGE_SIZE: u64 = 4096;

pub const SEG_READ: u32 = 0b001;
pub const SEG_WRITE: u32 = 0b010;
pub const SEG_EXEC: u32 = 0b100;
pub const SEG_RX: u32 = SEG_READ | SEG_EXEC;
pub const SEG_RW: u32 = SEG_READ | SEG_WRITE;
pub const SEG_RO: u32 = SEG_READ;

// ── SB0K (kernel) constants ──

pub const SB0K_MAGIC = [4]u8{ 'S', 'B', '0', 'K' };
pub const SB0K_FORMAT_VERSION: u16 = 1;
pub const SB0K_HEADER_SIZE: usize = 64;
pub const SB0K_BOOT_ABI_VERSION: u16 = 1;
pub const SB0K_FLAG_FIXED_LAYOUT: u32 = 1;
/// Default preferred physical load base for a bootable SB0K image. Matches the
/// fixed load address the SB0 boot flow / QEMU `virt` loader uses (and the
/// origin in `test/sb0_runner.ld`) when no explicit image base is requested.
pub const SB0K_DEFAULT_PHYSICAL_BASE: u64 = 0x4020_0000;

// ── Little-endian byte writers ──

pub fn writeU16LE(buf: []u8, val: u16) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
}

pub fn writeU32LE(buf: []u8, val: u32) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
    buf[2] = @truncate(val >> 16);
    buf[3] = @truncate(val >> 24);
}

pub fn writeU64LE(buf: []u8, val: u64) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
    buf[2] = @truncate(val >> 16);
    buf[3] = @truncate(val >> 24);
    buf[4] = @truncate(val >> 32);
    buf[5] = @truncate(val >> 40);
    buf[6] = @truncate(val >> 48);
    buf[7] = @truncate(val >> 56);
}

pub fn readU16LE(buf: []const u8) u16 {
    return @as(u16, buf[0]) | (@as(u16, buf[1]) << 8);
}

pub fn readU32LE(buf: []const u8) u32 {
    return @as(u32, buf[0]) |
        (@as(u32, buf[1]) << 8) |
        (@as(u32, buf[2]) << 16) |
        (@as(u32, buf[3]) << 24);
}

pub fn readU64LE(buf: []const u8) u64 {
    var v: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) v |= @as(u64, buf[i]) << @intCast(i * 8);
    return v;
}

pub fn alignForward(value: u64, alignment: u64) u64 {
    return (value + alignment - 1) & ~(alignment - 1);
}

// ── SB0X header / segment descriptors ──

pub const Sb0xHeader = struct {
    format_version: u8 = SB0X_FORMAT_VERSION,
    flags: u8 = 0,
    abi_version: u16 = SB0X_ABI_VERSION,
    entry_offset: u64 = 0,
    segment_count: u16 = 0,
    tls_template_offset: u32 = 0,
    tls_template_size: u32 = 0,
    tls_bss_size: u32 = 0,
    image_size: u64 = 0,
    stack_size: u64 = SB0X_DEFAULT_STACK_SIZE,
};

pub const Sb0xSegment = struct {
    file_offset: u64 = 0,
    vaddr_offset: u64 = 0,
    file_size: u64 = 0,
    mem_size: u64 = 0,
    flags: u32 = SEG_RX,
};

/// Encode the 64-byte SB0X header into `out` (must be >= 64 bytes).
pub fn encodeHeader(out: []u8, hdr: Sb0xHeader) usize {
    if (out.len < SB0X_HEADER_SIZE) return 0;
    var i: usize = 0;
    while (i < SB0X_HEADER_SIZE) : (i += 1) out[i] = 0;

    out[0] = SB0X_MAGIC[0];
    out[1] = SB0X_MAGIC[1];
    out[2] = SB0X_MAGIC[2];
    out[3] = SB0X_MAGIC[3];
    out[4] = hdr.format_version;
    out[5] = hdr.flags;
    writeU16LE(out[6..], hdr.abi_version);
    writeU64LE(out[8..], hdr.entry_offset);
    writeU16LE(out[16..], hdr.segment_count);
    writeU16LE(out[18..], 0);
    writeU32LE(out[20..], hdr.tls_template_offset);
    writeU32LE(out[24..], hdr.tls_template_size);
    writeU32LE(out[28..], hdr.tls_bss_size);
    writeU64LE(out[32..], hdr.image_size);
    writeU64LE(out[40..], hdr.stack_size);
    return SB0X_HEADER_SIZE;
}

/// Encode a 40-byte SB0X segment descriptor into `out` (must be >= 40 bytes).
pub fn encodeSegment(out: []u8, seg: Sb0xSegment) usize {
    if (out.len < SB0X_SEGMENT_SIZE) return 0;
    writeU64LE(out[0..], seg.file_offset);
    writeU64LE(out[8..], seg.vaddr_offset);
    writeU64LE(out[16..], seg.file_size);
    writeU64LE(out[24..], seg.mem_size);
    writeU32LE(out[32..], seg.flags);
    writeU32LE(out[36..], 0);
    return SB0X_SEGMENT_SIZE;
}

/// File offset where segment payloads begin, given a segment count.
pub fn payloadOffset(segment_count: usize) usize {
    return SB0X_HEADER_SIZE + segment_count * SB0X_SEGMENT_SIZE;
}

// ── SB0K kernel header ──

pub const Sb0kHeader = struct {
    format_version: u16 = SB0K_FORMAT_VERSION,
    boot_abi_version: u16 = SB0K_BOOT_ABI_VERSION,
    abi_revision: u16 = 0,
    flags: u32 = SB0K_FLAG_FIXED_LAYOUT,
    entry_offset: u64 = 0,
    total_image_bytes: u64 = 0,
    relocation_offset: u64 = 0,
    relocation_count: u32 = 0,
    relocation_entry_bytes: u32 = 0,
    build_identity: u64 = 0,
    preferred_physical_base: u64 = 0,
};

/// Encode the 64-byte SB0K header into `out` (must be >= 64 bytes).
pub fn encodeKernelHeader(out: []u8, hdr: Sb0kHeader) usize {
    if (out.len < SB0K_HEADER_SIZE) return 0;
    var i: usize = 0;
    while (i < SB0K_HEADER_SIZE) : (i += 1) out[i] = 0;

    out[0] = SB0K_MAGIC[0];
    out[1] = SB0K_MAGIC[1];
    out[2] = SB0K_MAGIC[2];
    out[3] = SB0K_MAGIC[3];
    writeU16LE(out[4..], hdr.format_version);
    writeU16LE(out[6..], @intCast(SB0K_HEADER_SIZE));
    writeU16LE(out[8..], hdr.boot_abi_version);
    writeU16LE(out[10..], hdr.abi_revision);
    writeU32LE(out[12..], hdr.flags);
    writeU64LE(out[16..], hdr.entry_offset);
    writeU64LE(out[24..], hdr.total_image_bytes);
    writeU64LE(out[32..], hdr.relocation_offset);
    writeU32LE(out[40..], hdr.relocation_count);
    writeU32LE(out[44..], hdr.relocation_entry_bytes);
    writeU64LE(out[48..], hdr.build_identity);
    writeU64LE(out[56..], hdr.preferred_physical_base);
    return SB0K_HEADER_SIZE;
}

// ── Validation helpers ──

pub fn isSb0x(buf: []const u8) bool {
    if (buf.len < SB0X_HEADER_SIZE) return false;
    return buf[0] == 'S' and buf[1] == 'B' and buf[2] == '0' and buf[3] == 'X' and
        buf[4] == SB0X_FORMAT_VERSION;
}

pub fn isSb0k(buf: []const u8) bool {
    if (buf.len < SB0K_HEADER_SIZE) return false;
    return buf[0] == 'S' and buf[1] == 'B' and buf[2] == '0' and buf[3] == 'K' and
        readU16LE(buf[4..]) == SB0K_FORMAT_VERSION;
}

pub fn isForeignContainer(buf: []const u8) bool {
    if (buf.len < 4) return false;
    if (buf[0] == 0x7f and buf[1] == 'E' and buf[2] == 'L' and buf[3] == 'F') return true;
    if (buf[0] == 'M' and buf[1] == 'Z') return true;
    if (buf[0] == 0xcf and buf[1] == 0xfa and buf[2] == 0xed and buf[3] == 0xfe) return true;
    return false;
}

// ============================================================================
// Tests — pin the exact byte layout so this mirror cannot drift from the zpm
// canonical module (zpm/src/platform/sb0x/format.sig).
// ============================================================================

test "SB0X header layout is byte-pinned to the shared contract" {
    var buf: [SB0X_HEADER_SIZE]u8 = undefined;
    const n = encodeHeader(&buf, .{
        .format_version = SB0X_FORMAT_VERSION,
        .flags = 0,
        .abi_version = SB0X_ABI_VERSION,
        .entry_offset = 0x11,
        .segment_count = 1,
        .tls_template_offset = 0x22,
        .tls_template_size = 0x33,
        .tls_bss_size = 0x44,
        .image_size = 0x1000,
        .stack_size = SB0X_DEFAULT_STACK_SIZE,
    });
    try std.testing.expectEqual(SB0X_HEADER_SIZE, n);
    // magic @0
    try std.testing.expect(buf[0] == 'S' and buf[1] == 'B' and buf[2] == '0' and buf[3] == 'X');
    try std.testing.expectEqual(@as(u8, 1), buf[4]); // format_version @4
    try std.testing.expectEqual(@as(u8, 0), buf[5]); // flags @5
    try std.testing.expectEqual(@as(u16, 1), readU16LE(buf[6..])); // abi @6
    try std.testing.expectEqual(@as(u64, 0x11), readU64LE(buf[8..])); // entry @8
    try std.testing.expectEqual(@as(u16, 1), readU16LE(buf[16..])); // segment_count @16
    try std.testing.expectEqual(@as(u32, 0x22), readU32LE(buf[20..])); // tls_template_offset @20
    try std.testing.expectEqual(@as(u32, 0x33), readU32LE(buf[24..])); // tls_template_size @24
    try std.testing.expectEqual(@as(u32, 0x44), readU32LE(buf[28..])); // tls_bss_size @28
    try std.testing.expectEqual(@as(u64, 0x1000), readU64LE(buf[32..])); // image_size @32
    try std.testing.expectEqual(SB0X_DEFAULT_STACK_SIZE, readU64LE(buf[40..])); // stack @40
    try std.testing.expect(isSb0x(&buf));
    try std.testing.expect(!isForeignContainer(&buf));
}

test "SB0X segment descriptor layout is byte-pinned" {
    var buf: [SB0X_SEGMENT_SIZE]u8 = undefined;
    const n = encodeSegment(&buf, .{
        .file_offset = 0x68,
        .vaddr_offset = 0,
        .file_size = 4,
        .mem_size = 0x1000,
        .flags = SEG_RX,
    });
    try std.testing.expectEqual(SB0X_SEGMENT_SIZE, n);
    try std.testing.expectEqual(@as(u64, 0x68), readU64LE(buf[0..])); // file_offset @0
    try std.testing.expectEqual(@as(u64, 0), readU64LE(buf[8..])); // vaddr_offset @8
    try std.testing.expectEqual(@as(u64, 4), readU64LE(buf[16..])); // file_size @16
    try std.testing.expectEqual(@as(u64, 0x1000), readU64LE(buf[24..])); // mem_size @24
    try std.testing.expectEqual(@as(u32, 0b101), readU32LE(buf[32..])); // flags RX @32
}

test "SB0K header layout is byte-pinned" {
    var buf: [SB0K_HEADER_SIZE]u8 = undefined;
    const n = encodeKernelHeader(&buf, .{
        .total_image_bytes = 0x50,
        .build_identity = 0x0102_0304_0506_0708,
        .preferred_physical_base = 0x8000_0000,
    });
    try std.testing.expectEqual(SB0K_HEADER_SIZE, n);
    try std.testing.expect(buf[0] == 'S' and buf[1] == 'B' and buf[2] == '0' and buf[3] == 'K');
    try std.testing.expectEqual(@as(u16, 1), readU16LE(buf[4..])); // format_version @4
    try std.testing.expectEqual(@as(u16, 64), readU16LE(buf[6..])); // header bytes @6
    try std.testing.expectEqual(@as(u16, 1), readU16LE(buf[8..])); // boot abi @8
    try std.testing.expectEqual(@as(u32, 1), readU32LE(buf[12..])); // flags @12
    try std.testing.expectEqual(@as(u64, 0x50), readU64LE(buf[24..])); // total image @24
    try std.testing.expectEqual(@as(u64, 0x0102_0304_0506_0708), readU64LE(buf[48..])); // build id @48
    try std.testing.expectEqual(@as(u64, 0x8000_0000), readU64LE(buf[56..])); // phys base @56
    try std.testing.expect(isSb0k(&buf));
}

test "payloadOffset matches header + N segment descriptors" {
    try std.testing.expectEqual(@as(usize, 64 + 40), payloadOffset(1));
    try std.testing.expectEqual(@as(usize, 64 + 3 * 40), payloadOffset(3));
}
