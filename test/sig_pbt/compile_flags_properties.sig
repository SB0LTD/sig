// Feature: sig-compilation-engine, Property 6: C++ compilation flags passthrough
//
// For any set of shared flags, per-file extra flags, include directories, and
// preprocessor definitions added to a Compilation_Context, the resulting cc_argv
// entries from buildCcArgv() SHALL contain all shared flags concatenated with
// per-file flags in order, all include directories as `-I<path>` entries, and all
// definitions as `-D<name>=<value>` entries (or `-D<name>` if value is empty).
//
// **Validates: Requirements 4.2, 4.3, 4.4**

const std = @import("std");
const harness = @import("harness");
const compile_context = @import("compile_context");
const compile_types = @import("compile_types");
const compile_engine = @import("compile_engine");

const Compilation_Context = compile_context.Compilation_Context;
const Compilation_Engine = compile_engine.Compilation_Engine;
const Cpp_Source = compile_types.Cpp_Source;
const Flag_Entry = compile_types.Flag_Entry;
const VALUE_BUF_SIZE = compile_types.VALUE_BUF_SIZE;
const NAME_BUF_SIZE = compile_types.NAME_BUF_SIZE;
const PATH_BUF_SIZE = compile_types.PATH_BUF_SIZE;
const MAX_COMPILER_FLAGS = compile_types.MAX_COMPILER_FLAGS;
const MAX_INCLUDE_DIRS = compile_types.MAX_INCLUDE_DIRS;
const MAX_PREPROCESSOR_DEFS = compile_types.MAX_PREPROCESSOR_DEFS;
const MAX_CC_ARGV: usize = MAX_COMPILER_FLAGS + MAX_COMPILER_FLAGS + MAX_INCLUDE_DIRS + MAX_PREPROCESSOR_DEFS;

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Generate a random alphanumeric string of length 1..max_len into buf.
/// Returns the slice of generated content.
fn randomAlphaStr(random: std.Random, buf: []u8, max_len: usize) []u8 {
    if (max_len == 0 or buf.len == 0) return buf[0..0];
    const effective_max = @min(max_len, buf.len);
    const len = random.uintAtMost(usize, effective_max - 1) + 1; // 1..effective_max
    for (0..len) |i| {
        buf[i] = 'a' + @as(u8, @intCast(random.uintAtMost(u8, 25)));
    }
    return buf[0..len];
}

/// Generate a random flag string like "-Wall", "-O2", "-fno-rtti" etc.
/// Uses a short random prefix to simulate realistic flags.
fn randomFlag(random: std.Random, buf: *[VALUE_BUF_SIZE]u8) usize {
    const prefix = "-";
    @memcpy(buf[0..prefix.len], prefix);
    // Random flag body: 1..20 alphanumeric chars
    const body_max: usize = 20;
    const body_len = random.uintAtMost(usize, body_max - 1) + 1;
    for (0..body_len) |i| {
        buf[prefix.len + i] = 'a' + @as(u8, @intCast(random.uintAtMost(u8, 25)));
    }
    return prefix.len + body_len;
}

/// Generate a random path for include directories.
fn randomPath(random: std.Random, buf: []u8, max_len: usize) usize {
    const effective_max = @min(max_len, buf.len);
    if (effective_max < 5) return 0;
    // Start with /
    buf[0] = '/';
    const body_len = random.uintAtMost(usize, effective_max - 2) + 1; // 1..effective_max-1
    for (0..body_len) |i| {
        const choice = random.uintAtMost(u8, 27);
        buf[1 + i] = if (choice == 27) '/' else 'a' + @as(u8, @intCast(choice % 26));
    }
    return 1 + body_len;
}

// ---------------------------------------------------------------------------
// Property 6: C++ compilation flags passthrough
// ---------------------------------------------------------------------------

