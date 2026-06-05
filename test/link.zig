pub fn addCases(cases: @import("tests.zig").LinkContext) void {
    if (cases.addTestStep("static-lib-exports")) |name| {
        const lib = cases.addStaticLibrary(.{
            .name = "lib",
            .zig_source_bytes =
            \\export fn foo() void {}
            \\var bar: u32 = 1234;
            \\comptime { @export(&bar, .{ .name = "bar", .linkage = .strong }); }
            \\const baz: u64 = 5678;
            \\comptime { @export(&baz, .{ .name = "baz", .linkage = .strong }); }
            ,
        });
        cases.verifyObjdump(name, lib, &.{"--symbols"}, .{ .os = true });
    }
}

const std = @import("std");
