// Zero-Alloc Compiler — Container Specializations
//
// Layer 0: Core Types & Containers
//
// Self-contained, comptime-parameterized container implementations for the
// zero-alloc compiler pipeline. Each container has a fixed capacity determined
// at compile time — zero heap allocation. LRU eviction policies ensure the
// compiler can process arbitrarily large inputs within bounded memory.
//
// No external library dependencies — fully standalone implementations.

const Compiler_Capacity_Plan = @import("capacity.sig").Compiler_Capacity_Plan;
const types = @import("types.sig");
const Token = types.Token;
const AST_Node = types.AST_Node;
const Source_Loc = types.Source_Loc;
const Symbol_Entry = types.Symbol_Entry;
const Type_Descriptor = types.Type_Descriptor;
const Relocation = types.Relocation;

// ============================================================================
// Diagnostic_Entry
// ============================================================================

/// A diagnostic message produced by any compiler phase.
pub const Diagnostic_Entry = struct {
    file_path: [256]u8 = undefined,
    file_path_len: usize = 0,
    line: u32 = 0,
    column: u32 = 0,
    severity: Severity = .@"error",
    message: [512]u8 = undefined,
    message_len: usize = 0,

    pub const Severity = enum { @"error", warning, note };
};

// ============================================================================
// RingBuffer(T, capacity) — Fixed-capacity circular buffer
// ============================================================================

/// Fixed-capacity circular buffer with head/tail indices.
/// When full, `push` overwrites the oldest entry (head advances).
/// Capacity must be a power of 2 for efficient modular arithmetic.
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buf: [capacity]T = undefined,
        head: usize = 0, // read position (oldest item)
        tail: usize = 0, // write position (next insert)
        count: usize = 0,

        /// Push an item into the ring buffer.
        /// If full, overwrites the oldest entry (advances head).
        pub fn push(self: *Self, item: T) void {
            self.buf[self.tail & (capacity - 1)] = item;
            self.tail +%= 1;
            if (self.count == capacity) {
                // Overwrite oldest — advance head
                self.head +%= 1;
            } else {
                self.count += 1;
            }
        }

        /// Pop the oldest item from the ring buffer.
        /// Returns null if empty.
        pub fn pop(self: *Self) ?T {
            if (self.count == 0) return null;
            const item = self.buf[self.head & (capacity - 1)];
            self.head +%= 1;
            self.count -= 1;
            return item;
        }

        /// Returns true if the buffer is at capacity.
        pub fn isFull(self: *const Self) bool {
            return self.count == capacity;
        }

        /// Returns true if the buffer is empty.
        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }

        /// Returns the number of items currently stored.
        pub fn len(self: *const Self) usize {
            return self.count;
        }

        /// Reset logical state without touching unused fixed-capacity storage.
        pub fn reset(self: *Self) void {
            self.head = 0;
            self.tail = 0;
            self.count = 0;
        }
    };
}

// ============================================================================
// FixedPool(T, capacity) — Fixed-capacity object pool with free-list
// ============================================================================

/// Fixed-capacity object pool using a bump cursor plus a stack of recycled
/// indices. Slots are pre-allocated at comptime size. Both `alloc()` and
/// `free()` are O(1), and initialization is O(1) regardless of capacity.
pub fn FixedPool(comptime T: type, comptime capacity: usize) type {
    comptime {
        if (capacity == 0) @compileError("FixedPool capacity must be non-zero");
        if (capacity > @as(usize, ~@as(u32, 0))) @compileError("FixedPool capacity exceeds its u32 index space");
    }
    return struct {
        const Self = @This();

        /// Storage for pooled objects.
        slots: [capacity]T = undefined,
        /// Stack of indices returned by `free`. Contents above `free_count`
        /// are deliberately undefined and never inspected.
        free_indices: [capacity]u32 = undefined,
        /// Number of valid entries in `free_indices`.
        free_count: usize = 0,
        /// First slot that has never been allocated.
        next_uninitialized: usize = 0,
        /// Number of currently allocated slots.
        allocated: usize = 0,

        /// Allocate a slot from the pool.
        /// Returns a pointer to the slot, or null if the pool is full.
        pub fn alloc(self: *Self) ?*T {
            const idx = if (self.free_count > 0) blk: {
                self.free_count -= 1;
                break :blk self.free_indices[self.free_count];
            } else blk: {
                if (self.next_uninitialized >= capacity) return null;
                const fresh = self.next_uninitialized;
                self.next_uninitialized += 1;
                break :blk fresh;
            };
            self.allocated += 1;
            return &self.slots[idx];
        }

        /// Free a previously allocated slot, returning it to the free list.
        pub fn free(self: *Self, ptr: *T) void {
            const addr = @intFromPtr(ptr);
            const base = @intFromPtr(&self.slots[0]);
            const idx: u32 = @intCast((addr - base) / @sizeOf(T));
            self.free_indices[self.free_count] = idx;
            self.free_count += 1;
            self.allocated -= 1;
        }

        /// Returns the number of currently allocated slots.
        pub fn count(self: *const Self) usize {
            return self.allocated;
        }

        /// Reset logical state without materializing or clearing slot storage.
        pub fn reset(self: *Self) void {
            self.free_count = 0;
            self.next_uninitialized = 0;
            self.allocated = 0;
        }
    };
}