test "Property 6: shared flags appear first in cc_argv in order" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var ctx = Compilation_Context{};

            // Set a minimal root source so context is somewhat valid
            try ctx.setRootSource("/test.zig");

            // Generate 1..8 shared flags
            const num_shared = random.uintAtMost(usize, 7) + 1;
            var shared_values: [8][VALUE_BUF_SIZE]u8 = undefined;
            var shared_lens: [8]usize = undefined;

            for (0..num_shared) |i| {
                shared_lens[i] = randomFlag(random, &shared_values[i]);
                try ctx.addSharedFlag(shared_values[i][0..shared_lens[i]]);
            }

            // Add a C++ source with a valid path
            var src: Cpp_Source = .{};
            src.path[0] = '/';
            src.path[1] = 'a';
            src.path[2] = '.';
            src.path[3] = 'c';
            src.path_len = 4;
            try ctx.addCppSource(src);

            // Build cc_argv
            var argv_buf: [MAX_CC_ARGV][VALUE_BUF_SIZE]u8 = undefined;
            var argv_lens: [MAX_CC_ARGV]usize = undefined;
            const argc = Compilation_Engine.buildCcArgv(&ctx, 0, &argv_buf, &argv_lens) orelse
                return error.BuildCcArgvOverflow;

            // Verify shared flags appear first in order
            try std.testing.expect(argc >= num_shared);
            for (0..num_shared) |i| {
                try std.testing.expectEqual(shared_lens[i], argv_lens[i]);
                const expected = shared_values[i][0..shared_lens[i]];
                const actual = argv_buf[i][0..argv_lens[i]];
                try std.testing.expect(eql(expected, actual));
            }
        }
    };
    harness.property("shared flags appear first in cc_argv in order", S.run);
}

test "Property 6: per-file extra flags follow shared flags" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var ctx = Compilation_Context{};
            try ctx.setRootSource("/test.zig");

            // Generate 1..4 shared flags
            const num_shared = random.uintAtMost(usize, 3) + 1;
            for (0..num_shared) |_| {
                var flag_buf: [VALUE_BUF_SIZE]u8 = undefined;
                const flag_len = randomFlag(random, &flag_buf);
                try ctx.addSharedFlag(flag_buf[0..flag_len]);
            }

            // Create C++ source with 1..4 extra flags
            var src: Cpp_Source = .{};
            src.path[0] = '/';
            src.path[1] = 'b';
            src.path[2] = '.';
            src.path[3] = 'c';
            src.path_len = 4;

            const num_extra = random.uintAtMost(usize, 3) + 1;
            var extra_values: [4][VALUE_BUF_SIZE]u8 = undefined;
            var extra_lens: [4]usize = undefined;

            for (0..num_extra) |i| {
                extra_lens[i] = randomFlag(random, &extra_values[i]);
                var entry: Flag_Entry = .{};
                @memcpy(entry.value[0..extra_lens[i]], extra_values[i][0..extra_lens[i]]);
                entry.value_len = extra_lens[i];
                src.extra_flags[src.extra_flag_count] = entry;
                src.extra_flag_count += 1;
            }

            try ctx.addCppSource(src);

            // Build cc_argv
            var argv_buf: [MAX_CC_ARGV][VALUE_BUF_SIZE]u8 = undefined;
            var argv_lens: [MAX_CC_ARGV]usize = undefined;
            const argc = Compilation_Engine.buildCcArgv(&ctx, 0, &argv_buf, &argv_lens) orelse
                return error.BuildCcArgvOverflow;

            // Verify extra flags follow shared flags
            const extra_start = num_shared;
            try std.testing.expect(argc >= extra_start + num_extra);
            for (0..num_extra) |i| {
                const idx = extra_start + i;
                try std.testing.expectEqual(extra_lens[i], argv_lens[idx]);
                const expected = extra_values[i][0..extra_lens[i]];
                const actual = argv_buf[idx][0..argv_lens[idx]];
                try std.testing.expect(eql(expected, actual));
            }
        }
    };
    harness.property("per-file extra flags follow shared flags", S.run);
}

