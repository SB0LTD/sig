/// Target Triple — typed cross-compilation target specification.
///
/// Provides a fixed-size struct encoding architecture, OS, and ABI for
/// cross-compilation. The `resolve()` method converts these typed enums
/// into the compiler's internal target representation.
///
/// Unlike the raw-string Target_Triple in the build runner (main.sig),
/// this uses typed enums for compile-time safety and exhaustive matching.
const std = @import("std");
const builtin = @import("builtin");

/// Resolved target information suitable for passing to the Compilation API.
/// Contains the concrete arch, OS, ABI, and object format after resolving
/// any `.native` fields against the host system.
pub const ResolvedTarget = struct {
    cpu_arch: std.Target.Cpu.Arch,
    os_tag: std.Target.Os.Tag,
    abi: std.Target.Abi,
    ofmt: std.Target.ObjectFormat,
};

/// A typed cross-compilation target triple.
///
/// All fields default to `.native`, meaning "use the host system's value".
/// When all fields are `.native`, `resolve()` returns the host target exactly.
pub const Target_Triple = struct {
    arch: Arch = .native,
    os: Os = .native,
    abi: Abi = .native,

    pub const Arch = enum {
        native,
        x86_64,
        aarch64,
        arm,
    };

    pub const Os = enum {
        native,
        linux,
        windows,
        macos,
    };

    pub const Abi = enum {
        native,
        musl,
        gnu,
        none,
        msvc,
    };

    /// Convert this Target_Triple to a ResolvedTarget by mapping enum values
    /// to std.Target types. For `.native` fields, the host system's values
    /// (from `builtin`) are used.
    pub fn resolve(self: Target_Triple) ResolvedTarget {
        const resolved_arch = switch (self.arch) {
            .native => builtin.cpu.arch,
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
            .arm => .arm,
        };

        const resolved_os: std.Target.Os.Tag = switch (self.os) {
            .native => builtin.os.tag,
            .linux => .linux,
            .windows => .windows,
            .macos => .macos,
        };

        const resolved_abi: std.Target.Abi = switch (self.abi) {
            .native => builtin.abi,
            .musl => .musl,
            .gnu => .gnu,
            .none => .none,
            .msvc => .msvc,
        };

        const resolved_ofmt = objectFormatForOs(resolved_os);

        return .{
            .cpu_arch = resolved_arch,
            .os_tag = resolved_os,
            .abi = resolved_abi,
            .ofmt = resolved_ofmt,
        };
    }

    /// Determine the correct object format for a given OS.
    /// - linux  → ELF
    /// - windows → COFF
    /// - macos  → Mach-O
    /// - other  → fall back to the host's object format
    fn objectFormatForOs(os_tag: std.Target.Os.Tag) std.Target.ObjectFormat {
        return switch (os_tag) {
            .linux => .elf,
            .windows => .coff,
            .macos => .macho,
            else => builtin.target.ofmt,
        };
    }
};
