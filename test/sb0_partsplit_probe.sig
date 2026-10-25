//! Native executable regression for aarch64-sb0 `Select.Value.FieldPartIterator`
//! part straddling and `copyAdvanced` recursion.
//!
//! Structs built field by field (so their Value is split into small byte parts) and
//! returned inside `error{Bad}!S` / `?S` make `copyAdvanced` ask for regions that
//! straddle those parts. Before the fix the compiler spun forever or overflowed its
//! stack on these shapes (ZPM `tzif.Cursor.rule` and `Exec.Tuples`). The probe checks
//! every field, sentinel fields next to the stored value, the error path, a source
//! that is still register resident (call result consumed immediately) and a source
//! and destination that are the same local.
//!
//! Build with -target aarch64-sb0 --script test/sb0_runner.ld and boot on QEMU virt.
//! Success is the runtime marker SB0-PARTSPLIT-PASS; every mismatch prints
//! SB0-PARTSPLIT-FAIL <case> and the PASS marker is then withheld.
const builtin = @import("builtin");
pub const panic = @import("std").debug.no_panic;
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
var failures: u32 = 0;
/// Report one mismatch and keep going, so a run lists every failing case.
noinline fn fail(name: []const u8) void {
    failures += 1;
    write("SB0-PARTSPLIT-FAIL ");
    write(name);
    write("\n");
}
fn expect(ok: bool, name: []const u8) void {
    if (!ok) fail(name);
}

const pre_sentinel: u32 = 0x1122_3344;
const post_sentinel: u16 = 0x5566;

// ---- 4 bytes: u8, u8, u16 ----------------------------------------------------------
const S4 = struct { a: u8 = 1, b: u8 = 1, c: u16 = 0 };
const W4 = struct { pre: u32, s: S4, post: u16 };
noinline fn make4(x: u8) error{Bad}!S4 {
    if (x == 0) return error.Bad;
    var out: S4 = .{};
    out.b = x;
    out.c = @as(u16, x) *% 257;
    return out;
}
noinline fn makeOpt4(x: u8) ?S4 {
    if (x == 0) return null;
    var out: S4 = .{};
    out.b = x;
    out.c = @as(u16, x) *% 257;
    return out;
}
noinline fn pass4(v: S4) error{Bad}!S4 {
    if (v.b == 0) return error.Bad;
    var out = v;
    out.a +%= 1;
    return out;
}
fn expect4(s: S4, x: u8, a: u8, name: []const u8) void {
    expect(s.a == a and s.b == x and s.c == @as(u16, x) *% 257, name);
}
noinline fn case4(x: u8) void {
    const r = make4(x) catch return fail("s4 catch");
    expect4(r, x, 1, "s4 local");
    expect4(make4(x) catch return fail("s4 reg catch"), x, 1, "s4 register resident");
    var w: W4 = .{ .pre = pre_sentinel, .s = .{}, .post = post_sentinel };
    w.s = make4(x) catch return fail("s4 field catch");
    expect(w.pre == pre_sentinel and w.post == post_sentinel, "s4 sentinels");
    expect4(w.s, x, 1, "s4 stored field");
    var t = r;
    t = pass4(t) catch return fail("s4 same local");
    expect4(t, x, 2, "s4 same local value");
    const o = makeOpt4(x) orelse return fail("s4 optional null");
    expect4(o, x, 1, "s4 optional");
    var wo: W4 = .{ .pre = pre_sentinel, .s = .{}, .post = post_sentinel };
    wo.s = makeOpt4(x).?;
    expect(wo.pre == pre_sentinel and wo.post == post_sentinel, "s4 optional sentinels");
    expect4(wo.s, x, 1, "s4 optional stored field");
    if (make4(0)) |_| fail("s4 missing error") else |err| expect(err == error.Bad, "s4 error");
    expect(makeOpt4(0) == null, "s4 optional null path");
}

