//! Native, allocator-free SB0 compiler service image.
//!
//! QEMU enters `_start` directly. The runner provisions its own bounded stack,
//! receives one bounded source unit from its fixed SB0 handoff page, invokes the
//! compiler using only static caller-owned storage, and returns SB0X over UART.

const compiler = @import("main.sig");
const streaming = @import("pipeline/streaming.sig");

const MAX_SOURCE_BYTES: usize = 64 * 1024;
const PROTOCOL_VERSION: u16 = 1;
const REQUEST_BASE: usize = 0x4100_0000;

var workspace: compiler.Pipeline_Workspace = undefined;
var source: [MAX_SOURCE_BYTES]u8 = undefined;
var output: [streaming.MAX_EXECUTABLE_IMAGE_BYTES]u8 = undefined;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\  mrs x10, CurrentEL
        \\  cmp x10, #0xc
        \\  b.ne 1f
        \\  msr CPTR_EL3, xzr
        \\1:
        \\  cmp x10, #0x8
        \\  b.lo 2f
        \\  msr CPTR_EL2, xzr
        \\2:
        \\  mov x10, #0x300000
        \\  msr CPACR_EL1, x10
        \\  isb
        \\  movz x9, #0x47f0, lsl #16
        \\  mov sp, x9
        \\  b sb0_runner_main
    );
}

pub export fn sb0_runner_main() callconv(.c) noreturn {
    const request: [*]const volatile u8 = @ptrFromInt(REQUEST_BASE);
    const request_magic = [_]u8{ 'S', 'B', '0', 'C' };
    for (request_magic, 0..) |expected, index| {
        if (request[index] != expected) respondAndHalt(1, 0, 0);
    }
    if (readRequestU16(request, 4) != PROTOCOL_VERSION) respondAndHalt(2, 0, 0);
    const source_len_u32 = readRequestU32(request, 6);
    if (source_len_u32 == 0 or source_len_u32 > MAX_SOURCE_BYTES) {
        respondAndHalt(3, 0, 0);
    }
    const source_len: usize = @intCast(source_len_u32);
    for (source[0..source_len], 0..) |*byte, index| byte.* = request[10 + index];

    const result = compiler.compileSb0SourceToBuffer(source[0..source_len], output[0..], &workspace);
    if (!result.success or result.error_count != 0 or result.bytes_emitted < 4) {
        respondAndHalt(4, 0, result.error_count);
    }
    if (output[0] != 'S' or output[1] != 'B' or output[2] != '0' or output[3] != 'X') {
        respondAndHalt(5, 0, result.error_count);
    }
    respondAndHalt(0, @intCast(result.bytes_emitted), 0);
}

fn respondAndHalt(status: u16, output_len: u32, error_count: u32) noreturn {
    for ([_]u8{ 'S', 'B', '0', 'R' }) |byte| writeUart(byte);
    writeU16Le(PROTOCOL_VERSION);
    writeU16Le(status);
    writeU32Le(output_len);
    writeU32Le(error_count);
    for (output[0..output_len]) |byte| writeUart(byte);
    while (true) asm volatile ("wfe");
}

fn readRequestU16(request: [*]const volatile u8, offset: usize) u16 {
    return @as(u16, request[offset]) | (@as(u16, request[offset + 1]) << 8);
}

fn readRequestU32(request: [*]const volatile u8, offset: usize) u32 {
    return @as(u32, request[offset]) |
        (@as(u32, request[offset + 1]) << 8) |
        (@as(u32, request[offset + 2]) << 16) |
        (@as(u32, request[offset + 3]) << 24);
}

fn writeU16Le(value: u16) void {
    writeUart(@truncate(value));
    writeUart(@truncate(value >> 8));
}

fn writeU32Le(value: u32) void {
    writeUart(@truncate(value));
    writeUart(@truncate(value >> 8));
    writeUart(@truncate(value >> 16));
    writeUart(@truncate(value >> 24));
}

inline fn writeUart(byte: u8) void {
    const data: *volatile u32 = @ptrFromInt(0x0900_0000);
    const flags: *const volatile u32 = @ptrFromInt(0x0900_0018);
    while ((flags.* & (1 << 5)) != 0) asm volatile ("yield");
    data.* = byte;
}
