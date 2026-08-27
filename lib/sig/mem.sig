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
/// Matches std.mem.asBytes — takes anytype pointer, infers size.
pub fn asBytes(ptr: anytype) AsBytes(@TypeOf(ptr)) {
    return @ptrCast(ptr);
}

fn AsBytes(comptime T: type) type {
    const info = @typeInfo(T);
    if (info == .pointer) {
        const child = info.pointer.child;
        const size = @sizeOf(child);
        if (info.pointer.is_const) {
            return *const [size]u8;
        } else {
            return *[size]u8;
        }
    }
    @compileError("expected pointer type");
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
// Substring Search
// ══════════════════════════════════════════════════════════════════════════════

/// Find the first occurrence of `needle` slice within `haystack`, or null.
pub fn indexOf(comptime T: type, haystack: []const T, needle: []const T) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    const end = haystack.len - needle.len + 1;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        if (eql(T, haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

// ══════════════════════════════════════════════════════════════════════════════
// Trimming
// ══════════════════════════════════════════════════════════════════════════════

/// Trim characters in `trim_set` from the end of `slice`.
pub fn trimEnd(comptime T: type, slice: []const T, trim_set: []const T) []const T {
    var end = slice.len;
    while (end > 0) {
        var found = false;
        for (trim_set) |c| {
            if (slice[end - 1] == c) {
                found = true;
                break;
            }
        }
        if (!found) break;
        end -= 1;
    }
    return slice[0..end];
}

// ══════════════════════════════════════════════════════════════════════════════
// Splitting
// ══════════════════════════════════════════════════════════════════════════════

/// Iterator that splits a slice on every occurrence of a scalar delimiter.
pub fn SplitIterator(comptime T: type) type {
    return struct {
        buffer: []const T,
        index: ?usize,
        delimiter: T,

        const Self = @This();

        /// Returns the next token, or null when exhausted.
        pub fn next(self: *Self) ?[]const T {
            const start = self.index orelse return null;
            if (indexOfScalar(T, self.buffer[start..], self.delimiter)) |delim_pos| {
                const end = start + delim_pos;
                self.index = end + 1;
                return self.buffer[start..end];
            } else {
                self.index = null;
                return self.buffer[start..];
            }
        }
    };
}

/// Split `slice` by a scalar `delimiter`. Returns an iterator with `.next()`.
pub fn splitScalar(comptime T: type, slice: []const T, delimiter: T) SplitIterator(T) {
    return .{
        .buffer = slice,
        .index = 0,
        .delimiter = delimiter,
    };
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

test "indexOf" {
    if ((indexOf(u8, "hello world", "world") orelse 99) != 6) return error.TestUnexpectedResult;
    if ((indexOf(u8, "abcabc", "abc") orelse 99) != 0) return error.TestUnexpectedResult;
    if (indexOf(u8, "hello", "xyz") != null) return error.TestUnexpectedResult;
    if ((indexOf(u8, "hello", "") orelse 99) != 0) return error.TestUnexpectedResult;
    if (indexOf(u8, "", "a") != null) return error.TestUnexpectedResult;
}

test "trimEnd" {
    if (!eql(u8, trimEnd(u8, "hello  \n", &[_]u8{ ' ', '\n' }), "hello")) return error.TestUnexpectedResult;
    if (!eql(u8, trimEnd(u8, "hello", &[_]u8{ ' ', '\n' }), "hello")) return error.TestUnexpectedResult;
    if (!eql(u8, trimEnd(u8, "", &[_]u8{ ' ' }), "")) return error.TestUnexpectedResult;
}

test "splitScalar" {
    var it = splitScalar(u8, "a.b.c", '.');
    if (!eql(u8, it.next() orelse "", "a")) return error.TestUnexpectedResult;
    if (!eql(u8, it.next() orelse "", "b")) return error.TestUnexpectedResult;
    if (!eql(u8, it.next() orelse "", "c")) return error.TestUnexpectedResult;
    if (it.next() != null) return error.TestUnexpectedResult;
}
