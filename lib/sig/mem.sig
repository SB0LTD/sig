//! Pure Sig Memory — zero-dependency slice/byte operations.
//!
//! Replaces std.mem for freestanding modules. All functions operate on
//! slices with no allocator, no OS, no heap.

// ══════════════════════════════════════════════════════════════════════════════
// Comparison
// ══════════════════════════════════════════════════════════════════════════════

/// Compare two slices for byte equality.
pub fn eql(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// Check if `haystack` starts with `needle`.
pub fn startsWith(comptime T: type, haystack: []const T, needle: []const T) bool {
    if (needle.len > haystack.len) return false;
    return eql(T, haystack[0..needle.len], needle);
}

/// Check if `haystack` ends with `needle`.
pub fn endsWith(comptime T: type, haystack: []const T, needle: []const T) bool {
    if (needle.len > haystack.len) return false;
    return eql(T, haystack[haystack.len - needle.len ..], needle);
}

// ══════════════════════════════════════════════════════════════════════════════
// Search
// ══════════════════════════════════════════════════════════════════════════════

/// Find the first index of `value` in `slice`, or null.
pub fn indexOfScalar(comptime T: type, slice: []const T, value: T) ?usize {
    for (slice, 0..) |item, i| {
        if (item == value) return i;
    }
    return null;
}

/// Find the last index of `value` in `slice`, or null.
pub fn lastIndexOfScalar(comptime T: type, slice: []const T, value: T) ?usize {
    var i = slice.len;
    while (i > 0) {
        i -= 1;
        if (slice[i] == value) return i;
    }
    return null;
}

/// Check if `slice` contains `value`.
pub fn containsScalar(comptime T: type, slice: []const T, value: T) bool {
    return indexOfScalar(T, slice, value) != null;
}

// ══════════════════════════════════════════════════════════════════════════════
// Byte Interpretation
// ══════════════════════════════════════════════════════════════════════════════

/// Reinterpret a pointer to any type as a pointer to its raw bytes.
pub fn asBytes(comptime T: type, ptr: *const T) *const [@sizeOf(T)]u8 {
    return @ptrCast(ptr);
}

/// Reinterpret a mutable pointer as mutable bytes.
pub fn asMutableBytes(comptime T: type, ptr: *T) *[@sizeOf(T)]u8 {
    return @ptrCast(ptr);
}

/// Read an integer from bytes in the specified endianness.
pub fn readInt(comptime T: type, bytes: *const [@sizeOf(T)]u8, endian: Endian) T {
    const size = @sizeOf(T);
    if (endian == .little) {
        var result: T = 0;
        inline for (0..size) |i| {
            result |= @as(T, bytes[i]) << @intCast(i * 8);
        }
        return result;
    } else {
        var result: T = 0;
        inline for (0..size) |i| {
            result |= @as(T, bytes[i]) << @intCast((size - 1 - i) * 8);
        }
        return result;
    }
}

/// Write an integer to bytes in the specified endianness.
pub fn writeInt(comptime T: type, buf: *[@sizeOf(T)]u8, value: T, endian: Endian) void {
    const size = @sizeOf(T);
    if (endian == .little) {
        inline for (0..size) |i| {
            buf[i] = @intCast((value >> @intCast(i * 8)) & 0xFF);
        }
    } else {
        inline for (0..size) |i| {
            buf[i] = @intCast((value >> @intCast((size - 1 - i) * 8)) & 0xFF);
        }
    }
}

pub const Endian = enum { little, big };

// ══════════════════════════════════════════════════════════════════════════════
// Conversion
// ══════════════════════════════════════════════════════════════════════════════

/// Convert a slice of one integer type to bytes (reinterpret cast).
pub fn sliceAsBytes(comptime T: type, slice: []const T) []const u8 {
    const byte_ptr: [*]const u8 = @ptrCast(slice.ptr);
    return byte_ptr[0 .. slice.len * @sizeOf(T)];
}

// ══════════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════════

test "eql" {
    if (!eql(u8, "hello", "hello")) return error.TestUnexpectedResult;
    if (eql(u8, "hello", "world")) return error.TestUnexpectedResult;
    if (eql(u8, "hello", "hell")) return error.TestUnexpectedResult;
}

test "startsWith and endsWith" {
    if (!startsWith(u8, "hello world", "hello")) return error.TestUnexpectedResult;
    if (startsWith(u8, "hello", "hello world")) return error.TestUnexpectedResult;
    if (!endsWith(u8, "hello world", "world")) return error.TestUnexpectedResult;
    if (endsWith(u8, "hello", "world")) return error.TestUnexpectedResult;
}

test "indexOfScalar" {
    const data = "hello";
    if ((indexOfScalar(u8, data, 'l') orelse 99) != 2) return error.TestUnexpectedResult;
    if (indexOfScalar(u8, data, 'z') != null) return error.TestUnexpectedResult;
}

test "readInt little endian" {
    const bytes = [4]u8{ 0x01, 0x02, 0x03, 0x04 };
    const val = readInt(u32, &bytes, .little);
    if (val != 0x04030201) return error.TestUnexpectedResult;
}

test "readInt big endian" {
    const bytes = [4]u8{ 0x01, 0x02, 0x03, 0x04 };
    const val = readInt(u32, &bytes, .big);
    if (val != 0x01020304) return error.TestUnexpectedResult;
}
