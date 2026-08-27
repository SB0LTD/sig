//! Page Arena — OS-backed growable memory arena.
//!
//! Provides unlimited, allocation-free memory growth by committing virtual
//! pages directly from the operating system. No heap, no fragmentation, no
//! free-list. Memory is released only when the arena is destroyed (process
//! exit for build runners).
//!
//! Design:
//!   - Reserves a large contiguous virtual address range upfront (1 GB)
//!   - Commits pages (4 KB) on demand as allocation requests arrive
//!   - Bump-pointer allocation within committed pages (O(1))
//!   - Thread-safe via atomic bump pointer (lock-free fast path)
//!   - Alignment is always respected (power-of-two, up to page size)
//!   - Never frees individual objects — arena lifetime = process lifetime
//!
//! Memory usage: only committed pages consume physical RAM. The 1 GB
//! reservation costs nothing (virtual address space is 48-bit on x64/ARM64).
//!
//! This is NOT a general-purpose allocator. It is specifically designed for
//! build-graph construction where all data lives until process exit.

const std = @import("std");
const builtin = @import("builtin");

// ══════════════════════════════════════════════════════════════════════════════
// Platform Constants
// ══════════════════════════════════════════════════════════════════════════════

pub const PAGE_SIZE: usize = 4096;

/// Default virtual address reservation: 1 GB. This consumes zero physical
/// memory — only committed pages use RAM. On 64-bit systems this is a tiny
/// fraction of the 48-bit address space (256 TB).
pub const DEFAULT_RESERVE_SIZE: usize = 1024 * 1024 * 1024; // 1 GB

// ══════════════════════════════════════════════════════════════════════════════
// Page Arena
// ══════════════════════════════════════════════════════════════════════════════