// ============================================================================
// BoundedVec(T, capacity) — Fixed-capacity dynamic array
// ============================================================================

/// Fixed-capacity dynamic array. Appends up to `capacity` items.
/// Returns an error if attempting to append beyond capacity.
pub fn BoundedVec(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const Error = error{Overflow};

        buf: [capacity]T = undefined,
        size: usize = 0,

        /// Append an item to the end of the vector.
        /// Returns error.Overflow if at capacity.
        pub fn append(self: *Self, item: T) Error!void {
            if (self.size >= capacity) return error.Overflow;
            self.buf[self.size] = item;
            self.size += 1;
        }

        /// Get the item at the given index.
        pub fn get(self: *const Self, index: usize) T {
            return self.buf[index];
        }

        /// Set the item at the given index.
        pub fn set(self: *Self, index: usize, value: T) void {
            self.buf[index] = value;
        }

        /// Returns the number of items currently stored.
        pub fn len(self: *const Self) usize {
            return self.size;
        }

        /// Clear all items (reset length to zero).
        pub fn clear(self: *Self) void {
            self.size = 0;
        }
    };
}

// ============================================================================
// Fixed_Hash_Map(K, V, bucket_count, max_entries) — Open-addressing hash map
// with LRU eviction
// ============================================================================

/// Fixed-capacity open-addressing hash map with LRU eviction.
/// Uses linear probing. When at `max_entries`, the entry with the lowest
/// `last_accessed` timestamp is evicted before inserting a new key.
///
/// K must be a type that can be hashed via `hashKey`. Currently supports
/// u64 keys directly; extend `hashKey` for other types.
pub fn Fixed_Hash_Map(comptime K: type, comptime V: type, comptime bucket_count: usize, comptime max_entries: usize) type {
    comptime {
        if (K != u64) @compileError("Fixed_Hash_Map currently requires u64 keys");
        if (bucket_count == 0 or bucket_count & (bucket_count - 1) != 0)
            @compileError("Fixed_Hash_Map bucket_count must be a non-zero power of two");
        if (max_entries == 0 or max_entries > bucket_count)
            @compileError("Fixed_Hash_Map max_entries must be in 1..bucket_count");
    }
    return struct {
        const Self = @This();

        const Entry = struct {
            key: K = undefined,
            value: V = undefined,
            occupied: bool = false,
            last_accessed: u32 = 0,
        };

        buckets: [bucket_count]Entry = @splat(.{}),
        entry_count: usize = 0,
        timestamp: u32 = 1,

        /// Insert or update a key-value pair.
        /// If at max_entries and key is new, evicts the LRU entry first.
        pub fn put(self: *Self, key: K, value: V) void {
            // Try to find existing entry
            const hash = self.hashKey(key);
            var idx = hash & (bucket_count - 1);
            var probe: usize = 0;
            while (probe < bucket_count) : (probe += 1) {
                const i = (idx + probe) & (bucket_count - 1);
                if (!self.buckets[i].occupied) break;
                if (self.keysEqual(self.buckets[i].key, key)) {
                    // Update existing
                    self.buckets[i].value = value;
                    self.buckets[i].last_accessed = self.timestamp;
                    self.timestamp +%= 1;
                    return;
                }
            }

            // New entry — evict LRU if at capacity
            if (self.entry_count >= max_entries) {
                self.evictLru();
            }

            // Insert into first empty bucket
            idx = hash & (bucket_count - 1);
            probe = 0;
            while (probe < bucket_count) : (probe += 1) {
                const i = (idx + probe) & (bucket_count - 1);
                if (!self.buckets[i].occupied) {
                    self.buckets[i] = .{
                        .key = key,
                        .value = value,
                        .occupied = true,
                        .last_accessed = self.timestamp,
                    };
                    self.timestamp +%= 1;
                    self.entry_count += 1;
                    return;
                }
            }
        }

        /// Look up a key. Returns a pointer to the value if found, null otherwise.
        /// Updates the LRU timestamp on access.
        pub fn get(self: *Self, key: K) ?*V {
            const hash = self.hashKey(key);
            var probe: usize = 0;
            while (probe < bucket_count) : (probe += 1) {
                const i = (hash + probe) & (bucket_count - 1);
                if (!self.buckets[i].occupied) return null;
                if (self.keysEqual(self.buckets[i].key, key)) {
                    self.buckets[i].last_accessed = self.timestamp;
                    self.timestamp +%= 1;
                    return &self.buckets[i].value;
                }
            }
            return null;
        }

        /// Remove an entry by key. Returns true if the key was found and removed.
        pub fn remove(self: *Self, key: K) bool {
            const hash = self.hashKey(key);
            var probe: usize = 0;
            while (probe < bucket_count) : (probe += 1) {
                const i = (hash + probe) & (bucket_count - 1);
                if (!self.buckets[i].occupied) return false;
                if (self.keysEqual(self.buckets[i].key, key)) {
                    self.buckets[i].occupied = false;
                    self.entry_count -= 1;
                    // Rehash subsequent entries in the probe chain
                    self.rehashFrom(i);
                    return true;
                }
            }
            return false;
        }

        /// Remove every live entry while leaving undefined key/value bytes
        /// untouched. This avoids embedding a multi-megabyte zero template in
        /// native compiler images.
        pub fn clear(self: *Self) void {
            for (&self.buckets) |*entry| entry.occupied = false;
            self.entry_count = 0;
            self.timestamp = 1;
        }

        /// Evict the entry with the lowest last_accessed timestamp.
        fn evictLru(self: *Self) void {
            var min_ts: u32 = ~@as(u32, 0);
            var min_idx: usize = 0;
            for (0..bucket_count) |i| {
                if (self.buckets[i].occupied and self.buckets[i].last_accessed < min_ts) {
                    min_ts = self.buckets[i].last_accessed;
                    min_idx = i;
                }
            }
            self.buckets[min_idx].occupied = false;
            self.entry_count -= 1;
            self.rehashFrom(min_idx);
        }

        /// Rehash entries after a deletion to maintain probe chain integrity.
        fn rehashFrom(self: *Self, deleted_idx: usize) void {
            var i = (deleted_idx + 1) & (bucket_count - 1);
            while (self.buckets[i].occupied) {
                const entry = self.buckets[i];
                self.buckets[i].occupied = false;
                self.entry_count -= 1;
                // Re-insert
                self.put(entry.key, entry.value);
                // Restore the timestamp (put increments it)
                const hash = self.hashKey(entry.key);
                var probe: usize = 0;
                while (probe < bucket_count) : (probe += 1) {
                    const j = (hash + probe) & (bucket_count - 1);
                    if (self.buckets[j].occupied and self.keysEqual(self.buckets[j].key, entry.key)) {
                        self.buckets[j].last_accessed = entry.last_accessed;
                        break;
                    }
                }
                i = (i + 1) & (bucket_count - 1);
                if (i == deleted_idx) break;
            }
        }

        fn hashKey(self: *const Self, key: K) usize {
            _ = self;
            // FNV-1a over the complete u64 key representation.
            const bytes = @as([8]u8, @bitCast(key));
            var h: u64 = 14695981039346656037;
            for (bytes) |b| {
                h ^= b;
                h *%= 1099511628211;
            }
            return @intCast(h & (bucket_count - 1));
        }

        fn keysEqual(self: *const Self, a: K, b: K) bool {
            _ = self;
            return a == b;
        }
    };
}

