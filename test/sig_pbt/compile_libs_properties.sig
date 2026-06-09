// Feature: sig-compilation-engine, Property 7: Library configuration passthrough
//
// For any set of static library names and system library names added to a
// Compilation_Context, the stored entries SHALL preserve the exact name bytes
// without modification, preserve the insertion order, have correct name_len
// matching the input length, and not exceed MAX_LLVM_LIBS (static) or
// MAX_SYSTEM_LIBS (system).
//
// Validates: Requirements 5.2, 5.3

const std = @import("std");
const harness = @import("harness");
const compile_context = @import("compile_context");
const compile_types = @import("compile_types");

const Compilation_Context = compile_context.Compilation_Context;
const NAME_BUF_SIZE = compile_types.NAME_BUF_SIZE;
const MAX_LLVM_LIBS = compile_types.MAX_LLVM_LIBS;
const MAX_SYSTEM_LIBS = compile_types.MAX_SYSTEM_LIBS;

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Generate a random alphanumeric library name of length 1..max_len into buf.
/// Returns the slice of the generated name.
fn randomLibName(random: std.Random, buf: []u8, max_len: usize) []const u8 {
    const len = 1 + random.uintAtMost(usize, max_len - 1);
    const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_";
    for (buf[0..len]) |*c| {
        c.* = charset[random.uintLessThan(usize, charset.len)];
    }
    return buf[0..len];
}

// ---------------------------------------------------------------------------
// Property 7: Static library names are stored in order with exact bytes
// ---------------------------------------------------------------------------

test "Property 7: static lib names preserved in insertion order with exact bytes" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var ctx = Compilation_Context{};

            // Generate 1..16 random static library names
            const count = 1 + random.uintAtMost(usize, 15);

            // Store generated names for later verification
            var names: [16][NAME_BUF_SIZE]u8 = undefined;
            var name_lens: [16]usize = undefined;

            var i: usize = 0;
            while (i < count) : (i += 1) {
                var buf: [NAME_BUF_SIZE]u8 = undefined;
                const name = randomLibName(random, &buf, NAME_BUF_SIZE);
                // Save the name for verification
                @memcpy(names[i][0..name.len], name);
                name_lens[i] = name.len;
                // Add to context
                try ctx.addStaticLib(name);
            }

            // Verify count matches
            try std.testing.expectEqual(count, ctx.static_lib_count);

            // Verify each stored entry preserves exact bytes and order
            i = 0;
            while (i < count) : (i += 1) {
                const entry = &ctx.static_libs[i];
                try std.testing.expectEqual(name_lens[i], entry.name_len);
                try std.testing.expectEqualSlices(
                    u8,
                    names[i][0..name_lens[i]],
                    entry.name[0..entry.name_len],
                );
            }
        }
    };
    harness.property("static lib names preserved in insertion order with exact bytes", S.run);
}

// ---------------------------------------------------------------------------
// Property 7: System library names are stored in order with exact bytes
// ---------------------------------------------------------------------------

test "Property 7: system lib names preserved in insertion order with exact bytes" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var ctx = Compilation_Context{};

            // Generate 1..16 random system library names
            const count = 1 + random.uintAtMost(usize, 15);

            // Store generated names for later verification
            var names: [16][NAME_BUF_SIZE]u8 = undefined;
            var name_lens: [16]usize = undefined;

            var i: usize = 0;
            while (i < count) : (i += 1) {
                var buf: [NAME_BUF_SIZE]u8 = undefined;
                const name = randomLibName(random, &buf, NAME_BUF_SIZE);
                // Save the name for verification
                @memcpy(names[i][0..name.len], name);
                name_lens[i] = name.len;
                // Add to context
                try ctx.addSystemLib(name);
            }

            // Verify count matches
            try std.testing.expectEqual(count, ctx.system_lib_count);

            // Verify each stored entry preserves exact bytes and order
            i = 0;
            while (i < count) : (i += 1) {
                const entry = &ctx.system_libs[i];
                try std.testing.expectEqual(name_lens[i], entry.name_len);
                try std.testing.expectEqualSlices(
                    u8,
                    names[i][0..name_lens[i]],
                    entry.name[0..entry.name_len],
                );
            }
        }
    };
    harness.property("system lib names preserved in insertion order with exact bytes", S.run);
}

// ---------------------------------------------------------------------------
// Property 7: Mixed interleaved additions do not cross-contaminate
// ---------------------------------------------------------------------------

