// Unit tests for Cache_Map and Content_Hash (task 1.8).
//
// Since the build runner (tools/sig_build/main.sig) is not wired as a test import,
// these tests replicate the Cache_Map logic using the same algorithms.
//
// Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7, 8.8, 10.5

const std = @import("std");
const testing = std.testing;

const NAME_BUF_SIZE = 64;
const MAX_CACHE_ENTRIES = 64; // Smaller capacity for tests (production uses 4096).
const HASH_CHUNK_SIZE = 8192;

pub const Content_Hash = [16]u8;
const RECORD_SIZE: usize = 96;
const HEADER_SIZE: usize = 12;
const CACHE_MAGIC = [4]u8{ 'S', 'I', 'G', 'C' };
const CACHE_VERSION: u32 = 1;

// ── Replicated Cache_Entry from main.sig ────────────────────────────────

const Cache_Entry = struct {
    hash: Content_Hash = .{0} ** 16,
    step_name: [NAME_BUF_SIZE]u8 = .{0} ** NAME_BUF_SIZE,
    step_name_len: usize = 0,
    timestamp: i64 = 0,
    valid: bool = false,
};

// ── Replicated Cache_Map from main.sig ──────────────────────────────────

const Cache_Map = struct {
    entries: [MAX_CACHE_ENTRIES]Cache_Entry = [_]Cache_Entry{.{}} ** MAX_CACHE_ENTRIES,
    count: usize = 0,

    pub fn lookup(self: *const Cache_Map, step_name: []const u8) ?Content_Hash {
        for (self.entries[0..MAX_CACHE_ENTRIES]) |*entry| {
            if (entry.valid and entry.step_name_len == step_name.len and
                std.mem.eql(u8, entry.step_name[0..entry.step_name_len], step_name))
            {
                return entry.hash;
            }
        }
        return null;
    }

    pub fn put(self: *Cache_Map, step_name: []const u8, hash: Content_Hash, timestamp: i64) !void {
        if (step_name.len > NAME_BUF_SIZE) return error.BufferTooSmall;

        // Check for existing entry with same name → update in place.
        for (self.entries[0..MAX_CACHE_ENTRIES]) |*entry| {
            if (entry.valid and entry.step_name_len == step_name.len and
                std.mem.eql(u8, entry.step_name[0..entry.step_name_len], step_name))
            {
                entry.hash = hash;
                entry.timestamp = timestamp;
                return;
            }
        }

        if (self.count >= MAX_CACHE_ENTRIES) {
            self.evictOldest(MAX_CACHE_ENTRIES - 1);
        }

        for (self.entries[0..MAX_CACHE_ENTRIES]) |*entry| {
            if (!entry.valid) {
                entry.hash = hash;
                @memcpy(entry.step_name[0..step_name.len], step_name);
                if (step_name.len < NAME_BUF_SIZE) {
                    @memset(entry.step_name[step_name.len..], 0);
                }
                entry.step_name_len = step_name.len;
                entry.timestamp = timestamp;
                entry.valid = true;
                self.count += 1;
                return;
            }
        }

        return error.CapacityExceeded;
    }

    pub fn evictOldest(self: *Cache_Map, target_count: usize) void {
        while (self.count > target_count) {
            var oldest_idx: ?usize = null;
            var oldest_ts: i64 = std.math.maxInt(i64);
            for (self.entries[0..MAX_CACHE_ENTRIES], 0..) |*entry, idx| {
                if (entry.valid and entry.timestamp < oldest_ts) {
                    oldest_ts = entry.timestamp;
                    oldest_idx = idx;
                }
            }
            if (oldest_idx) |idx| {
                self.entries[idx].valid = false;
                self.count -= 1;
            } else {
                break;
            }
        }
    }

    /// Serialize to a byte buffer (test-friendly version of save).
    pub fn serializeToBuffer(self: *const Cache_Map, buf: []u8) ?usize {
        const needed = HEADER_SIZE + self.count * RECORD_SIZE;
        if (needed > buf.len) return null;

        @memcpy(buf[0..4], &CACHE_MAGIC);
        std.mem.writeInt(u32, buf[4..8], CACHE_VERSION, .little);
        std.mem.writeInt(u32, buf[8..12], @intCast(self.count), .little);

        var offset: usize = HEADER_SIZE;
        for (self.entries[0..MAX_CACHE_ENTRIES]) |*entry| {
            if (!entry.valid) continue;
            var record: [RECORD_SIZE]u8 = .{0} ** RECORD_SIZE;
            @memcpy(record[0..16], &entry.hash);
            @memcpy(record[16..80], &entry.step_name);
            std.mem.writeInt(i64, record[80..88], entry.timestamp, .little);
            @memcpy(buf[offset..][0..RECORD_SIZE], &record);
            offset += RECORD_SIZE;
        }
        return offset;
    }

    /// Deserialize from a byte buffer (test-friendly version of load).
    pub fn deserializeFromBuffer(self: *Cache_Map, buf: []const u8) void {
        self.count = 0;
        for (&self.entries) |*entry| {
            entry.valid = false;
        }

        if (buf.len < HEADER_SIZE) return;
        if (!std.mem.eql(u8, buf[0..4], &CACHE_MAGIC)) return;

        const version = std.mem.readInt(u32, buf[4..8], .little);
        if (version != CACHE_VERSION) return;

        const file_count = std.mem.readInt(u32, buf[8..12], .little);
        if (file_count == 0) return;

        const load_count = @min(@as(usize, file_count), MAX_CACHE_ENTRIES);
        var offset: usize = HEADER_SIZE;
        var loaded: usize = 0;

        while (loaded < load_count) {
            if (offset + RECORD_SIZE > buf.len) return;
            const record = buf[offset..][0..RECORD_SIZE];

            var entry = &self.entries[loaded];
            @memcpy(&entry.hash, record[0..16]);
            @memcpy(&entry.step_name, record[16..80]);
            entry.step_name_len = 0;
            for (entry.step_name, 0..) |c, idx| {
                if (c == 0) {
                    entry.step_name_len = idx;
                    break;
                }
            } else {
                entry.step_name_len = NAME_BUF_SIZE;
            }
            entry.timestamp = std.mem.readInt(i64, record[80..88], .little);
            entry.valid = true;
            loaded += 1;
            offset += RECORD_SIZE;
        }
        self.count = loaded;

        if (file_count > MAX_CACHE_ENTRIES) {
            self.evictOldest(MAX_CACHE_ENTRIES);
        }
    }
};