// ============================================================================
// Intern_Pool(T, capacity) — Deduplication pool with LRU eviction
// ============================================================================

/// Fixed-capacity deduplication pool. Stores unique values and returns
/// stable indices. When full, evicts the least-recently-accessed entry.
/// Uses linear search for deduplication (suitable for comptime-bounded sizes).
pub fn Intern_Pool(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        const Entry = struct {
            value: T = undefined,
            occupied: bool = false,
            last_accessed: u32 = 0,
        };

        entries: [capacity]Entry = @splat(.{}),
        entry_count: usize = 0,
        timestamp: u32 = 1,

        /// Intern a value: returns the index of an existing match, or inserts
        /// a new entry. If at capacity, evicts the LRU entry first.
        pub fn intern(self: *Self, value: T) u32 {
            // Search for existing match
            for (0..capacity) |i| {
                if (self.entries[i].occupied and self.valuesEqual(self.entries[i].value, value)) {
                    self.entries[i].last_accessed = self.timestamp;
                    self.timestamp +%= 1;
                    return @intCast(i);
                }
            }

            // Not found — evict if full
            if (self.entry_count >= capacity) {
                const evict_idx = self.findLru();
                self.entries[evict_idx] = .{
                    .value = value,
                    .occupied = true,
                    .last_accessed = self.timestamp,
                };
                self.timestamp +%= 1;
                return @intCast(evict_idx);
            }

            // Find first empty slot
            for (0..capacity) |i| {
                if (!self.entries[i].occupied) {
                    self.entries[i] = .{
                        .value = value,
                        .occupied = true,
                        .last_accessed = self.timestamp,
                    };
                    self.timestamp +%= 1;
                    self.entry_count += 1;
                    return @intCast(i);
                }
            }

            // Should not reach here if entry_count < capacity
            unreachable;
        }

        /// Retrieve a value by index.
        pub fn get(self: *const Self, index: u32) *const T {
            return &self.entries[index].value;
        }

        /// Remove every interned value without clearing unused payload bytes.
        pub fn clear(self: *Self) void {
            for (&self.entries) |*entry| entry.occupied = false;
            self.entry_count = 0;
            self.timestamp = 1;
        }

        /// Find the index of the entry with the lowest last_accessed timestamp.
        fn findLru(self: *const Self) usize {
            var min_ts: u32 = ~@as(u32, 0);
            var min_idx: usize = 0;
            for (0..capacity) |i| {
                if (self.entries[i].occupied and self.entries[i].last_accessed < min_ts) {
                    min_ts = self.entries[i].last_accessed;
                    min_idx = i;
                }
            }
            return min_idx;
        }

        fn valuesEqual(self: *const Self, a: T, b: T) bool {
            _ = self;
            if (T == u64) return a == b;
            if (T == Type_Descriptor) return Type_Descriptor.eql(a, b);
            @compileError("Intern_Pool requires an explicit semantic equality implementation for this type");
        }
    };
}

