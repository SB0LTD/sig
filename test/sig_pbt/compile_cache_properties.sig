// Feature: sig-compilation-engine, Property 10 & 11: Content hash cache round-trip and key sensitivity
//
// Property 10: For any random source bytes, computing a content hash and storing
// it in the cache under a computed key SHALL produce a cache hit when the same
// key is looked up. Different source bytes SHALL (with overwhelming probability)
// produce different content hashes.
//
// Property 11: For any base compilation context, changing exactly one parameter
// dimension (source_path, flags, target.arch, target.os, target.abi) SHALL
// produce a different 128-bit key from computeKey().
//
// **Validates: Requirements 9.1, 9.2, 9.3**

const std = @import("std");
const harness = @import("harness");
const compile_cache = @import("compile_cache");
const compile_target = @import("compile_target");

const Content_Hash_Cache = compile_cache.Content_Hash_Cache;
const Target_Triple = compile_target.Target_Triple;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Generate random bytes of length 1..max_len into buf. Returns the filled slice.
fn randomSourceBytes(random: std.Random, buf: []u8, max_len: usize) []u8 {
    const len = random.uintAtMost(usize, max_len - 1) + 1; // 1..max_len
    random.bytes(buf[0..len]);
    return buf[0..len];
}

/// Generate a random alphanumeric string of length 1..max_len into buf.
fn randomAlphaStr(random: std.Random, buf: []u8, max_len: usize) []u8 {
    const len = random.uintAtMost(usize, max_len - 1) + 1;
    for (0..len) |i| {
        buf[i] = 'a' + @as(u8, @intCast(random.uintAtMost(u8, 25)));
    }
    return buf[0..len];
}

/// Compare two [16]u8 arrays for equality.
fn hashesEqual(a: [16]u8, b: [16]u8) bool {
    inline for (0..16) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Property 10: Content hash cache round-trip
// ---------------------------------------------------------------------------

test "Property 10: store and lookup returns same hash (cache hit)" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var cache: Content_Hash_Cache = .{};

            // Generate random source bytes (1..256 for speed)
            var src_buf: [256]u8 = undefined;
            const src = randomSourceBytes(random, &src_buf, 256);

            // Compute content hash
            const content_hash = Content_Hash_Cache.computeContentHash(src);

            // Compute a key from random path + flags + target
            var path_buf: [64]u8 = undefined;
            const path = randomAlphaStr(random, &path_buf, 32);

            var flags_buf: [64]u8 = undefined;
            const flags = randomAlphaStr(random, &flags_buf, 32);

            const target: Target_Triple = .{
                .arch = .x86_64,
                .os = .linux,
                .abi = .gnu,
            };

            const key = Content_Hash_Cache.computeKey(path, flags, target);

            // Store in cache
            cache.update(key, content_hash);

            // Lookup — should be a hit
            const result = cache.lookup(key);
            try std.testing.expect(result != null);
            try std.testing.expect(hashesEqual(result.?, content_hash));
        }
    };
    harness.property("store and lookup returns same hash (cache hit)", S.run);
}

test "Property 10: different source bytes produce different content hashes" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate two different source byte sequences
            var buf_a: [256]u8 = undefined;
            var buf_b: [256]u8 = undefined;

            const src_a = randomSourceBytes(random, &buf_a, 256);

            // Generate src_b ensuring it differs from src_a
            const src_b = randomSourceBytes(random, &buf_b, 256);

            // If by extreme coincidence they're identical, skip this iteration
            if (src_a.len == src_b.len) {
                var same = true;
                for (0..src_a.len) |i| {
                    if (src_a[i] != src_b[i]) {
                        same = false;
                        break;
                    }
                }
                if (same) return; // Skip — identical inputs are not interesting
            }

            const hash_a = Content_Hash_Cache.computeContentHash(src_a);
            const hash_b = Content_Hash_Cache.computeContentHash(src_b);

            // Different inputs should produce different hashes (collision = test failure)
            try std.testing.expect(!hashesEqual(hash_a, hash_b));
        }
    };
    harness.property("different source bytes produce different content hashes", S.run);
}

test "Property 10: cache miss for unstored key" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var cache: Content_Hash_Cache = .{};

            // Store one entry
            var path_buf: [32]u8 = undefined;
            const path = randomAlphaStr(random, &path_buf, 16);
            var flags_buf: [32]u8 = undefined;
            const flags = randomAlphaStr(random, &flags_buf, 16);
            const target: Target_Triple = .{ .arch = .x86_64, .os = .linux, .abi = .gnu };

            const key = Content_Hash_Cache.computeKey(path, flags, target);
            var src_buf: [64]u8 = undefined;
            const src = randomSourceBytes(random, &src_buf, 64);
            const hash = Content_Hash_Cache.computeContentHash(src);
            cache.update(key, hash);

            // Lookup with a different key — should miss
            var path2_buf: [32]u8 = undefined;
            const path2 = randomAlphaStr(random, &path2_buf, 16);
            // Ensure path2 differs from path by appending "X"
            var different_path_buf: [33]u8 = undefined;
            @memcpy(different_path_buf[0..path2.len], path2);
            different_path_buf[path2.len] = 'X';
            const different_path = different_path_buf[0 .. path2.len + 1];

            const other_key = Content_Hash_Cache.computeKey(different_path, flags, target);

            // Only assert miss if key is actually different
            if (!hashesEqual(key, other_key)) {
                const result = cache.lookup(other_key);
                try std.testing.expect(result == null);
            }
        }
    };
    harness.property("cache miss for unstored key", S.run);
}

