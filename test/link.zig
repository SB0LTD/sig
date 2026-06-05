pub fn addCases(ctx: *LinkContext) void {
    if (ctx.includeTest("static-lib")) |case| {
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
            \\fn fooWeak() callconv(.c) usize {
            \\    return 0xaabbccddaabbccdd;
            \\}
            \\export var foo_array: [2]u16 = .{ 0xffff, 0xabcd };
            \\export var foo_strong: usize = 0x1122334411223344;
            \\comptime {
            \\    @export(&fooWeak, .{ .name = "fooWeak", .linkage = .weak });
            \\    @export(&foo_strong, .{ .name = "foo_strong_alias", .linkage = .strong });
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

        case.verifyObjdump(lib.getEmittedBin(), &.{
            "-s",
            "--elements=file-type",
            "--symbols",
            "--only-symbol=foo",
        }, .{});

        const exe = case.addExecutable(.{
            .name = "test",
            .zig_source_bytes =
            \\extern fn fooBar() c_uint;
            \\extern fn fooWeak() usize;
            \\extern var foo_array: [2]u16;
            \\extern var foo_strong: usize;
            \\extern var foo_strong_alias: usize;
            \\pub fn main() !u8 {
            \\    return @intFromBool(0xcd003365cd00df35 != fooBar() +
            \\        fooWeak() +
            \\        foo_array[1] +
            \\        foo_strong +
            \\        foo_strong_alias);
            \\}
            ,
        });
        exe.root_module.linkLibrary(lib);

        const run = case.addRunArtifact(exe);
        run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    }

    if (ctx.includeTest("dynamic-lib-code")) |case| {
        const lib = case.addLibrary(.dynamic, .{
            .name = "lib",
            .name_target = false,
            .zig_source_bytes =
            \\export fn foo1() callconv(.c) u64 {
            \\    return 0x1122334411223344;
            \\}
            \\export fn foo2() callconv(.c) u64 {
            \\    return 0xaabbccddaabbccdd;
            \\}
            ,
        });

        case.verifyObjdump(lib.getEmittedBin(), &.{
            "-s",
            "--exports",
            "--only-symbol=foo",
        }, .{ .os = true });

        if (ctx.target.result.os.tag == .windows) {
            case.verifyObjdump(lib.getEmittedImplib(), &.{
                "-s",
                "--exports=sort",
                "--only-symbol=foo",
            }, .{ .sub_name = "implib", .os = true, .arch = true });
        }

        const exe = case.addExecutable(.{
            .name = "test",
            .zig_source_bytes =
            \\extern fn foo1() u64;
            \\pub fn main() !u8 {
            \\    const foo2 = @extern(
            \\        *const fn () callconv(.c) u64,
            \\        .{ .name = "foo2", .is_dll_import = true },
            \\    );
            \\    return @intFromBool(0xbbde0021bbde0021 != foo1() + foo2());
            \\}
            ,
        });
        exe.root_module.linkLibrary(lib);

        const run = case.addRunArtifact(exe);
        run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    }

    if (ctx.includeTest("dynamic-lib-data")) |case| {
        const lib = case.addLibrary(.dynamic, .{
            .name = "lib",
            .name_target = false,
            .zig_source_bytes =
            \\export var foo_array: [2]u16 = .{ 0xffff, 0xabcd };
            \\export var foo_strong: usize = 0x1122334411223344;
            \\comptime {
            \\    @export(&foo_strong, .{ .name = "foo_strong_alias", .linkage = .strong });
            \\}
            ,
        });

        case.verifyObjdump(lib.getEmittedBin(), &.{
            "-s",
            "--exports",
            "--only-symbol=foo",
        }, .{});

        if (ctx.target.result.os.tag == .windows) {
            case.verifyObjdump(lib.getEmittedImplib(), &.{
                "-s",
                "--exports=sort",
                "--only-symbol=foo",
            }, .{ .sub_name = "implib", .os = true, .arch = true });
        }

        const exe = case.addExecutable(.{
            .name = "test",
            .zig_source_bytes =
            \\pub fn main() !u8 {
            \\    const foo_array = @extern(*[2]u16, .{ .name = "foo_array", .is_dll_import = true });
            \\    const foo_strong = @extern(*usize, .{ .name = "foo_strong", .is_dll_import = true });
            \\    const foo_strong_alias = @extern(*usize, .{ .name = "foo_strong_alias", .is_dll_import = true });
            \\    return @intFromBool(0x2244668822451255 !=
            \\        foo_array[1] +
            \\            foo_strong.* +
            \\            foo_strong_alias.*);
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

        case.verifyObjdump(abs_reloc.getEmittedBin(), &.{
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
