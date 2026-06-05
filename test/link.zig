pub fn addCases(ctx: *@import("tests.zig").LinkContext) void {
    if (ctx.includeTest("exports-static")) |prefix| {
        const lib = ctx.addLibrary(.static, .{
            .name = "lib",
            .zig_source_file = ctx.sourcePath("exports.zig"),
        });
        ctx.verifyObjdump(prefix, lib, &.{
            "-s",
            "--symbols",
            "--only-symbol=foo",
        }, .{});
    }

    if (ctx.includeTest("exports-dynamic")) |prefix| {
        const lib = ctx.addLibrary(.dynamic, .{
            .name = "lib",
            .zig_source_file = ctx.sourcePath("exports.zig"),
        });
        ctx.verifyObjdump(prefix, lib, &.{
            "-s",
            "--exports",
            "--only-symbol=foo",
        }, .{});
    }



}

const std = @import("std");
