// Feature: sig-file-extension, Property 1: Per-file mode resolution
//
// **Validates: Requirements 2.1, 2.2, 3.2, 3.3, 3.4, 3.5**

const std = @import("std");
const harness = @import("harness");
const sig_diag = @import("sig_diagnostics");
const sig_integration = @import("sig_diagnostics_integration");

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Generates a random path prefix from printable ASCII (avoiding '.' to
/// prevent accidental extension collisions), then appends the given extension.
fn genFilePath(random: std.Random, buf: []u8, extension: []const u8) []const u8 {
    // Reserve space for at least 1 char prefix + extension
    const max_prefix = buf.len - extension.len;
    if (max_prefix == 0) {
        @memcpy(buf[0..extension.len], extension);
        return buf[0..extension.len];
    }
    // Random prefix length 1..max_prefix
    const prefix_len = 1 + random.uintAtMost(usize, max_prefix - 1);
    for (buf[0..prefix_len]) |*c| {
        // Printable ASCII 'a'-'z', '/', '_' — safe path chars, no '.'
        const choices = "abcdefghijklmnopqrstuvwxyz/_";
        c.* = choices[random.uintAtMost(usize, choices.len - 1)];
    }
    @memcpy(buf[prefix_len..][0..extension.len], extension);
    return buf[0 .. prefix_len + extension.len];
}

/// Returns a random Mode (.default or .strict).
fn genMode(random: std.Random) sig_integration.Mode {
    return if (random.boolean()) .default else .strict;
}

// ---------------------------------------------------------------------------
// Property 1: Per-file mode resolution
// ---------------------------------------------------------------------------

test "Property 1: resolveFileMode returns strict for .sig, global mode for .zig" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var buf: [128]u8 = undefined;
            const global_mode = genMode(random);

            // .sig path → always strict
            const sig_path = genFilePath(random, &buf, ".sig");
            const sig_result = sig_integration.resolveFileMode(sig_path, global_mode);
            try std.testing.expectEqual(sig_integration.Mode.strict, sig_result);

            // Also verify hasSigExtension is true for .sig
            try std.testing.expect(sig_integration.hasSigExtension(sig_path));

            // .zig path → follows global mode
            var buf2: [128]u8 = undefined;
            const zig_path = genFilePath(random, &buf2, ".zig");
            const zig_result = sig_integration.resolveFileMode(zig_path, global_mode);
            try std.testing.expectEqual(global_mode, zig_result);

            // Also verify hasSigExtension is false for .zig
            try std.testing.expect(!sig_integration.hasSigExtension(zig_path));
        }
    };
    harness.property(
        "resolveFileMode returns strict for .sig, global mode for .zig",
        S.run,
    );
}

// ---------------------------------------------------------------------------
// Source generators (for Properties 2+)
// ---------------------------------------------------------------------------

fn genAllocSource(random: std.Random, buf: []u8) []const u8 {
    const patterns = [_][]const u8{
        "allocator.alloc(u8, 64)",
        "allocator.create(Node)",
        "allocator.free(ptr)",
    };
    const pat = patterns[random.uintAtMost(usize, patterns.len - 1)];
    const names = [_][]const u8{ "doWork", "process", "handle" };
    const name = names[random.uintAtMost(usize, names.len - 1)];
    return std.fmt.bufPrint(
        buf,
        "fn {s}() void {{\n    const x = {s};\n    _ = x;\n}}\n",
        .{ name, pat },
    ) catch buf[0..0];
}

// ---------------------------------------------------------------------------
// Feature: sig-file-extension, Property 2: Sig file diagnostics are always errors
//
// **Validates: Requirements 2.3, 2.4, 2.5**
// ---------------------------------------------------------------------------

test "Property 2: sig file diagnostics are always formatted as errors" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const gpa = std.testing.allocator;
            var buf: [512]u8 = undefined;
            const source = genAllocSource(random, &buf);
            if (source.len == 0) return;

            // Generate a random .sig file path
            var path_buf: [128]u8 = undefined;
            const sig_path = genFilePath(random, &path_buf, ".sig");

            // Random global mode — should not matter for .sig files
            const global_mode = genMode(random);

            // Analyze the source with the .sig path
            const entries = try sig_diag.analyzeSource(
                gpa,
                source,
                sig_path,
                sig_integration.resolveFileMode(sig_path, global_mode),
            );
            defer sig_diag.freeEntries(gpa, entries);

            // Must detect at least one entry (source always has allocator usage)
            try std.testing.expect(entries.len > 0);

            // Resolve effective mode via integration — must be strict for .sig
            const effective_mode = sig_integration.resolveFileMode(sig_path, global_mode);
            try std.testing.expectEqual(sig_integration.Mode.strict, effective_mode);

            // Format each entry and verify all are errors, none are warnings
            for (entries) |entry| {
                const msg = try sig_diag.formatDiagnostic(gpa, entry, effective_mode);
                defer gpa.free(msg);

                // Must contain "error"
                try std.testing.expect(
                    std.mem.indexOf(u8, msg, "error") != null,
                );
                // Must NOT contain "warning"
                try std.testing.expect(
                    std.mem.indexOf(u8, msg, "warning") == null,
                );
            }
        }
    };
    harness.property(
        "sig file diagnostics are always formatted as errors",
        S.run,
    );
}

