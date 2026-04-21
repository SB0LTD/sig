const builtin = @import("builtin");
const std = @import("std");

test {
    _ = @import("c/inttypes.zig");
    _ = @import("c/math.zig");
    _ = @import("c/pthread.zig");
    _ = @import("c/search.zig");
    _ = @import("c/stdlib.zig");
    _ = @import("c/string.zig");
    _ = @import("c/strings.zig");
    _ = @import("c/unistd.zig");
}
