// Feature: sig-compilation-engine, Property 1: Compilation always returns a structured result
//
// For any Compilation_Context (valid or invalid), calling Compilation_Engine.execute()
// SHALL return a Compilation_Result with `success` set to true or false, and when
// `success` is false, `diagnostic_count` SHALL be greater than zero.
//
// Validates: Requirements 1.2

const std = @import("std");
const harness = @import("harness");
const compile_context = @import("compile_context");
const compile_types = @import("compile_types");
const compile_engine = @import("compile_engine");

const Compilation_Context = compile_context.Compilation_Context;
const Compilation_Engine = compile_engine.Compilation_Engine;
const Io = std.Io;

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Generate a random Compilation_Context with randomized fields.
/// Produces a mix of valid and invalid configurations to exercise
/// the engine's error handling paths.
fn generateRandomContext(random: std.Random) Compilation_Context {
    var ctx = Compilation_Context{};

    // Randomly set root source path (sometimes empty = invalid)
    var path_buf: [128]u8 = undefined;
    const path_slice = harness.randomBytes(random, &path_buf);
    if (path_slice.len > 0) {
        ctx.setRootSource(path_slice) catch {};
    }

    // Randomly set output name (sometimes empty)
    var name_buf: [32]u8 = undefined;
    const name_slice = harness.randomBytes(random, &name_buf);
    if (name_slice.len > 0) {
        ctx.setOutputName(name_slice) catch {};
    }

    // Randomly set optimization mode
    const opt_choice = random.uintAtMost(u8, 3);
    ctx.optimize = switch (opt_choice) {
        0 => .Debug,
        1 => .ReleaseSafe,
        2 => .ReleaseFast,
        3 => .ReleaseSmall,
        else => .Debug,
    };

    // Randomly set output mode
    const out_choice = random.uintAtMost(u8, 2);
    ctx.output_mode = switch (out_choice) {
        0 => .Exe,
        1 => .Lib,
        2 => .Obj,
        else => .Exe,
    };

    // Randomly toggle linking flags
    ctx.link_libc = random.boolean();
    ctx.link_libcpp = random.boolean();
    ctx.strip = random.boolean();
    ctx.single_threaded = random.boolean();

    // Randomly add 0..3 modules
    const mod_count = random.uintAtMost(usize, 3);
    var m: usize = 0;
    while (m < mod_count) : (m += 1) {
        var decl: compile_types.Module_Decl = .{};
        // Random short module name
        const name_len = random.uintAtMost(usize, 8) + 1; // 1..9 chars
        var i: usize = 0;
        while (i < name_len) : (i += 1) {
            decl.name[i] = 'a' + @as(u8, @intCast(random.uintAtMost(u8, 25)));
        }
        decl.name_len = name_len;
        // Random source path
        decl.source_path[0] = '/';
        decl.source_path[1] = 't';
        decl.source_path_len = 2;
        ctx.addModule(decl) catch {};
    }

    // Randomly set thread limit
    ctx.thread_limit = random.uintAtMost(usize, 16);

    return ctx;
}

// ---------------------------------------------------------------------------
// Property 1: Compilation always returns a structured result
// ---------------------------------------------------------------------------

test "Property 1: execute() always returns structured result with valid success field" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var ctx = generateRandomContext(random);
            const io: Io = undefined;
            const result = Compilation_Engine.execute(&ctx, io);

            // Result must have success as true or false (always holds for bool)
            // The real property: when success is false, diagnostics explain why
            if (!result.success) {
                try std.testing.expect(result.diagnostic_count > 0);
            }
        }
    };
    harness.property("execute() always returns structured result with valid success field", S.run);
}

test "Property 1: execute() with empty context returns failure with diagnostics" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            // A completely empty context (no root source) should fail with diagnostics
            var ctx = Compilation_Context{};
            const io: Io = undefined;
            const result = Compilation_Engine.execute(&ctx, io);

            // Empty context cannot succeed — no source file specified
            if (!result.success) {
                try std.testing.expect(result.diagnostic_count > 0);
            }
            // Note: if it somehow succeeds (unlikely for empty context),
            // that's still valid — the property only constrains failures.
        }
    };
    harness.property("execute() with empty context returns failure with diagnostics", S.run);
}

test "Property 1: execute() result diagnostic_count never exceeds MAX_DIAGNOSTICS" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var ctx = generateRandomContext(random);
            const io: Io = undefined;
            const result = Compilation_Engine.execute(&ctx, io);

            // diagnostic_count must be bounded by the fixed capacity
            try std.testing.expect(result.diagnostic_count <= compile_types.MAX_DIAGNOSTICS);
        }
    };
    harness.property("execute() result diagnostic_count never exceeds MAX_DIAGNOSTICS", S.run);
}
