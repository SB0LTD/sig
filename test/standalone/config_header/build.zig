const std = @import("std");

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "Test it");
    b.default_step = test_step;

    const config_header = b.addConfigHeader(
        .{ .style = .{
            .autoconf_undef = b.path("autoconf_undef/config.h.in"),
        } },
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
    const check_config_header = b.addCheckFile(config_header.getOutputFile(), .{
        .expected_exact = @embedFile("autoconf_undef/config.h"),
    });

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
    addCmakeChecks(b, test_step);
}

fn addCmakeChecks(b: *std.Build, test_step: *std.Build.Step) void {
    const config_header = b.addConfigHeader(
        .{
            .style = .{ .cmake = b.path("cmake/config.h.in") },
            .include_path = "config.h",
        },
        .{
            .noval = null,
            .trueval = true,
            .falseval = false,
            .zeroval = 0,
            .oneval = 1,
            .tenval = 10,
            .stringval = "test",

            .boolnoval = {},
            .booltrueval = true,
            .boolfalseval = false,
            .boolzeroval = 0,
            .booloneval = 1,
            .booltenval = 10,
            .boolstringval = "test",
        },
    );
    const check_config_header = b.addCheckFile(config_header.getOutputFile(), .{
        .expected_exact = @embedFile("cmake/expected_config.h"),
    });
    test_step.dependOn(&check_config_header.step);

    const pwd_sh = b.addConfigHeader(
        .{
            .style = .{ .cmake = b.path("cmake/pwd.sh.in") },
            .include_path = "pwd.sh",
        },
        .{ .DIR = "${PWD}" },
    );
    const check_pwd_sh = b.addCheckFile(pwd_sh.getOutputFile(), .{
        .expected_exact = @embedFile("cmake/expected_pwd.sh"),
    });
    test_step.dependOn(&check_pwd_sh.step);

    const sigil_header = b.addConfigHeader(
        .{
            .style = .{ .cmake = b.path("cmake/sigil.h.in") },
            .include_path = "sigil.h",
        },
        .{},
    );
    const check_sigil_header = b.addCheckFile(sigil_header.getOutputFile(), .{
        .expected_exact = @embedFile("cmake/expected_sigil.h"),
    });
    test_step.dependOn(&check_sigil_header.step);

    const stack_header = b.addConfigHeader(
        .{
            .style = .{ .cmake = b.path("cmake/stack.h.in") },
            .include_path = "stack.h",
        },
        .{
            .UNDERSCORE = "_",
            .NEST_UNDERSCORE_PROXY = "UNDERSCORE",
            .NEST_PROXY = "NEST_UNDERSCORE_PROXY",
        },
    );
    const check_stack_header = b.addCheckFile(stack_header.getOutputFile(), .{
        .expected_exact = @embedFile("cmake/expected_stack.h"),
    });
    test_step.dependOn(&check_stack_header.step);

    const wrapper_header = b.addConfigHeader(
        .{
            .style = .{ .cmake = b.path("cmake/wrapper.h.in") },
            .include_path = "wrapper.h",
        },
        .{
            .DOLLAR = "$",
            .TEXT = "TRAP",

            .STRING = "TEXT",
            .STRING_AT = "@STRING@",
            .STRING_CURLY = "{STRING}",
            .STRING_VAR = "${STRING}",
        },
    );
    const check_wrapper_header = b.addCheckFile(wrapper_header.getOutputFile(), .{
        .expected_exact = @embedFile("cmake/expected_wrapper.h"),
    });
    test_step.dependOn(&check_wrapper_header.step);

    const config_header_cmake = b.addConfigHeader(
        .{ .style = .{
            .cmake = b.path("cmake/cmake.txt.in"),
        } },
        .{
            .undef = null,
            .defined = {},
            .true = true,
            .false = false,
            .int = 42,
            .ident = "value",
            .string = "text",
        },
    );
    const check_config_header_cmake = b.addCheckFile(config_header_cmake.getOutputFile(), .{
        .expected_exact = @embedFile("cmake/cmake.txt"),
    });
    test_step.dependOn(&check_config_header_cmake.step);

    const config_header_cmake_edge_cases = b.addConfigHeader(
        .{ .style = .{
            .cmake = b.path("cmake/cmake_edge_cases.txt.in"),
        } },
        .{
            // .at = "@",
            // .trueval = true,
            .dollar = "$",
            .underscore = "_",
            .string = "text",
            .string_proxy = "string",
            .string_at = "@string@",
            .string_curly = "{string}",
            .string_var = "${string}",
            .nest_underscore_proxy = "underscore",
            .nest_proxy = "nest_underscore_proxy",
        },
    );
    const check_config_header_cmake_edge_cases = b.addCheckFile(config_header_cmake_edge_cases.getOutputFile(), .{
        .expected_exact = @embedFile("cmake/cmake_edge_cases.txt"),
    });
    test_step.dependOn(&check_config_header_cmake_edge_cases.step);
}