// ---------------------------------------------------------------------------
// Feature: sig-file-extension, Property 3: Zig file diagnostics follow global mode
//
// **Validates: Requirements 2.6, 7.1, 7.2, 7.4**
// ---------------------------------------------------------------------------

test "Property 3: zig file diagnostics follow global mode" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const gpa = std.testing.allocator;
            var src_buf: [512]u8 = undefined;
            const source = genAllocSource(random, &src_buf);
            if (source.len == 0) return;

            // Generate a random .zig file path
            var path_buf: [128]u8 = undefined;
            const zig_path = genFilePath(random, &path_buf, ".zig");

            // --- Default mode: diagnostics should be warnings ---
            {
                const effective_mode = sig_integration.resolveFileMode(zig_path, .default);
                try std.testing.expectEqual(sig_integration.Mode.default, effective_mode);

                const entries = try sig_diag.analyzeSource(gpa, source, zig_path, effective_mode);
                defer sig_diag.freeEntries(gpa, entries);

                try std.testing.expect(entries.len > 0);

                for (entries) |entry| {
                    const msg = try sig_diag.formatDiagnostic(gpa, entry, effective_mode);
                    defer gpa.free(msg);

                    // Must contain "warning"
                    try std.testing.expect(std.mem.indexOf(u8, msg, "warning") != null);
                    // Must NOT contain "error"
                    try std.testing.expect(std.mem.indexOf(u8, msg, "error") == null);
                }
            }

            // --- Strict mode: diagnostics should be errors ---
            {
                const effective_mode = sig_integration.resolveFileMode(zig_path, .strict);
                try std.testing.expectEqual(sig_integration.Mode.strict, effective_mode);

                const entries = try sig_diag.analyzeSource(gpa, source, zig_path, effective_mode);
                defer sig_diag.freeEntries(gpa, entries);

                try std.testing.expect(entries.len > 0);

                for (entries) |entry| {
                    const msg = try sig_diag.formatDiagnostic(gpa, entry, effective_mode);
                    defer gpa.free(msg);

                    // Must contain "error"
                    try std.testing.expect(std.mem.indexOf(u8, msg, "error") != null);
                }
            }
        }
    };
    harness.property(
        "zig file diagnostics follow global mode",
        S.run,
    );
}

// ---------------------------------------------------------------------------
// Feature: sig-file-extension, Property 4: Per-file mode independence in mixed analysis
//
// **Validates: Requirements 4.1, 4.2, 4.3**
// ---------------------------------------------------------------------------

test "Property 4: per-file mode independence — .sig errors and .zig warnings with same global mode" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const gpa = std.testing.allocator;

            // Generate two independent allocator-containing sources
            var sig_src_buf: [512]u8 = undefined;
            const sig_source = genAllocSource(random, &sig_src_buf);
            if (sig_source.len == 0) return;

            var zig_src_buf: [512]u8 = undefined;
            const zig_source = genAllocSource(random, &zig_src_buf);
            if (zig_source.len == 0) return;

            // Generate random file paths with the respective extensions
            var sig_path_buf: [128]u8 = undefined;
            const sig_path = genFilePath(random, &sig_path_buf, ".sig");

            var zig_path_buf: [128]u8 = undefined;
            const zig_path = genFilePath(random, &zig_path_buf, ".zig");

            // Global mode is default — the key scenario for mixed analysis
            const global_mode = sig_integration.Mode.default;

            // --- Analyze the .sig file ---
            const sig_effective = sig_integration.resolveFileMode(sig_path, global_mode);
            try std.testing.expectEqual(sig_integration.Mode.strict, sig_effective);

            const sig_entries = try sig_diag.analyzeSource(
                gpa,
                sig_source,
                sig_path,
                sig_effective,
            );
            defer sig_diag.freeEntries(gpa, sig_entries);

            try std.testing.expect(sig_entries.len > 0);

            // All .sig diagnostics must be errors
            for (sig_entries) |entry| {
                const msg = try sig_diag.formatDiagnostic(gpa, entry, sig_effective);
                defer gpa.free(msg);

                try std.testing.expect(std.mem.indexOf(u8, msg, "error") != null);
                try std.testing.expect(std.mem.indexOf(u8, msg, "warning") == null);
            }

            // --- Analyze the .zig file ---
            const zig_effective = sig_integration.resolveFileMode(zig_path, global_mode);
            try std.testing.expectEqual(sig_integration.Mode.default, zig_effective);

            const zig_entries = try sig_diag.analyzeSource(
                gpa,
                zig_source,
                zig_path,
                zig_effective,
            );
            defer sig_diag.freeEntries(gpa, zig_entries);

            try std.testing.expect(zig_entries.len > 0);

            // All .zig diagnostics must be warnings (not errors)
            for (zig_entries) |entry| {
                const msg = try sig_diag.formatDiagnostic(gpa, entry, zig_effective);
                defer gpa.free(msg);

                try std.testing.expect(std.mem.indexOf(u8, msg, "warning") != null);
                try std.testing.expect(std.mem.indexOf(u8, msg, "error") == null);
            }
        }
    };
    harness.property(
        "per-file mode independence — .sig errors and .zig warnings with same global mode",
        S.run,
    );
}