// ============================================================================
// BoundedBitSet(capacity) — Fixed-capacity bit set
// ============================================================================

/// Fixed-capacity bit set backed by an array of usize words.
/// Supports set, clear, test, population count, and find-first-set.
pub fn BoundedBitSet(comptime capacity: usize) type {
    const word_bits = @bitSizeOf(usize);
    const word_count = (capacity + word_bits - 1) / word_bits;

    return struct {
        const Self = @This();

        words: [word_count]usize = @splat(0),

        /// Set the bit at the given index.
        pub fn set(self: *Self, index: usize) void {
            const word_idx = index / word_bits;
            const bit_idx: u6 = @intCast(index % word_bits);
            self.words[word_idx] |= @as(usize, 1) << bit_idx;
        }

        /// Clear the bit at the given index.
        pub fn clear(self: *Self, index: usize) void {
            const word_idx = index / word_bits;
            const bit_idx: u6 = @intCast(index % word_bits);
            self.words[word_idx] &= ~(@as(usize, 1) << bit_idx);
        }

        /// Test whether the bit at the given index is set.
        pub fn isSet(self: *const Self, index: usize) bool {
            const word_idx = index / word_bits;
            const bit_idx: u6 = @intCast(index % word_bits);
            return (self.words[word_idx] & (@as(usize, 1) << bit_idx)) != 0;
        }

        /// Returns the population count (number of set bits).
        pub fn count(self: *const Self) usize {
            var total: usize = 0;
            for (self.words) |word| {
                total += @popCount(word);
            }
            return total;
        }

        /// Find the index of the first set bit. Returns null if no bits are set.
        pub fn findFirstSet(self: *const Self) ?usize {
            for (0..word_count) |w| {
                if (self.words[w] != 0) {
                    const bit: usize = @ctz(self.words[w]);
                    const result = w * word_bits + bit;
                    if (result < capacity) return result;
                }
            }
            return null;
        }

        pub fn clearAll(self: *Self) void {
            @memset(&self.words, 0);
        }
    };
}

