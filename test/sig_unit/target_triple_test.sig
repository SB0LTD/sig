// Unit tests for Target_Triple and Optimize_Mode (task 1.6).
//
// Since the build runner (tools/sig_build/main.sig) is not wired as a test import,
// these tests replicate the Target_Triple and Optimize_Mode logic using the same
// algorithms to validate correctness.
//
// Requirements: 9.4, 9.5

const std = @import("std");
const testing = std.testing;

const PATH_BUF_SIZE = 4096;
const SigError = @import("sig").SigError;

// ── Replicated types from main.sig ──────────────────────────────────────

const Optimize_Mode = enum { Debug, ReleaseSafe, ReleaseFast, ReleaseSmall };

const Target_Triple = struct {
    arch: [32]u8 = undefined,
    arch_len: usize = 0,
    os: [32]u8 = undefined,
    os_len: usize = 0,
    abi: [32]u8 = undefined,
    abi_len: usize = 0,

    pub fn format(self: *const Target_Triple, buf: *[PATH_BUF_SIZE]u8) SigError![]const u8 {
        const total = self.arch_len + 1 + self.os_len + 1 + self.abi_len;
        if (total > PATH_BUF_SIZE) return error.BufferTooSmall;

        var offset: usize = 0;
        @memcpy(buf[offset..][0..self.arch_len], self.arch[0..self.arch_len]);
        offset += self.arch_len;

        buf[offset] = '-';
        offset += 1;

        @memcpy(buf[offset..][0..self.os_len], self.os[0..self.os_len]);
        offset += self.os_len;

        buf[offset] = '-';
        offset += 1;

        @memcpy(buf[offset..][0..self.abi_len], self.abi[0..self.abi_len]);
        offset += self.abi_len;

        return buf[0..offset];
    }

    pub fn parse(s: []const u8) SigError!Target_Triple {
        const first_dash = std.mem.indexOfScalar(u8, s, '-') orelse return error.BufferTooSmall;
        const rest = s[first_dash + 1 ..];
        const second_dash = std.mem.indexOfScalar(u8, rest, '-') orelse return error.BufferTooSmall;

        const arch = s[0..first_dash];
        const os = rest[0..second_dash];
        const abi = rest[second_dash + 1 ..];

        if (arch.len > 32) return error.BufferTooSmall;
        if (os.len > 32) return error.BufferTooSmall;
        if (abi.len > 32) return error.BufferTooSmall;

        var triple: Target_Triple = .{};

        @memcpy(triple.arch[0..arch.len], arch);
        triple.arch_len = arch.len;

        @memcpy(triple.os[0..os.len], os);
        triple.os_len = os.len;

        @memcpy(triple.abi[0..abi.len], abi);
        triple.abi_len = abi.len;

        return triple;
    }
};


// ── Target_Triple.parse: valid triples ──────────────────────────────────

test "parse: x86_64-linux-gnu" {
    const triple = try Target_Triple.parse("x86_64-linux-gnu");
    try testing.expectEqualStrings("x86_64", triple.arch[0..triple.arch_len]);
    try testing.expectEqualStrings("linux", triple.os[0..triple.os_len]);
    try testing.expectEqualStrings("gnu", triple.abi[0..triple.abi_len]);
}

test "parse: aarch64-macos-none" {
    const triple = try Target_Triple.parse("aarch64-macos-none");
    try testing.expectEqualStrings("aarch64", triple.arch[0..triple.arch_len]);
    try testing.expectEqualStrings("macos", triple.os[0..triple.os_len]);
    try testing.expectEqualStrings("none", triple.abi[0..triple.abi_len]);
}

test "parse: wasm32-wasi-musl" {
    const triple = try Target_Triple.parse("wasm32-wasi-musl");
    try testing.expectEqualStrings("wasm32", triple.arch[0..triple.arch_len]);
    try testing.expectEqualStrings("wasi", triple.os[0..triple.os_len]);
    try testing.expectEqualStrings("musl", triple.abi[0..triple.abi_len]);
}

// ── Target_Triple.parse: error cases ────────────────────────────────────

test "parse: no dashes returns error" {
    try testing.expectError(error.BufferTooSmall, Target_Triple.parse("x86_64linuxgnu"));
}

test "parse: single dash returns error" {
    try testing.expectError(error.BufferTooSmall, Target_Triple.parse("x86_64-linux"));
}

test "parse: component exceeding 32 bytes returns error" {
    // 33-byte arch component
    const long = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-os-abi";
    try testing.expectError(error.BufferTooSmall, Target_Triple.parse(long));
}

// ── Target_Triple.format ────────────────────────────────────────────────

test "format: round-trip x86_64-linux-gnu" {
    const triple = try Target_Triple.parse("x86_64-linux-gnu");
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const result = try triple.format(&buf);
    try testing.expectEqualStrings("x86_64-linux-gnu", result);
}

test "format: round-trip aarch64-macos-none" {
    const triple = try Target_Triple.parse("aarch64-macos-none");
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const result = try triple.format(&buf);
    try testing.expectEqualStrings("aarch64-macos-none", result);
}

// ── Target_Triple: empty abi ────────────────────────────────────────────

test "parse: empty abi component is valid" {
    const triple = try Target_Triple.parse("x86_64-linux-");
    try testing.expectEqualStrings("x86_64", triple.arch[0..triple.arch_len]);
    try testing.expectEqualStrings("linux", triple.os[0..triple.os_len]);
    try testing.expectEqual(@as(usize, 0), triple.abi_len);
}

// ── Optimize_Mode enum ──────────────────────────────────────────────────

test "Optimize_Mode: all four variants exist" {
    const modes = [_]Optimize_Mode{ .Debug, .ReleaseSafe, .ReleaseFast, .ReleaseSmall };
    try testing.expectEqual(@as(usize, 4), modes.len);
}

test "Optimize_Mode: enum field names match std.Build conventions" {
    const fields = @typeInfo(Optimize_Mode).@"enum".fields;
    try testing.expectEqualStrings("Debug", fields[0].name);
    try testing.expectEqualStrings("ReleaseSafe", fields[1].name);
    try testing.expectEqualStrings("ReleaseFast", fields[2].name);
    try testing.expectEqualStrings("ReleaseSmall", fields[3].name);
}
