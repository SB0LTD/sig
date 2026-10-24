//! Native executable regression for aarch64-sb0 `@tagName` on run-time enum values.
//!
//! `tag_name` had no instruction selection on this target (`unimplemented tag_name`). It is now
//! expanded by `Air.Legalize` (`expand_tag_name`) into a `cmp_eq` / `cond_br` chain over the enum's
//! fields. The probe names every field of dense, sparse, single-member, 64-bit, negative, odd-width,
//! non-exhaustive and tagged-union enums from run-time values and checks the length, every byte and
//! the NUL sentinel of the returned slice.
//!
//! Build with -target aarch64-sb0 --script test/sb0_runner.ld and boot on QEMU virt.
//! Success is the runtime marker SB0-TAGNAME-PASS; the first mismatch prints SB0-TAGNAME-FAIL <case>.
const std = @import("std");
const builtin = @import("builtin");
pub const panic = std.debug.no_panic;
comptime {
    if (builtin.mode == .safe) {
        @export(&testMemcpy, .{ .name = "memcpy" });
        @export(&testMemset, .{ .name = "memset" });
    }
}
fn testMemcpy(destination: [*]u8, source: [*]const u8, count: usize) callconv(.c) [*]u8 {
    const out: [*]volatile u8 = @ptrCast(destination);
    const input: [*]const volatile u8 = @ptrCast(source);
    var index: usize = 0;
    while (index < count) : (index += 1) out[index] = input[index];
    // x2 is caller-clobbered: callers must not depend on it surviving the call.
    asm volatile ("mov x2, #0x1357" ::: .{ .x2 = true });
    return destination;
}
fn testMemset(destination: [*]u8, value: c_int, count: usize) callconv(.c) [*]u8 {
    const out: [*]volatile u8 = @ptrCast(destination);
    var index: usize = 0;
    while (index < count) : (index += 1) out[index] = @truncate(@as(c_uint, @bitCast(value)));
    asm volatile ("mov x2, #0x1357" ::: .{ .x2 = true });
    return destination;
}

const Dense = enum { a, bb, ccc };
const Sparse = enum(u16) { x = 1, y = 100, z = 40000 };
const Single = enum { only };
const Wide = enum(u64) { lo = 0, mid = 0x8000_0000_0000_0000, hi = 0xFFFF_FFFF_FFFF_FFFF };
const Backed = enum(i8) { neg = -1, zero = 0, pos = 1 };
const Odd = enum(u3) { p = 1, q = 5, r = 7 };
const Long = enum { this_member_name_is_deliberately_longer_than_thirty_two_bytes, short };
const Long64 = enum { abcdefghijklmnopqrstuvwxyz_0123456789_abcdefghijklmnopqrstuvwxyz, tail };
const Open = enum(u8) { first = 1, second = 2, third = 200, _ };
const Tagged = union(enum) { n: u32, s: [4]u8, none };
const TaggedExplicit = union(Dense) { a: u8, bb: u64, ccc };

extern var __bss_start: u8;
extern var __bss_end: u8;
fn write(bytes: []const u8) void {
    const flags: *volatile u32 = @ptrFromInt(0x09000018);
    const data: *volatile u32 = @ptrFromInt(0x09000000);
    for (bytes) |byte| {
        while (flags.* & 32 != 0) {}
        data.* = byte;
    }
}
fn park() noreturn {
    while (true) asm volatile ("wfe");
}
fn fail(what: []const u8) noreturn {
    write("SB0-TAGNAME-FAIL ");
    write(what);
    write("\n");
    park();
}

/// The name is taken in a function of its own so that the value is a run-time parameter.
noinline fn nameOf(value: anytype) [:0]const u8 {
    return @tagName(value);
}

fn expectName(got: [:0]const u8, want: []const u8, what: []const u8) void {
    if (got.len != want.len) fail(what);
    if (!std.mem.eql(u8, got, want)) fail(what);
    if (got.ptr[got.len] != 0) fail(what);
}

fn checkEnum(comptime E: type) void {
    const names = @typeInfo(E).@"enum".field_names;
    const table = comptime blk: {
        var t: [names.len]E = undefined;
        for (names, 0..) |n, k| t[k] = @field(E, n);
        break :blk t;
    };
    var i: usize = 0; // a run-time index: the values are not comptime-known at the call
    while (i < names.len) : (i += 1) {
        const got = nameOf(table[i]);
        inline for (names, 0..) |n, k| {
            if (i == k) expectName(got, n, @typeName(E));
        }
    }
}

fn checkTagged() void {
    var seed: u32 = 0;
    const p: *volatile u32 = &seed;
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        p.* = i;
        const value: Tagged = switch (p.*) {
            0 => .{ .n = 7 },
            1 => .{ .s = .{ 1, 2, 3, 4 } },
            else => .none,
        };
        const want: []const u8 = switch (p.*) {
            0 => "n",
            1 => "s",
            else => "none",
        };
        // The name of the union itself and the name of its tag must agree.
        expectName(nameOf(value), want, "Tagged");
        expectName(nameOf(std.meta.activeTag(value)), want, "Tagged tag");
    }
    i = 0;
    while (i < 3) : (i += 1) {
        p.* = i;
        const value: TaggedExplicit = switch (p.*) {
            0 => .{ .a = 9 },
            1 => .{ .bb = 0x1_0000_0000 },
            else => .ccc,
        };
        const want: []const u8 = switch (p.*) {
            0 => "a",
            1 => "bb",
            else => "ccc",
        };
        expectName(nameOf(value), want, "TaggedExplicit");
    }
}

export fn mainNative() callconv(.c) noreturn {
    const bytes: [*]u8 = @ptrCast(&__bss_start);
    const count = @intFromPtr(&__bss_end) - @intFromPtr(&__bss_start);
    for (0..count) |i| bytes[i] = 0;
    checkEnum(Dense);
    checkEnum(Sparse);
    checkEnum(Single);
    checkEnum(Wide);
    checkEnum(Backed);
    checkEnum(Odd);
    checkEnum(Long);
    checkEnum(Long64);
    checkEnum(Open); // named values of a non-exhaustive enum
    checkTagged();
    write("SB0-TAGNAME-PASS\n");
    park();
}
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ movz x0, #0x4100, lsl #16
        \\ mov sp, x0
        \\ movz x1, #0x30, lsl #16
        \\ msr cpacr_el1, x1
        \\ isb
        \\ bl %[main]
        \\ b .
        :
        : [main] "S" (&mainNative),
        : .{ .memory = true });
}