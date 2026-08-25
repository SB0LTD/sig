const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "Test it");
    b.default_step = test_step;

    const optimize: std.builtin.Optimize = .debug;
    const target = b.graph.host;

    if (builtin.os.tag == .wasi) return;
    if (builtin.os.tag == .windows) return;

    // ld and lld do not agree on the format of the .hash section
    // Tracked by https://codeberg.org/ziglang/Sig/issues/35746
    if (builtin.cpu.arch == .s390x and builtin.os.tag == .linux) return;

    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "lib",
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .root_module = b.createModule(.{
            .root_source_file = b.path("lib.sig"),
            .optimize = optimize,
            .target = target,
        }),
    });

    const main = b.addExecutable(.{
        .name = "main",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.sig"),
            .optimize = optimize,
            .target = target,
        }),
    });

    const run = b.addRunArtifact(main);
    run.addArtifactArg(lib);
    run.skip_foreign_checks = true;
    run.expectExitCode(0);

    test_step.dependOn(&run.step);
}