// ---------------------------------------------------------------------------
// Feature: sig-file-extension, Property 5: Sig annotation presence and diagnostic completeness
//
// **Validates: Requirements 6.1, 6.2, 6.3, 6.4**
// ---------------------------------------------------------------------------

test "Property 5: sig annotation presence and diagnostic completeness" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const gpa = std.testing.allocator;
            var src_buf: [512]u8 = undefined;
            const source = genAllocSource(random, &src_buf);
            if (source.len == 0) return;

            // --- .sig path: strict mode, must have annotation ---
            {
                var path_buf: [128]u8 = undefined;
                const sig_path = genFilePath(random, &path_buf, ".sig");

                const effective_mode = sig_integration.resolveFileMode(sig_path, .default);
                const entries = try sig_diag.analyzeSource(gpa, source, sig_path, effective_mode);
                defer sig_diag.freeEntries(gpa, entries);

                try std.testing.expect(entries.len > 0);

                for (entries) |entry| {
                    const msg = try sig_diag.formatDiagnostic(gpa, entry, effective_mode);
                    defer gpa.free(msg);

                    // Must contain .sig annotation
                    try std.testing.expect(
                        std.mem.indexOf(u8, msg, "(.sig file: strict mode enforced)") != null,
                    );

                    // Must contain one of the classification strings
                    const has_direct = std.mem.indexOf(u8, msg, "direct allocation") != null;
                    const has_transitive = std.mem.indexOf(u8, msg, "transitive allocation") != null;
                    const has_unknown = std.mem.indexOf(u8, msg, "unknown memory behavior") != null;
                    try std.testing.expect(has_direct or has_transitive or has_unknown);

                    // Must contain the file path
                    try std.testing.expect(
                        std.mem.indexOf(u8, msg, sig_path) != null,
                    );

                    // Must contain the function name
                    try std.testing.expect(
                        std.mem.indexOf(u8, msg, entry.function_name) != null,
                    );
                }
            }

            // --- .zig path: default mode, must NOT have annotation ---
            {
                var path_buf2: [128]u8 = undefined;
                const zig_path = genFilePath(random, &path_buf2, ".zig");

                const effective_mode = sig_integration.resolveFileMode(zig_path, .default);
                const entries = try sig_diag.analyzeSource(gpa, source, zig_path, effective_mode);
                defer sig_diag.freeEntries(gpa, entries);

                try std.testing.expect(entries.len > 0);

                for (entries) |entry| {
                    const msg = try sig_diag.formatDiagnostic(gpa, entry, effective_mode);
                    defer gpa.free(msg);

                    // Must NOT contain .sig annotation
                    try std.testing.expect(
                        std.mem.indexOf(u8, msg, "(.sig file: strict mode enforced)") == null,
                    );

                    // Must still contain classification string
                    const has_direct = std.mem.indexOf(u8, msg, "direct allocation") != null;
                    const has_transitive = std.mem.indexOf(u8, msg, "transitive allocation") != null;
                    const has_unknown = std.mem.indexOf(u8, msg, "unknown memory behavior") != null;
                    try std.testing.expect(has_direct or has_transitive or has_unknown);

                    // Must contain the file path
                    try std.testing.expect(
                        std.mem.indexOf(u8, msg, zig_path) != null,
                    );

                    // Must contain the function name
                    try std.testing.expect(
                        std.mem.indexOf(u8, msg, entry.function_name) != null,
                    );
                }
            }
        }
    };
    harness.property(
        "sig annotation presence and diagnostic completeness",
        S.run,
    );
}
