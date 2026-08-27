//! Hash Index — Open-address hash table backed by PageArena.
//!
//! Provides O(1) amortized name→handle lookup for build registries.
//! No fixed capacity — grows by doubling and rehashing when load factor
//! exceeds 75%. All memory drawn from a PageArena (no heap allocator).
//!
//! Design:
//!   - FNV-1a hash for string keys (fast, good distribution)
//!   - Open addressing with linear probing (cache-friendly)
//!   - Tombstone-free (never delete entries — build lifetime semantics)
//!   - Grows by allocating a new bucket array from the arena and rehashing
//!     (old array is abandoned in the arena — no free needed)
//!   - Thread-safe reads after construction (immutable once built)
//!
//! Usage:
//!   var index = HashIndex.init(&arena);
//!   index.put("module_name", 42);  // name → handle
//!   const handle = index.get("module_name"); // → ?u32

const page_arena = @import("page_arena.sig");

// ══════════════════════════════════════════════════════════════════════════════
// Hash Index
// ══════════════════════════════════════════════════════════════════════════════

pub const HashIndex = struct {
    buckets: [*]Bucket,
    capacity: u32,
    count: u32,
    arena: *page_arena.PageArena,

    const INITIAL_CAPACITY: u32 = 128;
    const LOAD_FACTOR_NUM: u32 = 3; // 75% = 3/4
    const LOAD_FACTOR_DEN: u32 = 4;

    const Bucket = struct {
        hash: u64, // 0 = empty sentinel
        value: u32, // The handle/index being stored
        key_ptr: [*]const u8, // Pointer to the key string (in arena)
        key_len: u32,
    };

    const EMPTY_HASH: u64 = 0;

    /// Initialize with default capacity.
    pub fn init(arena: *page_arena.PageArena) HashIndex {
        return initWithCapacity(arena, INITIAL_CAPACITY);
    }

    /// Initialize with a specific starting capacity (rounded up to power of 2).
    pub fn initWithCapacity(arena: *page_arena.PageArena, requested: u32) HashIndex {
        const cap = nextPow2(requested);
        const buckets = arena.allocSlice(Bucket, cap) orelse unreachable;
        // Zero-init all buckets (hash=0 means empty)
        for (buckets) |*b| {
            b.hash = EMPTY_HASH;
            b.value = 0;
            b.key_ptr = undefined;
            b.key_len = 0;
        }
        return .{
            .buckets = buckets.ptr,
            .capacity = cap,
            .count = 0,
            .arena = arena,
        };
    }

    /// Insert a key→value mapping. If the key already exists, updates the value.
    /// Keys are duplicated into the arena for stable lifetime.
    pub fn put(self: *HashIndex, key: []const u8, value: u32) void {
        // Check load factor and grow if needed
        if ((self.count + 1) * LOAD_FACTOR_DEN > self.capacity * LOAD_FACTOR_NUM) {
            self.grow();
        }

        const hash = fnv1a(key);
        const mask = self.capacity - 1;
        var idx = @as(u32, @intCast(hash & mask));

        while (true) {
            const bucket = &self.buckets[idx];
            if (bucket.hash == EMPTY_HASH) {
                // Empty slot — insert here
                const key_copy = self.arena.dupe(key) orelse unreachable;
                bucket.hash = hash;
                bucket.value = value;
                bucket.key_ptr = key_copy.ptr;
                bucket.key_len = @intCast(key_copy.len);
                self.count += 1;
                return;
            }
            if (bucket.hash == hash and bucket.key_len == key.len) {
                // Potential match — verify key bytes
                if (keysEqual(bucket.key_ptr[0..bucket.key_len], key)) {
                    // Update existing entry
                    bucket.value = value;
                    return;
                }
            }
            // Linear probe
            idx = (idx + 1) & mask;
        }
    }

    /// Look up a key. Returns the associated value or null if not found.
    pub fn get(self: *const HashIndex, key: []const u8) ?u32 {
        const hash = fnv1a(key);
        const mask = self.capacity - 1;
        var idx = @as(u32, @intCast(hash & mask));

        while (true) {
            const bucket = &self.buckets[idx];
            if (bucket.hash == EMPTY_HASH) return null; // Not found
            if (bucket.hash == hash and bucket.key_len == key.len) {
                if (keysEqual(bucket.key_ptr[0..bucket.key_len], key)) {
                    return bucket.value;
                }
            }
            idx = (idx + 1) & mask;
        }
    }

    /// Check if a key exists.
    pub fn contains(self: *const HashIndex, key: []const u8) bool {
        return self.get(key) != null;
    }

    /// Number of entries in the index.
    pub fn len(self: *const HashIndex) u32 {
        return self.count;
    }

    // ── Internal ──

    fn grow(self: *HashIndex) void {
        const new_cap = self.capacity * 2;
        const new_buckets = self.arena.allocSlice(Bucket, new_cap) orelse unreachable;
        for (new_buckets) |*b| {
            b.hash = EMPTY_HASH;
            b.value = 0;
            b.key_ptr = undefined;
            b.key_len = 0;
        }

        const new_mask = new_cap - 1;
        const old_buckets = self.buckets[0..self.capacity];

        // Rehash all existing entries into new table
        for (old_buckets) |*old| {
            if (old.hash == EMPTY_HASH) continue;

            var idx = @as(u32, @intCast(old.hash & new_mask));
            while (true) {
                if (new_buckets[idx].hash == EMPTY_HASH) {
                    new_buckets[idx] = old.*;
                    break;
                }
                idx = (idx + 1) & new_mask;
            }
        }

        // Old bucket array is abandoned in the arena (no free needed)
        self.buckets = new_buckets.ptr;
        self.capacity = new_cap;
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// FNV-1a Hash (64-bit)
// ══════════════════════════════════════════════════════════════════════════════

/// FNV-1a 64-bit hash. Fast, well-distributed, deterministic.
/// Never returns 0 (reserved as empty sentinel) — if the natural hash
/// is 0 we return 1 instead.
pub fn fnv1a(data: []const u8) u64 {
    const FNV_OFFSET: u64 = 0xcbf29ce484222325;
    const FNV_PRIME: u64 = 0x00000100000001B3;

    var hash: u64 = FNV_OFFSET;
    for (data) |byte| {
        hash ^= byte;
        hash *%= FNV_PRIME;
    }

    // Ensure non-zero (0 is our empty sentinel)
    return if (hash == 0) 1 else hash;
}

// ══════════════════════════════════════════════════════════════════════════════
// Helpers
// ══════════════════════════════════════════════════════════════════════════════

fn keysEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn nextPow2(v: u32) u32 {
    if (v == 0) return 1;
    var n = v - 1;
    n |= n >> 1;
    n |= n >> 2;
    n |= n >> 4;
    n |= n >> 8;
    n |= n >> 16;
    return n + 1;
}