// ---- 8 bytes: u8, u8, u16, i32 -----------------------------------------------------
const S8 = struct { a: u8 = 1, b: u8 = 1, c: u16 = 0, d: i32 = 7200 };
const W8 = struct { pre: u32, s: S8, post: u16 };
noinline fn make8(x: u8) error{Bad}!S8 {
    if (x == 0) return error.Bad;
    var out: S8 = .{};
    out.b = x;
    out.d = 0 -% @as(i32, x) *% 100;
    return out;
}
noinline fn makeOpt8(x: u8) ?S8 {
    if (x == 0) return null;
    var out: S8 = .{};
    out.b = x;
    out.d = 0 -% @as(i32, x) *% 100;
    return out;
}
noinline fn pass8(v: S8) error{Bad}!S8 {
    if (v.b == 0) return error.Bad;
    var out = v;
    out.a +%= 1;
    return out;
}
fn expect8(s: S8, x: u8, a: u8, name: []const u8) void {
    expect(s.a == a and s.b == x and s.c == 0 and s.d == 0 -% @as(i32, x) *% 100, name);
}
noinline fn case8(x: u8) void {
    const r = make8(x) catch return fail("s8 catch");
    expect8(r, x, 1, "s8 local");
    expect8(make8(x) catch return fail("s8 reg catch"), x, 1, "s8 register resident");
    var w: W8 = .{ .pre = pre_sentinel, .s = .{}, .post = post_sentinel };
    w.s = make8(x) catch return fail("s8 field catch");
    expect(w.pre == pre_sentinel and w.post == post_sentinel, "s8 sentinels");
    expect8(w.s, x, 1, "s8 stored field");
    var t = r;
    t = pass8(t) catch return fail("s8 same local");
    expect8(t, x, 2, "s8 same local value");
    const o = makeOpt8(x) orelse return fail("s8 optional null");
    expect8(o, x, 1, "s8 optional");
    var wo: W8 = .{ .pre = pre_sentinel, .s = .{}, .post = post_sentinel };
    wo.s = makeOpt8(x).?;
    expect(wo.pre == pre_sentinel and wo.post == post_sentinel, "s8 optional sentinels");
    expect8(wo.s, x, 1, "s8 optional stored field");
    if (make8(0)) |_| fail("s8 missing error") else |err| expect(err == error.Bad, "s8 error");
    expect(makeOpt8(0) == null, "s8 optional null path");
}

// ---- 12 bytes: the ZPM `tzif.RuleDate` shape ---------------------------------------
const Kind = enum { month_week_day, julian, day_of_year };
const S12 = struct {
    kind: Kind = .month_week_day,
    month: u8 = 1,
    week: u8 = 1,
    weekday: u8 = 0,
    day: u16 = 0,
    time: i32 = 7200,
};
const W12 = struct { pre: u32, s: S12, post: u16 };
const Posix12 = struct { std_offset: i32 = 0, has_dst: bool = false, dst_offset: i32 = 0, start: S12 = .{}, end: S12 = .{} };
noinline fn make12(x: u8) error{Bad}!S12 {
    if (x == 0) return error.Bad;
    var out: S12 = .{};
    out.month = x;
    out.day = @as(u16, x) *% 7;
    return out;
}
noinline fn makeOpt12(x: u8) ?S12 {
    if (x == 0) return null;
    var out: S12 = .{};
    out.month = x;
    out.day = @as(u16, x) *% 7;
    return out;
}
noinline fn plain12(x: u8) S12 {
    var out: S12 = .{};
    out.month = x;
    out.day = @as(u16, x) *% 7;
    return out;
}
noinline fn pass12(v: S12) error{Bad}!S12 {
    if (v.month == 0) return error.Bad;
    var out = v;
    out.week +%= 1;
    return out;
}
noinline fn parse12(x: u8) error{Bad}!Posix12 {
    var out: Posix12 = .{};
    out.start = try make12(x);
    out.end = try make12(x +% 1);
    return out;
}
fn expect12(s: S12, x: u8, week: u8, name: []const u8) void {
    expect(s.kind == .month_week_day and s.month == x and s.week == week and s.weekday == 0 and
        s.day == @as(u16, x) *% 7 and s.time == 7200, name);
}
noinline fn case12(x: u8) void {
    expect12(plain12(x), x, 1, "s12 plain return");
    const r = make12(x) catch return fail("s12 catch");
    expect12(r, x, 1, "s12 local");
    expect12(make12(x) catch return fail("s12 reg catch"), x, 1, "s12 register resident");
    var w: W12 = .{ .pre = pre_sentinel, .s = .{}, .post = post_sentinel };
    w.s = make12(x) catch return fail("s12 field catch");
    expect(w.pre == pre_sentinel and w.post == post_sentinel, "s12 sentinels");
    expect12(w.s, x, 1, "s12 stored field");
    var t = r;
    t = pass12(t) catch return fail("s12 same local");
    expect12(t, x, 2, "s12 same local value");
    const o = makeOpt12(x) orelse return fail("s12 optional null");
    expect12(o, x, 1, "s12 optional");
    var wo: W12 = .{ .pre = pre_sentinel, .s = .{}, .post = post_sentinel };
    wo.s = makeOpt12(x).?;
    expect(wo.pre == pre_sentinel and wo.post == post_sentinel, "s12 optional sentinels");
    expect12(wo.s, x, 1, "s12 optional stored field");
    const p = parse12(x) catch return fail("s12 nested catch");
    expect(p.std_offset == 0 and !p.has_dst and p.dst_offset == 0, "s12 nested sentinels");
    expect12(p.start, x, 1, "s12 nested start");
    expect12(p.end, x +% 1, 1, "s12 nested end");
    if (make12(0)) |_| fail("s12 missing error") else |err| expect(err == error.Bad, "s12 error");
    if (parse12(0)) |_| fail("s12 nested missing error") else |err| expect(err == error.Bad, "s12 nested error");
    expect(makeOpt12(0) == null, "s12 optional null path");
}

