// Minimal build script for regenerating zig1.wasm. Both version identities are
// required inputs derived from build.sig, keeping this bootstrap path free of
// independent mutable version constants.
const std = @import("std");

const DevEnv = enum { bootstrap, core, full };
const ValueInterpretMode = enum { direct, by_name };

pub fn build(b: *std.Build) void {
    const zig_version = b.option([]const u8, "zig-version", "Zig compatibility version from build.sig") orelse
        @panic("-Dzig-version is required");
    const sig_version = b.option([]const u8, "sig-version", "Sig version from build.sig") orelse
        @panic("-Dsig-version is required");
    const zig_semver = std.SemanticVersion.parse(zig_version) catch
        @panic("invalid -Dzig-version semantic version");
    const zig_version_z = b.graph.arena.dupeSentinel(u8, zig_version, 0) catch @panic("out of memory");
    const sig_version_z = b.graph.arena.dupeSentinel(u8, sig_version, 0) catch @panic("out of memory");

    const exe = b.addExecutable(.{
        .name = "zig1",
        .max_rss = 7_000_000_000,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(std.Target.Query.parse(.{
                .arch_os_abi = "wasm32-wasi",
                .cpu_features = "baseline+nontrapping_bulk_memory_len0",
            }) catch unreachable),
            .optimize = .ReleaseSmall,
            .single_threaded = true,
        }),
    });

    const aro_mod = b.createModule(.{
        .root_source_file = b.path("lib/compiler/aro/aro.zig"),
    });
    exe.root_module.addImport("aro", aro_mod);

    const exe_options = b.addOptions();
    exe.root_module.addOptions("build_options", exe_options);
    exe_options.addOption(u32, "mem_leak_frames", 0);
    exe_options.addOption(bool, "have_llvm", false);
    exe_options.addOption(bool, "llvm_has_m68k", false);
    exe_options.addOption(bool, "llvm_has_csky", false);
    exe_options.addOption(bool, "llvm_has_arc", false);
    exe_options.addOption(bool, "llvm_has_xtensa", false);
    exe_options.addOption(bool, "debug_gpa", false);
    exe_options.addOption([:0]const u8, "version", zig_version_z);
    exe_options.addOption(std.SemanticVersion, "semver", zig_semver);
    exe_options.addOption(bool, "enable_debug_extensions", false);
    exe_options.addOption(bool, "enable_logging", false);
    exe_options.addOption(bool, "enable_link_snapshots", false);
    exe_options.addOption(bool, "enable_tracy", false);
    exe_options.addOption(bool, "enable_tracy_callstack", false);
    exe_options.addOption(bool, "enable_tracy_allocation", false);
    exe_options.addOption(u32, "tracy_callstack_depth", 0);
    exe_options.addOption(bool, "value_tracing", false);
    exe_options.addOption(bool, "skip_non_native", false);
    exe_options.addOption(DevEnv, "dev", .bootstrap);
    exe_options.addOption(enum { threaded, evented }, "io_mode", .threaded);
    exe_options.addOption(ValueInterpretMode, "value_interpret_mode", .by_name);
    exe_options.addOption([:0]const u8, "sig_version", sig_version_z);

    const update_zig1 = b.addUpdateSourceFiles();
    update_zig1.addCopyFileToSource(exe.getEmittedBin(), "stage1/zig1.wasm");

    const update_step = b.step("update-zig1", "Update stage1/zig1.wasm");
    update_step.dependOn(&update_zig1.step);
}