// ── Helper: create a test hash from a single byte value ─────────────────

fn makeHash(val: u8) Content_Hash {
    return .{val} ** 16;
}

fn makeName(comptime name: []const u8) [NAME_BUF_SIZE]u8 {
    var buf: [NAME_BUF_SIZE]u8 = .{0} ** NAME_BUF_SIZE;
    @memcpy(buf[0..name.len], name);
    return buf;
}

// ── CR+LF normalization helper (replicated from main.sig) ───────────────

fn normalizeCrLf(data: []const u8, out: []u8) usize {
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < data.len) {
        if (data[i] == '\r' and i + 1 < data.len and data[i + 1] == '\n') {
            out[out_len] = '\n';
            out_len += 1;
            i += 2;
        } else {
            out[out_len] = data[i];
            out_len += 1;
            i += 1;
        }
    }
    return out_len;
}

// ── Cache_Map: lookup tests ─────────────────────────────────────────────

test "lookup: empty cache returns null" {
    var cache: Cache_Map = .{};
    try testing.expect(cache.lookup("compile") == null);
}

test "lookup: finds existing entry" {
    var cache: Cache_Map = .{};
    const hash = makeHash(0xAB);
    try cache.put("compile", hash, 1000);
    const found = cache.lookup("compile");
    try testing.expect(found != null);
    try testing.expectEqualSlices(u8, &hash, &found.?);
}

test "lookup: returns null for non-existent name" {
    var cache: Cache_Map = .{};
    try cache.put("compile", makeHash(0xAB), 1000);
    try testing.expect(cache.lookup("test") == null);
}

test "lookup: distinguishes similar names" {
    var cache: Cache_Map = .{};
    try cache.put("compile", makeHash(0x01), 1000);
    try cache.put("compile2", makeHash(0x02), 1001);
    const h1 = cache.lookup("compile").?;
    const h2 = cache.lookup("compile2").?;
    try testing.expectEqual(@as(u8, 0x01), h1[0]);
    try testing.expectEqual(@as(u8, 0x02), h2[0]);
}

// ── Cache_Map: put tests ────────────────────────────────────────────────

test "put: inserts new entry" {
    var cache: Cache_Map = .{};
    try cache.put("step1", makeHash(0x10), 100);
    try testing.expectEqual(@as(usize, 1), cache.count);
}

