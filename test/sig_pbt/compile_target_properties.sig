// Feature: sig-compilation-engine, Property 5: Target triple resolution correctness
//
// For any valid Target_Triple with a specified (arch, os, abi) combination,
// resolve() SHALL produce a ResolvedTarget where cpu_arch matches the requested
// architecture, os_tag matches the requested OS, abi matches the requested ABI,
// and ofmt equals the correct object format (ELF for linux, COFF for windows,
// Mach-O for macos).
//
// Validates: Requirements 3.1, 3.6

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const compile_target = @import("compile_target");

const Target_Triple = compile_target.Target_Triple;
const ResolvedTarget = compile_target.ResolvedTarget;

// ---------------------------------------------------------------------------
// Generators — random enum selection excluding `.native`
// ---------------------------------------------------------------------------

fn randomArch(random: std.Random) Target_Triple.Arch {
    const non_native = [_]Target_Triple.Arch{ .x86_64, .aarch64, .arm };
    return non_native[random.uintLessThan(usize, non_native.len)];
}

fn randomOs(random: std.Random) Target_Triple.Os {
    const non_native = [_]Target_Triple.Os{ .linux, .windows, .macos };
    return non_native[random.uintLessThan(usize, non_native.len)];
}

fn randomAbi(random: std.Random) Target_Triple.Abi {
    const non_native = [_]Target_Triple.Abi{ .musl, .gnu, .none, .msvc };
    return non_native[random.uintLessThan(usize, non_native.len)];
}

// ---------------------------------------------------------------------------
// Helpers — expected mappings
// ---------------------------------------------------------------------------

fn expectedCpuArch(arch: Target_Triple.Arch) std.Target.Cpu.Arch {
    return switch (arch) {
        .native => builtin.cpu.arch,
        .x86_64 => .x86_64,
        .aarch64 => .aarch64,
        .arm => .arm,
    };
}

fn expectedOsTag(os: Target_Triple.Os) std.Target.Os.Tag {
    return switch (os) {
        .native => builtin.os.tag,
        .linux => .linux,
        .windows => .windows,
        .macos => .macos,
    };
}

fn expectedAbi(abi: Target_Triple.Abi) std.Target.Abi {
    return switch (abi) {
        .native => builtin.abi,
        .musl => .musl,
        .gnu => .gnu,
        .none => .none,
        .msvc => .msvc,
    };
}

fn expectedOfmt(os_tag: std.Target.Os.Tag) std.Target.ObjectFormat {
    return switch (os_tag) {
        .linux => .elf,
        .windows => .coff,
        .macos => .macho,
        else => builtin.target.ofmt,
    };
}

// ---------------------------------------------------------------------------
// Property 5 – Random valid triple resolution
// ---------------------------------------------------------------------------

test "Property 5: random valid triple resolves to correct arch, os, abi, ofmt" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const arch = randomArch(random);
            const os = randomOs(random);
            const abi = randomAbi(random);

            const triple = Target_Triple{
                .arch = arch,
                .os = os,
                .abi = abi,
            };

            const resolved = triple.resolve();

            try std.testing.expectEqual(expectedCpuArch(arch), resolved.cpu_arch);
            try std.testing.expectEqual(expectedOsTag(os), resolved.os_tag);
            try std.testing.expectEqual(expectedAbi(abi), resolved.abi);
            try std.testing.expectEqual(expectedOfmt(expectedOsTag(os)), resolved.ofmt);
        }
    };
    harness.property("random valid triple resolves to correct arch, os, abi, ofmt", S.run);
}

// ---------------------------------------------------------------------------
// Property 5 – Native target defaults
// ---------------------------------------------------------------------------

test "Property 5: native triple resolves to host builtin values" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            const triple = Target_Triple{
                .arch = .native,
                .os = .native,
                .abi = .native,
            };

            const resolved = triple.resolve();

            try std.testing.expectEqual(builtin.cpu.arch, resolved.cpu_arch);
            try std.testing.expectEqual(builtin.os.tag, resolved.os_tag);
            try std.testing.expectEqual(builtin.abi, resolved.abi);
            try std.testing.expectEqual(expectedOfmt(builtin.os.tag), resolved.ofmt);
        }
    };
    harness.property("native triple resolves to host builtin values", S.run);
}

// ---------------------------------------------------------------------------
// Property 5 – Object format mapping per OS
// ---------------------------------------------------------------------------

test "Property 5: object format mapping linux->elf, windows->coff, macos->macho" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            // linux → ELF
            const linux_triple = Target_Triple{ .arch = .x86_64, .os = .linux, .abi = .gnu };
            const linux_resolved = linux_triple.resolve();
            try std.testing.expectEqual(std.Target.ObjectFormat.elf, linux_resolved.ofmt);

            // windows → COFF
            const win_triple = Target_Triple{ .arch = .x86_64, .os = .windows, .abi = .msvc };
            const win_resolved = win_triple.resolve();
            try std.testing.expectEqual(std.Target.ObjectFormat.coff, win_resolved.ofmt);

            // macos → Mach-O
            const mac_triple = Target_Triple{ .arch = .aarch64, .os = .macos, .abi = .none };
            const mac_resolved = mac_triple.resolve();
            try std.testing.expectEqual(std.Target.ObjectFormat.macho, mac_resolved.ofmt);
        }
    };
    harness.property("object format mapping linux->elf, windows->coff, macos->macho", S.run);
}
