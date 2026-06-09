// Feature: sig-compilation-engine, Property 2: Diagnostic propagation fidelity
//
// For any diagnostic emitted with a file path, line number, column number,
// level, and message, the captured Diagnostic in the buffer SHALL contain
// the identical file path, line number, column number, level, and message
// without truncation (up to DIAGNOSTIC_BUF_SIZE / PATH_BUF_SIZE).
//
// Validates: Requirements 1.4, 4.5, 10.1, 10.2, 10.4

const std = @import("std");
const harness = @import("harness");
const compile_diagnostics = @import("compile_diagnostics");

const Diagnostic = compile_diagnostics.Diagnostic;
const Diagnostic_Buffer = compile_diagnostics.Diagnostic_Buffer;
const captureDiagnostic = compile_diagnostics.captureDiagnostic;

// Derive buffer sizes from the Diagnostic struct field sizes
const PATH_BUF_SIZE = @typeInfo(@TypeOf(@as(Diagnostic, undefined).file_path)).array.len;
const DIAGNOSTIC_BUF_SIZE = @typeInfo(@TypeOf(@as(Diagnostic, undefined).message)).array.len;

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Generate a random diagnostic level.
fn randomLevel(random: std.Random) Diagnostic.Level {
    const levels = [_]Diagnostic.Level{ .@"error", .warning, .note };
    return levels[random.uintLessThan(usize, levels.len)];
}

/// Generate a random file path of length 1..max_len into buf, return slice.
fn randomFilePath(random: std.Random, buf: []u8, max_len: usize) []const u8 {
    if (max_len == 0) return buf[0..0];
    const len = 1 + random.uintAtMost(usize, max_len - 1);
    // Fill with printable ASCII characters to simulate realistic paths
    for (buf[0..len]) |*c| {
        c.* = @intCast(32 + random.uintAtMost(u8, 94)); // printable ASCII 32..126
    }
    return buf[0..len];
}

/// Generate a random message of length 1..max_len into buf, return slice.
fn randomMessage(random: std.Random, buf: []u8, max_len: usize) []const u8 {
    if (max_len == 0) return buf[0..0];
    const len = 1 + random.uintAtMost(usize, max_len - 1);
    // Fill with printable ASCII characters
    for (buf[0..len]) |*c| {
        c.* = @intCast(32 + random.uintAtMost(u8, 94)); // printable ASCII 32..126
    }
    return buf[0..len];
}

// ---------------------------------------------------------------------------
// Property 2: Diagnostic propagation fidelity — fields preserved within limits
// ---------------------------------------------------------------------------

test "Property 2: random diagnostic fields preserved without truncation up to buffer size" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var path_buf: [PATH_BUF_SIZE]u8 = undefined;
            var msg_buf: [DIAGNOSTIC_BUF_SIZE]u8 = undefined;

            // Generate random fields within buffer limits (no truncation expected)
            const file_path = randomFilePath(random, &path_buf, PATH_BUF_SIZE);
            const line = random.int(u32);
            const column = random.int(u32);
            const level = randomLevel(random);
            const message = randomMessage(random, &msg_buf, DIAGNOSTIC_BUF_SIZE);

            // Emit through capture mechanism
            var buf = Diagnostic_Buffer{};
            captureDiagnostic(&buf, level, file_path, line, column, message);

            // Verify single entry captured
            const diagnostics = buf.slice();
            try std.testing.expectEqual(@as(usize, 1), diagnostics.len);

            const diag = diagnostics[0];

            // Verify level preserved
            try std.testing.expectEqual(level, diag.level);

            // Verify line and column preserved
            try std.testing.expectEqual(line, diag.line);
            try std.testing.expectEqual(column, diag.column);

            // Verify file path preserved (within PATH_BUF_SIZE)
            try std.testing.expectEqual(file_path.len, diag.file_path_len);
            try std.testing.expectEqualSlices(u8, file_path, diag.file_path[0..diag.file_path_len]);

            // Verify message preserved (within DIAGNOSTIC_BUF_SIZE)
            try std.testing.expectEqual(message.len, diag.message_len);
            try std.testing.expectEqualSlices(u8, message, diag.message[0..diag.message_len]);
        }
    };
    harness.property("random diagnostic fields preserved without truncation up to buffer size", S.run);
}

// ---------------------------------------------------------------------------
// Property 2: Exact buffer boundary — strings at exactly buffer size
// ---------------------------------------------------------------------------