test "Property 6: include directories appear as -I<path> entries" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var ctx = Compilation_Context{};
            try ctx.setRootSource("/test.zig");

            // Generate 1..4 include directories
            const num_dirs = random.uintAtMost(usize, 3) + 1;
            var dir_paths: [4][128]u8 = undefined;
            var dir_lens: [4]usize = undefined;

            for (0..num_dirs) |i| {
                dir_lens[i] = randomPath(random, &dir_paths[i], 60);
                try ctx.addIncludeDir(dir_paths[i][0..dir_lens[i]]);
            }

            // Add a C++ source with no extra flags
            var src: Cpp_Source = .{};
            src.path[0] = '/';
            src.path[1] = 'c';
            src.path[2] = '.';
            src.path[3] = 'c';
            src.path_len = 4;
            try ctx.addCppSource(src);

            // Build cc_argv
            var argv_buf: [MAX_CC_ARGV][VALUE_BUF_SIZE]u8 = undefined;
            var argv_lens: [MAX_CC_ARGV]usize = undefined;
            const argc = Compilation_Engine.buildCcArgv(&ctx, 0, &argv_buf, &argv_lens) orelse
                return error.BuildCcArgvOverflow;

            // Include dirs come after shared flags (0) + extra flags (0) = index 0
            try std.testing.expect(argc >= num_dirs);
            for (0..num_dirs) |i| {
                const expected_prefix = "-I";
                const expected_len = expected_prefix.len + dir_lens[i];
                try std.testing.expectEqual(expected_len, argv_lens[i]);

                // Check "-I" prefix
                try std.testing.expect(eql(argv_buf[i][0..2], "-I"));
                // Check path content
                const actual_path = argv_buf[i][2..argv_lens[i]];
                const expected_path = dir_paths[i][0..dir_lens[i]];
                try std.testing.expect(eql(actual_path, expected_path));
            }
        }
    };
    harness.property("include directories appear as -I<path> entries", S.run);
}

test "Property 6: preprocessor definitions appear as -D<name>=<value> entries" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var ctx = Compilation_Context{};
            try ctx.setRootSource("/test.zig");

            // Generate 1..4 definitions with name and value
            const num_defs = random.uintAtMost(usize, 3) + 1;
            var def_names: [4][32]u8 = undefined;
            var def_name_lens: [4]usize = undefined;
            var def_values: [4][32]u8 = undefined;
            var def_value_lens: [4]usize = undefined;

            for (0..num_defs) |i| {
                // Random name: 1..16 alpha chars
                const name_slice = randomAlphaStr(random, &def_names[i], 16);
                def_name_lens[i] = name_slice.len;

                // Random value: 0..16 alpha chars (0 = no value)
                const has_value = random.boolean();
                if (has_value) {
                    const val_slice = randomAlphaStr(random, &def_values[i], 16);
                    def_value_lens[i] = val_slice.len;
                } else {
                    def_value_lens[i] = 0;
                }

                try ctx.addDefinition(
                    def_names[i][0..def_name_lens[i]],
                    def_values[i][0..def_value_lens[i]],
                );
            }

            // Add a C++ source with no extra flags
            var src: Cpp_Source = .{};
            src.path[0] = '/';
            src.path[1] = 'd';
            src.path[2] = '.';
            src.path[3] = 'c';
            src.path_len = 4;
            try ctx.addCppSource(src);

            // Build cc_argv
            var argv_buf: [MAX_CC_ARGV][VALUE_BUF_SIZE]u8 = undefined;
            var argv_lens: [MAX_CC_ARGV]usize = undefined;
            const argc = Compilation_Engine.buildCcArgv(&ctx, 0, &argv_buf, &argv_lens) orelse
                return error.BuildCcArgvOverflow;

            // Definitions come after shared flags (0) + extra flags (0) + include dirs (0)
            try std.testing.expect(argc >= num_defs);
            for (0..num_defs) |i| {
                const entry = argv_buf[i][0..argv_lens[i]];

                // Must start with "-D"
                try std.testing.expect(entry.len >= 2);
                try std.testing.expect(eql(entry[0..2], "-D"));

                // Extract the rest after "-D"
                const rest = entry[2..];

                if (def_value_lens[i] > 0) {
                    // Expect: <name>=<value>
                    const expected_len = def_name_lens[i] + 1 + def_value_lens[i];
                    try std.testing.expectEqual(expected_len, rest.len);
                    try std.testing.expect(eql(rest[0..def_name_lens[i]], def_names[i][0..def_name_lens[i]]));
                    try std.testing.expectEqual(@as(u8, '='), rest[def_name_lens[i]]);
                    try std.testing.expect(eql(rest[def_name_lens[i] + 1 ..], def_values[i][0..def_value_lens[i]]));
                } else {
                    // Expect: just <name>
                    try std.testing.expectEqual(def_name_lens[i], rest.len);
                    try std.testing.expect(eql(rest, def_names[i][0..def_name_lens[i]]));
                }
            }
        }
    };
    harness.property("preprocessor definitions appear as -D<name>=<value> entries", S.run);
}

