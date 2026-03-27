const builtin = @import("builtin");
const std = @import("std");

const c = std.c;
const testing = std.testing;

test "strncmp" {
    try testing.expect(c.strncmp(@ptrCast("a"), @ptrCast("b"), 1) < 0);
    try testing.expect(c.strncmp(@ptrCast("a"), @ptrCast("c"), 1) < 0);
    try testing.expect(c.strncmp(@ptrCast("b"), @ptrCast("a"), 1) > 0);
    try testing.expect(c.strncmp(@ptrCast("\xff"), @ptrCast("\x02"), 1) > 0);
}
