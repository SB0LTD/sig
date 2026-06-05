const std = @import("std");

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "Test it");
    b.default_step = test_step;

    const optimize: std.builtin.OptimizeMode = .Debug;
    const target = b.standardTargetOptions(.{});

    const exe_names: []const []const u8 = &.{ "test", "test-dync", "test-no-llvm", "test-no-llvm-dync" };
    const lib_names: []const []const u8 = &.{ "mathtest", "mathtest-dync", "mathtest-no-llvm", "mathtest-no-llvm-dync" };
    const lib_link_libc: []const bool = &.{ false, true, false, true };
    const lib_use_llvm: []const bool = &.{ true, true, false, false };

    for (exe_names, lib_names, lib_link_libc, lib_use_llvm) |exe_name, lib_name, dyn_libc, use_llvm| {
        if (target.result.os.tag == .windows and target.result.abi == .gnu and dyn_libc and !use_llvm)
            continue; // TODO: sub-compilation of compiler_rt failed (failed to link with LLD: LibCInstallationNotAvailable)

        const lib = b.addLibrary(.{
            .linkage = .dynamic,
            .name = lib_name,
            .version = .{ .major = 1, .minor = 0, .patch = 0 },
            .root_module = b.createModule(.{
                .root_source_file = b.path("mathtest.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = dyn_libc,
            }),
            .use_llvm = use_llvm,
        });

        const exe = b.addExecutable(.{
            .name = exe_name,
            .root_module = b.createModule(.{
                .root_source_file = null,
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        exe.root_module.addCSourceFile(.{
            .file = b.path("test.c"),
            .flags = &[_][]const u8{"-std=c99"},
        });
        exe.root_module.linkLibrary(lib);

        const run_cmd = b.addRunArtifact(exe);
        test_step.dependOn(&run_cmd.step);
    }
}
