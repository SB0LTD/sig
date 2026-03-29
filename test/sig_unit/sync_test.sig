const std = @import("std");
const testing = std.testing;
const sig_sync = @import("sig_sync");

const SyncEntry = sig_sync.SyncEntry;
const SyncManifest = sig_sync.SyncManifest;

// ── Unit Tests for Sig_Sync manifest serialization, conflict detection, entry recording ──
// Requirements: 10.2, 10.3, 10.4

// ── Serialization / Deserialization ──────────────────────────────────────

test "parseManifest with known single integrated entry" {
    const json =
        \\{
        \\  "last_integrated_commit": "deadbeef1234567890abcdef1234567890abcdef",
        \\  "last_integration_timestamp": 1710000000,
        \\  "entries": [
        \\    {
        \\      "upstream_commit": "deadbeef1234567890abcdef1234567890abcdef",
        \\      "timestamp": 1710000000,
        \\      "status": "integrated",
        \\      "conflicting_files": null
        \\    }
        \\  ]
        \\}
    ;
    const m = sig_sync.parseManifest(json);

    try testing.expectEqualStrings("deadbeef1234567890abcdef1234567890abcdef", m.lastCommit());
    try testing.expectEqual(@as(i64, 1710000000), m.last_integration_timestamp);
    try testing.expectEqual(@as(usize, 1), m.entry_count);
    try testing.expectEqualStrings("deadbeef1234567890abcdef1234567890abcdef", m.entries[0].commit());
    try testing.expectEqual(SyncEntry.Status.integrated, m.entries[0].status);
    try testing.expectEqual(@as(usize, 0), m.entries[0].conflict_count);
}

test "serializeManifest produces valid JSON that round-trips" {
    var original = SyncManifest{};
    original.setLastCommit("aabbccdd00112233445566778899aabbccddeeff");
    original.last_integration_timestamp = 1720000000;
    var entry = SyncEntry{};
    entry.setCommit("aabbccdd00112233445566778899aabbccddeeff");
    entry.timestamp = 1720000000;
    entry.status = .integrated;
    original.addEntry(entry);

    var buf: [8192]u8 = undefined;
    const json = try sig_sync.serializeManifest(&original, &buf);

    const m = sig_sync.parseManifest(json);

    try testing.expectEqualStrings("aabbccdd00112233445566778899aabbccddeeff", m.lastCommit());
    try testing.expectEqual(@as(i64, 1720000000), m.last_integration_timestamp);
    try testing.expectEqual(@as(usize, 1), m.entry_count);
    try testing.expectEqual(SyncEntry.Status.integrated, m.entries[0].status);
}


// ── Conflict Detection ──────────────────────────────────────────────────

test "conflict entry has non-empty conflicting_files list" {
    const json =
        \\{
        \\  "last_integrated_commit": "1111111111111111111111111111111111111111",
        \\  "last_integration_timestamp": 1700000000,
        \\  "entries": [
        \\    {
        \\      "upstream_commit": "2222222222222222222222222222222222222222",
        \\      "timestamp": 1700001000,
        \\      "status": "conflict",
        \\      "conflicting_files": ["lib/sig/fmt.zig", "src/main.zig", "build.zig"]
        \\    }
        \\  ]
        \\}
    ;
    const m = sig_sync.parseManifest(json);
    const entry = m.entries[0];

    try testing.expectEqual(SyncEntry.Status.conflict, entry.status);
    try testing.expectEqual(@as(usize, 3), entry.conflict_count);
    try testing.expectEqualStrings("lib/sig/fmt.zig", entry.conflictFile(0));
    try testing.expectEqualStrings("src/main.zig", entry.conflictFile(1));
    try testing.expectEqualStrings("build.zig", entry.conflictFile(2));
}

