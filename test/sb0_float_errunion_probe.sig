//! Native executable regression for aarch64-sb0 error unions, optionals and
//! aggregates whose payload is a runtime float.
//!
//! `error{Bad}!f64` is a 16-byte non-HFA aggregate: the ABI keeps it in x0/x1, but the
//! error-union Value used to tag its payload part as a vector register by type alone, so
//! float instructions were encoded on a general-purpose register alias and the compiler
//! crashed (access violation). The probe produces, returns, unwraps, compares and converts
//! such values within one function and across noinline calls, and checks exact bit patterns.
//! HFA aggregates (struct{f32,f32}) must keep using vector registers.
//!
//! Build with -target aarch64-sb0 --script test/sb0_runner.ld and boot on QEMU virt.
//! Success is the runtime marker SB0-FLOAT-EU-PASS; a mismatch prints
//! SB0-FLOAT-EU-FAIL <case> and parks.
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
noinline fn fail(name: []const u8) noreturn {
    write("SB0-FLOAT-EU-FAIL ");
    write(name);
    write("\n");
    park();
}
fn expect(ok: bool, name: []const u8) void {
    if (!ok) fail(name);
}

const bad_input: u8 = 7;

// Producers: a runtime float payload wrapped in an error union or optional.
noinline fn euF64(x: u8) error{Bad}!f64 {
    if (x == bad_input) return error.Bad;
    return @floatFromInt(x);
}
noinline fn euF32(x: u8) error{Bad}!f32 {
    if (x == bad_input) return error.Bad;
    return @floatFromInt(x);
}
noinline fn optF64(x: u8) ?f64 {
    if (x == bad_input) return null;
    return @floatFromInt(x);
}
noinline fn optF32(x: u8) ?f32 {
    if (x == bad_input) return null;
    return @floatFromInt(x);
}
noinline fn euArith(a: f64, b: f64) error{Bad}!f64 {
    const sum = a * 2.0 + b;
    if (sum > 1000.0) return error.Bad;
    return sum;
}
noinline fn euConst(x: u8) error{Bad}!f64 {
    if (x == bad_input) return error.Bad;
    return 1.5;
}
noinline fn euPassthrough(v: f64) error{Bad}!f64 {
    if (v < 0.0) return error.Bad;
    return v;
}

// HFA and mixed aggregates.
const Hfa = struct { a: f32, b: f32 };
noinline fn makeHfa(x: u8) Hfa {
    const f: f32 = @floatFromInt(x);
    return .{ .a = f, .b = f + 0.5 };
}
const Mixed = struct { d: f64, t: u8 };
noinline fn makeMixed(x: u8) Mixed {
    const f: f64 = @floatFromInt(x);
    return .{ .d = f * 2.0, .t = x };
}
noinline fn euMixed(x: u8) error{Bad}!Mixed {
    if (x == bad_input) return error.Bad;
    const f: f64 = @floatFromInt(x);
    return .{ .d = f * 2.0, .t = x };
}

fn bits64(v: f64) u64 {
    return @bitCast(v);
}
fn bits32(v: f32) u32 {
    return @bitCast(v);
}

// The same function produces and consumes the error union (no ABI boundary).
noinline fn sameFunction(x: u8) f64 {
    const r: error{Bad}!f64 = if (x == bad_input) error.Bad else @as(f64, @floatFromInt(x));
    return r catch -1.0;
}
noinline fn sameFunction32(x: u8) f32 {
    const r: error{Bad}!f32 = if (x == bad_input) error.Bad else @as(f32, @floatFromInt(x));
    return r catch -1.0;
}

// `try` of an error union with a different payload inside a function that returns an error union
// with a float payload: the error path wraps the error and leaves the float payload undefined.
noinline fn inner(x: u8) error{Bad}!u8 {
    if (x == bad_input) return error.Bad;
    return x;
}
noinline fn propagate64(x: u8) error{Bad}!f64 {
    const v = try inner(x);
    return @floatFromInt(v);
}
noinline fn propagate32(x: u8) error{Bad}!f32 {
    const v = try inner(x);
    return @floatFromInt(v);
}

