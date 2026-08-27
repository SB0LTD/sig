const std = @import("std");
const SigError = @import("errors.sig").SigError;

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

/// Formats into a caller-provided buffer. Returns the slice of bytes written.
/// Returns error.BufferTooSmall if the buffer cannot hold the full output.
pub fn formatInto(buf: []u8, comptime fmt_str: []const u8, args: anytype) SigError![]u8 {
    return std.fmt.bufPrint(buf, fmt_str, args) catch return error.BufferTooSmall;
}

/// Computes the exact byte length of the formatted output without writing.
pub fn measureFormat(comptime fmt_str: []const u8, args: anytype) usize {
    return std.fmt.count(fmt_str, args);
}

/// Formats arguments according to fmt into buf. Returns the formatted slice.
/// Direct replacement for std.fmt.bufPrint.
pub fn bufPrint(buf: []u8, comptime fmt: []const u8, args: anytype) BufPrintError![]u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch return error.NoSpaceLeft;
}

/// Parses the string `buf` as a signed or unsigned integer in the specified radix.
/// Direct replacement for std.fmt.parseInt.
pub fn parseInt(comptime T: type, buf: []const u8, base: u8) ParseIntError!T {
    return std.fmt.parseInt(T, buf, base) catch |err| switch (err) {
        error.Overflow => return error.Overflow,
        error.InvalidCharacter => return error.InvalidCharacter,
    };
}
