// Feature: sig-memory-model, Property 15: Sync manifest integrity
//
// For any sequence of upstream commits processed by Sig_Sync, the resulting
// manifest shall contain one SyncEntry per processed commit with a valid
// 40-character hex commit hash and a status of integrated, conflict, or
// skipped. Non-conflicting commits shall have status integrated. Conflicting
// commits shall have status conflict with a non-empty conflict_count.
//
// **Validates: Requirements 10.2, 10.3, 10.4**

const std = @import("std");
const harness = @import("harness");
const sig_sync = @import("sig_sync");

const SyncEntry = sig_sync.SyncEntry;
const SyncManifest = sig_sync.SyncManifest;

// ---------------------------------------------------------------------------
// Generators (zero allocators)
// ---------------------------------------------------------------------------

const hex_chars = "0123456789abcdef";

fn genCommitHash(random: std.Random, buf: *[40]u8) void {
    for (buf) |*c| {
        c.* = hex_chars[random.uintAtMost(usize, hex_chars.len - 1)];
    }
}

fn isValidCommitHash(hash: []const u8) bool {
    if (hash.len != 40) return false;
    for (hash) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) return false;
    }
    return true;
}

fn genStatus(random: std.Random) SyncEntry.Status {
    return switch (random.uintAtMost(u8, 3)) {
        0 => .integrated,
        1 => .conflict,
        2 => .skipped,
        3 => .ai_resolved,
        else => unreachable,
    };
}

const path_pool = [_][]const u8{
    "lib/sig/fmt.zig",
    "src/main.zig",
    "lib/sig/io.zig",
    "tools/sig_sync/main.zig",
    "lib/sig/containers.zig",
};

fn genSyncEntry(random: std.Random) SyncEntry {
    var entry = SyncEntry{};
    var hash_buf: [40]u8 = undefined;
    genCommitHash(random, &hash_buf);
    entry.setCommit(&hash_buf);
    entry.timestamp = random.int(i64) & 0x7FFFFFFF;
    entry.status = genStatus(random);
    if (entry.status == .conflict or entry.status == .ai_resolved) {
        const count = 1 + random.uintAtMost(usize, 3);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            entry.addConflictFile(path_pool[random.uintAtMost(usize, path_pool.len - 1)]);
        }
    }
    return entry;
}

// ---------------------------------------------------------------------------
// Property 15: Sync manifest integrity
// ---------------------------------------------------------------------------

test "Property 15: serialize-parse round trip preserves entry count" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const entry_count = 1 + random.uintAtMost(usize, 7);
            var manifest = SyncManifest{};
            var first_hash: [40]u8 = undefined;
            genCommitHash(random, &first_hash);
            manifest.setLastCommit(&first_hash);
            manifest.last_integration_timestamp = random.int(i64) & 0x7FFFFFFF;

            var i: usize = 0;
            while (i < entry_count) : (i += 1) {
                manifest.addEntry(genSyncEntry(random));
            }

            var buf: [32768]u8 = undefined;
            const json = try sig_sync.serializeManifest(&manifest, &buf);
            const parsed = sig_sync.parseManifest(json);
            try std.testing.expectEqual(entry_count, parsed.entry_count);
        }
    };
    harness.property("serialize-parse round trip preserves entry count", S.run);
}

test "Property 15: every entry has a valid 40-char hex commit hash" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const entry_count = 1 + random.uintAtMost(usize, 7);
            var manifest = SyncManifest{};
            var first_hash: [40]u8 = undefined;
            genCommitHash(random, &first_hash);
            manifest.setLastCommit(&first_hash);
            manifest.last_integration_timestamp = random.int(i64) & 0x7FFFFFFF;

            var i: usize = 0;
            while (i < entry_count) : (i += 1) {
                manifest.addEntry(genSyncEntry(random));
            }

            var buf: [32768]u8 = undefined;
            const json = try sig_sync.serializeManifest(&manifest, &buf);
            const parsed = sig_sync.parseManifest(json);

            var j: usize = 0;
            while (j < parsed.entry_count) : (j += 1) {
                try std.testing.expect(isValidCommitHash(parsed.entries[j].commit()));
            }
        }
    };
    harness.property("every entry has a valid 40-char hex commit hash", S.run);
}

test "Property 15: status is one of integrated, conflict, skipped, or ai_resolved" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const entry_count = 1 + random.uintAtMost(usize, 7);
            var manifest = SyncManifest{};
            var first_hash: [40]u8 = undefined;
            genCommitHash(random, &first_hash);
            manifest.setLastCommit(&first_hash);
            manifest.last_integration_timestamp = random.int(i64) & 0x7FFFFFFF;

            var i: usize = 0;
            while (i < entry_count) : (i += 1) {
                manifest.addEntry(genSyncEntry(random));
            }

            var buf: [32768]u8 = undefined;
            const json = try sig_sync.serializeManifest(&manifest, &buf);
            const parsed = sig_sync.parseManifest(json);

            var j: usize = 0;
            while (j < parsed.entry_count) : (j += 1) {
                const valid = parsed.entries[j].status == .integrated or
                    parsed.entries[j].status == .conflict or
                    parsed.entries[j].status == .skipped or
                    parsed.entries[j].status == .ai_resolved;
                try std.testing.expect(valid);
            }
        }
    };
    harness.property("status is one of integrated, conflict, skipped, or ai_resolved", S.run);
}

test "Property 15: conflict entries have non-zero conflict_count, others have zero" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const entry_count = 1 + random.uintAtMost(usize, 7);
            var manifest = SyncManifest{};
            var first_hash: [40]u8 = undefined;
            genCommitHash(random, &first_hash);
            manifest.setLastCommit(&first_hash);
            manifest.last_integration_timestamp = random.int(i64) & 0x7FFFFFFF;

            var i: usize = 0;
            while (i < entry_count) : (i += 1) {
                manifest.addEntry(genSyncEntry(random));
            }

            var buf: [32768]u8 = undefined;
            const json = try sig_sync.serializeManifest(&manifest, &buf);
            const parsed = sig_sync.parseManifest(json);

            var j: usize = 0;
            while (j < parsed.entry_count) : (j += 1) {
                switch (parsed.entries[j].status) {
                    .conflict, .ai_resolved => {
                        try std.testing.expect(parsed.entries[j].conflict_count > 0);
                    },
                    .integrated, .skipped => {
                        try std.testing.expectEqual(@as(usize, 0), parsed.entries[j].conflict_count);
                    },
                }
            }
        }
    };
    harness.property("conflict entries have non-zero conflict_count, others have zero", S.run);
}