test "put: updates existing entry" {
    var cache: Cache_Map = .{};
    try cache.put("step1", makeHash(0x10), 100);
    try cache.put("step1", makeHash(0x20), 200);
    try testing.expectEqual(@as(usize, 1), cache.count);
    const found = cache.lookup("step1").?;
    try testing.expectEqual(@as(u8, 0x20), found[0]);
}

test "put: multiple entries" {
    var cache: Cache_Map = .{};
    try cache.put("a", makeHash(1), 10);
    try cache.put("b", makeHash(2), 20);
    try cache.put("c", makeHash(3), 30);
    try testing.expectEqual(@as(usize, 3), cache.count);
    try testing.expect(cache.lookup("a") != null);
    try testing.expect(cache.lookup("b") != null);
    try testing.expect(cache.lookup("c") != null);
}

test "put: name too long returns BufferTooSmall" {
    var cache: Cache_Map = .{};
    const long_name = "a" ** (NAME_BUF_SIZE + 1);
    try testing.expectError(error.BufferTooSmall, cache.put(long_name, makeHash(0), 0));
}

// ── Cache_Map: evictOldest tests ────────────────────────────────────────

test "evictOldest: removes entry with smallest timestamp" {
    var cache: Cache_Map = .{};
    try cache.put("old", makeHash(1), 100);
    try cache.put("mid", makeHash(2), 200);
    try cache.put("new", makeHash(3), 300);
    try testing.expectEqual(@as(usize, 3), cache.count);

    cache.evictOldest(2);
    try testing.expectEqual(@as(usize, 2), cache.count);
    try testing.expect(cache.lookup("old") == null); // oldest evicted
    try testing.expect(cache.lookup("mid") != null);
    try testing.expect(cache.lookup("new") != null);
}

test "evictOldest: evicts multiple to reach target" {
    var cache: Cache_Map = .{};
    try cache.put("a", makeHash(1), 10);
    try cache.put("b", makeHash(2), 20);
    try cache.put("c", makeHash(3), 30);
    try cache.put("d", makeHash(4), 40);

    cache.evictOldest(1);
    try testing.expectEqual(@as(usize, 1), cache.count);
    // Only the newest should remain
    try testing.expect(cache.lookup("d") != null);
    try testing.expect(cache.lookup("a") == null);
    try testing.expect(cache.lookup("b") == null);
    try testing.expect(cache.lookup("c") == null);
}

test "evictOldest: no-op when already at target" {
    var cache: Cache_Map = .{};
    try cache.put("a", makeHash(1), 10);
    cache.evictOldest(5);
    try testing.expectEqual(@as(usize, 1), cache.count);
}

// ── Cache_Map: capacity and auto-eviction ───────────────────────────────

test "put: auto-evicts when at capacity" {
    var cache: Cache_Map = .{};
    // Fill to capacity
    for (0..MAX_CACHE_ENTRIES) |i| {
        var name_buf: [8]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "s{d}", .{i}) catch unreachable;
        try cache.put(name, makeHash(@intCast(i)), @intCast(i));
    }
    try testing.expectEqual(@as(usize, MAX_CACHE_ENTRIES), cache.count);

    // One more should auto-evict the oldest (timestamp 0)
    try cache.put("new_step", makeHash(0xFF), 9999);
    try testing.expectEqual(@as(usize, MAX_CACHE_ENTRIES), cache.count);
    try testing.expect(cache.lookup("new_step") != null);
    // The entry with timestamp 0 ("s0") should have been evicted
    try testing.expect(cache.lookup("s0") == null);
}

// ── Binary serialization round-trip ─────────────────────────────────────

test "serialize/deserialize: empty cache round-trip" {
    var cache: Cache_Map = .{};
    var buf: [HEADER_SIZE + MAX_CACHE_ENTRIES * RECORD_SIZE]u8 = undefined;
    const written = cache.serializeToBuffer(&buf).?;
    try testing.expectEqual(@as(usize, HEADER_SIZE), written);

    var loaded: Cache_Map = .{};
    loaded.deserializeFromBuffer(buf[0..written]);
    try testing.expectEqual(@as(usize, 0), loaded.count);
}

