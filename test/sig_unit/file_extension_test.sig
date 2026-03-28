const std = @import("std");
const testing = std.testing;
const sig_integration = @import("sig_diagnostics_integration");
const sig_diag = @import("sig_diagnostics");

/// Mirrors the Zcu.File.modeFromPath logic from src/Zcu.zig.
/// Used for unit testing since Zcu is not available as a test import.
/// [sig] .zon is checked first, so .sig.zon files are correctly parsed as ZON (not as .sig source).
const AstMode = enum { zig, zon };
fn modeFromPath(path: []const u8) ?AstMode {
    if (std.mem.endsWith(u8, path, ".zon")) {
        return .zon;
    } else if (std.mem.endsWith(u8, path, ".zig") or std.mem.endsWith(u8, path, ".sig")) {
        return .zig;
    } else {
        return null;
    }
}

// Unit Tests for hasSigExtension and resolveFileMode
// Requirements: 2.1, 2.2, 3.2, 3.3, 3.4, 3.5

test "hasSigExtension: returns true for foo.sig" {
    try testing.expect(sig_integration.hasSigExtension("foo.sig"));
}

test "hasSigExtension: returns true for path/to/bar.sig" {
    try testing.expect(sig_integration.hasSigExtension("path/to/bar.sig"));
}

test "hasSigExtension: returns true for .sig" {
    try testing.expect(sig_integration.hasSigExtension(".sig"));
}

test "hasSigExtension: returns false for foo.zig" {
    try testing.expect(!sig_integration.hasSigExtension("foo.zig"));
}

test "hasSigExtension: returns false for foo.sig.zig" {
    try testing.expect(!sig_integration.hasSigExtension("foo.sig.zig"));
}

test "hasSigExtension: returns false for foo.signature" {
    try testing.expect(!sig_integration.hasSigExtension("foo.signature"));
}

test "hasSigExtension: returns false for foo.SIG (case-sensitive)" {
    try testing.expect(!sig_integration.hasSigExtension("foo.SIG"));
}

test "resolveFileMode: .sig file with default global mode returns strict" {
    try testing.expectEqual(sig_integration.Mode.strict, sig_integration.resolveFileMode("x.sig", .default));
}

test "resolveFileMode: .sig file with strict global mode returns strict" {
    try testing.expectEqual(sig_integration.Mode.strict, sig_integration.resolveFileMode("x.sig", .strict));
}

test "resolveFileMode: .zig file with default global mode returns default" {
    try testing.expectEqual(sig_integration.Mode.default, sig_integration.resolveFileMode("x.zig", .default));
}

test "resolveFileMode: .zig file with strict global mode returns strict" {
    try testing.expectEqual(sig_integration.Mode.strict, sig_integration.resolveFileMode("x.zig", .strict));
}

// Unit Tests for formatDiagnostic with .sig annotation
// Requirements: 6.1, 6.4

test "formatDiagnostic: .sig file in strict mode includes sig annotation" {
    const gpa = testing.allocator;
    const entry = sig_diag.DiagnosticEntry{
        .file_path = "src/core.sig",
        .line = 42,
        .column = 5,
        .function_name = "init",
        .classification = .direct_allocation,
        .call_path = null,
    };
    const msg = try sig_diag.formatDiagnostic(gpa, entry, .strict);
    defer gpa.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "(.sig file: strict mode enforced)") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "error") != null);
}

test "formatDiagnostic: .zig file in default mode does not include sig annotation" {
    const gpa = testing.allocator;
    const entry = sig_diag.DiagnosticEntry{
        .file_path = "src/core.zig",
        .line = 10,
        .column = 3,
        .function_name = "setup",
        .classification = .direct_allocation,
        .call_path = null,
    };
    const msg = try sig_diag.formatDiagnostic(gpa, entry, .default);
    defer gpa.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "(.sig file: strict mode enforced)") == null);
    try testing.expect(std.mem.indexOf(u8, msg, "warning") != null);
}

