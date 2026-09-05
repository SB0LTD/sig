//! Type-derived JSON using std.json.Stringify and std.Io.Writer.
//! No new JSON encoding algorithm, heap or Allocator boundary.
const std = @import("std");
pub const Error = error{ BufferTooSmall, DepthExceeded, InvalidUtf8, NonFiniteNumber };
pub const max_depth = 64;

/// Serialize a value into caller-owned output. Validates and counts first so
/// capacity/UTF-8/depth failures leave output unchanged. Input must remain stable
/// and must not overlap output during the call. Custom jsonStringify hooks are
/// intentionally excluded from this two-pass API; use std directly for hooks.
pub fn encode(value: anytype, output: []u8) Error![]const u8 {
    try check(value, 0);
    var scratch: [128]u8 = undefined;
    var counter = std.Io.Writer.Discarding.init(&scratch);
    std.json.Stringify.value(value, .{}, &counter.writer) catch return error.BufferTooSmall;
    if (counter.fullCount() > output.len) return error.BufferTooSmall;
    var writer = std.Io.Writer.fixed(output);
    std.json.Stringify.value(value, .{}, &writer) catch return error.BufferTooSmall;
    return writer.buffered();
}

fn check(value: anytype, depth: usize) Error!void {
    if (depth > max_depth) return error.DepthExceeded;
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .null, .void => {},
        .float, .comptime_float => if (!std.math.isFinite(value)) { return error.NonFiniteNumber; },
        .optional => if (value) |item| { try check(item, depth); },
        .@"enum" => |info| {
            if (@hasDecl(T, "jsonStringify")) @compileError("application.json excludes custom jsonStringify hooks; use std.json.Stringify directly");
            if (info.mode != .exhaustive) @compileError("application.json requires an exhaustive enum");
            if (!std.unicode.utf8ValidateSlice(@tagName(value))) return error.InvalidUtf8;
        },
        .@"struct" => |info| {
            if (@hasDecl(T, "jsonStringify")) @compileError("application.json excludes custom jsonStringify hooks; use std.json.Stringify directly");
            inline for (info.field_names) |name| {
                if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidUtf8;
                try check(@field(value, name), depth + 1);
            }
        },
        .array => |info| {
            if (info.child == u8) {
                if (!std.unicode.utf8ValidateSlice(&value)) return error.InvalidUtf8;
            } else { for (value) |item| try check(item, depth + 1); }
        },
        .pointer => |info| switch (info.size) {
            .one => try check(value.*, depth),
            .slice => {
                if (info.child == u8) {
                    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
                } else { for (value) |item| try check(item, depth + 1); }
            },
            else => @compileError("application.json requires bounded slices or single-item pointers"),
        },
        else => @compileError("unsupported application.json type: " ++ @typeName(T)),
    }
}

test "JSON derives nested structs enums optional fields and escaped strings" {
    const Role = enum { reader, author };
    const User = struct { name: []const u8, age: u8, role: Role, active: bool, note: ?u8 };
    const user = User{ .name = "Sig\n\"\xe2\x9c\x93", .age = 8, .role = .author, .active = true, .note = null };
    var out: [256]u8 = undefined;
    const result = try encode(.{ .user = user }, &out);
    if (!std.mem.eql(u8, result, "{\"user\":{\"name\":\"Sig\\n\\\"\xe2\x9c\x93\",\"age\":8,\"role\":\"author\",\"active\":true,\"note\":null}}")) return error.BadJson;
}

test "JSON capacity and invalid inputs do not partially overwrite output" {
    var small = [_]u8{ 'x', 'x', 'x' };
    if (encode(.{ .name = "Sig" }, &small)) |_| return error.ExpectedFailure else |err| if (err != error.BufferTooSmall) return err;
    if (!std.mem.eql(u8, &small, "xxx")) return error.PartialWrite;
    if (encode(@as([]const u8, "\xff"), &small)) |_| return error.ExpectedFailure else |err| if (err != error.InvalidUtf8) return err;
    if (encode(std.math.inf(f64), &small)) |_| return error.ExpectedFailure else |err| if (err != error.NonFiniteNumber) return err;
    if (!std.mem.eql(u8, &small, "xxx")) return error.PartialWrite;
    if (!std.mem.eql(u8, try encode(@as(u8, 123), &small), "123")) return error.BadExactFit;
}

test "JSON recursive values stop at a named depth error" {
    const Node = struct { next: ?*const @This() };
    var node = Node{ .next = null };
    node.next = &node;
    var out: [32]u8 = @splat(1);
    if (encode(node, &out)) |_| return error.ExpectedFailure else |err| if (err != error.DepthExceeded) return err;
    for (out) |byte| if (byte != 1) return error.PartialWrite;
}