// ============================================================================
// Type Aliases — Compiler-specific instantiations using Compiler_Capacity_Plan
// ============================================================================

pub const TokenRing = RingBuffer(Token, Compiler_Capacity_Plan.TOKEN_RING_CAPACITY);
pub const AstNodePool = FixedPool(AST_Node, Compiler_Capacity_Plan.AST_NODE_POOL_CAPACITY);
pub const SourceMapVec = BoundedVec(Source_Loc, Compiler_Capacity_Plan.SOURCE_MAP_CAPACITY);
pub const SymbolTable = Fixed_Hash_Map(u64, Symbol_Entry, Compiler_Capacity_Plan.SYMBOL_BUCKETS, Compiler_Capacity_Plan.SYMBOL_TABLE_CAPACITY);
pub const TypePool = Intern_Pool(Type_Descriptor, Compiler_Capacity_Plan.TYPE_INTERN_CAPACITY);
pub const AstBitSet = BoundedBitSet(Compiler_Capacity_Plan.AST_NODE_POOL_CAPACITY);
pub const RelocationVec = BoundedVec(Relocation, Compiler_Capacity_Plan.RELOCATION_TABLE_CAPACITY);
pub const DiagnosticRing = RingBuffer(Diagnostic_Entry, Compiler_Capacity_Plan.DIAGNOSTIC_RING_CAPACITY);
pub const CodegenRing = RingBuffer(u8, Compiler_Capacity_Plan.CODEGEN_RING_CAPACITY);

// ============================================================================
// Tests
// ============================================================================

const testing = @import("std").testing;

test "RingBuffer push/pop basic" {
    var rb: RingBuffer(u32, 4) = .{};
    try testing.expect(!(!rb.isEmpty())); // new ring should be empty
    rb.push(10);
    rb.push(20);
    rb.push(30);
    try testing.expect(!(rb.len() != 3)); // expected len 3
    try testing.expect(!(rb.pop().? != 10)); // expected 10
    try testing.expect(!(rb.pop().? != 20)); // expected 20
    try testing.expect(!(rb.pop().? != 30)); // expected 30
    try testing.expect(!(rb.pop() != null)); // expected null
    rb.push(40);
    rb.reset();
    try testing.expect(rb.isEmpty());
}

test "RingBuffer overwrite when full" {
    var rb: RingBuffer(u32, 2) = .{};
    rb.push(1);
    rb.push(2);
    try testing.expect(!(!rb.isFull())); // should be full
    rb.push(3); // overwrites 1
    try testing.expect(!(rb.pop().? != 2)); // expected 2 after overwrite
    try testing.expect(!(rb.pop().? != 3)); // expected 3 after overwrite
}

test "BoundedVec append and get" {
    var v: BoundedVec(u32, 4) = .{};
    try v.append(100); // unexpected overflow
    try v.append(200); // unexpected overflow
    try testing.expect(!(v.get(0) != 100)); // expected 100
    try testing.expect(!(v.get(1) != 200)); // expected 200
    try testing.expect(!(v.len() != 2)); // expected len 2
    v.clear();
    try testing.expect(!(v.len() != 0)); // expected len 0 after clear
}