test "Property 2: file path at exact PATH_BUF_SIZE preserved without truncation" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var path_buf: [PATH_BUF_SIZE]u8 = undefined;
            var msg_buf: [DIAGNOSTIC_BUF_SIZE]u8 = undefined;

            // Fill path to exact capacity
            for (&path_buf) |*c| {
                c.* = @intCast(33 + random.uintAtMost(u8, 93)); // printable non-space
            }
            const file_path = path_buf[0..PATH_BUF_SIZE];

            // Short message for this test
            const message = randomMessage(random, &msg_buf, 64);
            const line = random.int(u32);
            const column = random.int(u32);
            const level = randomLevel(random);

            var buf = Diagnostic_Buffer{};
            captureDiagnostic(&buf, level, file_path, line, column, message);

            const diagnostics = buf.slice();
            try std.testing.expectEqual(@as(usize, 1), diagnostics.len);

            const diag = diagnostics[0];
            try std.testing.expectEqual(PATH_BUF_SIZE, diag.file_path_len);
            try std.testing.expectEqualSlices(u8, file_path, diag.file_path[0..diag.file_path_len]);
        }
    };
    harness.property("file path at exact PATH_BUF_SIZE preserved without truncation", S.run);
}

test "Property 2: message at exact DIAGNOSTIC_BUF_SIZE preserved without truncation" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var path_buf: [PATH_BUF_SIZE]u8 = undefined;
            var msg_buf: [DIAGNOSTIC_BUF_SIZE]u8 = undefined;

            // Short path for this test
            const file_path = randomFilePath(random, &path_buf, 64);

            // Fill message to exact capacity
            for (&msg_buf) |*c| {
                c.* = @intCast(33 + random.uintAtMost(u8, 93)); // printable non-space
            }
            const message = msg_buf[0..DIAGNOSTIC_BUF_SIZE];

            const line = random.int(u32);
            const column = random.int(u32);
            const level = randomLevel(random);

            var buf = Diagnostic_Buffer{};
            captureDiagnostic(&buf, level, file_path, line, column, message);

            const diagnostics = buf.slice();
            try std.testing.expectEqual(@as(usize, 1), diagnostics.len);

            const diag = diagnostics[0];
            try std.testing.expectEqual(DIAGNOSTIC_BUF_SIZE, diag.message_len);
            try std.testing.expectEqualSlices(u8, message, diag.message[0..diag.message_len]);
        }
    };
    harness.property("message at exact DIAGNOSTIC_BUF_SIZE preserved without truncation", S.run);
}

// ---------------------------------------------------------------------------
// Property 2: Oversized inputs — graceful truncation
// ---------------------------------------------------------------------------

test "Property 2: file path exceeding PATH_BUF_SIZE is gracefully truncated" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Create an oversized path (PATH_BUF_SIZE + 1..PATH_BUF_SIZE + 256)
            const extra = 1 + random.uintAtMost(usize, 255);
            const oversized_len = PATH_BUF_SIZE + extra;
            var oversized_buf: [PATH_BUF_SIZE + 256]u8 = undefined;
            for (oversized_buf[0..oversized_len]) |*c| {
                c.* = @intCast(33 + random.uintAtMost(u8, 93));
            }
            const oversized_path = oversized_buf[0..oversized_len];

            var msg_buf: [128]u8 = undefined;
            const message = randomMessage(random, &msg_buf, 128);
            const line = random.int(u32);
            const column = random.int(u32);
            const level = randomLevel(random);

            var buf = Diagnostic_Buffer{};
            captureDiagnostic(&buf, level, oversized_path, line, column, message);

            const diagnostics = buf.slice();
            try std.testing.expectEqual(@as(usize, 1), diagnostics.len);

            const diag = diagnostics[0];

            // Should be truncated to PATH_BUF_SIZE
            try std.testing.expectEqual(PATH_BUF_SIZE, diag.file_path_len);
            // Truncated content should match the first PATH_BUF_SIZE bytes
            try std.testing.expectEqualSlices(u8, oversized_path[0..PATH_BUF_SIZE], diag.file_path[0..PATH_BUF_SIZE]);

            // Other fields still preserved
            try std.testing.expectEqual(level, diag.level);
            try std.testing.expectEqual(line, diag.line);
            try std.testing.expectEqual(column, diag.column);
        }
    };
    harness.property("file path exceeding PATH_BUF_SIZE is gracefully truncated", S.run);
}

