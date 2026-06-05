pub fn addCases(ctx: *LinkContext) void {
    if (ctx.includeTest("exports-static")) |case| {
        const lib = case.addLibrary(.static, .{
            .name = "lib",
            .zig_source_file = ctx.sourcePath("exports.zig"),
        });
        case.verifyObjdump(lib, &.{
            "-s",
            "--symbols",
            "--only-symbol=foo",
        }, .{});
    }

    if (ctx.includeTest("exports-dynamic")) |case| {
        const lib = case.addLibrary(.dynamic, .{
            .name = "lib",
            .zig_source_file = ctx.sourcePath("exports.zig"),
        });
        case.verifyObjdump(lib, &.{
            "-s",
            "--exports",
            "--only-symbol=foo",
        }, .{});
    }

    if (ctx.includeTest("emit-static-lib")) |case| {
        const obj1 = case.addObject(.{
            .name = "obj1",
            .name_prefix = false,
            .name_target = false,
            .use_llvm = true,
            .use_lld = true,
            .c_source_bytes =
            \\int foo1 = 1;
            \\int foo2 = 2;
            \\unsigned int fooBar() {
            \\  return foo1 + foo2;
            \\}
            ,
        });
        const obj2 = case.addObject(.{
            .name = "this_is_a_long_name",
            .name_prefix = false,
            .name_target = false,
            .zig_source_bytes =
            \\fn weakFoo() callconv(.c) usize {
            \\    return 0xaabbccdd;
            \\}
            \\export var strong_foo: usize = 0x11223344;
            \\comptime {
            \\    @export(&weakFoo, .{ .name = "weakFoo", .linkage = .weak });
            \\    @export(&strong_foo, .{ .name = "strong_foo_alias", .linkage = .strong });
            \\}
            ,
        });

        const lib = case.addLibrary(.static, .{
            .name = "lib",
            .name_prefix = false,
            .name_target = false,
        });
        lib.root_module.addObject(obj1);
        lib.root_module.addObject(obj2);

        case.verifyObjdump(lib, &.{
            "-s",
            "--elements=file-type",
            "--symbols",
            "--only-symbol=foo",
            "--only-symbol=Foo",
        }, .{});

        const exe = case.addExecutable(.{
            .name = "test",
            .zig_source_bytes =
            \\extern fn fooBar() c_uint;
            \\extern fn weakFoo() usize;
            \\extern var strong_foo: usize;
            \\extern var strong_foo_alias: usize;
            \\pub fn main() !u8 {
            \\    return @intFromBool(0xcd003368 != fooBar() +
            \\        weakFoo() +
            \\        strong_foo +
            \\        strong_foo_alias);
            \\}
            ,
        });
        exe.root_module.linkLibrary(lib);

        const run = case.addRunArtifact(exe);
        run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    }
}

const LinkContext = @import("tests.zig").LinkContext;
const std = @import("std");
