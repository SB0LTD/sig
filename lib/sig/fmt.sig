//! Sig Format — freestanding formatting and parsing.
//!
//! Zero std dependency. Provides bufPrint (comptime format + runtime args)
//! and parseInt (string to integer conversion).

const SigError = @import("errors.sig").SigError;

// ══════════════════════════════════════════════════════════════════════════════
// Error Types
// ══════════════════════════════════════════════════════════════════════════════

/// Error set for integer parsing operations.
pub const ParseIntError = error{
    /// The result cannot fit in the type specified.
    Overflow,
    /// The input was empty or contained an invalid character.
    InvalidCharacter,
};

/// Error set for buffer printing operations.
pub const BufPrintError = error{
    /// The buffer is too small to hold the formatted output.
    NoSpaceLeft,
};

// ══════════════════════════════════════════════════════════════════════════════
// parseInt — string to integer conversion
// ══════════════════════════════════════════════════════════════════════════════

/// Parse a string as an integer in the given base (0, 2, 8, 10, 16).
/// Base 0 auto-detects: 0x=hex, 0o=octal, 0b=binary, else decimal.
/// Handles optional leading '+' or '-' sign.
pub fn parseInt(comptime T: type, buf: []const u8, base: u8) ParseIntError!T {
    if (buf.len == 0) return error.InvalidCharacter;

    const info = @typeInfo(T).int;
    const is_signed = info.signedness == .signed;
    const bits = info.bits;

    var i: usize = 0;
    var negative = false;

    // Handle sign
    if (buf[i] == '-') {
        if (!is_signed) return error.InvalidCharacter;
        negative = true;
        i += 1;
    } else if (buf[i] == '+') {
        i += 1;
    }

    if (i >= buf.len) return error.InvalidCharacter;

    // Auto-detect base if base == 0
    var effective_base: u8 = base;
    if (effective_base == 0) {
        if (buf.len > i + 1 and buf[i] == '0') {
            switch (buf[i + 1]) {
                'x', 'X' => {
                    effective_base = 16;
                    i += 2;
                },
                'o', 'O' => {
                    effective_base = 8;
                    i += 2;
                },
                'b', 'B' => {
                    effective_base = 2;
                    i += 2;
                },
                else => {
                    effective_base = 10;
                },
            }
        } else {
            effective_base = 10;
        }
    }

    if (i >= buf.len) return error.InvalidCharacter;

    // Parse digits into u64 (can hold any value up to 64-bit unsigned)
    var result: u64 = 0;
    var has_digits = false;

    while (i < buf.len) : (i += 1) {
        const c = buf[i];
        if (c == '_') continue; // Skip underscores (digit separator)

        const digit: u8 = if (c >= '0' and c <= '9')
            c - '0'
        else if (c >= 'a' and c <= 'f')
            c - 'a' + 10
        else if (c >= 'A' and c <= 'F')
            c - 'A' + 10
        else
            return error.InvalidCharacter;

        if (digit >= effective_base) return error.InvalidCharacter;
        has_digits = true;

        // Overflow-checked multiply + add on u64
        const mul_result = @mulWithOverflow(result, @as(u64, effective_base));
        if (mul_result[1] != 0) return error.Overflow;
        const add_result = @addWithOverflow(mul_result[0], @as(u64, digit));
        if (add_result[1] != 0) return error.Overflow;
        result = add_result[0];
    }

    if (!has_digits) return error.InvalidCharacter;

    // Bounds check and convert to target type
    if (is_signed) {
        if (negative) {
            // For signed negative: max magnitude is 2^(bits-1)
            const max_neg: u64 = @as(u64, 1) << @as(u6, @intCast(bits - 1));
            if (result > max_neg) return error.Overflow;
            if (result == max_neg) {
                // This is the min value (e.g. -128 for i8).
                // Can't negate it directly — use: -(max_neg - 1) - 1
                const almost: T = @intCast(result - 1);
                return -(almost) - 1;
            }
            return -@as(T, @intCast(result));
        } else {
            const max_pos: u64 = (@as(u64, 1) << @as(u6, @intCast(bits - 1))) - 1;
            if (result > max_pos) return error.Overflow;
            return @as(T, @intCast(result));
        }
    } else {
        if (negative) return error.Overflow;
        // Check unsigned fits in T
        if (bits < 64) {
            const max_val: u64 = (@as(u64, 1) << @as(u6, @intCast(bits))) - 1;
            if (result > max_val) return error.Overflow;
        }
        return @as(T, @intCast(result));
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// bufPrint — comptime format string + runtime args → buffer
// ══════════════════════════════════════════════════════════════════════════════

/// Format args into a caller-provided buffer using a comptime format string.
/// Supports: {d} decimal, {s} string, {x} hex, {c} char, {t} tag/error name,
/// {} default format, {{ }} literal braces.
/// Returns the formatted slice on success, or NoSpaceLeft if buffer too small.
pub fn bufPrint(buf: []u8, comptime fmt: []const u8, args: anytype) BufPrintError![]u8 {
    var w = BufWriter{ .buf = buf };
    try formatArgs(&w, fmt, args);
    return buf[0..w.pos];
}

/// Same as bufPrint but returns SigError.BufferTooSmall on overflow.
pub fn formatInto(buf: []u8, comptime fmt_str: []const u8, args: anytype) SigError![]u8 {
    return bufPrint(buf, fmt_str, args) catch return error.BufferTooSmall;
}

/// Computes the exact byte length of the formatted output without writing.
pub fn measureFormat(comptime fmt_str: []const u8, args: anytype) usize {
    var w = CountWriter{};
    formatArgs(@ptrCast(&w), fmt_str, args) catch unreachable;
    return w.count;
}

// ── Writer infrastructure ────────────────────────────────────────────────────

const BufWriter = struct {
    buf: []u8,
    pos: usize = 0,

    fn writeSlice(self: *BufWriter, data: []const u8) BufPrintError!void {
        if (self.pos + data.len > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    fn writeByte(self: *BufWriter, byte: u8) BufPrintError!void {
        if (self.pos >= self.buf.len) return error.NoSpaceLeft;
        self.buf[self.pos] = byte;
        self.pos += 1;
    }
};

const CountWriter = struct {
    count: usize = 0,

    fn writeSlice(self: *CountWriter, data: []const u8) BufPrintError!void {
        self.count += data.len;
    }

    fn writeByte(self: *CountWriter, _: u8) BufPrintError!void {
        self.count += 1;
    }
};

// ── Format engine ────────────────────────────────────────────────────────────

fn formatArgs(w: *BufWriter, comptime fmt: []const u8, args: anytype) BufPrintError!void {
    @setEvalBranchQuota(100_000);
    comptime var i: usize = 0;
    comptime var arg_idx: usize = 0;

    inline while (i < fmt.len) {
        if (fmt[i] == '{') {
            if (i + 1 < fmt.len and fmt[i + 1] == '{') {
                // Escaped brace: {{ → {
                try w.writeByte('{');
                i += 2;
            } else {
                // Find closing '}'
                comptime var end = i + 1;
                inline while (end < fmt.len and fmt[end] != '}') {
                    end += 1;
                }
                const spec = fmt[i + 1 .. end];
                i = end + 1;

                try formatValue(w, args[arg_idx], spec);
                arg_idx += 1;
            }
        } else if (fmt[i] == '}' and i + 1 < fmt.len and fmt[i + 1] == '}') {
            // Escaped brace: }} → }
            try w.writeByte('}');
            i += 2;
        } else {
            try w.writeByte(fmt[i]);
            i += 1;
        }
    }
}

fn formatValue(w: *BufWriter, value: anytype, comptime spec: []const u8) BufPrintError!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    if (comptime spec.len > 0 and spec[0] == 's') {
        // {s} — format as string slice
        try w.writeSlice(value);
    } else if (comptime spec.len > 0 and spec[0] == 'x') {
        // {x} — format as lowercase hex
        try formatHex(w, value, spec);
    } else if (comptime spec.len > 0 and spec[0] == 'd') {
        // {d} — format as decimal integer
        try formatDecimal(w, value);
    } else if (comptime spec.len > 0 and spec[0] == 'c') {
        // {c} — single character (u8)
        try w.writeByte(@intCast(value));
    } else if (comptime spec.len > 0 and spec[0] == 't') {
        // {t} — tag name (enum field name or error name)
        try formatTagName(w, value);
    } else {
        // {} — default format based on type
        switch (info) {
            .int, .comptime_int => try formatDecimal(w, value),
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) {
                    try w.writeSlice(value);
                } else if (ptr.size == .one) {
                    // Pointer to array of u8 (e.g. *const [N]u8) — coerce to slice
                    const child_info = @typeInfo(ptr.child);
                    if (child_info == .array and child_info.array.child == u8) {
                        try w.writeSlice(value);
                    } else {
                        try formatHex(w, @intFromPtr(value), "x");
                    }
                } else {
                    try formatHex(w, @intFromPtr(value), "x");
                }
            },
            .@"enum" => try w.writeSlice(@tagName(value)),
            .error_set => try w.writeSlice(@errorName(value)),
            .bool => try w.writeSlice(if (value) "true" else "false"),
            else => try w.writeSlice("?"),
        }
    }
}

fn formatTagName(w: *BufWriter, value: anytype) BufPrintError!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    switch (info) {
        .@"enum" => try w.writeSlice(@tagName(value)),
        .error_set => try w.writeSlice(@errorName(value)),
        else => try w.writeSlice("?"),
    }
}