test "Property 2: message exceeding DIAGNOSTIC_BUF_SIZE is gracefully truncated" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Create an oversized message (DIAGNOSTIC_BUF_SIZE + 1..DIAGNOSTIC_BUF_SIZE + 256)
            const extra = 1 + random.uintAtMost(usize, 255);
            const oversized_len = DIAGNOSTIC_BUF_SIZE + extra;
            var oversized_buf: [DIAGNOSTIC_BUF_SIZE + 256]u8 = undefined;
            for (oversized_buf[0..oversized_len]) |*c| {
                c.* = @intCast(33 + random.uintAtMost(u8, 93));
            }
            const oversized_msg = oversized_buf[0..oversized_len];

            var path_buf: [128]u8 = undefined;
            const file_path = randomFilePath(random, &path_buf, 128);
            const line = random.int(u32);
            const column = random.int(u32);
            const level = randomLevel(random);

            var buf = Diagnostic_Buffer{};
            captureDiagnostic(&buf, level, file_path, line, column, oversized_msg);

            const diagnostics = buf.slice();
            try std.testing.expectEqual(@as(usize, 1), diagnostics.len);

            const diag = diagnostics[0];

            // Should be truncated to DIAGNOSTIC_BUF_SIZE
            try std.testing.expectEqual(DIAGNOSTIC_BUF_SIZE, diag.message_len);
            // Truncated content should match the first DIAGNOSTIC_BUF_SIZE bytes
            try std.testing.expectEqualSlices(u8, oversized_msg[0..DIAGNOSTIC_BUF_SIZE], diag.message[0..DIAGNOSTIC_BUF_SIZE]);

            // Other fields still preserved
            try std.testing.expectEqual(level, diag.level);
            try std.testing.expectEqual(line, diag.line);
            try std.testing.expectEqual(column, diag.column);
        }
    };
    harness.property("message exceeding DIAGNOSTIC_BUF_SIZE is gracefully truncated", S.run);
}


// ---------------------------------------------------------------------------
// Feature: sig-compilation-engine, Property 3: Diagnostic ordering preservation
//
// For any sequence of N diagnostics emitted during a single compilation in order
// D₁, D₂, ..., Dₙ, the Diagnostic_Buffer.slice()[0..N] SHALL contain those
// diagnostics in the same emission order.
//
// Validates: Requirements 10.3
// ---------------------------------------------------------------------------

const compile_types = @import("compile_types");
const MAX_DIAGNOSTICS = compile_types.MAX_DIAGNOSTICS;

// ---------------------------------------------------------------------------
// Helpers (Property 3)
// ---------------------------------------------------------------------------

/// Generate a diagnostic with a unique line number to serve as an ordering tag.
/// The line number is used to identify each diagnostic's position in the sequence.
fn makeDiagnosticWithIndex(index: u32, random: std.Random) Diagnostic {
    var diag: Diagnostic = .{};

    // Use the index as the line number — this is our ordering marker
    diag.line = index;

    // Random column for variety
    diag.column = random.uintAtMost(u32, 999);

    // Random level
    const level_choice = random.uintAtMost(u8, 2);
    diag.level = switch (level_choice) {
        0 => .@"error",
        1 => .warning,
        2 => .note,
        else => .@"error",
    };

    // Short file path with index embedded for traceability
    const prefix = "src/file_";
    @memcpy(diag.file_path[0..prefix.len], prefix);
    var pos: usize = prefix.len;
    // Encode index as decimal digits
    var tmp: [10]u8 = undefined;
    var tmp_len: usize = 0;
    var v: u32 = index;
    if (v == 0) {
        tmp[0] = '0';
        tmp_len = 1;
    } else {
        while (v > 0) {
            tmp[tmp_len] = @intCast((v % 10) + '0');
            tmp_len += 1;
            v /= 10;
        }
    }
    // Reverse digits into file_path
    var r: usize = 0;
    while (r < tmp_len) : (r += 1) {
        diag.file_path[pos] = tmp[tmp_len - 1 - r];
        pos += 1;
    }
    const ext = ".sig";
    @memcpy(diag.file_path[pos .. pos + ext.len], ext);
    pos += ext.len;
    diag.file_path_len = pos;

    // Short message with index
    const msg_prefix = "diagnostic_";
    @memcpy(diag.message[0..msg_prefix.len], msg_prefix);
    var mpos: usize = msg_prefix.len;
    // Reuse tmp for message index
    var tmp2: [10]u8 = undefined;
    var tmp2_len: usize = 0;
    var v2: u32 = index;
    if (v2 == 0) {
        tmp2[0] = '0';
        tmp2_len = 1;
    } else {
        while (v2 > 0) {
            tmp2[tmp2_len] = @intCast((v2 % 10) + '0');
            tmp2_len += 1;
            v2 /= 10;
        }
    }
    var r2: usize = 0;
    while (r2 < tmp2_len) : (r2 += 1) {
        diag.message[mpos] = tmp2[tmp2_len - 1 - r2];
        mpos += 1;
    }
    diag.message_len = mpos;

    return diag;
}

