//! Small strict-memory adapters. Algorithms and storage come from std and Sig.
const std = @import("std");
const containers = @import("../containers.sig");

pub const Vector = containers.BoundedVec;
pub const StringMap = containers.BoundedStringMap;
pub const StaticMap = std.StaticStringMap;
pub const Error = error{ CapacityExceeded, IndexOutOfBounds };

/// Borrows storage for its entire lifetime. Copies of a List share that storage;
/// keep one mutable owner. Returned slices are invalidated by remove/clear.
pub fn List(comptime T: type) type {
    return struct {
        const Self = @This();
        inner: std.ArrayList(T),

        pub fn init(storage: []T) Self { return .{ .inner = .initBuffer(storage) }; }
        pub fn append(self: *Self, value: T) Error!void {
            self.inner.appendBounded(value) catch return error.CapacityExceeded;
        }
        /// Failure leaves the list and backing storage unchanged.
        pub fn extend(self: *Self, values: []const T) Error!void {
            if (values.len > self.inner.capacity - self.inner.items.len) return error.CapacityExceeded;
            self.inner.appendSliceAssumeCapacity(values);
        }
        pub fn pop(self: *Self) ?T { return self.inner.pop(); }
        pub fn remove(self: *Self, index: usize) Error!T {
            if (index >= self.inner.items.len) return error.IndexOutOfBounds;
            return self.inner.orderedRemove(index);
        }
        pub fn clear(self: *Self) void { self.inner.clearRetainingCapacity(); }
        pub fn slice(self: *const Self) []const T { return self.inner.items; }
        pub fn mutableSlice(self: *Self) []T { return self.inner.items; }
        pub fn len(self: *const Self) usize { return self.inner.items.len; }
        pub fn capacity(self: *const Self) usize { return self.inner.capacity; }
    };
}

/// A bounded FIFO over std.Deque. O(1) push/pop, including wraparound.
/// This is an in-memory queue, not a durable or concurrent job scheduler.
pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();
        inner: std.Deque(T),
        pub fn init(storage: []T) Self { return .{ .inner = .initBuffer(storage) }; }
        pub fn push(self: *Self, value: T) Error!void {
            self.inner.pushBackBounded(value) catch return error.CapacityExceeded;
        }
        pub fn pop(self: *Self) ?T { return self.inner.popFront(); }
        pub fn len(self: *const Self) usize { return self.inner.len; }
        pub fn clear(self: *Self) void { self.inner = .initBuffer(self.inner.buffer); }
    };
}

test "list capacity failures preserve storage and ordered removal is checked" {
    var storage = [_]u8{ 90, 91, 92 };
    var list = List(u8).init(&storage);
    try list.extend(&.{ 10, 20 });
    if (list.extend(&.{ 30, 40 })) return error.ExpectedFailure else |err| if (err != error.CapacityExceeded) return err;
    if (list.len() != 2 or storage[2] != 92) return error.PartialWrite;
    try list.append(30);
    if (try list.remove(1) != 20 or list.slice()[1] != 30) return error.BadOrder;
    if (list.remove(5)) |_| return error.ExpectedFailure else |err| if (err != error.IndexOutOfBounds) return err;
    if (list.pop() != 30) return error.BadPop;
    list.clear();
    if (list.len() != 0 or list.capacity() != 3) return error.BadClear;
    var empty = List(u8).init(&.{});
    if (empty.append(1)) return error.ExpectedFailure else |err| if (err != error.CapacityExceeded) return err;
}

test "queue wraparound and zero capacity use existing bounded deque" {
    var storage: [2]u8 = undefined;
    var queue = Queue(u8).init(&storage);
    try queue.push(1);
    try queue.push(2);
    if (queue.push(3)) return error.ExpectedFailure else |err| if (err != error.CapacityExceeded) return err;
    if (queue.pop() != 1) return error.BadOrder;
    try queue.push(3);
    if (queue.pop() != 2 or queue.pop() != 3 or queue.pop() != null) return error.BadOrder;
    var empty = Queue(u8).init(&.{});
    if (empty.push(1)) return error.ExpectedFailure else |err| if (err != error.CapacityExceeded) return err;
}

test "reuse Sig vector and string map including update at capacity" {
    var vector: Vector(u8, 1) = .{};
    try vector.push(9);
    if (vector.push(8)) return error.ExpectedFailure else |err| if (err != error.CapacityExceeded) return err;
    var map: StringMap(8, 8, 1) = .{};
    try map.put("name", "Sig");
    try map.put("name", "Studio");
    if (!std.mem.eql(u8, map.getValue("name").?, "Studio")) return error.BadMap;
    if (map.put("other", "value")) return error.ExpectedFailure else |err| if (err != error.CapacityExceeded) return err;
    if (!map.remove("name") or map.length() != 0) return error.BadMap;
    const codes = StaticMap(u16).initComptime(.{ .{ "ok", 200 }, .{ "invalid", 422 } });
    if (codes.get("ok") != 200 or codes.get("missing") != null) return error.BadMap;
}