// ── Integer formatting ───────────────────────────────────────────────────────

fn formatDecimal(w: *BufWriter, value: anytype) BufPrintError!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    if (info == .comptime_int) {
        // Comptime integer — format at comptime
        if (value < 0) {
            try w.writeByte('-');
            try writeUnsignedDecimal(w, @as(u64, @intCast(-value)));
        } else {
            try writeUnsignedDecimal(w, @as(u64, @intCast(value)));
        }
        return;
    }

    if (info != .int) {
        try w.writeSlice("?");
        return;
    }

    if (info.int.signedness == .signed) {
        if (value < 0) {
            try w.writeByte('-');
            // Widen to i64, @bitCast to u64, then wrapping negate to get absolute value.
            // This handles min_int correctly:
            //   min_int @bitCast → 0x80..00, then 0 -% 0x80..00 = 0x80..00 (correct magnitude).
            const wide_signed: i64 = @intCast(value);
            const wide_unsigned: u64 = @bitCast(wide_signed);
            const abs: u64 = 0 -% wide_unsigned;
            try writeUnsignedDecimal(w, abs);
        } else {
            try writeUnsignedDecimal(w, @as(u64, @intCast(value)));
        }
    } else {
        try writeUnsignedDecimal(w, value);
    }
}

fn writeUnsignedDecimal(w: *BufWriter, value: anytype) BufPrintError!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    // Handle zero
    if (info == .comptime_int) {
        if (value == 0) {
            try w.writeByte('0');
            return;
        }
    } else {
        if (value == 0) {
            try w.writeByte('0');
            return;
        }
    }

    // Write digits in reverse into a stack buffer, then copy forward.
    // Max digits for u64 is 20, u128 is 39. Use 40 to be safe.
    var digits: [40]u8 = undefined;
    var len: usize = 0;
    var n: u64 = if (info == .comptime_int) value else @intCast(value);

    while (n > 0) {
        digits[len] = @intCast('0' + @as(u8, @intCast(n % 10)));
        n /= 10;
        len += 1;
    }

    // Write in correct order (most significant first)
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        try w.writeByte(digits[i]);
    }
}