test "integrated entry has zero conflict_count" {
    const json =
        \\{
        \\  "last_integrated_commit": "aaaa000000000000000000000000000000000000",
        \\  "last_integration_timestamp": 1700000000,
        \\  "entries": [
        \\    {
        \\      "upstream_commit": "aaaa000000000000000000000000000000000000",
        \\      "timestamp": 1700000000,
        \\      "status": "integrated",
        \\      "conflicting_files": null
        \\    }
        \\  ]
        \\}
    ;
    const m = sig_sync.parseManifest(json);
    const entry = m.entries[0];

    try testing.expectEqual(SyncEntry.Status.integrated, entry.status);
    try testing.expectEqual(@as(usize, 0), entry.conflict_count);
}

test "conflict entry round-trips through serialize/parse with files preserved" {
    var manifest = SyncManifest{};
    manifest.setLastCommit("cccccccccccccccccccccccccccccccccccccccc");
    manifest.last_integration_timestamp = 1700005000;
    var entry = SyncEntry{};
    entry.setCommit("dddddddddddddddddddddddddddddddddddddd");
    entry.timestamp = 1700005000;
    entry.status = .conflict;
    entry.addConflictFile("lib/sig/io.zig");
    entry.addConflictFile("tools/sig_sync/main.zig");
    manifest.addEntry(entry);

    var buf: [8192]u8 = undefined;
    const json = try sig_sync.serializeManifest(&manifest, &buf);

    const parsed = sig_sync.parseManifest(json);
    const pe = parsed.entries[0];

    try testing.expectEqual(SyncEntry.Status.conflict, pe.status);
    try testing.expectEqual(@as(usize, 2), pe.conflict_count);
    try testing.expectEqualStrings("lib/sig/io.zig", pe.conflictFile(0));
    try testing.expectEqualStrings("tools/sig_sync/main.zig", pe.conflictFile(1));
}


// ── Entry Recording — all fields preserved ──────────────────────────────

test "all SyncEntry fields preserved through serialize/parse round trip" {
    var manifest = SyncManifest{};
    manifest.setLastCommit("abcdef0123456789abcdef0123456789abcdef01");
    manifest.last_integration_timestamp = 1699999999;

    // Entry 0: integrated
    var e0 = SyncEntry{};
    e0.setCommit("1234567890abcdef1234567890abcdef12345678");
    e0.timestamp = 1699999000;
    e0.status = .integrated;
    manifest.addEntry(e0);

    // Entry 1: conflict with file
    var e1 = SyncEntry{};
    e1.setCommit("abcdef0123456789abcdef0123456789abcdef01");
    e1.timestamp = 1699999500;
    e1.status = .conflict;
    e1.addConflictFile("src/Compilation.zig");
    manifest.addEntry(e1);

    // Entry 2: skipped
    var e2 = SyncEntry{};
    e2.setCommit("fedcba9876543210fedcba9876543210fedcba98");
    e2.timestamp = 1699999999;
    e2.status = .skipped;
    manifest.addEntry(e2);

    var buf: [16384]u8 = undefined;
    const json = try sig_sync.serializeManifest(&manifest, &buf);

    const m = sig_sync.parseManifest(json);

    // Top-level fields
    try testing.expectEqualStrings("abcdef0123456789abcdef0123456789abcdef01", m.lastCommit());
    try testing.expectEqual(@as(i64, 1699999999), m.last_integration_timestamp);
    try testing.expectEqual(@as(usize, 3), m.entry_count);

    // Entry 0: integrated
    try testing.expectEqualStrings("1234567890abcdef1234567890abcdef12345678", m.entries[0].commit());
    try testing.expectEqual(@as(i64, 1699999000), m.entries[0].timestamp);
    try testing.expectEqual(SyncEntry.Status.integrated, m.entries[0].status);
    try testing.expectEqual(@as(usize, 0), m.entries[0].conflict_count);

    // Entry 1: conflict
    try testing.expectEqualStrings("abcdef0123456789abcdef0123456789abcdef01", m.entries[1].commit());
    try testing.expectEqual(@as(i64, 1699999500), m.entries[1].timestamp);
    try testing.expectEqual(SyncEntry.Status.conflict, m.entries[1].status);
    try testing.expectEqual(@as(usize, 1), m.entries[1].conflict_count);
    try testing.expectEqualStrings("src/Compilation.zig", m.entries[1].conflictFile(0));

    // Entry 2: skipped
    try testing.expectEqualStrings("fedcba9876543210fedcba9876543210fedcba98", m.entries[2].commit());
    try testing.expectEqual(@as(i64, 1699999999), m.entries[2].timestamp);
    try testing.expectEqual(SyncEntry.Status.skipped, m.entries[2].status);
    try testing.expectEqual(@as(usize, 0), m.entries[2].conflict_count);
}


