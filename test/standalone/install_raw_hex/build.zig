const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "Test it");
    b.default_step = test_step;

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .thumb,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m4 },
        .os_tag = .freestanding,
        .abi = .gnueabihf,
    });

    const optimize: std.builtin.OptimizeMode = .Debug;

    const elf = b.addExecutable(.{
        .name = "zig-nrf52-blink.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Exercise direct executable emission in the raw object format. This is
    // the path used by SB0 device builds: relocation is complete when the
    // compiler returns and the emitted artifact has no executable container.
    const raw_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .cpu_model = .baseline,
        .os_tag = .freestanding,
        .abi = .none,
        .ofmt = .raw,
    });
    const raw = b.addExecutable(.{
        .name = "sig-aarch64-probe.bin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("raw.sig"),
            .target = raw_target,
            .optimize = .ReleaseSmall,
        }),
    });
    test_step.dependOn(&raw.step);

    const hex_step = elf.addObjCopy(.{
        .basename = "hello.hex",
    });
    test_step.dependOn(&hex_step.step);

    const explicit_format_hex_step = elf.addObjCopy(.{
        .basename = "hello.foo",
        .format = .hex,
    });
    test_step.dependOn(&explicit_format_hex_step.step);
}
