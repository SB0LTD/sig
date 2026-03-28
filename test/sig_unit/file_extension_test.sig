const std = @import("std");
const testing = std.testing;
const sig_integration = @import("sig_diagnostics_integration");
const sig_diag = @import("sig_diagnostics");

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