test "Property 7: interleaved static and system lib additions preserve both independently" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var ctx = Compilation_Context{};

            // Generate random counts for each type (1..8 each)
            const static_count = 1 + random.uintAtMost(usize, 7);
            const system_count = 1 + random.uintAtMost(usize, 7);
            const total = static_count + system_count;

            // Store names for verification
            var static_names: [8][NAME_BUF_SIZE]u8 = undefined;
            var static_lens: [8]usize = undefined;
            var system_names: [8][NAME_BUF_SIZE]u8 = undefined;
            var system_lens: [8]usize = undefined;

            // Build an interleaved schedule: 0 = add static, 1 = add system
            // We need exactly static_count zeros and system_count ones.
            var schedule: [16]u8 = undefined;
            var si: usize = 0;
            while (si < static_count) : (si += 1) {
                schedule[si] = 0;
            }
            var sj: usize = 0;
            while (sj < system_count) : (sj += 1) {
                schedule[static_count + sj] = 1;
            }

            // Fisher-Yates shuffle on the schedule
            var k: usize = total;
            while (k > 1) {
                k -= 1;
                const j = random.uintAtMost(usize, k);
                const tmp = schedule[k];
                schedule[k] = schedule[j];
                schedule[j] = tmp;
            }

            // Execute the interleaved schedule
            var static_idx: usize = 0;
            var system_idx: usize = 0;
            var step: usize = 0;
            while (step < total) : (step += 1) {
                var buf: [NAME_BUF_SIZE]u8 = undefined;
                const name = randomLibName(random, &buf, NAME_BUF_SIZE);

                if (schedule[step] == 0) {
                    // Add static lib
                    @memcpy(static_names[static_idx][0..name.len], name);
                    static_lens[static_idx] = name.len;
                    try ctx.addStaticLib(name);
                    static_idx += 1;
                } else {
                    // Add system lib
                    @memcpy(system_names[system_idx][0..name.len], name);
                    system_lens[system_idx] = name.len;
                    try ctx.addSystemLib(name);
                    system_idx += 1;
                }
            }

            // Verify static libs
            try std.testing.expectEqual(static_count, ctx.static_lib_count);
            var i: usize = 0;
            while (i < static_count) : (i += 1) {
                const entry = &ctx.static_libs[i];
                try std.testing.expectEqual(static_lens[i], entry.name_len);
                try std.testing.expectEqualSlices(
                    u8,
                    static_names[i][0..static_lens[i]],
                    entry.name[0..entry.name_len],
                );
            }

            // Verify system libs
            try std.testing.expectEqual(system_count, ctx.system_lib_count);
            i = 0;
            while (i < system_count) : (i += 1) {
                const entry = &ctx.system_libs[i];
                try std.testing.expectEqual(system_lens[i], entry.name_len);
                try std.testing.expectEqualSlices(
                    u8,
                    system_names[i][0..system_lens[i]],
                    entry.name[0..entry.name_len],
                );
            }
        }
    };
    harness.property("interleaved static and system lib additions preserve both independently", S.run);
}

// ---------------------------------------------------------------------------
// Property 7: name_len always matches input length exactly
// ---------------------------------------------------------------------------

test "Property 7: name_len matches input length for varying name sizes" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var ctx = Compilation_Context{};

            // Test with a range of name lengths from 1 to NAME_BUF_SIZE
            const count = 1 + random.uintAtMost(usize, 15);

            var i: usize = 0;
            while (i < count) : (i += 1) {
                var buf: [NAME_BUF_SIZE]u8 = undefined;
                // Pick a specific length between 1 and NAME_BUF_SIZE
                const target_len = 1 + random.uintAtMost(usize, NAME_BUF_SIZE - 1);
                const charset = "abcdefghijklmnopqrstuvwxyz0123456789";
                for (buf[0..target_len]) |*c| {
                    c.* = charset[random.uintLessThan(usize, charset.len)];
                }
                const name = buf[0..target_len];

                try ctx.addStaticLib(name);

                // Verify stored name_len matches exactly
                try std.testing.expectEqual(target_len, ctx.static_libs[i].name_len);

                // Also add as system lib
                try ctx.addSystemLib(name);
                try std.testing.expectEqual(target_len, ctx.system_libs[i].name_len);
            }
        }
    };
    harness.property("name_len matches input length for varying name sizes", S.run);
}