// ---- 16 bytes: u8, u16, i32, u8, u16, i32 ------------------------------------------
const S16 = struct { a: u8 = 1, b: u16 = 2, c: i32 = -7200, d: u8 = 3, e: u16 = 4, f: i32 = 5 };
const W16 = struct { pre: u32, s: S16, post: u16 };
noinline fn make16(x: u8) error{Bad}!S16 {
    if (x == 0) return error.Bad;
    var out: S16 = .{};
    out.b = @as(u16, x) *% 2;
    out.c = 0 -% @as(i32, x) *% 1000;
    out.e = @as(u16, x) +% 5;
    return out;
}
noinline fn makeOpt16(x: u8) ?S16 {
    if (x == 0) return null;
    var out: S16 = .{};
    out.b = @as(u16, x) *% 2;
    out.c = 0 -% @as(i32, x) *% 1000;
    out.e = @as(u16, x) +% 5;
    return out;
}
noinline fn plain16(x: u8) S16 {
    var out: S16 = .{};
    out.b = @as(u16, x) *% 2;
    out.c = 0 -% @as(i32, x) *% 1000;
    out.e = @as(u16, x) +% 5;
    return out;
}
noinline fn pass16(v: S16) error{Bad}!S16 {
    if (v.a == 0) return error.Bad;
    var out = v;
    out.a +%= 1;
    return out;
}
fn expect16(s: S16, x: u8, a: u8, name: []const u8) void {
    expect(s.a == a and s.b == @as(u16, x) *% 2 and s.c == 0 -% @as(i32, x) *% 1000 and s.d == 3 and
        s.e == @as(u16, x) +% 5 and s.f == 5, name);
}
noinline fn case16(x: u8) void {
    expect16(plain16(x), x, 1, "s16 plain return");
    const r = make16(x) catch return fail("s16 catch");
    expect16(r, x, 1, "s16 local");
    expect16(make16(x) catch return fail("s16 reg catch"), x, 1, "s16 register resident");
    var w: W16 = .{ .pre = pre_sentinel, .s = .{}, .post = post_sentinel };
    w.s = make16(x) catch return fail("s16 field catch");
    expect(w.pre == pre_sentinel and w.post == post_sentinel, "s16 sentinels");
    expect16(w.s, x, 1, "s16 stored field");
    var t = r;
    t = pass16(t) catch return fail("s16 same local");
    expect16(t, x, 2, "s16 same local value");
    const o = makeOpt16(x) orelse return fail("s16 optional null");
    expect16(o, x, 1, "s16 optional");
    var wo: W16 = .{ .pre = pre_sentinel, .s = .{}, .post = post_sentinel };
    wo.s = makeOpt16(x).?;
    expect(wo.pre == pre_sentinel and wo.post == post_sentinel, "s16 optional sentinels");
    expect16(wo.s, x, 1, "s16 optional stored field");
    if (make16(0)) |_| fail("s16 missing error") else |err| expect(err == error.Bad, "s16 error");
    expect(makeOpt16(0) == null, "s16 optional null path");
}