noinline fn caseValues(x: u8) void {
    const want64: f64 = @floatFromInt(x);
    const want32: f32 = @floatFromInt(x);

    // error{Bad}!f64
    const r64 = euF64(x) catch fail("eu64 catch");
    expect(r64 == want64, "eu64 value");
    expect(bits64(r64) == bits64(want64), "eu64 bits");
    expect(euF64(x) catch fail("eu64 reg catch") == want64, "eu64 register resident");
    expect((euF64(x) catch fail("eu64 try compare")) < want64 + 1.0, "eu64 less");
    expect((euF64(x) catch fail("eu64 try compare2")) > want64 - 1.0, "eu64 greater");
    expect(@as(u32, @intFromFloat(r64)) == x, "eu64 intFromFloat");

    // error{Bad}!f32
    const r32 = euF32(x) catch fail("eu32 catch");
    expect(r32 == want32, "eu32 value");
    expect(bits32(r32) == bits32(want32), "eu32 bits");
    expect(@as(u32, @intFromFloat(r32)) == x, "eu32 intFromFloat");
    expect(r32 < want32 + 1.0 and r32 > want32 - 1.0, "eu32 compare");

    // payload produced after a `try` of another error union
    expect(bits64(propagate64(x) catch fail("propagate64")) == bits64(want64), "propagate64 value");
    expect(bits32(propagate32(x) catch fail("propagate32")) == bits32(want32), "propagate32 value");

    // ?f64 and ?f32
    const o64 = optF64(x) orelse fail("opt64 null");
    expect(bits64(o64) == bits64(want64), "opt64 bits");
    const o32 = optF32(x) orelse fail("opt32 null");
    expect(bits32(o32) == bits32(want32), "opt32 bits");

    // arithmetic through an error union, then a chained call
    const a = euArith(want64, 0.5) catch fail("euArith");
    expect(a == want64 * 2.0 + 0.5, "euArith value");
    const c = euPassthrough(a) catch fail("euPassthrough");
    expect(bits64(c) == bits64(a), "euPassthrough bits");
    expect((euConst(x) catch fail("euConst")) == 1.5, "euConst");

    // same function, no call boundary
    expect(sameFunction(x) == want64, "same function f64");
    expect(sameFunction32(x) == want32, "same function f32");

    // aggregates
    const h = makeHfa(x);
    expect(h.a == want32 and h.b == want32 + 0.5, "hfa");
    const m = makeMixed(x);
    expect(m.d == want64 * 2.0 and m.t == x, "mixed");
    const em = euMixed(x) catch fail("euMixed");
    expect(em.d == want64 * 2.0 and em.t == x, "euMixed value");
}

noinline fn caseBad() void {
    if (propagate64(bad_input)) |_| fail("propagate64 missing error") else |err| expect(err == error.Bad, "propagate64 error");
    if (propagate32(bad_input)) |_| fail("propagate32 missing error") else |err| expect(err == error.Bad, "propagate32 error");
    if (euF64(bad_input)) |_| fail("eu64 missing error") else |err| expect(err == error.Bad, "eu64 error");
    if (euF32(bad_input)) |_| fail("eu32 missing error") else |err| expect(err == error.Bad, "eu32 error");
    expect(optF64(bad_input) == null, "opt64 null path");
    expect(optF32(bad_input) == null, "opt32 null path");
    expect(sameFunction(bad_input) == -1.0, "same function error path");
    expect(sameFunction32(bad_input) == -1.0, "same function f32 error path");
    if (euMixed(bad_input)) |_| fail("euMixed missing error") else |err| expect(err == error.Bad, "euMixed error");
    if (euArith(600.0, 1.0)) |_| fail("euArith missing error") else |err| expect(err == error.Bad, "euArith error");
    expect((euPassthrough(-1.0) catch 42.0) == 42.0, "euPassthrough error path");
}

var seed_cell: u8 = 0;
noinline fn seed(value: u8) u8 {
    const cell: *volatile u8 = &seed_cell;
    cell.* = value;
    return cell.*;
}

export fn mainNative() callconv(.c) noreturn {
    const bytes: [*]u8 = @ptrCast(&__bss_start);
    const count = @intFromPtr(&__bss_end) - @intFromPtr(&__bss_start);
    for (0..count) |i| bytes[i] = 0;
    for ([_]u8{ 0, 1, 3, 100, 255 }) |value| caseValues(seed(value));
    caseBad();
    // Exact bit pattern of a known constant: 3.0 = 0x4008000000000000, 3.0f = 0x40400000.
    expect(bits64(euF64(seed(3)) catch fail("pattern eu64")) == 0x4008_0000_0000_0000, "pattern f64");
    expect(bits32(euF32(seed(3)) catch fail("pattern eu32")) == 0x4040_0000, "pattern f32");
    write("SB0-FLOAT-EU-PASS\n");
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
