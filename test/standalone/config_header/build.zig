const std = @import("std");

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "Test it");
    b.default_step = test_step;

    const config_header = b.addConfigHeader(
        .{ .style = .{ .autoconf_undef = b.path("config.h.in") } },
        .{
            .SOME_NO = null,
            .SOME_TRUE = true,
            .SOME_FALSE = false,
            .SOME_ZERO = 0,
            .SOME_ONE = 1,
            .SOME_TEN = 10,
            .SOME_ENUM = @as(enum { foo, bar }, .foo),
            .SOME_ENUM_LITERAL = .@"test",
            .SOME_STRING = "test",

            .PREFIX_SPACE = null,
            .PREFIX_TAB = null,
            .POSTFIX_SPACE = null,
            .POSTFIX_TAB = null,
        },
    );

    const check_config_header = b.addCheckFile(config_header.getOutputFile(), .{ .expected_exact = @embedFile("config.h") });

    const config_header_autoconf_at = b.addConfigHeader(
        .{ .style = .{
            .autoconf_at = b.path("autoconf_at/autoconf_at.txt.in"),
        } },
        .{
            .undefined = null,
            .defined = {},
            .boolean_true = true,
            .boolean_false = false,
            .integer = 42,
            .string = "text",
            .string_at = "@string@",
        },
    );
    const check_config_header_autoconf_at = b.addCheckFile(config_header_autoconf_at.getOutputFile(), .{
        .expected_exact = @embedFile("autoconf_at/autoconf_at.txt"),
    });

    test_step.dependOn(&check_config_header.step);
    test_step.dependOn(&check_config_header_autoconf_at.step);
}
