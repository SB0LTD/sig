// Unit tests for Option_Map and option parsing logic (task 1.4).
//
// Since the build runner (tools/sig_build/main.sig) is not wired as a test import,
// these tests replicate the parsing and accessor logic using the same containers
// module and algorithms to validate correctness.
//
// Requirements: 14.1, 14.2, 14.3, 14.4, 14.5, 14.6, 14.7, 14.8

const std = @import("std");
const testing = std.testing;
const containers = @import("containers");

const NAME_BUF_SIZE = 64;
const VALUE_BUF_SIZE = 256;
const MAX_OPTIONS = 128;

const Option_Map = containers.BoundedStringMap(NAME_BUF_SIZE, VALUE_BUF_SIZE, MAX_OPTIONS);

/// Replicates parseOption from main.sig for testing.
fn parseOption(map: *Option_Map, arg: []const u8) !void {
    const rest = arg[2..];
    if (std.mem.indexOfScalar(u8, rest, '=')) |eq_pos| {
        try map.put(rest[0..eq_pos], rest[eq_pos + 1 ..]);
    } else {
        try map.put(rest, "true");
    }
}

/// Replicates getOption from main.sig for testing.
fn getOption(comptime T: type, map: *const Option_Map, name: []const u8) ?T {
    const value = map.getValue(name) orelse return null;
    return switch (@typeInfo(T)) {
        .bool => {
            if (std.mem.eql(u8, value, "true")) return true;
            if (std.mem.eql(u8, value, "false")) return false;
            return null;
        },
        .int => std.fmt.parseInt(T, value, 10) catch return null,
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8 and ptr.is_const) {
                return value;
            }
            return null;
        },
        .@"enum" => {
            inline for (@typeInfo(T).@"enum".fields) |field| {
                if (std.mem.eql(u8, value, field.name)) {
                    return @field(T, field.name);
                }
            }
            return null;
        },
        else => null,
    };
}


// ── parseOption: -Dname=value ───────────────────────────────────────────

test "parseOption: -Doptimize=Debug stores name and value" {
    var map = Option_Map{};
    try parseOption(&map, "-Doptimize=Debug");
    try testing.expectEqualStrings("Debug", map.getValue("optimize").?);
}

test "parseOption: -Dname=value splits on first = only" {
    var map = Option_Map{};
    try parseOption(&map, "-Dpath=a=b=c");
    try testing.expectEqualStrings("a=b=c", map.getValue("path").?);
}

test "parseOption: -Dname=empty stores empty value" {
    var map = Option_Map{};
    try parseOption(&map, "-Dkey=");
    try testing.expectEqualStrings("", map.getValue("key").?);
}

// ── parseOption: boolean shorthand ──────────────────────────────────────

test "parseOption: -Dsingle-threaded stores true" {
    var map = Option_Map{};
    try parseOption(&map, "-Dsingle-threaded");
    try testing.expectEqualStrings("true", map.getValue("single-threaded").?);
}

test "parseOption: -Dverbose stores true (boolean shorthand)" {
    var map = Option_Map{};
    try parseOption(&map, "-Dverbose");
    try testing.expectEqualStrings("true", map.getValue("verbose").?);
}

// ── parseOption: overwrite ──────────────────────────────────────────────

test "parseOption: second -D with same name overwrites value" {
    var map = Option_Map{};
    try parseOption(&map, "-Doptimize=Debug");
    try parseOption(&map, "-Doptimize=ReleaseFast");
    try testing.expectEqualStrings("ReleaseFast", map.getValue("optimize").?);
    try testing.expectEqual(@as(usize, 1), map.length());
}

// ── getOption: bool ─────────────────────────────────────────────────────

test "getOption bool: true string returns true" {
    var map = Option_Map{};
    try map.put("flag", "true");
    try testing.expectEqual(@as(?bool, true), getOption(bool, &map, "flag"));
}

test "getOption bool: false string returns false" {
    var map = Option_Map{};
    try map.put("flag", "false");
    try testing.expectEqual(@as(?bool, false), getOption(bool, &map, "flag"));
}

test "getOption bool: invalid string returns null" {
    var map = Option_Map{};
    try map.put("flag", "yes");
    try testing.expectEqual(@as(?bool, null), getOption(bool, &map, "flag"));
}

test "getOption bool: missing key returns null" {
    var map = Option_Map{};
    try testing.expectEqual(@as(?bool, null), getOption(bool, &map, "missing"));
}

// ── getOption: integer ──────────────────────────────────────────────────

test "getOption i64: valid integer parses correctly" {
    var map = Option_Map{};
    try map.put("mem-leak-frames", "4");
    try testing.expectEqual(@as(?i64, 4), getOption(i64, &map, "mem-leak-frames"));
}

test "getOption i64: negative integer parses correctly" {
    var map = Option_Map{};
    try map.put("offset", "-100");
    try testing.expectEqual(@as(?i64, -100), getOption(i64, &map, "offset"));
}

test "getOption i64: non-numeric returns null" {
    var map = Option_Map{};
    try map.put("count", "abc");
    try testing.expectEqual(@as(?i64, null), getOption(i64, &map, "count"));
}

// ── getOption: string ───────────────────────────────────────────────────

test "getOption string: returns raw value" {
    var map = Option_Map{};
    try map.put("target", "x86_64-linux-gnu");
    try testing.expectEqualStrings("x86_64-linux-gnu", getOption([]const u8, &map, "target").?);
}

test "getOption string: missing key returns null" {
    var map = Option_Map{};
    try testing.expect(getOption([]const u8, &map, "missing") == null);
}

// ── getOption: enum ─────────────────────────────────────────────────────

const Optimize_Mode = enum { Debug, ReleaseSafe, ReleaseFast, ReleaseSmall };

test "getOption enum: valid variant returns enum value" {
    var map = Option_Map{};
    try map.put("optimize", "Debug");
    try testing.expectEqual(@as(?Optimize_Mode, .Debug), getOption(Optimize_Mode, &map, "optimize"));
}

test "getOption enum: ReleaseFast variant" {
    var map = Option_Map{};
    try map.put("optimize", "ReleaseFast");
    try testing.expectEqual(@as(?Optimize_Mode, .ReleaseFast), getOption(Optimize_Mode, &map, "optimize"));
}

test "getOption enum: invalid variant returns null" {
    var map = Option_Map{};
    try map.put("optimize", "SuperFast");
    try testing.expectEqual(@as(?Optimize_Mode, null), getOption(Optimize_Mode, &map, "optimize"));
}

test "getOption enum: missing key returns null" {
    var map = Option_Map{};
    try testing.expectEqual(@as(?Optimize_Mode, null), getOption(Optimize_Mode, &map, "optimize"));
}

// ── Option_Map capacity ─────────────────────────────────────────────────

test "Option_Map: 128 entries fills to capacity" {
    var map = Option_Map{};
    var name_buf: [4]u8 = undefined;
    var i: usize = 0;
    while (i < MAX_OPTIONS) : (i += 1) {
        // Generate unique 4-char keys: "0000", "0001", ..., "0127"
        name_buf[0] = '0' + @as(u8, @intCast(i / 100 % 10));
        name_buf[1] = '0' + @as(u8, @intCast(i / 10 % 10));
        name_buf[2] = '0' + @as(u8, @intCast(i % 10));
        name_buf[3] = 'x';
        try map.put(&name_buf, "v");
    }
    try testing.expectEqual(@as(usize, MAX_OPTIONS), map.length());
    // 129th should fail
    try testing.expectError(error.CapacityExceeded, map.put("overflow", "v"));
}