test "serialize/deserialize: single entry round-trip" {
    var cache: Cache_Map = .{};
    const hash = makeHash(0xDE);
    try cache.put("build", hash, 42);

    var buf: [HEADER_SIZE + MAX_CACHE_ENTRIES * RECORD_SIZE]u8 = undefined;
    const written = cache.serializeToBuffer(&buf).?;
    try testing.expectEqual(@as(usize, HEADER_SIZE + RECORD_SIZE), written);

    var loaded: Cache_Map = .{};
    loaded.deserializeFromBuffer(buf[0..written]);
    try testing.expectEqual(@as(usize, 1), loaded.count);
    const found = loaded.lookup("build").?;
    try testing.expectEqualSlices(u8, &hash, &found);
}

test "serialize/deserialize: multiple entries round-trip" {
    var cache: Cache_Map = .{};
    try cache.put("compile", makeHash(0x01), 100);
    try cache.put("test", makeHash(0x02), 200);
    try cache.put("install", makeHash(0x03), 300);

    var buf: [HEADER_SIZE + MAX_CACHE_ENTRIES * RECORD_SIZE]u8 = undefined;
    const written = cache.serializeToBuffer(&buf).?;

    var loaded: Cache_Map = .{};
    loaded.deserializeFromBuffer(buf[0..written]);
    try testing.expectEqual(@as(usize, 3), loaded.count);
    try testing.expectEqualSlices(u8, &makeHash(0x01), &loaded.lookup("compile").?);
    try testing.expectEqualSlices(u8, &makeHash(0x02), &loaded.lookup("test").?);
    try testing.expectEqualSlices(u8, &makeHash(0x03), &loaded.lookup("install").?);
}

