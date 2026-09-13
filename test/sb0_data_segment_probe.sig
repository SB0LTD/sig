//! SB0X two-segment probe: an app with initialized data AND a large zero-init
//! (BSS) buffer, proving the SB0 link backend emits a read-execute segment plus
//! a SEPARATE read-write segment whose BSS tail is mem-only (file_size <
//! mem_size). This is the layout a real userspace process needs: it must be
//! able to write its own globals (RW pages) and a large zero buffer must not
//! bloat the on-disk image. ci/test-sb0-target.sh asserts the emitted segments.

const builtin = @import("builtin");

comptime {
    if (builtin.target.os.tag != .sb0) @compileError("SB0 OS identity was lost");
    if (builtin.target.abi != .sb0) @compileError("SB0 ABI identity was lost");
}

// Initialized, mutable data → the read-write segment's file-backed bytes.
var counter: u64 = 0x1122334455667788;

// A large zero-initialized buffer → BSS. It must contribute to the RW segment's
// mem_size but NOT its file_size, so the image stays tiny despite the 1 MiB.
var scratch: [1024 * 1024]u8 = undefined;

// A file-scope global-assembly trap stub (as real SB0 apps use) exercises the
// code path that owns executable bytes in the read-execute segment.
export fn probeTrap(op: u64) callconv(.c) void {
    _ = op;
}
comptime {
    if (builtin.cpu.arch == .aarch64) {
        asm (
            \\.global probeTrapAsm
            \\.type probeTrapAsm, %function
            \\probeTrapAsm:
            \\  svc #0
            \\  ret
        );
    }
}

pub export fn _start() callconv(.naked) noreturn {
    // Touch both the data global and the bss buffer so they are retained and
    // land in the read-write segment, then park in the canonical self-loop.
    asm volatile (
        \\  adrp x0, counter
        \\  add  x0, x0, :lo12:counter
        \\  ldr  x1, [x0]
        \\  add  x1, x1, #1
        \\  str  x1, [x0]
        \\  adrp x2, scratch
        \\  add  x2, x2, :lo12:scratch
        \\  str  x1, [x2]
        \\1:
        \\  wfe
        \\  b 1b
    );
}
