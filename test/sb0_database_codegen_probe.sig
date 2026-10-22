//! Native executable regressions for the wide values used by SQL/wire codecs.
//! Build with -target aarch64-sb0 --script test/sb0_runner.ld and boot on QEMU
//! virt. Success is the runtime marker SB0-DATABASE-CODEGEN-PASS.
// ReleaseSafe uses bounded local routines to keep this regression independent
// of unrelated checked compiler-rt operations. ReleaseSmall executes the normal
// compiler-rt routines as an additional register-clobber regression.
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
    // x2 is caller-clobbered. A surrounding try must reload its error tag,
    // rather than accidentally depending on this helper leaving x2 zero.
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
const Text = struct { bytes: [128]u8, len: usize };
const Cell = union(enum) { number: i64, text: Text, empty };
const Pair = struct { first: Text, second: Text };
const Floats = struct { first: f64, second: f64, third: f64 };
const FloatEnvelope = struct { floats: Floats, identity: u64 };
var optional: ?Text = null;
var reader_input: [2]u8 = undefined;
const Reader = struct {
    bytes: []const u8,
    at: usize = 0,
    fn take(self: *Reader, n: usize) ![]const u8 {
        if (n > self.bytes.len - self.at) return error.ProtocolViolation;
        const result = self.bytes[self.at..][0..n];
        self.at += n;
        return result;
    }
    noinline fn byte(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }
    fn string(self: *Reader) ![]const u8 {
        const begin = self.at;
        while (self.at < self.bytes.len) : (self.at += 1) {
            if (self.bytes[self.at] == 0) {
                const result = self.bytes[begin..self.at];
                self.at += 1;
                return result;
            }
        }
        return error.ProtocolViolation;
    }
    fn done(self: *const Reader) !void {
        if (self.at != self.bytes.len) return error.ProtocolViolation;
    }
};
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
fn check(ok: bool) !void {
    if (!ok) return error.WrongNativeValue;
}

noinline fn make(seed: u64) !Cell {
    if (seed == 0) return error.NoValue;
    var text: Text = .{ .bytes = @splat('x'), .len = @intCast(seed) };
    text.bytes[127] = @truncate(seed);
    return .{ .text = text };
}
noinline fn readText(cell: Cell) Text {
    return switch (cell) {
        .text => |text| text,
        else => .{ .bytes = @splat(0), .len = 0 },
    };
}
noinline fn optionalPresent(pointer: *const ?Text) bool {
    return pointer.* != null;
}
noinline fn pair(seed: usize) !Pair {
    if (seed == 0) return error.NoValue;
    return .{ .first = .{ .bytes = @splat(19), .len = seed }, .second = .{ .bytes = @splat(27), .len = seed + 1 } };
}
noinline fn makeFloats(seed: f64) Floats {
    return .{ .first = seed, .second = seed + 1, .third = seed + 2 };
}
noinline fn embedFloats(seed: f64, identity: u64) FloatEnvelope {
    return .{ .floats = makeFloats(seed), .identity = identity };
}
noinline fn extractFloats(value: FloatEnvelope) Floats {
    return value.floats;
}
const FloatOuter = struct { floats: Floats };
noinline fn makeFloatOuter(seed: f64) FloatOuter {
    return .{ .floats = makeFloats(seed) };
}
noinline fn extractFloatOuter(seed: f64) Floats {
    return makeFloatOuter(seed).floats;
}
noinline fn readKind(bytes: []const u8) !u8 {
    var reader: Reader = .{ .bytes = bytes };
    const kind = try reader.byte();
    const name = try reader.string();
    try reader.done();
    try check(name.len == 0);
    if (kind == 'S') return 1;
    if (kind == 'P') return 2;
    return error.ProtocolViolation;
}
noinline fn probe(seed: u64) !void {
    reader_input[0] = if (seed & 1 == 0) 'S' else 'P';
    reader_input[1] = 0;
    try check(try readKind(&reader_input) == @as(u8, if (seed & 1 == 0) 1 else 2));
    const cell = try make(seed);
    const text = readText(cell);
    try check(text.len == seed and text.bytes[0] == 'x' and text.bytes[127] == @as(u8, @truncate(seed)));
    const both = try pair(@intCast(seed));
    try check(both.first.len == seed and both.second.len == seed + 1);
    try check(both.first.bytes[127] == 19 and both.second.bytes[0] == 27);
    const float_seed: f64 = @floatFromInt(seed);
    const floats = extractFloats(embedFloats(float_seed, seed));
    try check(floats.first == float_seed and floats.second == float_seed + 1 and floats.third == float_seed + 2);
    const outer_floats = extractFloatOuter(float_seed);
    try check(outer_floats.first == float_seed and outer_floats.second == float_seed + 1 and outer_floats.third == float_seed + 2);
    try check(!optionalPresent(&optional));
    optional = text;
    try check(optionalPresent(&optional));
    try check(optional.?.bytes[127] == @as(u8, @truncate(seed)));
    optional = null;
    try check(!optionalPresent(&optional));
    const bit: u1 = @truncate(seed);
    const boolean: bool = @bitCast(bit);
    try check(boolean == (bit == 1));
    const signed: i1 = @bitCast(bit);
    const signed_boolean: bool = @bitCast(signed);
    try check(@intFromBool(signed_boolean) == @as(u8, bit));
    if (make(0)) |_| return error.MissingError else |err| try check(err == error.NoValue);
    if (pair(0)) |_| return error.MissingError else |err| try check(err == error.NoValue);
}
export fn mainNative() callconv(.c) noreturn {
    const bytes: [*]u8 = @ptrCast(&__bss_start);
    const count = @intFromPtr(&__bss_end) - @intFromPtr(&__bss_start);
    for (0..count) |i| bytes[i] = 0;
    for ([_]u64{ 1, 2, 123, 128 }) |seed| probe(seed) catch {
        write("SB0-DATABASE-CODEGEN-FAIL\n");
        park();
    };
    write("SB0-DATABASE-CODEGEN-PASS\n");
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