test "serialize/deserialize: preserves timestamps" {
    var cache: Cache_Map = .{};
    try cache.put("step", makeHash(0xAA), 1234567890);

    var buf: [HEADER_SIZE + MAX_CACHE_ENTRIES * RECORD_SIZE]u8 = undefined;
    const written = cache.serializeToBuffer(&buf).?;

    var loaded: Cache_Map = .{};
    loaded.deserializeFromBuffer(buf[0..written]);
    // Find the entry and check timestamp
    for (loaded.entries[0..MAX_CACHE_ENTRIES]) |*entry| {
        if (entry.valid and std.mem.eql(u8, entry.step_name[0..entry.step_name_len], "step")) {
            try testing.expectEqual(@as(i64, 1234567890), entry.timestamp);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

// ── Corrupt/missing cache handling ──────────────────────────────────────

test "deserialize: empty buffer starts empty" {
    var cache: Cache_Map = .{};
    cache.deserializeFromBuffer(&[_]u8{});
    try testing.expectEqual(@as(usize, 0), cache.count);
}

test "deserialize: bad magic starts empty" {
    var buf: [HEADER_SIZE]u8 = undefined;
    @memcpy(buf[0..4], "BAAD");
    std.mem.writeInt(u32, buf[4..8], 1, .little);
    std.mem.writeInt(u32, buf[8..12], 0, .little);

    var cache: Cache_Map = .{};
    cache.deserializeFromBuffer(&buf);
    try testing.expectEqual(@as(usize, 0), cache.count);
}

test "deserialize: wrong version starts empty" {
    var buf: [HEADER_SIZE]u8 = undefined;
    @memcpy(buf[0..4], &CACHE_MAGIC);
    std.mem.writeInt(u32, buf[4..8], 99, .little); // wrong version
    std.mem.writeInt(u32, buf[8..12], 0, .little);

    var cache: Cache_Map = .{};
    cache.deserializeFromBuffer(&buf);
    try testing.expectEqual(@as(usize, 0), cache.count);
}

test "deserialize: truncated header starts empty" {
    const buf = [_]u8{ 'S', 'I', 'G' }; // only 3 bytes
    var cache: Cache_Map = .{};
    cache.deserializeFromBuffer(&buf);
    try testing.expectEqual(@as(usize, 0), cache.count);
}

test "deserialize: truncated record loads partial" {
    // Write header claiming 2 entries but only provide 1 full record
    var buf: [HEADER_SIZE + RECORD_SIZE + 10]u8 = .{0} ** (HEADER_SIZE + RECORD_SIZE + 10);
    @memcpy(buf[0..4], &CACHE_MAGIC);
    std.mem.writeInt(u32, buf[4..8], CACHE_VERSION, .little);
    std.mem.writeInt(u32, buf[8..12], 2, .little); // claims 2 entries

    // Write one valid record
    buf[HEADER_SIZE + 0] = 0xAA; // first byte of hash
    @memcpy(buf[HEADER_SIZE + 16 ..][0..4], "test");
    std.mem.writeInt(i64, buf[HEADER_SIZE + 80 ..][0..8], 42, .little);

    var cache: Cache_Map = .{};
    cache.deserializeFromBuffer(&buf);
    // Should load 1 entry (second is truncated)
    try testing.expectEqual(@as(usize, 1), cache.count);
}

// ── CR+LF normalization tests ───────────────────────────────────────────

test "normalizeCrLf: no change for LF-only" {
    const input = "hello\nworld\n";
    var out: [64]u8 = undefined;
    const len = normalizeCrLf(input, &out);
    try testing.expectEqualSlices(u8, input, out[0..len]);
}

test "normalizeCrLf: converts CR+LF to LF" {
    const input = "hello\r\nworld\r\n";
    var out: [64]u8 = undefined;
    const len = normalizeCrLf(input, &out);
    try testing.expectEqualSlices(u8, "hello\nworld\n", out[0..len]);
}

test "normalizeCrLf: preserves standalone CR" {
    const input = "hello\rworld";
    var out: [64]u8 = undefined;
    const len = normalizeCrLf(input, &out);
    try testing.expectEqualSlices(u8, "hello\rworld", out[0..len]);
}

test "normalizeCrLf: mixed line endings" {
    const input = "a\r\nb\nc\r\nd";
    var out: [64]u8 = undefined;
    const len = normalizeCrLf(input, &out);
    try testing.expectEqualSlices(u8, "a\nb\nc\nd", out[0..len]);
}

test "normalizeCrLf: empty input" {
    var out: [64]u8 = undefined;
    const len = normalizeCrLf("", &out);
    try testing.expectEqual(@as(usize, 0), len);
}

test "normalizeCrLf: CR at end of buffer (no following LF)" {
    const input = "hello\r";
    var out: [64]u8 = undefined;
    const len = normalizeCrLf(input, &out);
    try testing.expectEqualSlices(u8, "hello\r", out[0..len]);
}

// ── Content_Hash: XxHash64 dual-seed produces 128 bits ──────────────────

test "Content_Hash: dual XxHash64 produces deterministic 128-bit hash" {
    const data = "hello world";
    var h0 = std.hash.XxHash64.init(0);
    var h1 = std.hash.XxHash64.init(0x9e3779b97f4a7c15);
    h0.update(data);
    h1.update(data);
    const lo = h0.final();
    const hi = h1.final();

    var result: Content_Hash = undefined;
    std.mem.writeInt(u64, result[0..8], lo, .little);
    std.mem.writeInt(u64, result[8..16], hi, .little);

    // Hash again — must be identical (deterministic).
    var h0b = std.hash.XxHash64.init(0);
    var h1b = std.hash.XxHash64.init(0x9e3779b97f4a7c15);
    h0b.update(data);
    h1b.update(data);
    var result2: Content_Hash = undefined;
    std.mem.writeInt(u64, result2[0..8], h0b.final(), .little);
    std.mem.writeInt(u64, result2[8..16], h1b.final(), .little);

    try testing.expectEqualSlices(u8, &result, &result2);
}

test "Content_Hash: different inputs produce different hashes" {
    const data1 = "hello";
    const data2 = "world";

    var h0a = std.hash.XxHash64.init(0);
    var h1a = std.hash.XxHash64.init(0x9e3779b97f4a7c15);
    h0a.update(data1);
    h1a.update(data1);
    var hash1: Content_Hash = undefined;
    std.mem.writeInt(u64, hash1[0..8], h0a.final(), .little);
    std.mem.writeInt(u64, hash1[8..16], h1a.final(), .little);

    var h0b = std.hash.XxHash64.init(0);
    var h1b = std.hash.XxHash64.init(0x9e3779b97f4a7c15);
    h0b.update(data2);
    h1b.update(data2);
    var hash2: Content_Hash = undefined;
    std.mem.writeInt(u64, hash2[0..8], h0b.final(), .little);
    std.mem.writeInt(u64, hash2[8..16], h1b.final(), .little);

    try testing.expect(!std.mem.eql(u8, &hash1, &hash2));
}

// ── Binary format: header structure ─────────────────────────────────────

test "binary format: header has correct magic and version" {
    var cache: Cache_Map = .{};
    try cache.put("x", makeHash(1), 1);

    var buf: [HEADER_SIZE + RECORD_SIZE]u8 = undefined;
    _ = cache.serializeToBuffer(&buf).?;

    try testing.expectEqualSlices(u8, "SIGC", buf[0..4]);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, buf[4..8], .little));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, buf[8..12], .little));
}
