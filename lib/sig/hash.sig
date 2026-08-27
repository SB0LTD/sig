//! XxHash64 — Streaming 64-bit hash (xxHash spec).
//!
//! Zero-dependency, freestanding implementation of the xxHash64 algorithm.
//! Provides a streaming API: init(seed) → update(data) → final() → u64.
//!
//! Usage:
//!   var h = XxHash64.init(0);
//!   h.update(data);
//!   const digest = h.final();

// ══════════════════════════════════════════════════════════════════════════════
// Constants (official xxHash64 spec)
// ══════════════════════════════════════════════════════════════════════════════

const PRIME64_1: u64 = 0x9E3779B185EBCA87;
const PRIME64_2: u64 = 0xC2B2AE3D27D4EB4F;
const PRIME64_3: u64 = 0x165667B19E3779F9;
const PRIME64_4: u64 = 0x85EBCA77C2B2AE63;
const PRIME64_5: u64 = 0x27D4EB2F165667C5;

// ══════════════════════════════════════════════════════════════════════════════
// XxHash64 Streaming Hasher
// ══════════════════════════════════════════════════════════════════════════════

pub const XxHash64 = struct {
    acc1: u64,
    acc2: u64,
    acc3: u64,
    acc4: u64,
    seed: u64,
    buf: [32]u8,
    buf_len: usize,
    total_len: u64,

    /// Initialize a new XxHash64 hasher with the given seed.
    pub fn init(seed: u64) XxHash64 {
        return .{
            .acc1 = seed +% PRIME64_1 +% PRIME64_2,
            .acc2 = seed +% PRIME64_2,
            .acc3 = seed,
            .acc4 = seed -% PRIME64_1,
            .seed = seed,
            .buf = undefined,
            .buf_len = 0,
            .total_len = 0,
        };
    }

    /// Feed bytes into the hasher. Can be called multiple times.
    pub fn update(self: *XxHash64, data: []const u8) void {
        var input = data;
        self.total_len += input.len;

        // If we have buffered data, try to fill the 32-byte stripe buffer first.
        if (self.buf_len > 0) {
            const needed = 32 - self.buf_len;
            if (input.len < needed) {
                // Not enough to complete a stripe — just buffer.
                @memcpy(self.buf[self.buf_len .. self.buf_len + input.len], input);
                self.buf_len += input.len;
                return;
            }
            // Complete the buffered stripe.
            @memcpy(self.buf[self.buf_len..32], input[0..needed]);
            self.processStripe(&self.buf);
            input = input[needed..];
            self.buf_len = 0;
        }

        // Process full 32-byte stripes directly from input.
        while (input.len >= 32) {
            self.processStripe(input[0..32]);
            input = input[32..];
        }

        // Buffer remaining bytes (< 32).
        if (input.len > 0) {
            @memcpy(self.buf[0..input.len], input);
            self.buf_len = input.len;
        }
    }

    /// Finalize and return the 64-bit digest. Does not modify the hasher state
    /// (you could continue calling update + final for rolling hashes, though
    /// that is non-standard usage).
    pub fn final(self: *XxHash64) u64 {
        var h: u64 = undefined;

        if (self.total_len >= 32) {
            // Merge the 4 accumulators.
            h = rotl(self.acc1, 1) +% rotl(self.acc2, 7) +% rotl(self.acc3, 12) +% rotl(self.acc4, 18);
            h = mergeAccumulator(h, self.acc1);
            h = mergeAccumulator(h, self.acc2);
            h = mergeAccumulator(h, self.acc3);
            h = mergeAccumulator(h, self.acc4);
        } else {
            // Short input — never filled a full stripe.
            h = self.seed +% PRIME64_5;
        }

        h +%= self.total_len;

        // Process remaining buffered bytes.
        const remaining = self.buf[0..self.buf_len];
        var i: usize = 0;

        // 8-byte lanes.
        while (i + 8 <= remaining.len) {
            const k = readU64LE(remaining[i..][0..8]);
            h ^= round(0, k);
            h = rotl(h, 27) *% PRIME64_1 +% PRIME64_4;
            i += 8;
        }

        // 4-byte lane.
        if (i + 4 <= remaining.len) {
            const k = @as(u64, readU32LE(remaining[i..][0..4]));
            h ^= k *% PRIME64_1;
            h = rotl(h, 23) *% PRIME64_2 +% PRIME64_3;
            i += 4;
        }

        // Remaining single bytes.
        while (i < remaining.len) {
            h ^= @as(u64, remaining[i]) *% PRIME64_5;
            h = rotl(h, 11) *% PRIME64_1;
            i += 1;
        }

        // Avalanche.
        h = avalanche(h);
        return h;
    }

    // ── Internal ────────────────────────────────────────────────────────────

    fn processStripe(self: *XxHash64, stripe: *const [32]u8) void {
        self.acc1 = round(self.acc1, readU64LE(stripe[0..8]));
        self.acc2 = round(self.acc2, readU64LE(stripe[8..16]));
        self.acc3 = round(self.acc3, readU64LE(stripe[16..24]));
        self.acc4 = round(self.acc4, readU64LE(stripe[24..32]));
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// One-shot convenience
// ══════════════════════════════════════════════════════════════════════════════

/// Hash a byte slice in one shot with the given seed. Returns u64.
pub fn xxhash64(data: []const u8, seed: u64) u64 {
    var h = XxHash64.init(seed);
    h.update(data);
    return h.final();
}

// ══════════════════════════════════════════════════════════════════════════════
// Primitives
// ══════════════════════════════════════════════════════════════════════════════

fn round(acc: u64, input: u64) u64 {
    var a = acc +% (input *% PRIME64_2);
    a = rotl(a, 31);
    a *%= PRIME64_1;
    return a;
}

fn mergeAccumulator(h: u64, acc: u64) u64 {
    var v = h;
    v ^= round(0, acc);
    v = v *% PRIME64_1 +% PRIME64_4;
    return v;
}

fn avalanche(h_in: u64) u64 {
    var h = h_in;
    h ^= h >> 33;
    h *%= PRIME64_2;
    h ^= h >> 29;
    h *%= PRIME64_3;
    h ^= h >> 32;
    return h;
}

fn rotl(x: u64, comptime r: u6) u64 {
    return (x << r) | (x >> @as(u6, @intCast(@as(u7, 64) - @as(u7, r))));
}

fn readU64LE(buf: *const [8]u8) u64 {
    return @as(u64, buf[0]) |
        (@as(u64, buf[1]) << 8) |
        (@as(u64, buf[2]) << 16) |
        (@as(u64, buf[3]) << 24) |
        (@as(u64, buf[4]) << 32) |
        (@as(u64, buf[5]) << 40) |
        (@as(u64, buf[6]) << 48) |
        (@as(u64, buf[7]) << 56);
}

fn readU32LE(buf: *const [4]u8) u32 {
    return @as(u32, buf[0]) |
        (@as(u32, buf[1]) << 8) |
        (@as(u32, buf[2]) << 16) |
        (@as(u32, buf[3]) << 24);
}

// ══════════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════════

test "xxhash64 empty string seed 0" {
    // Official vector: xxh64("", 0) = 0xef46db3751d8e999
    const result = xxhash64("", 0);
    if (result != 0xef46db3751d8e999) return error.TestUnexpectedResult;
}

test "xxhash64 single char 'a'" {
    // Official vector: xxh64("a", 0) = 0xd24ec4f1a98c6e5b
    const result = xxhash64("a", 0);
    if (result != 0xd24ec4f1a98c6e5b) return error.TestUnexpectedResult;
}

test "xxhash64 'abc' seed 0" {
    // Official vector: xxh64("abc", 0) = 0x44bc2cf5ad770999
    const result = xxhash64("abc", 0);
    if (result != 0x44bc2cf5ad770999) return error.TestUnexpectedResult;
}

test "xxhash64 'message digest' seed 0" {
    // Official vector: xxh64("message digest", 0) = 0x066ed728fceeb3be
    const result = xxhash64("message digest", 0);
    if (result != 0x066ed728fceeb3be) return error.TestUnexpectedResult;
}

test "xxhash64 long string seed 0" {
    // Official vector: xxh64("abcdefghijklmnopqrstuvwxyz", 0) = 0xcfe1f278fa89835c
    const result = xxhash64("abcdefghijklmnopqrstuvwxyz", 0);
    if (result != 0xcfe1f278fa89835c) return error.TestUnexpectedResult;
}

test "xxhash64 streaming matches one-shot" {
    const data = "Hello, World! This is a test of xxHash64 streaming.";
    const one_shot = xxhash64(data, 0);

    // Stream in multiple chunks
    var h = XxHash64.init(0);
    h.update(data[0..7]);
    h.update(data[7..20]);
    h.update(data[20..]);
    const streamed = h.final();

    if (one_shot != streamed) return error.TestUnexpectedResult;
}

test "xxhash64 different seeds produce different results" {
    const data = "test data";
    const r0 = xxhash64(data, 0);
    const r1 = xxhash64(data, 1);
    if (r0 == r1) return error.TestUnexpectedResult;
}

test "xxhash64 large input byte-by-byte streaming" {
    // Create 128 bytes of data (4 full stripes)
    var data: [128]u8 = undefined;
    for (&data, 0..) |*b, i| {
        b.* = @intCast(i & 0xFF);
    }

    // One-shot
    const one_shot = xxhash64(&data, 42);

    // Stream byte-by-byte
    var h = XxHash64.init(42);
    for (&data) |*b| {
        h.update(@as(*const [1]u8, b));
    }
    const byte_by_byte = h.final();

    if (one_shot != byte_by_byte) return error.TestUnexpectedResult;
}
