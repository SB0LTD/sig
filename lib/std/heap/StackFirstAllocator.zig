//! A "composite" allocator that attempts to allocate first on the stack, using
//! the provided FixedBufferAllocator; upon failure, the provided secondary
//! allocator is used.  reset() is NOT provided, even though available for the
//! (primary) FixedBufferAllocator, because it may not be available for the
//! provided secondary allocator (so callers must call reset() on underlying
//! allocators, themselves, when desirable).

const std = @import("../std.zig");
const mem = std.mem;
const Allocator = mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const assert = std.debug.assert;

const StackFirstAllocator = @This();

primary: FixedBufferAllocator,
secondary: Allocator,

pub fn init(buffer: []u8, secondary_allocator: Allocator) StackFirstAllocator {
    return .{
        .primary = .init(buffer),
        .secondary = secondary_allocator,
    };
}

pub fn allocator(self: *StackFirstAllocator) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

pub fn alloc(ctx: *anyopaque, len: usize, alignment: mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *StackFirstAllocator = @ptrCast(@alignCast(ctx));
    return FixedBufferAllocator.alloc(&self.primary, len, alignment, ret_addr) orelse
        self.secondary.rawAlloc(len, alignment, ret_addr);
}

pub fn resize(ctx: *anyopaque, memory: []u8, alignment: mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *StackFirstAllocator = @ptrCast(@alignCast(ctx));
    return if (self.primary.ownsPtr(memory.ptr))
        FixedBufferAllocator.resize(&self.primary, memory, alignment, new_len, ret_addr)
    else
        self.secondary.rawResize(memory, alignment, new_len, ret_addr);
}

pub fn remap(ctx: *anyopaque, memory: []u8, alignment: mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *StackFirstAllocator = @ptrCast(@alignCast(ctx));
    return if (self.primary.ownsPtr(memory.ptr))
        FixedBufferAllocator.remap(&self.primary, memory, alignment, new_len, ret_addr)
    else
        self.secondary.rawRemap(memory, alignment, new_len, ret_addr);
}

pub fn free(ctx: *anyopaque, memory: []u8, alignment: mem.Alignment, ret_addr: usize) void {
    const self: *StackFirstAllocator = @ptrCast(@alignCast(ctx));
    return if (self.primary.ownsPtr(memory.ptr))
        FixedBufferAllocator.free(&self.primary, memory, alignment, ret_addr)
    else
        self.secondary.rawFree(memory, alignment, ret_addr);
}

test StackFirstAllocator {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [10]u8 = undefined;
    var sfa = StackFirstAllocator.init(&buffer, arena.allocator());

    const expect = std.testing.expect;
    const expectEqualStrings = std.testing.expectEqualStrings;

    const al = sfa.allocator();
    const txt = "0123456789";

    const dest = try al.alloc(u8, txt.len);
    @memcpy(dest, txt);
    try expectEqualStrings(txt, dest);
    try expect(sfa.primary.ownsPtr(dest.ptr));

    const txt2 = "abcde";
    const dest2 = try al.alloc(u8, txt2.len);
    @memcpy(dest2, txt2);
    try expectEqualStrings(txt2, dest2);
    try expect(!sfa.primary.ownsPtr(dest2.ptr));

    sfa.primary.reset();

    const txt3 = "0123";
    const dest3 = try al.alloc(u8, txt3.len);
    @memcpy(dest3, txt3);
    try expectEqualStrings(txt3, dest3);
    try expect(sfa.primary.ownsPtr(dest3.ptr));

    sfa.primary.reset();
    //arena.reset(); // unnecessary, but allowed (note `defer arena.deinit()` above)

    // stock tests:
    {
        var buf: [16]u8 = undefined;
        var a = StackFirstAllocator.init(&buf, std.testing.allocator);
        try std.heap.testAllocator(a.allocator());
    }
    {
        var buf: [16]u8 = undefined;
        var a = StackFirstAllocator.init(&buf, std.testing.allocator);
        try std.heap.testAllocatorAligned(a.allocator());
    }
    {
        var buf: [16]u8 = undefined;
        var a = StackFirstAllocator.init(&buf, std.testing.allocator);
        try std.heap.testAllocatorLargeAlignment(a.allocator());
    }
    {
        var buf: [16]u8 = undefined;
        var a = StackFirstAllocator.init(&buf, std.testing.allocator);
        try std.heap.testAllocatorAlignedShrink(a.allocator());
    }
}
