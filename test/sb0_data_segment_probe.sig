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

// Touch both globals from Sig so the backend emits real nav relocations (which
// the SB0 linker resolves) -- referencing them by name in raw asm would not
// bind. export + callconv(.c) keeps it a plain function the entry calls.
export fn probeTouch() callconv(.c) void {
    counter +%= 1;
    scratch[0] = @truncate(counter);
    scratch[scratch.len - 1] = @truncate(counter >> 8);
}

pub export fn _start() callconv(.naked) noreturn {
    // Call the Sig-level touch (retains + writes the data/bss globals) then park
    // in the canonical self-loop. The entry is placed first in the RX segment.
    asm volatile (
        \\  bl   %[touch]
        \\1:
        \\  wfe
        \\  b 1b
        :
        : [touch] "S" (&probeTouch),
        : .{ .memory = true });
}
