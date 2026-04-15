// Minimal build.zig for generating zig1.wasm via: zig2 build --build-file build_wasm.zig update-zig1
const std = @import("std");

const DevEnv = enum { bootstrap, core, full };
const ValueInterpretMode = enum { direct, by_name };

pub fn build(b: *std.Build) void {
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
    exe_options.addOption([:0]const u8, "version", "0.16.0-dev");
    exe_options.addOption(std.SemanticVersion, "semver", std.SemanticVersion.parse("0.16.0-dev") catch unreachable);
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
    exe_options.addOption([:0]const u8, "sig_version", "0.1.2");

    const update_zig1 = b.addUpdateSourceFiles();
    update_zig1.addCopyFileToSource(exe.getEmittedBin(), "stage1/zig1.wasm");

    const update_step = b.step("update-zig1", "Update stage1/zig1.wasm");
    update_step.dependOn(&update_zig1.step);
}