// ── Edge Cases ──────────────────────────────────────────────────────────

test "empty manifest parses to defaults" {
    const m = sig_sync.parseManifest("");
    try testing.expectEqualStrings("", m.lastCommit());
    try testing.expectEqual(@as(i64, 0), m.last_integration_timestamp);
    try testing.expectEqual(@as(usize, 0), m.entry_count);
}

test "empty manifest serializes and round-trips" {
    var manifest = SyncManifest{};

    var buf: [8192]u8 = undefined;
    const json = try sig_sync.serializeManifest(&manifest, &buf);

    const m = sig_sync.parseManifest(json);

    try testing.expectEqualStrings("", m.lastCommit());
    try testing.expectEqual(@as(i64, 0), m.last_integration_timestamp);
    try testing.expectEqual(@as(usize, 0), m.entry_count);
}

test "single entry manifest round-trips correctly" {
    var manifest = SyncManifest{};
    manifest.setLastCommit("0000000000000000000000000000000000000001");
    manifest.last_integration_timestamp = 1;
    var entry = SyncEntry{};
    entry.setCommit("0000000000000000000000000000000000000001");
    entry.timestamp = 1;
    entry.status = .skipped;
    manifest.addEntry(entry);

    var buf: [8192]u8 = undefined;
    const json = try sig_sync.serializeManifest(&manifest, &buf);

    const parsed = sig_sync.parseManifest(json);

    try testing.expectEqual(@as(usize, 1), parsed.entry_count);
    try testing.expectEqual(SyncEntry.Status.skipped, parsed.entries[0].status);
}