fn formatHex(w: *BufWriter, value: anytype, comptime spec: []const u8) BufPrintError!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    const v: u64 = if (info == .comptime_int) value else @intCast(value);

    // Check for zero-padding specifier: {x:0>N}
    const pad_width = comptime parseHexPadWidth(spec);

    if (pad_width > 0) {
        // Zero-padded hex with fixed width
        try writeHexPadded(w, v, pad_width);
    } else {
        // Minimal-width hex
        if (v == 0) {
            try w.writeByte('0');
            return;
        }
        const hex_chars = "0123456789abcdef";
        var digits: [16]u8 = undefined;
        var len: usize = 0;
        var n = v;
        while (n > 0) {
            digits[len] = hex_chars[@intCast(n & 0xF)];
            n >>= 4;
            len += 1;
        }
        var i: usize = len;
        while (i > 0) {
            i -= 1;
            try w.writeByte(digits[i]);
        }
    }
}

fn writeHexPadded(w: *BufWriter, value: u64, width: usize) BufPrintError!void {
    const hex_chars = "0123456789abcdef";
    // Write exactly `width` hex digits, zero-padded from the left
    var i: usize = width;
    while (i > 0) {
        i -= 1;
        const shift: u6 = @intCast(i * 4);
        try w.writeByte(hex_chars[@intCast((value >> shift) & 0xF)]);
    }
}

fn parseHexPadWidth(comptime spec: []const u8) usize {
    // Parse "x:0>2" or "x:0>4" etc. → returns the width (2, 4, etc.)
    // Format: x:0>N
    if (spec.len < 4) return 0;
    if (spec[1] != ':' or spec[2] != '0' or spec[3] != '>') return 0;
    // Parse the number after '>'
    var width: usize = 0;
    var i: usize = 4;
    while (i < spec.len) : (i += 1) {
        if (spec[i] >= '0' and spec[i] <= '9') {
            width = width * 10 + (spec[i] - '0');
        } else break;
    }
    return width;
}

// ══════════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════════

test "parseInt decimal" {
    const val = try parseInt(u32, "12345", 10);
    if (val != 12345) return error.TestUnexpectedResult;
}

test "parseInt hex" {
    const val = try parseInt(u32, "FF", 16);
    if (val != 255) return error.TestUnexpectedResult;
}

test "parseInt hex lowercase" {
    const val = try parseInt(u32, "ff", 16);
    if (val != 255) return error.TestUnexpectedResult;
}

