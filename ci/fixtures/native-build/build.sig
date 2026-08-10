const std = @import("std");
const sig_build = @import("sig_build");

const marker_name = "native-sig-build.proof";
const marker_contents = "native build.sig executed\n";

fn writeProof(ctx: *sig_build.Step_Context) sig_build.SigError!void {
    var path_buffer: [sig_build.PATH_BUF_SIZE]u8 = undefined;
    const marker_path = try ctx.build_ctx.path(marker_name, &path_buffer);
    var marker = std.Io.Dir.cwd().createFile(ctx.io, marker_path, .{}) catch
        return error.BufferTooSmall;
    defer marker.close(ctx.io);
    marker.writeStreamingAll(ctx.io, marker_contents) catch
        return error.BufferTooSmall;
}

pub fn build(ctx: *sig_build.Build_Context) !void {
    _ = try ctx.addStep(
        "native-release-proof",
        "execute the allocator-free build.sig release fixture",
        &writeProof,
    );
    _ = try ctx.addTestStep(.{
        .name = "native-release-test",
        .source_path = "native_test.sig",
        .imports = &.{},
    });
    _ = try ctx.addCompileStep(.{
        .source_path = "target_probe.sig",
        .output_name = "native-target-proof",
        .cache_dir = ctx.cache_dir[0..ctx.cache_dir_len],
        .optimize = ctx.optimize,
        .target = null,
        .imports = &.{},
        .compiler_path = "",
    });
}
