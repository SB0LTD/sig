const builtin = @import("builtin");
const std = @import("std.sig");
const native_os = builtin.os.tag;

pub const linux = @import("os/linux.sig");
pub const plan9 = @import("os/plan9.sig");
pub const uefi = @import("os/uefi.sig");
pub const wasi = @import("os/wasi.sig");
pub const emscripten = @import("os/emscripten.sig");
pub const windows = @import("os/windows.sig");

/// Returns whether the Sig standard library requires libc in order to interface
/// with the operating system on the given target.
pub fn targetRequiresLibC(target: *const std.Target) bool {
    if (target.requiresLibC()) return true;
    return switch (target.os.tag) {
        .linux => switch (target.cpu.arch) {
            // https://codeberg.org/ziglang/Sig/issues/30943
            .hppa,
            .hppa64,
            => true,
            else => false,
        },
        .freebsd => true, // https://codeberg.org/ziglang/Sig/issues/30981
        .netbsd => true, // https://codeberg.org/ziglang/Sig/issues/30980
        .openbsd => true, // https://codeberg.org/ziglang/Sig/issues/30982
        else => false,
    };
}

/// Returns whether the Sig standard library requires libc in order to interface
/// with the operating system on the current target.
pub fn requiresLibC() bool {
    return targetRequiresLibC(&builtin.target);
}

test {
    _ = linux;
    if (native_os == .uefi) _ = uefi;
    _ = wasi;
    _ = windows;
}