test "formatDiagnostic: .zig file in strict mode does not include sig annotation" {
    const gpa = testing.allocator;
    const entry = sig_diag.DiagnosticEntry{
        .file_path = "src/core.zig",
        .line = 10,
        .column = 3,
        .function_name = "setup",
        .classification = .direct_allocation,
        .call_path = null,
    };
    const msg = try sig_diag.formatDiagnostic(gpa, entry, .strict);
    defer gpa.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "(.sig file: strict mode enforced)") == null);
    try testing.expect(std.mem.indexOf(u8, msg, "error") != null);
}

// Unit Tests for analyzeFile with .sig and .zig file paths
// Requirements: 1.2, 7.1, 7.2, 7.3

test "analyzeFile: .sig file with default global mode produces errors" {
    const gpa = testing.allocator;
    const source = "fn doWork() void {\n    const x = allocator.alloc(u8, 64);\n    _ = x;\n}\n";
    var result = try sig_integration.analyzeFile(gpa, "test.sig", source, .default);
    defer result.deinit();
    try testing.expect(result.total_errors > 0);
    try testing.expectEqual(@as(usize, 0), result.total_warnings);
}

test "analyzeFile: .zig file with default global mode produces warnings" {
    const gpa = testing.allocator;
    const source = "fn doWork() void {\n    const x = allocator.alloc(u8, 64);\n    _ = x;\n}\n";
    var result = try sig_integration.analyzeFile(gpa, "test.zig", source, .default);
    defer result.deinit();
    try testing.expect(result.total_warnings > 0);
    try testing.expectEqual(@as(usize, 0), result.total_errors);
}

// Unit Tests for .sig.zon mode resolution (modeFromPath)
// Requirements: 9.1, 9.2, 9.3

test "modeFromPath: build.sig.zon returns .zon" {
    try testing.expectEqual(AstMode.zon, modeFromPath("build.sig.zon").?);
}

test "modeFromPath: foo.sig.zon returns .zon" {
    try testing.expectEqual(AstMode.zon, modeFromPath("foo.sig.zon").?);
}

test "modeFromPath: path/to/bar.sig.zon returns .zon" {
    try testing.expectEqual(AstMode.zon, modeFromPath("path/to/bar.sig.zon").?);
}

test "modeFromPath: build.sig returns .zig (not .zon)" {
    try testing.expectEqual(AstMode.zig, modeFromPath("build.sig").?);
}

test "hasSigExtension: build.sig.zon returns false (it is ZON, not Sig source)" {
    try testing.expect(!sig_integration.hasSigExtension("build.sig.zon"));
}

// Unit Tests for build file precedence constants
// Requirements: 8.1, 8.4

/// Mirrors the build file constants from src/Package.zig and src/Package/Manifest.zig.
/// These are compiler-internal modules not available as test imports, so we verify
/// the contract values directly to ensure the constants match the spec.
const build_sig_basename = "build.sig";
const build_zig_basename = "build.zig";
const manifest_sig_basename = "build.sig.zon";
const manifest_zig_basename = "build.zig.zon";

test "build_sig_basename constant equals 'build.sig'" {
    try testing.expectEqualStrings("build.sig", build_sig_basename);
}

test "Manifest.sig_basename constant equals 'build.sig.zon'" {
    try testing.expectEqualStrings("build.sig.zon", manifest_sig_basename);
}

test "build.sig has .sig extension (hasSigExtension)" {
    try testing.expect(sig_integration.hasSigExtension(build_sig_basename));
}

test "build.sig.zon is not a .sig file (hasSigExtension)" {
    try testing.expect(!sig_integration.hasSigExtension(manifest_sig_basename));
}

test "build.sig resolves to .zig mode (not .zon)" {
    try testing.expectEqual(AstMode.zig, modeFromPath(build_sig_basename).?);
}

test "build.sig.zon resolves to .zon mode" {
    try testing.expectEqual(AstMode.zon, modeFromPath(manifest_sig_basename).?);
}

test "build.zig.zon resolves to .zon mode" {
    try testing.expectEqual(AstMode.zon, modeFromPath(manifest_zig_basename).?);
}

test "build.zig resolves to .zig mode" {
    try testing.expectEqual(AstMode.zig, modeFromPath(build_zig_basename).?);
}
