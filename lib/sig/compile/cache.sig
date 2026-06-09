// Compilation Engine — Content Hash Cache
//
// Fixed-capacity content hash cache for incremental builds.
// Detects unchanged source files by comparing 128-bit content hashes,
// allowing the compilation engine to skip recompilation when source
// content and compilation parameters have not changed.
//
// All storage is stack-allocated with zero heap allocations.
// Uses LRU eviction when the table reaches capacity.

const types = @import("types.sig");
const target_mod = @import("target.sig");

const MAX_CACHE_ENTRIES = types.MAX_CACHE_ENTRIES;
const Target_Triple = target_mod.Target_Triple;

// ── Content_Hash_Cache ──

/// Fixed-capacity cache mapping (source_path + compile params) keys to
/// content hashes. Used for incremental build detection: if the content
/// hash for a given key matches, the source has not changed and
/// recompilation can be skipped.
///
/// Storage: stack-allocated table of MAX_CACHE_ENTRIES (1024) entries.
/// Eviction: LRU — when the table is full, the entry with the lowest
/// `last_access` counter is overwritten.
pub const Content_Hash_Cache = struct {
    entries: [MAX_CACHE_ENTRIES]Cache_Entry = [_]Cache_Entry{.{}} ** MAX_CACHE_ENTRIES,
    count: usize = 0,
    /// Monotonically increasing counter for LRU tracking.
    access_counter: u64 = 0,

    pub const Cache_Entry = struct {
        /// Key: hash of (source_path + compile params).
        key: [16]u8 = [_]u8{0} ** 16,
        /// Value: content hash of source file at last successful compile.
        content_hash: [16]u8 = [_]u8{0} ** 16,
        /// Whether this entry contains valid data.
        valid: bool = false,
        /// LRU timestamp — higher values are more recently accessed.
        last_access: u64 = 0,
    };

    /// Look up a content hash by key.
    /// Returns the stored content hash on cache hit, or null on miss.
    /// Updates the LRU access counter on hit.
    pub fn lookup(self: *Content_Hash_Cache, key: [16]u8) ?[16]u8 {
        for (0..MAX_CACHE_ENTRIES) |i| {
            if (self.entries[i].valid and keysEqual(self.entries[i].key, key)) {
                // Cache hit — update LRU counter
                self.access_counter += 1;
                self.entries[i].last_access = self.access_counter;
                return self.entries[i].content_hash;
            }
        }
        return null;
    }

    /// Store or update a cache entry. If the key already exists, its
    /// content hash and LRU counter are updated. If the key is new and
    /// the table is full, the least-recently-used entry is evicted.
    pub fn update(self: *Content_Hash_Cache, key: [16]u8, hash: [16]u8) void {
        self.access_counter += 1;

        // Check if key already exists — update in place
        for (0..MAX_CACHE_ENTRIES) |i| {
            if (self.entries[i].valid and keysEqual(self.entries[i].key, key)) {
                self.entries[i].content_hash = hash;
                self.entries[i].last_access = self.access_counter;
                return;
            }
        }

        // Key not found — insert new entry
        if (self.count < MAX_CACHE_ENTRIES) {
            // Find the first invalid slot
            for (0..MAX_CACHE_ENTRIES) |i| {
                if (!self.entries[i].valid) {
                    self.entries[i] = .{
                        .key = key,
                        .content_hash = hash,
                        .valid = true,
                        .last_access = self.access_counter,
                    };
                    self.count += 1;
                    return;
                }
            }
        }

        // Table is full — evict the LRU entry (lowest last_access)
        var lru_idx: usize = 0;
        var lru_access: u64 = self.entries[0].last_access;
        for (1..MAX_CACHE_ENTRIES) |i| {
            if (self.entries[i].last_access < lru_access) {
                lru_access = self.entries[i].last_access;
                lru_idx = i;
            }
        }

        self.entries[lru_idx] = .{
            .key = key,
            .content_hash = hash,
            .valid = true,
            .last_access = self.access_counter,
        };
    }

    /// Compute a 128-bit cache key from source path, flags, and target triple.
    /// Different parameters produce different keys (with high probability).
    pub fn computeKey(source_path: []const u8, flags: []const u8, target: Target_Triple) [16]u8 {
        // Initialize state with distinct seeds
        var h0: u64 = 0x517cc1b727220a95; // seed 0
        var h1: u64 = 0x6c62272e07bb0142; // seed 1

        // Hash source path
        hashBytes(source_path, &h0, &h1);

        // Separator to avoid path/flags collision
        hashByte(0xFF, &h0, &h1);

        // Hash flags
        hashBytes(flags, &h0, &h1);

        // Separator
        hashByte(0xFE, &h0, &h1);

        // Hash target triple as enum ordinals
        hashByte(@intFromEnum(target.arch), &h0, &h1);
        hashByte(@intFromEnum(target.os), &h0, &h1);
        hashByte(@intFromEnum(target.abi), &h0, &h1);

        // Final mixing
        h0 = mix64(h0);
        h1 = mix64(h1);

        return toBytes128(h0, h1);
    }

    /// Compute a 128-bit content hash from source file bytes.
    /// Used to detect whether source content has changed since the last
    /// successful compilation.
    pub fn computeContentHash(source_bytes: []const u8) [16]u8 {
        // Initialize state with different seeds than computeKey
        var h0: u64 = 0x9e3779b97f4a7c15; // golden ratio derived
        var h1: u64 = 0xbf58476d1ce4e5b9; // splitmix64 constant

        // Process input in 16-byte chunks for efficiency
        const full_chunks = source_bytes.len / 16;
        for (0..full_chunks) |chunk_idx| {
            const offset = chunk_idx * 16;
            const lo = readU64(source_bytes[offset..][0..8]);
            const hi = readU64(source_bytes[offset + 8 ..][0..8]);
            h0 ^= lo;
            h0 = mix64(h0);
            h1 ^= hi;
            h1 = mix64(h1);
        }

        // Process remaining bytes
        const remainder_start = full_chunks * 16;
        const remainder = source_bytes[remainder_start..];
        for (remainder) |byte| {
            hashByte(byte, &h0, &h1);
        }

        // Mix in length to differentiate inputs with trailing zeros
        h0 ^= @intCast(source_bytes.len);
        h0 = mix64(h0);
        h1 ^= @intCast(source_bytes.len);
        h1 = mix64(h1);

        return toBytes128(h0, h1);
    }
};

