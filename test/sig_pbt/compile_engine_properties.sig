// Feature: sig-compilation-engine, Property 4: Capacity overflow produces identifiable error
//
// For any fixed-capacity buffer in Compilation_Context (modules, cpp_sources,
// include_dirs, definitions, lib_search_paths, static_libs, system_libs, shared_flags),
// attempting to add one more entry than the buffer's defined maximum SHALL return
// error.CapacityExceeded.
//
// Validates: Requirements 2.3

const std = @import("std");
const harness = @import("harness");
const compile_context = @import("compile_context");
const compile_types = @import("compile_types");

const Compilation_Context = compile_context.Compilation_Context;

// ---------------------------------------------------------------------------
// Property 4: Capacity overflow produces identifiable error
// ---------------------------------------------------------------------------

test "Property 4: addModule returns CapacityExceeded when full" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            var ctx = Compilation_Context{};
            // Fill to capacity
            var i: usize = 0;
            while (i < compile_types.MAX_MODULES) : (i += 1) {
                var decl: compile_types.Module_Decl = .{};
                decl.name[0] = 'a';
                decl.name_len = 1;
                try ctx.addModule(decl);
            }
            // One more should fail
            var extra: compile_types.Module_Decl = .{};
            extra.name[0] = 'x';
            extra.name_len = 1;
            try std.testing.expectError(error.CapacityExceeded, ctx.addModule(extra));
        }
    };
    harness.property("addModule returns CapacityExceeded when full", S.run);
}

test "Property 4: addCppSource returns CapacityExceeded when full" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            var ctx = Compilation_Context{};
            var i: usize = 0;
            while (i < compile_types.MAX_CPP_SOURCES) : (i += 1) {
                var src: compile_types.Cpp_Source = .{};
                src.path[0] = 'a';
                src.path_len = 1;
                try ctx.addCppSource(src);
            }
            var extra: compile_types.Cpp_Source = .{};
            extra.path[0] = 'x';
            extra.path_len = 1;
            try std.testing.expectError(error.CapacityExceeded, ctx.addCppSource(extra));
        }
    };
    harness.property("addCppSource returns CapacityExceeded when full", S.run);
}

test "Property 4: addSharedFlag returns CapacityExceeded when full" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            var ctx = Compilation_Context{};
            var i: usize = 0;
            while (i < compile_types.MAX_COMPILER_FLAGS) : (i += 1) {
                try ctx.addSharedFlag("-Wall");
            }
            try std.testing.expectError(error.CapacityExceeded, ctx.addSharedFlag("-Werror"));
        }
    };
    harness.property("addSharedFlag returns CapacityExceeded when full", S.run);
}

test "Property 4: addIncludeDir returns CapacityExceeded when full" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            var ctx = Compilation_Context{};
            var i: usize = 0;
            while (i < compile_types.MAX_INCLUDE_DIRS) : (i += 1) {
                try ctx.addIncludeDir("/usr/include");
            }
            try std.testing.expectError(error.CapacityExceeded, ctx.addIncludeDir("/extra"));
        }
    };
    harness.property("addIncludeDir returns CapacityExceeded when full", S.run);
}

test "Property 4: addDefinition returns CapacityExceeded when full" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            var ctx = Compilation_Context{};
            var i: usize = 0;
            while (i < compile_types.MAX_PREPROCESSOR_DEFS) : (i += 1) {
                try ctx.addDefinition("NDEBUG", "1");
            }
            try std.testing.expectError(error.CapacityExceeded, ctx.addDefinition("EXTRA", "1"));
        }
    };
    harness.property("addDefinition returns CapacityExceeded when full", S.run);
}

test "Property 4: addLibSearchPath returns CapacityExceeded when full" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            var ctx = Compilation_Context{};
            var i: usize = 0;
            while (i < compile_types.MAX_LIB_SEARCH_DIRS) : (i += 1) {
                try ctx.addLibSearchPath("/usr/lib");
            }
            try std.testing.expectError(error.CapacityExceeded, ctx.addLibSearchPath("/extra"));
        }
    };
    harness.property("addLibSearchPath returns CapacityExceeded when full", S.run);
}

test "Property 4: addStaticLib returns CapacityExceeded when full" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            var ctx = Compilation_Context{};
            var i: usize = 0;
            while (i < compile_types.MAX_LLVM_LIBS) : (i += 1) {
                try ctx.addStaticLib("LLVMCore");
            }
            try std.testing.expectError(error.CapacityExceeded, ctx.addStaticLib("extra"));
        }
    };
    harness.property("addStaticLib returns CapacityExceeded when full", S.run);
}

test "Property 4: addSystemLib returns CapacityExceeded when full" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            var ctx = Compilation_Context{};
            var i: usize = 0;
            while (i < compile_types.MAX_SYSTEM_LIBS) : (i += 1) {
                try ctx.addSystemLib("pthread");
            }
            try std.testing.expectError(error.CapacityExceeded, ctx.addSystemLib("extra"));
        }
    };
    harness.property("addSystemLib returns CapacityExceeded when full", S.run);
}
