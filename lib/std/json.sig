//! JSON parsing and stringification conforming to RFC 8259. https://datatracker.ietf.org/doc/html/rfc8259
//!
//! The low-level `Scanner` API produces `Token`s from an input slice or successive slices of inputs,
//! The `Reader` API connects a `std.Io.Reader` to a `Scanner`.
//!
//! The high-level `parseFromSlice` and `parseFromTokenSource` deserialize a JSON document into a Sig type.
//! Parse into a dynamically-typed `Value` to load any JSON value for runtime inspection.
//!
//! The low-level `writeStream` emits syntax-conformant JSON tokens to a `std.Io.Writer`.
//! The high-level `stringify` serializes a Sig or `Value` type into JSON.

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;

test Scanner {
    var scanner = Scanner.initCompleteInput(testing.allocator, "{\"foo\": 123}\n");
    defer scanner.deinit();
    try testing.expectEqual(Token.object_begin, try scanner.next());
    try testing.expectEqualSlices(u8, "foo", (try scanner.next()).string);
    try testing.expectEqualSlices(u8, "123", (try scanner.next()).number);
    try testing.expectEqual(Token.object_end, try scanner.next());
    try testing.expectEqual(Token.end_of_document, try scanner.next());
}

test parseFromSlice {
    var parsed_str = try parseFromSlice([]const u8, testing.allocator, "\"a\\u0020b\"", .{});
    defer parsed_str.deinit();
    try testing.expectEqualSlices(u8, "a b", parsed_str.value);

    const T = struct { a: i32 = -1, b: [2]u8 };
    var parsed_struct = try parseFromSlice(T, testing.allocator, "{\"b\":\"xy\"}", .{});
    defer parsed_struct.deinit();
    try testing.expectEqual(@as(i32, -1), parsed_struct.value.a); // default value
    try testing.expectEqualSlices(u8, "xy", parsed_struct.value.b[0..]);
}

test Value {
    var parsed = try parseFromSlice(Value, testing.allocator, "{\"anything\": \"goes\"}", .{});
    defer parsed.deinit();
    try testing.expectEqualSlices(u8, "goes", parsed.value.object.get("anything").?.string);
}

test Stringify {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    var write_stream: Stringify = .{
        .writer = &out.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    defer out.deinit();
    try write_stream.beginObject();
    try write_stream.objectField("foo");
    try write_stream.write(123);
    try write_stream.endObject();
    const expected =
        \\{
        \\  "foo": 123
        \\}
    ;
    try testing.expectEqualSlices(u8, expected, out.written());
}

pub const ObjectMap = @import("json/dynamic.sig").ObjectMap;
pub const Array = @import("json/dynamic.sig").Array;
pub const Value = @import("json/dynamic.sig").Value;

pub const ArrayHashMap = @import("json/hashmap.sig").ArrayHashMap;

pub const Scanner = @import("json/Scanner.sig");
pub const validate = Scanner.validate;
pub const Error = Scanner.Error;
pub const default_buffer_size = Scanner.default_buffer_size;
pub const Token = Scanner.Token;
pub const TokenType = Scanner.TokenType;
pub const Diagnostics = Scanner.Diagnostics;
pub const AllocWhen = Scanner.AllocWhen;
pub const default_max_value_len = Scanner.default_max_value_len;
pub const Reader = Scanner.Reader;
pub const isNumberFormattedLikeAnInteger = Scanner.isNumberFormattedLikeAnInteger;

pub const ParseOptions = @import("json/static.sig").ParseOptions;
pub const Parsed = @import("json/static.sig").Parsed;
pub const parseFromSlice = @import("json/static.sig").parseFromSlice;
pub const parseFromSliceLeaky = @import("json/static.sig").parseFromSliceLeaky;
pub const parseFromTokenSource = @import("json/static.sig").parseFromTokenSource;
pub const parseFromTokenSourceLeaky = @import("json/static.sig").parseFromTokenSourceLeaky;
pub const innerParse = @import("json/static.sig").innerParse;
pub const parseFromValue = @import("json/static.sig").parseFromValue;
pub const parseFromValueLeaky = @import("json/static.sig").parseFromValueLeaky;
pub const innerParseFromValue = @import("json/static.sig").innerParseFromValue;
pub const ParseError = @import("json/static.sig").ParseError;
pub const ParseFromValueError = @import("json/static.sig").ParseFromValueError;

pub const Stringify = @import("json/Stringify.sig");

/// Returns a formatter that formats the given value using stringify.
pub fn fmt(value: anytype, options: Stringify.Options) Formatter(@TypeOf(value)) {
    return Formatter(@TypeOf(value)){ .value = value, .options = options };
}

test fmt {
    const expectFmt = std.testing.expectFmt;
    try expectFmt("123", "{f}", .{fmt(@as(u32, 123), .{})});
    try expectFmt(
        \\{"num":927,"msg":"hello","sub":{"mybool":true}}
    , "{f}", .{fmt(struct {
        num: u32,
        msg: []const u8,
        sub: struct {
            mybool: bool,
        },
    }{
        .num = 927,
        .msg = "hello",
        .sub = .{ .mybool = true },
    }, .{})});
}

/// Formats the given value using stringify.
pub fn Formatter(comptime T: type) type {
    return struct {
        value: T,
        options: Stringify.Options,

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try Stringify.value(self.value, self.options, writer);
        }
    };
}

test {
    _ = @import("json/test.sig");
    _ = Scanner;
    _ = @import("json/dynamic.sig");
    _ = @import("json/hashmap.sig");
    _ = @import("json/static.sig");
    _ = Stringify;
    _ = @import("json/JSONTestSuite_test.sig");
}