// ---------------------------------------------------------------------------
// Property 11: Hash key parameter sensitivity
// ---------------------------------------------------------------------------

test "Property 11: different source_path produces different key" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var path_buf: [32]u8 = undefined;
            const base_path = randomAlphaStr(random, &path_buf, 16);
            var flags_buf: [32]u8 = undefined;
            const flags = randomAlphaStr(random, &flags_buf, 16);
            const target: Target_Triple = .{ .arch = .x86_64, .os = .windows, .abi = .msvc };

            const key_base = Content_Hash_Cache.computeKey(base_path, flags, target);

            // Variant: append a char to make it differ
            var variant_buf: [33]u8 = undefined;
            @memcpy(variant_buf[0..base_path.len], base_path);
            variant_buf[base_path.len] = 'Z';
            const variant_path = variant_buf[0 .. base_path.len + 1];

            const key_variant = Content_Hash_Cache.computeKey(variant_path, flags, target);

            try std.testing.expect(!hashesEqual(key_base, key_variant));
        }
    };
    harness.property("different source_path produces different key", S.run);
}

test "Property 11: different flags produces different key" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var path_buf: [32]u8 = undefined;
            const path = randomAlphaStr(random, &path_buf, 16);
            var flags_buf: [32]u8 = undefined;
            const base_flags = randomAlphaStr(random, &flags_buf, 16);
            const target: Target_Triple = .{ .arch = .x86_64, .os = .linux, .abi = .gnu };

            const key_base = Content_Hash_Cache.computeKey(path, base_flags, target);

            // Variant: append a char to make flags differ
            var variant_buf: [33]u8 = undefined;
            @memcpy(variant_buf[0..base_flags.len], base_flags);
            variant_buf[base_flags.len] = 'Q';
            const variant_flags = variant_buf[0 .. base_flags.len + 1];

            const key_variant = Content_Hash_Cache.computeKey(path, variant_flags, target);

            try std.testing.expect(!hashesEqual(key_base, key_variant));
        }
    };
    harness.property("different flags produces different key", S.run);
}

test "Property 11: different target.arch produces different key" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var path_buf: [32]u8 = undefined;
            const path = randomAlphaStr(random, &path_buf, 16);
            var flags_buf: [32]u8 = undefined;
            const flags = randomAlphaStr(random, &flags_buf, 16);

            const target_a: Target_Triple = .{ .arch = .x86_64, .os = .linux, .abi = .gnu };
            const target_b: Target_Triple = .{ .arch = .aarch64, .os = .linux, .abi = .gnu };

            const key_a = Content_Hash_Cache.computeKey(path, flags, target_a);
            const key_b = Content_Hash_Cache.computeKey(path, flags, target_b);

            try std.testing.expect(!hashesEqual(key_a, key_b));
        }
    };
    harness.property("different target.arch produces different key", S.run);
}

test "Property 11: different target.os produces different key" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var path_buf: [32]u8 = undefined;
            const path = randomAlphaStr(random, &path_buf, 16);
            var flags_buf: [32]u8 = undefined;
            const flags = randomAlphaStr(random, &flags_buf, 16);

            const target_a: Target_Triple = .{ .arch = .x86_64, .os = .linux, .abi = .gnu };
            const target_b: Target_Triple = .{ .arch = .x86_64, .os = .windows, .abi = .gnu };

            const key_a = Content_Hash_Cache.computeKey(path, flags, target_a);
            const key_b = Content_Hash_Cache.computeKey(path, flags, target_b);

            try std.testing.expect(!hashesEqual(key_a, key_b));
        }
    };
    harness.property("different target.os produces different key", S.run);
}

test "Property 11: different target.abi produces different key" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var path_buf: [32]u8 = undefined;
            const path = randomAlphaStr(random, &path_buf, 16);
            var flags_buf: [32]u8 = undefined;
            const flags = randomAlphaStr(random, &flags_buf, 16);

            const target_a: Target_Triple = .{ .arch = .x86_64, .os = .linux, .abi = .gnu };
            const target_b: Target_Triple = .{ .arch = .x86_64, .os = .linux, .abi = .musl };

            const key_a = Content_Hash_Cache.computeKey(path, flags, target_a);
            const key_b = Content_Hash_Cache.computeKey(path, flags, target_b);

            try std.testing.expect(!hashesEqual(key_a, key_b));
        }
    };
    harness.property("different target.abi produces different key", S.run);
}
