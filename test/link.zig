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
            \\    return 0xaabbccddaabbccdd;
            \\}
            \\export var array_foo: [2]u16 = .{ 0xffff, 0xabcd };
            \\export var strong_foo: usize = 0x1122334411223344;
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
            \\extern var array_foo: [2]u16;
            \\extern var strong_foo: usize;
            \\extern var strong_foo_alias: usize;
            \\pub fn main() !u8 {
            \\    return @intFromBool(0xcd003365cd00df35 != fooBar() +
            \\        weakFoo() +
            \\        array_foo[1] +
            \\        strong_foo +
            \\        strong_foo_alias);
            \\}
            ,
        });
        exe.root_module.linkLibrary(lib);

        const run = case.addRunArtifact(exe);
        run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    }

    if (ctx.includeTest("abs-symbol")) |case| {
        const abs = case.addObject(.{
            .name = "abs",
            .use_llvm = true, // TODO: .globl not supported on self-hosted
            .use_lld = true,
            .asm_source_bytes =
            \\.globl foo
            \\foo = 0xcafecafe
            \\
            ,
        });

        const abs_reloc = case.addObject(.{
            .name = "abs_reloc",
            .use_llvm = true, // TODO: .globl not supported on self-hosted
            .use_lld = true,
            .asm_source_bytes =
            \\.data
            \\.globl foo_copy
            \\foo_copy:
            \\.long foo
            ,
        });

        case.verifyObjdump(abs_reloc, &.{
            "-s",
            "--relocs",
        }, .{ .arch = true });

        const exe_reloc_err = case.addExecutable(.{
            .name = "test-reloc-err",
            .zig_source_bytes =
            \\extern const foo: usize;
            \\pub fn main() !u8 {
            \\    return @intFromBool(foo != 0xcafecafe);
            \\}
            ,
        });
        exe_reloc_err.root_module.addObject(abs);
        case.expectLinkErrors(exe_reloc_err, .{
            .contains = "error: absolute symbol 'foo' targeted by invalid relocation type: /?/",
        });

        const exe = case.addExecutable(.{
            .name = "test",
            .zig_source_bytes =
            \\extern var foo_copy: u32;
            \\pub fn main() !u8 {
            \\    return @intFromBool(foo_copy != 0xcafecafe);
            \\}
            ,
        });
        exe.root_module.addObject(abs);
        exe.root_module.addObject(abs_reloc);

        const run = case.addRunArtifact(exe);
        run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    }
}

const LinkContext = @import("tests.zig").LinkContext;
const std = @import("std");
