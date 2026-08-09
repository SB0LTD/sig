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
    };
}

// ============================================================================
// FixedPool(T, capacity) — Fixed-capacity object pool with free-list
// ============================================================================

/// Fixed-capacity object pool using an intrusive free-list.
/// Slots are pre-allocated at comptime size. `alloc()` returns the next
/// free slot; `free()` returns a slot to the free list. O(1) alloc/free.
pub fn FixedPool(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        /// Storage for pooled objects.
        slots: [capacity]T = undefined,
        /// Free-list: each entry holds the index of the next free slot.
        /// A value of `capacity` means "end of free list".
        free_list: [capacity]u32 = init_free_list(),
        /// Head of the free list (index of next available slot).
        free_head: u32 = 0,
        /// Number of currently allocated slots.
        allocated: usize = 0,

        fn init_free_list() [capacity]u32 {
            var list: [capacity]u32 = undefined;
            for (0..capacity) |i| {
                list[i] = @intCast(i + 1);
            }
            return list;
        }

        /// Allocate a slot from the pool.
        /// Returns a pointer to the slot, or null if the pool is full.
        pub fn alloc(self: *Self) ?*T {
            if (self.free_head >= capacity) return null;
            const idx = self.free_head;
            self.free_head = self.free_list[idx];
            self.allocated += 1;
            return &self.slots[idx];
        }

        /// Free a previously allocated slot, returning it to the free list.
        pub fn free(self: *Self, ptr: *T) void {
            const addr = @intFromPtr(ptr);
            const base = @intFromPtr(&self.slots[0]);
            const idx: u32 = @intCast((addr - base) / @sizeOf(T));
            self.free_list[idx] = self.free_head;
            self.free_head = idx;
            self.allocated -= 1;
        }

        /// Returns the number of currently allocated slots.
        pub fn count(self: *const Self) usize {
            return self.allocated;
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
            // FNV-1a style hash for integer keys
            if (K == u64) {
                var h: u64 = 14695981039346656037;
                const bytes = @as([8]u8, @bitCast(key));
                for (bytes) |b| {
                    h ^= b;
                    h *%= 1099511628211;
                }
                return @intCast(h & (bucket_count - 1));
            }
            // Fallback: treat as raw bytes
            const bytes = @as([@sizeOf(K)]u8, @bitCast(key));
            var h: u64 = 14695981039346656037;
            for (bytes) |b| {
                h ^= b;
                h *%= 1099511628211;
            }
            return @intCast(h & (bucket_count - 1));
        }

        fn keysEqual(self: *const Self, a: K, b: K) bool {
            _ = self;
            if (K == u64) return a == b;
            // Fallback: byte comparison
            const a_bytes = @as([@sizeOf(K)]u8, @bitCast(a));
            const b_bytes = @as([@sizeOf(K)]u8, @bitCast(b));
            for (a_bytes, b_bytes) |ab, bb| {
                if (ab != bb) return false;
            }
            return true;
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
            const a_bytes = @as([@sizeOf(T)]u8, @bitCast(a));
            const b_bytes = @as([@sizeOf(T)]u8, @bitCast(b));
            for (a_bytes, b_bytes) |ab, bb| {
                if (ab != bb) return false;
            }
            return true;
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

test "RingBuffer push/pop basic" {
    var rb: RingBuffer(u32, 4) = .{};
    if (!rb.isEmpty()) @compileError("new ring should be empty");
    rb.push(10);
    rb.push(20);
    rb.push(30);
    if (rb.len() != 3) @compileError("expected len 3");
    if (rb.pop().? != 10) @compileError("expected 10");
    if (rb.pop().? != 20) @compileError("expected 20");
    if (rb.pop().? != 30) @compileError("expected 30");
    if (rb.pop() != null) @compileError("expected null");
}

test "RingBuffer overwrite when full" {
    var rb: RingBuffer(u32, 2) = .{};
    rb.push(1);
    rb.push(2);
    if (!rb.isFull()) @compileError("should be full");
    rb.push(3); // overwrites 1
    if (rb.pop().? != 2) @compileError("expected 2 after overwrite");
    if (rb.pop().? != 3) @compileError("expected 3 after overwrite");
}

test "BoundedVec append and get" {
    var v: BoundedVec(u32, 4) = .{};
    v.append(100) catch @compileError("unexpected overflow");
    v.append(200) catch @compileError("unexpected overflow");
    if (v.get(0) != 100) @compileError("expected 100");
    if (v.get(1) != 200) @compileError("expected 200");
    if (v.len() != 2) @compileError("expected len 2");
    v.clear();
    if (v.len() != 0) @compileError("expected len 0 after clear");
}

test "BoundedBitSet basic operations" {
    var bs: BoundedBitSet(128) = .{};
    bs.set(0);
    bs.set(64);
    bs.set(127);
    if (!bs.isSet(0)) @compileError("bit 0 should be set");
    if (!bs.isSet(64)) @compileError("bit 64 should be set");
    if (!bs.isSet(127)) @compileError("bit 127 should be set");
    if (bs.isSet(1)) @compileError("bit 1 should not be set");
    if (bs.count() != 3) @compileError("expected popcount 3");
    if (bs.findFirstSet().? != 0) @compileError("first set should be 0");
    bs.clear(0);
    if (bs.findFirstSet().? != 64) @compileError("first set should be 64 after clear(0)");
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
    if (map.entry_count > 4) @compileError("entry_count should never exceed max_entries");
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
    if (map.get(2) != null) @compileError("key 2 should be evicted (LRU)");
    // Key 1 should still be present (was accessed recently)
    if (map.get(1) == null) @compileError("key 1 should survive (recently accessed)");
}

test "RingBuffer len never exceeds capacity" {
    var rb: RingBuffer(u32, 4) = .{};
    rb.push(1);
    rb.push(2);
    rb.push(3);
    rb.push(4);
    rb.push(5); // overwrite
    if (rb.len() > 4) @compileError("RingBuffer len should never exceed capacity");
}

test "Intern_Pool count never exceeds capacity" {
    var pool: Intern_Pool(u64, 4) = .{};
    _ = pool.intern(10);
    _ = pool.intern(20);
    _ = pool.intern(30);
    _ = pool.intern(40);
    _ = pool.intern(50); // should evict LRU
    if (pool.entry_count > 4) @compileError("Intern_Pool should never exceed capacity");
}