test "FixedPool exhausts and recycles in constant time" {
    var pool: FixedPool(u32, 2) = .{};
    const first = pool.alloc().?;
    const second = pool.alloc().?;
    try testing.expect(pool.alloc() == null);
    first.* = 41;
    second.* = 42;
    pool.free(first);
    try testing.expect(pool.count() == 1);
    const recycled = pool.alloc().?;
    try testing.expect(@intFromPtr(recycled) == @intFromPtr(first));
    try testing.expect(pool.count() == 2);
    pool.reset();
    try testing.expect(pool.count() == 0);
    try testing.expect(@intFromPtr(pool.alloc().?) == @intFromPtr(first));
}

test "BoundedBitSet basic operations" {
    var bs: BoundedBitSet(128) = .{};
    bs.set(0);
    bs.set(64);
    bs.set(127);
    try testing.expect(!(!bs.isSet(0))); // bit 0 should be set
    try testing.expect(!(!bs.isSet(64))); // bit 64 should be set
    try testing.expect(!(!bs.isSet(127))); // bit 127 should be set
    try testing.expect(!(bs.isSet(1))); // bit 1 should not be set
    try testing.expect(!(bs.count() != 3)); // expected popcount 3
    try testing.expect(!(bs.findFirstSet().? != 0)); // first set should be 0
    bs.clear(0);
    try testing.expect(!(bs.findFirstSet().? != 64)); // first set should be 64 after clear(0)
    bs.clearAll();
    try testing.expect(bs.findFirstSet() == null);
}

// ============================================================================
// Property Tests — Eviction Capacity Invariant (Property 1)
// **Validates: Requirements 1.4, 3.3, 4.4, 6.7**
// ============================================================================

test "Fixed_Hash_Map capacity invariant after many puts" {
    // Insert more items than max_entries — eviction should keep count bounded
    var map: Fixed_Hash_Map(u64, u64, 8, 4) = .{};
    map.put(1, 100);
    map.put(2, 200);
    map.put(3, 300);
    map.put(4, 400);
    // At capacity (4 entries) — next put should evict
    map.put(5, 500);
    try testing.expect(!(map.entry_count > 4)); // entry_count should never exceed max_entries
    map.clear();
    try testing.expect(map.entry_count == 0);
    try testing.expect(map.get(5) == null);
}

test "Fixed_Hash_Map LRU eviction removes oldest entry" {
    var map: Fixed_Hash_Map(u64, u64, 8, 4) = .{};
    map.put(1, 100); // timestamp 1
    map.put(2, 200); // timestamp 2
    map.put(3, 300); // timestamp 3
    map.put(4, 400); // timestamp 4
    // Access key 1 to refresh it (makes it NOT the LRU)
    _ = map.get(1);
    // Insert 5 — should evict key 2 (oldest un-accessed)
    map.put(5, 500);
    // Key 2 should be evicted
    try testing.expect(!(map.get(2) != null)); // key 2 should be evicted (LRU)
    // Key 1 should still be present (was accessed recently)
    try testing.expect(!(map.get(1) == null)); // key 1 should survive (recently accessed)
}

test "Fixed_Hash_Map removal preserves a collision probe chain" {
    var map: Fixed_Hash_Map(u64, u64, 8, 4) = .{};
    // FNV-1a reduced to eight buckets depends on the low three key bits, so 0
    // and 8 collide. Removing the first must rehash and preserve the second.
    map.put(0, 100);
    map.put(8, 800);
    try testing.expect(map.remove(0));
    try testing.expect(map.get(8).?.* == 800);
}

test "RingBuffer len never exceeds capacity" {
    var rb: RingBuffer(u32, 4) = .{};
    rb.push(1);
    rb.push(2);
    rb.push(3);
    rb.push(4);
    rb.push(5); // overwrite
    try testing.expect(!(rb.len() > 4)); // RingBuffer len should never exceed capacity
}

test "Intern_Pool count never exceeds capacity" {
    var pool: Intern_Pool(u64, 4) = .{};
    _ = pool.intern(10);
    _ = pool.intern(20);
    _ = pool.intern(30);
    _ = pool.intern(40);
    _ = pool.intern(50); // should evict LRU
    try testing.expect(!(pool.entry_count > 4)); // Intern_Pool should never exceed capacity
    pool.clear();
    try testing.expect(pool.entry_count == 0);
}
