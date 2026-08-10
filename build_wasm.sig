// Native, allocator-free build description for regenerating stage1/zig1.wasm.
//
// This deliberately bypasses std.Build: the checked-in Sig bootstrap compiles
// the WebAssembly compiler snapshot directly, with every mutable identity
// supplied by build.sig and every buffer bounded at compile time.
const std = @import("std");
const sig_build = @import("sig_build");

const wasm_output = "stage1/zig1.wasm";

fn buildWasm(step: *sig_build.Step_Context) sig_build.SigError!void {
    const ctx = step.build_ctx;
    const io = step.io;
    const compiler = if (step.compiler_path.len > 0) step.compiler_path else "sig";

    var version_buf: [32]u8 = undefined;
    const zig_version = std.fmt.bufPrint(&version_buf, "{d}.{d}.{d}", .{
        ctx.zig_version_major,
        ctx.zig_version_minor,
        ctx.zig_version_patch,
    }) catch return error.BufferTooSmall;
    const cache_dir = ctx.cache_dir[0..ctx.cache_dir_len];
    try sig_build.generateBuildOptions(ctx, zig_version, cache_dir, io);

    var build_options_path_buf: [sig_build.PATH_BUF_SIZE]u8 = undefined;
    const build_options_path = try sig_build.pathJoin(
        &build_options_path_buf,
        &.{ cache_dir, "build_options.sig" },
    );
    var step_cache_path_buf: [sig_build.PATH_BUF_SIZE]u8 = undefined;
    const step_cache_path = try sig_build.pathJoin(
        &step_cache_path_buf,
        &.{ cache_dir, "wasm-compiler" },
    );
    std.Io.Dir.cwd().createDirPath(io, step_cache_path) catch
        return error.BufferTooSmall;

    var root_module_buf: [sig_build.PATH_BUF_SIZE]u8 = undefined;
    const root_module = std.fmt.bufPrint(&root_module_buf, "-Mroot={s}", .{"src/main.zig"}) catch
        return error.BufferTooSmall;
    var aro_module_buf: [sig_build.PATH_BUF_SIZE]u8 = undefined;
    const aro_module = std.fmt.bufPrint(&aro_module_buf, "-Maro={s}", .{"lib/compiler/aro/aro.zig"}) catch
        return error.BufferTooSmall;
    var options_module_buf: [sig_build.PATH_BUF_SIZE]u8 = undefined;
    const options_module = std.fmt.bufPrint(
        &options_module_buf,
        "-Mbuild_options={s}",
        .{build_options_path},
    ) catch return error.BufferTooSmall;
    var emit_buf: [sig_build.PATH_BUF_SIZE]u8 = undefined;
    const emit = std.fmt.bufPrint(&emit_buf, "-femit-bin={s}", .{wasm_output}) catch
        return error.BufferTooSmall;

    var cmd: sig_build.Command_Buffer = .{};
    try cmd.appendArg(compiler);
    try cmd.appendArg("build-exe");
    // Target, CPU, optimization and threading are per-module CLI options;
    // they must precede the root -M declaration or they silently apply to no
    // module and a host executable is emitted instead.
    try cmd.appendArg("-target");
    try cmd.appendArg("wasm32-wasi");
    try cmd.appendArg("-mcpu");
    try cmd.appendArg("baseline+nontrapping_bulk_memory_len0");
    try cmd.appendArg("-OReleaseSmall");
    try cmd.appendArg("-fsingle-threaded");
    try cmd.appendArg("--dep");
    try cmd.appendArg("aro");
    try cmd.appendArg("--dep");
    try cmd.appendArg("build_options");
    try cmd.appendArg(root_module);
    try cmd.appendArg(aro_module);
    try cmd.appendArg(options_module);
    try cmd.appendArg("-lc");
    try cmd.appendArg("--cache-dir");
    try cmd.appendArg(step_cache_path);
    if (ctx.global_cache_dir_len > 0) {
        try cmd.appendArg("--global-cache-dir");
        try cmd.appendArg(ctx.global_cache_dir[0..ctx.global_cache_dir_len]);
    }
    if (ctx.zig_lib_dir_len > 0) {
        try cmd.appendArg("--zig-lib-dir");
        try cmd.appendArg(ctx.zig_lib_dir[0..ctx.zig_lib_dir_len]);
    }
    try cmd.appendArg(emit);

    sig_build.printMsg(io, "wasm: compiling {s}", .{wasm_output});
    var stderr_buf: [sig_build.STDERR_CAPTURE_SIZE]u8 = undefined;
    var stderr_len: usize = 0;
    const exit_code = try sig_build.runCommand(&cmd, &stderr_buf, &stderr_len, io);
    if (exit_code != 0) {
        if (stderr_len > 0) sig_build.printMsg(io, "wasm compiler failed:\n{s}", .{stderr_buf[0..stderr_len]});
        return error.BufferTooSmall;
    }

    var file = std.Io.Dir.cwd().openFile(io, wasm_output, .{}) catch
        return error.BufferTooSmall;
    defer file.close(io);
    var magic: [4]u8 = undefined;
    var reader = file.readerStreaming(io, &.{});
    const count = reader.interface.readSliceShort(&magic) catch
        return error.BufferTooSmall;
    if (count != magic.len or !std.mem.eql(u8, &magic, "\x00asm")) {
        sig_build.printMsg(io, "wasm: invalid output magic", .{});
        return error.BufferTooSmall;
    }
    sig_build.printMsg(io, "wasm: verified {s}", .{wasm_output});
}

pub fn build(ctx: *sig_build.Build_Context) !void {
    const zig_version = ctx.option(
        []const u8,
        "zig-version",
        "Zig compatibility version from build.sig",
    ) orelse return error.BufferTooSmall;
    const sig_version = ctx.option(
        []const u8,
        "sig-version",
        "Sig version from build.sig",
    ) orelse return error.BufferTooSmall;
    const semver = std.SemanticVersion.parse(zig_version) catch
        return error.BufferTooSmall;
    if (sig_version.len == 0 or sig_version.len > ctx.sig_version.len) {
        return error.BufferTooSmall;
    }

    ctx.zig_version_major = @intCast(semver.major);
    ctx.zig_version_minor = @intCast(semver.minor);
    ctx.zig_version_patch = @intCast(semver.patch);
    @memcpy(ctx.sig_version[0..sig_version.len], sig_version);
    ctx.sig_version_len = sig_version.len;
    ctx.optimize = .ReleaseSmall;

    // These values reproduce the canonical stage1 bootstrap personality from
    // the former std.Build description without allocating an options object.
    try ctx.options.put("dev", "bootstrap");
    try ctx.options.put("value-interpret-mode", "by_name");
    try ctx.options.put("mem-leak-frames", "0");
    try ctx.options.put("skip-non-native", "false");

    _ = try ctx.addStep(
        "update-zig1",
        "Compile and atomically verify stage1/zig1.wasm",
        &buildWasm,
    );
}
