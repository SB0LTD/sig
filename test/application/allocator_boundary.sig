// Compatibility probe only: compile this file, never execute it.
const std = @import("std");
pub fn main(init: std.process.Init) !void {
 _ = init;
 const values = try std.heap.page_allocator.alloc(u8, 4);
 defer std.heap.page_allocator.free(values);
 values[0] = 7;
 std.mem.doNotOptimizeAway(values.ptr);
}
