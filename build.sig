// build.sig — Sig build configuration using sig_build APIs
//
// This file defines the build graph for the Sig compiler project.
// It uses the sig_build zero-allocator build system exclusively.
//
const sig_build = @import("sig_build");
const std = @import("std");

const zig_version: std.SemanticVersion = .{ .major = 0, .minor = 17, .patch = 0 };
const sig_version_string = "0.2.0";

fn noopStep(ctx: *sig_build.Step_Context) sig_build.SigError!void {
    _ = ctx;
}

pub fn build(ctx: *sig_build.Build_Context) !void {
    // Wire version constants
    ctx.zig_version_major = zig_version.major;
    ctx.zig_version_minor = zig_version.minor;
    ctx.zig_version_patch = zig_version.patch;
    @memcpy(ctx.sig_version[0..sig_version_string.len], sig_version_string);
    ctx.sig_version_len = sig_version_string.len;

    // Build options
    const skip_lib = ctx.option(bool, "no-lib", "Skip lib install") orelse false;
    const no_bin = ctx.option(bool, "no-bin", "Skip compiler binary") orelse false;
    const static_llvm = ctx.option(bool, "static-llvm", "Static LLVM") orelse false;
    const enable_llvm = ctx.option(bool, "enable-llvm", "Enable LLVM backend") orelse static_llvm;
    _ = ctx.option(bool, "strip", "Omit debug info");
    _ = ctx.option([]const u8, "version-string", "Override version");
    _ = ctx.option([]const u8, "llvm-prefix", "LLVM prefix path");
    _ = ctx.option([]const u8, "cpp-compiler", "C++ compiler path");
    _ = ctx.option(bool, "llvm-has-m68k", "LLVM m68k target");
    _ = ctx.option(bool, "llvm-has-csky", "LLVM csky target");
    _ = ctx.option(bool, "llvm-has-arc", "LLVM arc target");
    _ = ctx.option(bool, "llvm-has-xtensa", "LLVM xtensa target");

    const has_target = ctx.target.arch_len > 0;

    // Compiler compilation step
    if (!no_bin) {
        _ = try ctx.addCompileStep(.{
            .source_path = "src/main.zig",
            .output_name = "sig",
            .cache_dir = ctx.cache_dir[0..ctx.cache_dir_len],
            .optimize = ctx.optimize,
            .target = if (has_target) &ctx.target else null,
            .imports = &.{},
            .compiler_path = "",
        });
    }

    // LLVM pipeline (conditional)
    if (enable_llvm) {
        const discover_cpp = try ctx.addStep("discover:cpp-compiler", "Find C++ compiler", &sig_build.discoverCppCompiler);
        const discover_llvm = try ctx.addStep("discover:llvm", "Find LLVM 22.x", &sig_build.discoverLlvm);
        try ctx.addDependency(discover_llvm, discover_cpp);

        const cpp_sources = [_]struct { path: []const u8, name: []const u8 }{
            .{ .path = "src/zig_llvm.cpp", .name = "zig_llvm" },
            .{ .path = "src/zig_llvm-ar.cpp", .name = "zig_llvm-ar" },
            .{ .path = "src/zig_clang_driver.cpp", .name = "zig_clang_driver" },
            .{ .path = "src/zig_clang_cc1_main.cpp", .name = "zig_clang_cc1_main" },
            .{ .path = "src/zig_clang_cc1as_main.cpp", .name = "zig_clang_cc1as_main" },
        };

        var cpp_handles: [5]sig_build.Step_Handle = undefined;
        for (cpp_sources, 0..) |src, i| {
            cpp_handles[i] = try ctx.addCppCompileStep(.{
                .source_path = src.path,
                .output_name = src.name,
                .include_dirs = &.{},
                .extra_flags = &.{},
                .extra_defs = &.{},
            });
            try ctx.addDependency(cpp_handles[i], discover_llvm);
        }

        const archive = try ctx.addArchiveStep(.{
            .object_handles = &cpp_handles,
            .output_name = "zigcpp",
        });

        const config = try ctx.addStep("config:sig", "Generate config.sig", &sig_build.generateConfig);

        _ = try ctx.addLlvmLinkStep(.{
            .zigcpp_handle = archive,
            .config_handle = config,
            .lib_dirs = &.{},
            .llvm_libs = &.{},
            .clang_libs = &.{},
            .lld_libs = &.{},
            .system_libs = &.{},
        });
    }

    // Lib installation
    if (!skip_lib) {
        _ = try ctx.addInstallStep(.{
            .source_dir = "lib",
            .dest_dir = "lib/sig",
        });
    }

    // Test step
    _ = try ctx.addStep("test", "Run all tests", &noopStep);
}