// ---- a struct with a bare union field, built from an anonymous literal and passed by value -------------
// (compiler/frontend/sema.sig `emitIR`): the 16 byte union is a single part wider than a register.
const Node = struct {
    tag: u16,
    data: Data,
    type_index: u32,
    const Data = union {
        binary: struct { lhs: u32, rhs: u32 },
        constant: struct { value: u64 },
        branch: struct { cond: u32, then_block: u32, else_block: u32 },
        none: void,
    };
};
var node_sink: [4]Node = undefined;
var node_count: usize = 0;
noinline fn emitNode(ir: Node) void {
    node_sink[node_count & 3] = ir;
    node_count += 1;
}
noinline fn emitConstant(value: u64, type_index: u32) u32 {
    emitNode(.{ .tag = 1, .data = .{ .constant = .{ .value = value } }, .type_index = type_index });
    return type_index;
}
noinline fn emitBinary(lhs: u32, rhs: u32, type_index: u32) u32 {
    emitNode(.{ .tag = 2, .data = .{ .binary = .{ .lhs = lhs, .rhs = rhs } }, .type_index = type_index });
    return type_index;
}
noinline fn emitBranch(x: u32) void {
    emitNode(.{ .tag = 3, .data = .{ .branch = .{ .cond = x, .then_block = x +% 1, .else_block = x +% 2 } }, .type_index = x *% 3 });
}
noinline fn caseNode(x: u8) void {
    const before = node_count;
    const value: u64 = 0x1122_3344_5566_7788 ^ (@as(u64, x) << 8);
    expect(emitConstant(value, x) == x, "node constant result");
    const c = node_sink[before & 3];
    expect(c.tag == 1 and c.type_index == x and c.data.constant.value == value, "node constant");
    expect(emitBinary(x, ~@as(u32, x), x +% 40) == x +% 40, "node binary result");
    const b = node_sink[(before + 1) & 3];
    expect(b.tag == 2 and b.type_index == x +% 40 and b.data.binary.lhs == x and b.data.binary.rhs == ~@as(u32, x), "node binary");
    emitBranch(x);
    const r = node_sink[(before + 2) & 3];
    expect(r.tag == 3 and r.type_index == @as(u32, x) *% 3 and r.data.branch.cond == x and
        r.data.branch.then_block == @as(u32, x) +% 1 and r.data.branch.else_block == @as(u32, x) +% 2, "node branch");
    expect(node_count == before + 3, "node count");
    // the entries emitted before are not clobbered by later ones (4 entry ring)
    expect(node_sink[before & 3].data.constant.value == value and node_sink[before & 3].type_index == x, "node constant kept");
}var seed_cell: u8 = 0;
noinline fn seed(value: u8) u8 {
    const cell: *volatile u8 = &seed_cell;
    cell.* = value;
    return cell.*;
}

export fn mainNative() callconv(.c) noreturn {
    const bytes: [*]u8 = @ptrCast(&__bss_start);
    const count = @intFromPtr(&__bss_end) - @intFromPtr(&__bss_start);
    for (0..count) |i| bytes[i] = 0;
    for ([_]u8{ 1, 2, 7, 100, 254 }) |value| {
        const x = seed(value);
        case4(x);
        case8(x);
        case12(x);
        case16(x);
        caseNode(x);
    }
    if (failures == 0) write("SB0-PARTSPLIT-PASS\n");
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