// ---------------------------------------------------------------------------
// Property 3: Diagnostic ordering preservation
// ---------------------------------------------------------------------------

test "Property 3: emitted diagnostics preserve emission order in slice" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate random N in 1..MAX_DIAGNOSTICS
            const n = 1 + random.uintAtMost(usize, MAX_DIAGNOSTICS - 1);

            var buf = Diagnostic_Buffer{};

            // Emit N diagnostics in order, each with line number = emission index
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const diag = makeDiagnosticWithIndex(@intCast(i), random);
                buf.emit(diag);
            }

            // Verify buffer count matches N
            try std.testing.expectEqual(n, buf.count);

            // Verify no overflow occurred
            try std.testing.expectEqual(@as(usize, 0), buf.overflow_count);

            // Verify ordering: slice()[k].line == k for all k in 0..N
            const diagnostics = buf.slice();
            try std.testing.expectEqual(n, diagnostics.len);

            i = 0;
            while (i < n) : (i += 1) {
                try std.testing.expectEqual(@as(u32, @intCast(i)), diagnostics[i].line);
            }
        }
    };
    harness.property("emitted diagnostics preserve emission order in slice", S.run);
}

test "Property 3: captureDiagnostic preserves emission order" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate random N in 1..MAX_DIAGNOSTICS
            const n = 1 + random.uintAtMost(usize, MAX_DIAGNOSTICS - 1);

            var buf = Diagnostic_Buffer{};

            // Emit N diagnostics via captureDiagnostic interface
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const level_choice = random.uintAtMost(u8, 2);
                const level: Diagnostic.Level = switch (level_choice) {
                    0 => .@"error",
                    1 => .warning,
                    2 => .note,
                    else => .@"error",
                };
                captureDiagnostic(
                    &buf,
                    level,
                    "test.sig",
                    @intCast(i), // line = emission index
                    @intCast(i + 1), // column = emission index + 1
                    "msg",
                );
            }

            // Verify ordering via line numbers
            const diagnostics = buf.slice();
            try std.testing.expectEqual(n, diagnostics.len);

            i = 0;
            while (i < n) : (i += 1) {
                try std.testing.expectEqual(@as(u32, @intCast(i)), diagnostics[i].line);
                try std.testing.expectEqual(@as(u32, @intCast(i + 1)), diagnostics[i].column);
            }
        }
    };
    harness.property("captureDiagnostic preserves emission order", S.run);
}

test "Property 3: overflow keeps most recent diagnostics in order" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Emit more than MAX_DIAGNOSTICS to trigger ring buffer overflow
            // N is MAX_DIAGNOSTICS + random extra (1..MAX_DIAGNOSTICS)
            const extra = 1 + random.uintAtMost(usize, MAX_DIAGNOSTICS - 1);
            const total = MAX_DIAGNOSTICS + extra;

            var buf = Diagnostic_Buffer{};

            // Emit total diagnostics, each with line = emission index
            var i: usize = 0;
            while (i < total) : (i += 1) {
                const diag = makeDiagnosticWithIndex(@intCast(i), random);
                buf.emit(diag);
            }

            // Buffer should be full
            try std.testing.expectEqual(MAX_DIAGNOSTICS, buf.count);

            // Overflow count should match the number of dropped diagnostics
            try std.testing.expectEqual(extra, buf.overflow_count);

            // The ring buffer drops oldest — remaining entries should be
            // the last MAX_DIAGNOSTICS emitted, in emission order.
            // Expected: line numbers from (total - MAX_DIAGNOSTICS) to (total - 1)
            const diagnostics = buf.slice();
            try std.testing.expectEqual(MAX_DIAGNOSTICS, diagnostics.len);

            const first_kept = total - MAX_DIAGNOSTICS;
            i = 0;
            while (i < MAX_DIAGNOSTICS) : (i += 1) {
                const expected_line: u32 = @intCast(first_kept + i);
                try std.testing.expectEqual(expected_line, diagnostics[i].line);
            }
        }
    };
    harness.property("overflow keeps most recent diagnostics in order", S.run);
}