test "many entries manifest round-trips preserving count" {
    var manifest = SyncManifest{};
    manifest.setLastCommit("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    manifest.last_integration_timestamp = 9000;

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var entry = SyncEntry{};
        entry.setCommit("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        entry.timestamp = @as(i64, @intCast(i)) * 1000;
        entry.status = if (i % 3 == 0) .integrated else if (i % 3 == 1) .conflict else .skipped;
        if (i % 3 == 1) {
            entry.addConflictFile("file.zig");
        }
        manifest.addEntry(entry);
    }

    var buf: [32768]u8 = undefined;
    const json = try sig_sync.serializeManifest(&manifest, &buf);

    const parsed = sig_sync.parseManifest(json);

    try testing.expectEqual(@as(usize, 10), parsed.entry_count);
}

test "large commit hash (all f's) round-trips" {
    var manifest = SyncManifest{};
    manifest.setLastCommit("ffffffffffffffffffffffffffffffffffffffff");
    manifest.last_integration_timestamp = 2147483647;
    var entry = SyncEntry{};
    entry.setCommit("ffffffffffffffffffffffffffffffffffffffff");
    entry.timestamp = 2147483647;
    entry.status = .integrated;
    manifest.addEntry(entry);

    var buf: [8192]u8 = undefined;
    const json = try sig_sync.serializeManifest(&manifest, &buf);

    const parsed = sig_sync.parseManifest(json);

    try testing.expectEqualStrings("ffffffffffffffffffffffffffffffffffffffff", parsed.lastCommit());
    try testing.expectEqualStrings("ffffffffffffffffffffffffffffffffffffffff", parsed.entries[0].commit());
}


// ── Mixed Statuses ──────────────────────────────────────────────────────

test "multiple entries with mixed statuses preserve all fields" {
    const json =
        \\{
        \\  "last_integrated_commit": "aaaa000000000000000000000000000000000000",
        \\  "last_integration_timestamp": 1700003000,
        \\  "entries": [
        \\    {
        \\      "upstream_commit": "aaaa000000000000000000000000000000000000",
        \\      "timestamp": 1700001000,
        \\      "status": "integrated",
        \\      "conflicting_files": null
        \\    },
        \\    {
        \\      "upstream_commit": "bbbb000000000000000000000000000000000000",
        \\      "timestamp": 1700002000,
        \\      "status": "conflict",
        \\      "conflicting_files": ["lib/sig/containers.zig"]
        \\    },
        \\    {
        \\      "upstream_commit": "cccc000000000000000000000000000000000000",
        \\      "timestamp": 1700003000,
        \\      "status": "skipped",
        \\      "conflicting_files": null
        \\    }
        \\  ]
        \\}
    ;
    const m = sig_sync.parseManifest(json);

    try testing.expectEqual(@as(usize, 3), m.entry_count);
    try testing.expectEqual(SyncEntry.Status.integrated, m.entries[0].status);
    try testing.expectEqual(SyncEntry.Status.conflict, m.entries[1].status);
    try testing.expectEqual(SyncEntry.Status.skipped, m.entries[2].status);

    // Only the conflict entry has files
    try testing.expectEqual(@as(usize, 0), m.entries[0].conflict_count);
    try testing.expectEqual(@as(usize, 1), m.entries[1].conflict_count);
    try testing.expectEqual(@as(usize, 0), m.entries[2].conflict_count);
}

// ── JSON Structure Verification ─────────────────────────────────────────

test "serialized manifest JSON contains expected top-level keys" {
    var manifest = SyncManifest{};
    manifest.setLastCommit("0123456789abcdef0123456789abcdef01234567");
    manifest.last_integration_timestamp = 1700000000;
    var entry = SyncEntry{};
    entry.setCommit("0123456789abcdef0123456789abcdef01234567");
    entry.timestamp = 1700000000;
    entry.status = .integrated;
    manifest.addEntry(entry);

    var buf: [8192]u8 = undefined;
    const json = try sig_sync.serializeManifest(&manifest, &buf);

    // Verify expected JSON keys are present
    try testing.expect(std.mem.indexOf(u8, json, "\"last_integrated_commit\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"last_integration_timestamp\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"entries\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"upstream_commit\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"timestamp\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"status\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"conflicting_files\"") != null);
}

test "serialized manifest contains status string values not enum integers" {
    var manifest = SyncManifest{};
    manifest.setLastCommit("0000000000000000000000000000000000000000");
    manifest.last_integration_timestamp = 0;

    var e0 = SyncEntry{};
    e0.setCommit("1111111111111111111111111111111111111111");
    e0.timestamp = 1;
    e0.status = .integrated;
    manifest.addEntry(e0);

    var e1 = SyncEntry{};
    e1.setCommit("2222222222222222222222222222222222222222");
    e1.timestamp = 2;
    e1.status = .conflict;
    e1.addConflictFile("a.zig");
    manifest.addEntry(e1);

    var e2 = SyncEntry{};
    e2.setCommit("3333333333333333333333333333333333333333");
    e2.timestamp = 3;
    e2.status = .skipped;
    manifest.addEntry(e2);

    var buf: [16384]u8 = undefined;
    const json = try sig_sync.serializeManifest(&manifest, &buf);

    // Status values are serialized as human-readable strings
    try testing.expect(std.mem.indexOf(u8, json, "\"integrated\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"conflict\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"skipped\"") != null);
}

test "invalid JSON input returns default manifest" {
    const m = sig_sync.parseManifest("{invalid json!!}");
    try testing.expectEqual(@as(usize, 0), m.entry_count);
    try testing.expectEqualStrings("", m.lastCommit());
}
