const std = @import("std");
const testing = std.testing;
const readme = @import("sig_readme");

const SyncManifest = readme.SyncManifest;

// ── Fixed-buffer Writer (zero allocators) ────────────────────────────────
// Captures writeReadme output into a stack buffer via the std.Io.Writer vtable.

const FixedBufWriter = struct {
    output: []u8,
    pos: usize,
    writer: std.Io.Writer,

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
    };

    fn init(buf: []u8) FixedBufWriter {
        return .{
            .output = buf,
            .pos = 0,
            .writer = .{
                .vtable = &vtable,
                .buffer = &.{}, // unbuffered — all writes go through drain
            },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FixedBufWriter = @alignCast(@fieldParentPtr("writer", w));
        var total: usize = 0;

        // First flush any buffered data.
        if (w.end > 0) {
            const buffered = w.buffer[0..w.end];
            if (self.pos + buffered.len > self.output.len) return error.WriteFailed;
            @memcpy(self.output[self.pos..][0..buffered.len], buffered);
            self.pos += buffered.len;
            w.end = 0;
        }

        // Write all data slices except the last (which is the splat pattern).
        const slices = data[0 .. data.len - 1];
        for (slices) |slice| {
            if (self.pos + slice.len > self.output.len) return error.WriteFailed;
            @memcpy(self.output[self.pos..][0..slice.len], slice);
            self.pos += slice.len;
            total += slice.len;
        }

        // Write the splat pattern repeated `splat` times.
        const pattern = data[data.len - 1];
        var s: usize = 0;
        while (s < splat) : (s += 1) {
            if (self.pos + pattern.len > self.output.len) return error.WriteFailed;
            @memcpy(self.output[self.pos..][0..pattern.len], pattern);
            self.pos += pattern.len;
            total += pattern.len;
        }

        return total;
    }

    fn written(self: *const FixedBufWriter) []const u8 {
        return self.output[0..self.pos];
    }
};

/// Helper: generate README output into a stack buffer with given manifest.
fn generateReadme(buf: []u8, manifest: SyncManifest) ![]const u8 {
    var fbw = FixedBufWriter.init(buf);
    try readme.writeReadme(&fbw.writer, manifest);
    return fbw.written();
}

// ── Unit Tests ───────────────────────────────────────────────────────────

test "README contains 'Memory is not a guess' tagline" {
    var buf: [131072]u8 = undefined;
    const output = try generateReadme(&buf, SyncManifest{});
    try testing.expect(std.mem.indexOf(u8, output, "Memory is not a guess") != null);
}

test "README renders default benchmark tables" {
    var buf: [131072]u8 = undefined;
    const output = try generateReadme(&buf, SyncManifest{});

    // Default benchmark section headers present
    try testing.expect(std.mem.indexOf(u8, output, "### Formatting") != null);
    try testing.expect(std.mem.indexOf(u8, output, "### I/O Reads") != null);
    try testing.expect(std.mem.indexOf(u8, output, "### Containers") != null);
    // Table header row present
    try testing.expect(std.mem.indexOf(u8, output, "Sig") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Zig") != null);
}

test "README sync status includes commit hash and timestamp" {
    var manifest = SyncManifest{};
    const hash = "deadbeef1234567890abcdef1234567890abcdef";
    @memcpy(manifest.last_integrated_commit[0..40], hash);
    manifest.last_commit_len = 40;
    manifest.last_integration_timestamp = 1700000000;

    var buf: [131072]u8 = undefined;
    const output = try generateReadme(&buf, manifest);

    // Full commit hash appears
    try testing.expect(std.mem.indexOf(u8, output, hash) != null);
    // Timestamp appears
    try testing.expect(std.mem.indexOf(u8, output, "1700000000") != null);
    // Short hash link to upstream
    try testing.expect(std.mem.indexOf(u8, output, "deadbee") != null);
    try testing.expect(std.mem.indexOf(u8, output, "https://github.com/ziglang/zig/commit/") != null);
}

test "README contains all required sections" {
    var manifest = SyncManifest{};
    const hash = "abc1234567890def1234567890abcdef12345678";
    @memcpy(manifest.last_integrated_commit[0..40], hash);
    manifest.last_commit_len = 40;
    manifest.last_integration_timestamp = 1700000000;

    var buf: [131072]u8 = undefined;
    const output = try generateReadme(&buf, manifest);

    const required_sections = [_][]const u8{
        "## Why Sig?",
        "## Benchmarks",
        "## The Spoon Model",
        "## Sync Status",
        "## Getting Started",
        "## Memory Model at a Glance",
        "## Error Model",
        "## Contributing",
        "## License",
    };
    for (required_sections) |section| {
        try testing.expect(std.mem.indexOf(u8, output, section) != null);
    }
}


// ── Property 21: README reflects current sync state ──────────────────────
// Validates: Requirements 1.7, 1.9

test "Property 21: sync commit hash from manifest appears in generated README" {
    // For any sync manifest with a commit hash, the generated README shall
    // contain that exact commit hash string.
    var manifest = SyncManifest{};
    const hash = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    @memcpy(manifest.last_integrated_commit[0..40], hash);
    manifest.last_commit_len = 40;
    manifest.last_integration_timestamp = 1710000000;

    var buf: [131072]u8 = undefined;
    const output = try generateReadme(&buf, manifest);

    // The full commit hash must appear in the output (Req 1.7)
    try testing.expect(std.mem.indexOf(u8, output, hash) != null);
    // The timestamp must appear in the output (Req 1.7)
    try testing.expect(std.mem.indexOf(u8, output, "1710000000") != null);
}

test "Property 21: different manifest data produces different sync sections" {
    // Verifies that the README actually reflects the *current* state, not
    // hardcoded values — two different manifests produce different outputs.
    var manifest_a = SyncManifest{};
    const hash_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    @memcpy(manifest_a.last_integrated_commit[0..40], hash_a);
    manifest_a.last_commit_len = 40;
    manifest_a.last_integration_timestamp = 1000000001;

    var manifest_b = SyncManifest{};
    const hash_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    @memcpy(manifest_b.last_integrated_commit[0..40], hash_b);
    manifest_b.last_commit_len = 40;
    manifest_b.last_integration_timestamp = 1000000002;

    var buf_a: [131072]u8 = undefined;
    const output_a = try generateReadme(&buf_a, manifest_a);

    var buf_b: [131072]u8 = undefined;
    const output_b = try generateReadme(&buf_b, manifest_b);

    // Each output contains its own commit, not the other's
    try testing.expect(std.mem.indexOf(u8, output_a, hash_a) != null);
    try testing.expect(std.mem.indexOf(u8, output_a, hash_b) == null);
    try testing.expect(std.mem.indexOf(u8, output_b, hash_b) != null);
    try testing.expect(std.mem.indexOf(u8, output_b, hash_a) == null);

    // Timestamps differ
    try testing.expect(std.mem.indexOf(u8, output_a, "1000000001") != null);
    try testing.expect(std.mem.indexOf(u8, output_b, "1000000002") != null);
}

test "README with empty manifest shows no sync data message" {
    var buf: [131072]u8 = undefined;
    const output = try generateReadme(&buf, SyncManifest{});

    // When no commit is set, should show fallback message
    try testing.expect(std.mem.indexOf(u8, output, "No sync data available") != null);
}