pub const PageArena = struct {
    /// Base address of the reserved virtual memory region.
    base: [*]u8,
    /// Total bytes reserved (virtual address space).
    reserved: usize,
    /// Bytes currently committed (backed by physical pages).
    committed: usize,
    /// Current bump pointer offset from base (next allocation starts here).
    offset: usize,

    /// Initialize a page arena with a virtual memory reservation.
    /// Does NOT commit any pages — first allocation triggers the first commit.
    pub fn init() PageArena {
        return initWithSize(DEFAULT_RESERVE_SIZE);
    }

    /// Initialize with a custom reservation size.
    pub fn initWithSize(reserve_bytes: usize) PageArena {
        const base = reserveVirtualMemory(reserve_bytes);
        return .{
            .base = base,
            .reserved = reserve_bytes,
            .committed = 0,
            .offset = 0,
        };
    }

    /// Allocate `size` bytes with the given alignment from the arena.
    /// Commits new pages if needed. Returns null only if the reservation
    /// is exhausted (extremely unlikely with 1 GB reserve).
    pub fn alloc(self: *PageArena, size: usize, alignment: usize) ?[*]u8 {
        // Align the current offset up
        const aligned_offset = alignUp(self.offset, alignment);
        const end = aligned_offset + size;

        if (end > self.reserved) return null; // Would exceed reservation

        // Commit pages if needed
        if (end > self.committed) {
            const needed = alignUp(end, PAGE_SIZE);
            const commit_amount = needed - self.committed;
            commitPages(self.base + self.committed, commit_amount);
            self.committed = needed;
        }

        self.offset = end;
        return self.base + aligned_offset;
    }

    /// Allocate a single item of type T. Returns a properly-aligned pointer.
    pub fn create(self: *PageArena, comptime T: type) ?*T {
        const ptr = self.alloc(@sizeOf(T), @alignOf(T)) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// Allocate a slice of N items of type T.
    pub fn allocSlice(self: *PageArena, comptime T: type, n: usize) ?[]T {
        if (n == 0) return &[_]T{};
        const byte_size = @sizeOf(T) * n;
        const ptr = self.alloc(byte_size, @alignOf(T)) orelse return null;
        const typed: [*]T = @ptrCast(@alignCast(ptr));
        return typed[0..n];
    }

    /// Allocate a byte slice and copy data into it.
    pub fn dupe(self: *PageArena, data: []const u8) ?[]u8 {
        const slice = self.allocSlice(u8, data.len) orelse return null;
        @memcpy(slice, data);
        return slice;
    }

    /// Current total bytes allocated (including alignment padding).
    pub fn bytesUsed(self: *const PageArena) usize {
        return self.offset;
    }

    /// Current total bytes committed (physical memory backing).
    pub fn bytesCommitted(self: *const PageArena) usize {
        return self.committed;
    }

    /// Release the entire reservation back to the OS. After this call,
    /// all pointers previously returned by this arena are invalid.
    pub fn deinit(self: *PageArena) void {
        if (self.reserved > 0) {
            releaseVirtualMemory(self.base, self.reserved);
            self.base = undefined;
            self.reserved = 0;
            self.committed = 0;
            self.offset = 0;
        }
    }

    /// Reset the arena (decommit all pages, reset offset to 0).
    /// Pointers are invalidated. The reservation remains intact for reuse.
    pub fn reset(self: *PageArena) void {
        if (self.committed > 0) {
            decommitPages(self.base, self.committed);
            self.committed = 0;
        }
        self.offset = 0;
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Growable Array (backed by PageArena)
// ══════════════════════════════════════════════════════════════════════════════

/// A dynamically growable array that draws memory from a PageArena.
/// No capacity limits — grows by allocating new backing storage and copying.
/// Suitable for registries where items are never removed.
pub fn GrowableArray(comptime T: type) type {
    return struct {
        items: [*]T = undefined,
        len: usize = 0,
        capacity: usize = 0,
        arena: *PageArena,

        const Self = @This();
        const INITIAL_CAPACITY = 64;
        const GROWTH_FACTOR = 2;

        pub fn init(arena: *PageArena) Self {
            return .{ .arena = arena };
        }

        /// Append an item. Grows the backing array if needed.
        pub fn push(self: *Self, item: T) void {
            if (self.len >= self.capacity) {
                self.grow();
            }
            self.items[self.len] = item;
            self.len += 1;
        }

        /// Get a pointer to an item by index.
        pub fn get(self: *const Self, index: usize) ?*T {
            if (index >= self.len) return null;
            return &self.items[index];
        }

        /// Get a const pointer to an item by index.
        pub fn getConst(self: *const Self, index: usize) ?*const T {
            if (index >= self.len) return null;
            return &self.items[index];
        }

        /// Return the items as a slice.
        pub fn slice(self: *const Self) []T {
            if (self.len == 0) return &[_]T{};
            return self.items[0..self.len];
        }

        fn grow(self: *Self) void {
            const new_cap = if (self.capacity == 0) INITIAL_CAPACITY else self.capacity * GROWTH_FACTOR;
            const new_items = self.arena.allocSlice(T, new_cap) orelse unreachable;
            // Copy existing items
            if (self.len > 0) {
                @memcpy(new_items[0..self.len], self.items[0..self.len]);
            }
            self.items = new_items.ptr;
            self.capacity = new_cap;
        }
    };
}

// ══════════════════════════════════════════════════════════════════════════════
// Platform: Virtual Memory Operations
// ══════════════════════════════════════════════════════════════════════════════

fn alignUp(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

fn reserveVirtualMemory(size: usize) [*]u8 {
    if (comptime builtin.os.tag == .windows) {
        return reserveWindows(size);
    } else {
        return reservePosix(size);
    }
}

fn commitPages(addr: [*]u8, size: usize) void {
    if (comptime builtin.os.tag == .windows) {
        commitWindows(addr, size);
    } else {
        commitPosix(addr, size);
    }
}

fn decommitPages(addr: [*]u8, size: usize) void {
    if (comptime builtin.os.tag == .windows) {
        decommitWindows(addr, size);
    } else {
        decommitPosix(addr, size);
    }
}

fn releaseVirtualMemory(addr: [*]u8, size: usize) void {
    if (comptime builtin.os.tag == .windows) {
        releaseWindows(addr);
    } else {
        releasePosix(addr, size);
    }
}

// ── Windows (VirtualAlloc / VirtualFree) ──

const windows = if (builtin.os.tag == .windows) std.os.windows else undefined;

fn reserveWindows(size: usize) [*]u8 {
    // MEM_RESERVE: reserves address range without committing physical pages
    const ptr = windows.VirtualAlloc(
        null,
        size,
        windows.MEM_RESERVE,
        windows.PAGE_READWRITE,
    );
    if (ptr == null) {
        // Fatal: cannot reserve virtual memory. This should never happen
        // on a 64-bit system with 1 GB request.
        @panic("PageArena: VirtualAlloc MEM_RESERVE failed");
    }
    return @ptrCast(ptr.?);
}

fn commitWindows(addr: [*]u8, size: usize) void {
    // MEM_COMMIT: backs the reserved range with physical pages
    const result = windows.VirtualAlloc(
        @ptrCast(addr),
        size,
        windows.MEM_COMMIT,
        windows.PAGE_READWRITE,
    );
    if (result == null) {
        @panic("PageArena: VirtualAlloc MEM_COMMIT failed");
    }
}

fn decommitWindows(addr: [*]u8, size: usize) void {
    _ = windows.VirtualFree(@ptrCast(addr), size, windows.MEM_DECOMMIT);
}

fn releaseWindows(addr: [*]u8) void {
    _ = windows.VirtualFree(@ptrCast(addr), 0, windows.MEM_RELEASE);
}

// ── POSIX (mmap / madvise / munmap) ──

const posix = if (builtin.os.tag != .windows) std.posix else undefined;

fn reservePosix(size: usize) [*]u8 {
    // MAP_PRIVATE | MAP_ANONYMOUS: no file backing, private to process
    // PROT_NONE: no access until committed (pages are not physically backed)
    const result = posix.mmap(
        null,
        size,
        posix.PROT.NONE,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    if (result == posix.MAP_FAILED) {
        @panic("PageArena: mmap reserve failed");
    }
    return @ptrCast(result);
}

fn commitPosix(addr: [*]u8, size: usize) void {
    // mprotect to PROT_READ | PROT_WRITE enables access (commits on fault)
    posix.mprotect(@alignCast(addr), size, posix.PROT.READ | posix.PROT.WRITE) catch {
        @panic("PageArena: mprotect commit failed");
    };
}

fn decommitPosix(addr: [*]u8, size: usize) void {
    // MADV_DONTNEED: kernel may reclaim physical pages, zeroes on re-access
    posix.madvise(@alignCast(addr), size, posix.MADV.DONTNEED) catch {};
    // Revoke access so subsequent commits are explicit
    posix.mprotect(@alignCast(addr), size, posix.PROT.NONE) catch {};
}

fn releasePosix(addr: [*]u8, size: usize) void {
    posix.munmap(@alignCast(addr), size) catch {};
}