test "parseInt signed negative" {
    const val = try parseInt(i32, "-42", 10);
    if (val != -42) return error.TestUnexpectedResult;
}

test "parseInt signed positive" {
    const val = try parseInt(i32, "+99", 10);
    if (val != 99) return error.TestUnexpectedResult;
}

test "parseInt min i8" {
    const val = try parseInt(i8, "-128", 10);
    if (val != -128) return error.TestUnexpectedResult;
}

test "parseInt max u8" {
    const val = try parseInt(u8, "255", 10);
    if (val != 255) return error.TestUnexpectedResult;
}

test "parseInt overflow u8" {
    const result = parseInt(u8, "256", 10);
    if (result) |_| return error.TestUnexpectedResult else |err| {
        if (err != error.Overflow) return error.TestUnexpectedResult;
    }
}

test "parseInt overflow i8 positive" {
    const result = parseInt(i8, "128", 10);
    if (result) |_| return error.TestUnexpectedResult else |err| {
        if (err != error.Overflow) return error.TestUnexpectedResult;
    }
}

test "parseInt invalid char" {
    const result = parseInt(u32, "12x4", 10);
    if (result) |_| return error.TestUnexpectedResult else |err| {
        if (err != error.InvalidCharacter) return error.TestUnexpectedResult;
    }
}

test "parseInt empty" {
    const result = parseInt(u32, "", 10);
    if (result) |_| return error.TestUnexpectedResult else |err| {
        if (err != error.InvalidCharacter) return error.TestUnexpectedResult;
    }
}

test "parseInt auto-detect hex" {
    const val = try parseInt(u32, "0xFF", 0);
    if (val != 255) return error.TestUnexpectedResult;
}

test "parseInt auto-detect binary" {
    const val = try parseInt(u8, "0b1010", 0);
    if (val != 10) return error.TestUnexpectedResult;
}

test "parseInt underscore separator" {
    const val = try parseInt(u32, "1_000_000", 10);
    if (val != 1000000) return error.TestUnexpectedResult;
}

test "parseInt zero" {
    const val = try parseInt(u32, "0", 10);
    if (val != 0) return error.TestUnexpectedResult;
}

test "bufPrint string" {
    var buf: [64]u8 = undefined;
    const result = try bufPrint(&buf, "hello {s}!", .{"world"});
    if (!strEql(result, "hello world!")) return error.TestUnexpectedResult;
}

test "bufPrint decimal" {
    var buf: [64]u8 = undefined;
    const result = try bufPrint(&buf, "n={d}", .{@as(u32, 42)});
    if (!strEql(result, "n=42")) return error.TestUnexpectedResult;
}

test "bufPrint negative decimal" {
    var buf: [64]u8 = undefined;
    const result = try bufPrint(&buf, "{d}", .{@as(i32, -99)});
    if (!strEql(result, "-99")) return error.TestUnexpectedResult;
}

test "bufPrint hex" {
    var buf: [64]u8 = undefined;
    const result = try bufPrint(&buf, "0x{x}", .{@as(u32, 255)});
    if (!strEql(result, "0xff")) return error.TestUnexpectedResult;
}

test "bufPrint zero decimal" {
    var buf: [64]u8 = undefined;
    const result = try bufPrint(&buf, "{d}", .{@as(u32, 0)});
    if (!strEql(result, "0")) return error.TestUnexpectedResult;
}

test "bufPrint escaped braces" {
    var buf: [64]u8 = undefined;
    const result = try bufPrint(&buf, "{{literal}}", .{});
    if (!strEql(result, "{literal}")) return error.TestUnexpectedResult;
}

test "bufPrint multiple args" {
    var buf: [128]u8 = undefined;
    const result = try bufPrint(&buf, "{s} {d} {x}", .{ "test", @as(u32, 100), @as(u32, 16) });
    if (!strEql(result, "test 100 10")) return error.TestUnexpectedResult;
}

test "bufPrint char" {
    var buf: [64]u8 = undefined;
    const result = try bufPrint(&buf, "char={c}", .{@as(u8, 'A')});
    if (!strEql(result, "char=A")) return error.TestUnexpectedResult;
}

test "bufPrint buffer too small" {
    var buf: [3]u8 = undefined;
    const result = bufPrint(&buf, "hello", .{});
    if (result) |_| return error.TestUnexpectedResult else |err| {
        if (err != error.NoSpaceLeft) return error.TestUnexpectedResult;
    }
}

test "bufPrint hex padded" {
    var buf: [64]u8 = undefined;
    const result = try bufPrint(&buf, "{x:0>2}", .{@as(u8, 5)});
    if (!strEql(result, "05")) return error.TestUnexpectedResult;
}

// Test helper (avoids circular dependency on mem.sig for test-only code)
fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}