test "Property 6: full combination - all flags concatenated correctly with correct total count" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var ctx = Compilation_Context{};
            try ctx.setRootSource("/test.zig");

            // Generate random counts (1..4 each to stay within limits)
            const num_shared = random.uintAtMost(usize, 3) + 1;
            const num_extra = random.uintAtMost(usize, 3) + 1;
            const num_dirs = random.uintAtMost(usize, 3) + 1;
            const num_defs = random.uintAtMost(usize, 3) + 1;

            // Add shared flags
            for (0..num_shared) |_| {
                var flag_buf: [VALUE_BUF_SIZE]u8 = undefined;
                const flag_len = randomFlag(random, &flag_buf);
                try ctx.addSharedFlag(flag_buf[0..flag_len]);
            }

            // Add include directories
            for (0..num_dirs) |_| {
                var dir_buf: [128]u8 = undefined;
                const dir_len = randomPath(random, &dir_buf, 60);
                try ctx.addIncludeDir(dir_buf[0..dir_len]);
            }

            // Add definitions
            for (0..num_defs) |_| {
                var name_buf: [32]u8 = undefined;
                var val_buf: [32]u8 = undefined;
                const name_slice = randomAlphaStr(random, &name_buf, 12);
                const has_value = random.boolean();
                const val_slice = if (has_value) randomAlphaStr(random, &val_buf, 12) else val_buf[0..0];
                try ctx.addDefinition(name_slice, val_slice);
            }

            // Create C++ source with extra flags
            var src: Cpp_Source = .{};
            src.path[0] = '/';
            src.path[1] = 'e';
            src.path[2] = '.';
            src.path[3] = 'c';
            src.path_len = 4;

            for (0..num_extra) |_| {
                var flag_buf: [VALUE_BUF_SIZE]u8 = undefined;
                const flag_len = randomFlag(random, &flag_buf);
                var entry: Flag_Entry = .{};
                @memcpy(entry.value[0..flag_len], flag_buf[0..flag_len]);
                entry.value_len = flag_len;
                src.extra_flags[src.extra_flag_count] = entry;
                src.extra_flag_count += 1;
            }

            try ctx.addCppSource(src);

            // Build cc_argv
            var argv_buf: [MAX_CC_ARGV][VALUE_BUF_SIZE]u8 = undefined;
            var argv_lens: [MAX_CC_ARGV]usize = undefined;
            const argc = Compilation_Engine.buildCcArgv(&ctx, 0, &argv_buf, &argv_lens) orelse
                return error.BuildCcArgvOverflow;

            // Total count must match
            const expected_total = num_shared + num_extra + num_dirs + num_defs;
            try std.testing.expectEqual(expected_total, argc);

            // Verify ordering: shared, extra, includes (-I prefix), defines (-D prefix)
            var idx: usize = 0;

            // Shared flags (no prefix requirement, just count)
            idx += num_shared;

            // Extra flags (no prefix requirement, just count)
            idx += num_extra;

            // Include dirs must have -I prefix
            for (0..num_dirs) |_| {
                try std.testing.expect(argv_lens[idx] >= 2);
                try std.testing.expect(eql(argv_buf[idx][0..2], "-I"));
                idx += 1;
            }

            // Definitions must have -D prefix
            for (0..num_defs) |_| {
                try std.testing.expect(argv_lens[idx] >= 2);
                try std.testing.expect(eql(argv_buf[idx][0..2], "-D"));
                idx += 1;
            }
        }
    };
    harness.property("full combination - all flags concatenated correctly with correct total count", S.run);
}

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

/// Byte-for-byte equality check.
fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}
