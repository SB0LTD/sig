pub fn addCases(ctx: *LinkContext) void {
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

    if (ctx.includeTest("emit-static-lib")) |prefix| {
        const obj1 = ctx.addObject(.{
            .name = "obj1",
            .use_llvm = true,
            .use_lld = true,
            .c_source_bytes =
            \\int foo1 = 1;
            \\int foo2 = 2;
            \\int fooBar() {
            \\  return foo1 + foo2;
            \\}
            ,
        });
        const obj2 = ctx.addObject(.{
            .name = "this_is_a_long_name",
            .zig_source_bytes =
            \\fn weakFoo() callconv(.c) usize {
            \\    return 42;
            \\}
            \\export var strong_foo: usize = 100;
            \\comptime {
            \\    @export(&weakFoo, .{ .name = "weakFoo", .linkage = .weak });
            \\    @export(&strong_foo, .{ .name = "strong_foo_alias", .linkage = .strong });
            \\}
            ,
        });

        const lib = ctx.addLibrary(.static, .{ .name = "lib" });
        lib.root_module.addObject(obj1);
        lib.root_module.addObject(obj2);

        ctx.verifyObjdump(prefix, lib, &.{
            "-s",
            "--elements=file-type",
            "--symbols",
            "--only-symbol=foo",
            "--only-symbol=Foo",
        }, .{});
    }
}

const LinkContext = @import("tests.zig").LinkContext;
const std = @import("std");