// ── Internal Hashing Helpers ──

/// Compare two 16-byte keys for equality.
fn keysEqual(a: [16]u8, b: [16]u8) bool {
    inline for (0..16) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}

/// Hash a single byte into the state.
fn hashByte(byte: u8, h0: *u64, h1: *u64) void {
    h0.* ^= @intCast(byte);
    h0.* *%= 0x9e3779b97f4a7c15;
    h1.* ^= @intCast(byte);
    h1.* +%= h0.*;
}

/// Hash a byte slice into the state.
fn hashBytes(data: []const u8, h0: *u64, h1: *u64) void {
    for (data) |byte| {
        hashByte(byte, h0, h1);
    }
}

/// 64-bit finalizer mixing function (splitmix64-style).
/// Provides good avalanche properties for diffusing all bits.
fn mix64(v: u64) u64 {
    var x = v;
    x ^= x >> 30;
    x *%= 0xbf58476d1ce4e5b9;
    x ^= x >> 27;
    x *%= 0x94d049bb133111eb;
    x ^= x >> 31;
    return x;
}

/// Read 8 bytes as a little-endian u64.
fn readU64(bytes: *const [8]u8) u64 {
    var result: u64 = 0;
    inline for (0..8) |i| {
        result |= @as(u64, bytes[i]) << @intCast(i * 8);
    }
    return result;
}

/// Convert two u64 values into a [16]u8 array (little-endian).
fn toBytes128(h0: u64, h1: u64) [16]u8 {
    var result: [16]u8 = undefined;
    inline for (0..8) |i| {
        result[i] = @intCast((h0 >> @intCast(i * 8)) & 0xFF);
    }
    inline for (0..8) |i| {
        result[8 + i] = @intCast((h1 >> @intCast(i * 8)) & 0xFF);
    }
    return result;
}
