// Zero-Alloc Compiler — Diagnostic Ring Buffer and Formatting
//
// Layer 2: Pipeline Orchestration
//
// Collects diagnostics from all compiler phases into a fixed-capacity ring
// buffer. When the ring is full, auto-flushes to the output buffer before
// storing new entries. Formats diagnostics in the standard
// "file:line:column: severity: message" format.
//
// Zero heap allocations — output is written into a caller-provided buffer.

const containers = @import("../core/containers.sig");
const RingBuffer = containers.RingBuffer;
const Diagnostic_Entry = containers.Diagnostic_Entry;
const Compiler_Capacity_Plan = @import("../core/capacity.sig").Compiler_Capacity_Plan;

/// Fixed-capacity diagnostic collection with auto-flush and error limiting.
///
/// Diagnostics emitted by any compiler phase are stored in the ring buffer.
/// When the ring fills up, it auto-flushes all pending diagnostics to the
/// internal output buffer before accepting new entries. The error limit
/// (MAX_ERROR_LIMIT) halts further error emission once reached.
pub const Diagnostic_Ring = struct {
    ring: RingBuffer(Diagnostic_Entry, Compiler_Capacity_Plan.DIAGNOSTIC_RING_CAPACITY),
    error_count: u32 = 0,
    warning_count: u32 = 0,
    note_count: u32 = 0,

    /// Internal flush buffer used during auto-flush when ring is full.
    /// Sized to hold worst-case formatted output for a full ring.
    /// Each entry: up to 256 (path) + 10 (line) + 10 (col) + 10 (severity) + 512 (msg) + separators ~ 820 bytes
    /// 256 entries * 820 = ~210KB — fits comfortably on stack for a compiler.
    flush_buf: [256 * 820]u8 = undefined,
    flush_buf_len: usize = 0,

    /// Emit a diagnostic entry into the ring buffer.
    /// If the ring is full, auto-flushes all pending diagnostics first.
    /// Tracks error/warning/note counts by severity.
    pub fn emit(self: *Diagnostic_Ring, entry: Diagnostic_Entry) void {
        // If at error limit and this is an error, skip
        if (entry.severity == .@"error" and self.atErrorLimit()) return;

        // Auto-flush if ring is full
        if (self.ring.isFull()) {
            self.autoFlush();
        }

        // Store the diagnostic
        self.ring.push(entry);

        // Update severity counts
        switch (entry.severity) {
            .@"error" => self.error_count += 1,
            .warning => self.warning_count += 1,
            .note => self.note_count += 1,
        }
    }

    /// Flush all pending diagnostics to the provided output buffer.
    /// Formats each as: "file:line:column: severity: message\n"
    /// Returns the number of bytes written. If the buffer is too small,
    /// truncates cleanly at the last complete diagnostic.
    pub fn flush(self: *Diagnostic_Ring, output: []u8) usize {
        var written: usize = 0;

        while (self.ring.pop()) |entry| {
            // Format this diagnostic into a temp working area
            var line_buf: [820]u8 = undefined;
            const line_len = formatDiagnostic(&entry, &line_buf);

            // Check if it fits in the remaining output space
            if (written + line_len > output.len) {
                // Doesn't fit — stop (truncate at last complete diagnostic)
                // Push the entry back so it's not lost
                self.ring.push(entry);
                break;
            }

            // Copy formatted diagnostic to output
            copyBytes(output[written..], line_buf[0..line_len]);
            written += line_len;
        }

        return written;
    }

    /// Returns true if error limit has been reached.
    pub fn atErrorLimit(self: *const Diagnostic_Ring) bool {
        return self.error_count >= Compiler_Capacity_Plan.MAX_ERROR_LIMIT;
    }

    /// Returns the total number of diagnostics currently pending in the ring.
    pub fn pendingCount(self: *const Diagnostic_Ring) usize {
        return self.ring.len();
    }

    // ── Internal ──

    /// Auto-flush: drain all pending diagnostics into the internal flush buffer.
    /// This is called when the ring is full and a new diagnostic needs to be stored.
    fn autoFlush(self: *Diagnostic_Ring) void {
        self.flush_buf_len = self.flush(&self.flush_buf);
    }

    /// Read the contents of the last auto-flush buffer.
    /// Returns the slice of formatted diagnostics from the most recent auto-flush.
    pub fn getAutoFlushed(self: *const Diagnostic_Ring) []const u8 {
        return self.flush_buf[0..self.flush_buf_len];
    }
};

// ============================================================================
// Formatting Helpers (no allocations)
// ============================================================================

/// Format a single diagnostic entry into the provided buffer.
/// Format: "file:line:column: severity: message\n"
/// Returns number of bytes written.
fn formatDiagnostic(entry: *const Diagnostic_Entry, buf: []u8) usize {
    var pos: usize = 0;

    // file_path
    const path = entry.file_path[0..entry.file_path_len];
    if (pos + path.len <= buf.len) {
        copyBytes(buf[pos..], path);
        pos += path.len;
    } else return pos;

    // ':'
    if (pos < buf.len) {
        buf[pos] = ':';
        pos += 1;
    } else return pos;

    // line number
    pos += writeU32(buf[pos..], entry.line);

    // ':'
    if (pos < buf.len) {
        buf[pos] = ':';
        pos += 1;
    } else return pos;

    // column number
    pos += writeU32(buf[pos..], entry.column);

    // ': '
    if (pos + 2 <= buf.len) {
        buf[pos] = ':';
        buf[pos + 1] = ' ';
        pos += 2;
    } else return pos;

    // severity
    const sev_str = severityString(entry.severity);
    if (pos + sev_str.len <= buf.len) {
        copyBytes(buf[pos..], sev_str);
        pos += sev_str.len;
    } else return pos;

    // ': '
    if (pos + 2 <= buf.len) {
        buf[pos] = ':';
        buf[pos + 1] = ' ';
        pos += 2;
    } else return pos;

    // message
    const msg = entry.message[0..entry.message_len];
    if (pos + msg.len <= buf.len) {
        copyBytes(buf[pos..], msg);
        pos += msg.len;
    } else return pos;

    // newline
    if (pos < buf.len) {
        buf[pos] = '\n';
        pos += 1;
    }

    return pos;
}

/// Returns the string representation of a severity level.
fn severityString(severity: Diagnostic_Entry.Severity) []const u8 {
    return switch (severity) {
        .@"error" => "error",
        .warning => "warning",
        .note => "note",
    };
}

/// Write a u32 as decimal digits into buf. Returns number of bytes written.
fn writeU32(buf: []u8, value: u32) usize {
    if (value == 0) {
        if (buf.len > 0) {
            buf[0] = '0';
            return 1;
        }
        return 0;
    }

    // Convert digits in reverse
    var tmp: [10]u8 = undefined; // u32 max is 4294967295 (10 digits)
    var n = value;
    var digit_count: usize = 0;
    while (n > 0) {
        tmp[digit_count] = @intCast((n % 10) + '0');
        n /= 10;
        digit_count += 1;
    }

    // Write in correct order
    if (digit_count > buf.len) return 0;
    var i: usize = 0;
    while (i < digit_count) : (i += 1) {
        buf[i] = tmp[digit_count - 1 - i];
    }
    return digit_count;
}

/// Copy bytes from src to dst (non-overlapping).
fn copyBytes(dst: []u8, src: []const u8) void {
    for (src, 0..) |byte, i| {
        dst[i] = byte;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Diagnostic_Ring emit and flush single entry" {
    var ring: Diagnostic_Ring = .{ .ring = .{} };

    var entry: Diagnostic_Entry = .{};
    // Set file path
    const path = "src/main.sig";
    for (path, 0..) |c, i| {
        entry.file_path[i] = c;
    }
    entry.file_path_len = path.len;
    entry.line = 10;
    entry.column = 5;
    entry.severity = .@"error";
    // Set message
    const msg = "undeclared identifier";
    for (msg, 0..) |c, i| {
        entry.message[i] = c;
    }
    entry.message_len = msg.len;

    ring.emit(entry);

    if (ring.error_count != 1) @compileError("expected error_count == 1");
    if (ring.pendingCount() != 1) @compileError("expected 1 pending");

    var out: [256]u8 = undefined;
    const written = ring.flush(&out);

    // Expected: "src/main.sig:10:5: error: undeclared identifier\n"
    const expected = "src/main.sig:10:5: error: undeclared identifier\n";
    if (written != expected.len) @compileError("unexpected output length");

    for (expected, 0..) |c, i| {
        if (out[i] != c) @compileError("output mismatch");
    }
}

test "Diagnostic_Ring warning and note counting" {
    var ring: Diagnostic_Ring = .{ .ring = .{} };

    var warn_entry: Diagnostic_Entry = .{};
    warn_entry.severity = .warning;
    warn_entry.file_path_len = 0;
    warn_entry.message_len = 0;
    warn_entry.line = 1;
    warn_entry.column = 1;

    var note_entry: Diagnostic_Entry = .{};
    note_entry.severity = .note;
    note_entry.file_path_len = 0;
    note_entry.message_len = 0;
    note_entry.line = 1;
    note_entry.column = 1;

    ring.emit(warn_entry);
    ring.emit(note_entry);
    ring.emit(note_entry);

    if (ring.warning_count != 1) @compileError("expected warning_count == 1");
    if (ring.note_count != 2) @compileError("expected note_count == 2");
    if (ring.error_count != 0) @compileError("expected error_count == 0");
}

test "Diagnostic_Ring atErrorLimit respects MAX_ERROR_LIMIT" {
    var ring: Diagnostic_Ring = .{ .ring = .{} };
    ring.error_count = Compiler_Capacity_Plan.MAX_ERROR_LIMIT;
    if (!ring.atErrorLimit()) @compileError("should be at error limit");

    ring.error_count = Compiler_Capacity_Plan.MAX_ERROR_LIMIT - 1;
    if (ring.atErrorLimit()) @compileError("should not be at error limit");
}

test "Diagnostic_Ring flush truncates at last complete diagnostic" {
    var ring: Diagnostic_Ring = .{ .ring = .{} };

    var entry: Diagnostic_Entry = .{};
    const path = "a.sig";
    for (path, 0..) |c, i| {
        entry.file_path[i] = c;
    }
    entry.file_path_len = path.len;
    entry.line = 1;
    entry.column = 1;
    entry.severity = .@"error";
    const msg = "x";
    entry.message[0] = msg[0];
    entry.message_len = 1;

    ring.emit(entry);
    ring.emit(entry);

    // "a.sig:1:1: error: x\n" = 20 chars each
    // Provide only 25 bytes — should fit first but not second
    var small_out: [25]u8 = undefined;
    const written = ring.flush(&small_out);
    if (written != 20) @compileError("expected only first diagnostic (20 bytes)");
    // Second entry should still be pending
    if (ring.pendingCount() != 1) @compileError("expected 1 still pending");
}

test "writeU32 formats numbers correctly" {
    var buf: [10]u8 = undefined;

    if (writeU32(&buf, 0) != 1) @compileError("expected 1 digit for 0");
    if (buf[0] != '0') @compileError("expected '0'");

    if (writeU32(&buf, 42) != 2) @compileError("expected 2 digits for 42");
    if (buf[0] != '4' or buf[1] != '2') @compileError("expected '42'");

    if (writeU32(&buf, 1234567890) != 10) @compileError("expected 10 digits");
}

test "severityString returns correct strings" {
    const e = severityString(.@"error");
    const w = severityString(.warning);
    const n = severityString(.note);
    if (e.len != 5) @compileError("error should be 5 chars");
    if (w.len != 7) @compileError("warning should be 7 chars");
    if (n.len != 4) @compileError("note should be 4 chars");
}

// ============================================================================
// Property Tests — Diagnostic Format Compliance (Task 10.2)
// **Validates: Requirements 11.1, 11.4, 11.5**
// ============================================================================

test "diagnostic format compliance - error format" {
    var ring: Diagnostic_Ring = .{ .ring = .{} };
    var entry: Diagnostic_Entry = .{};
    const path = "test.sig";
    for (path, 0..) |c, i| {
        entry.file_path[i] = c;
    }
    entry.file_path_len = path.len;
    entry.line = 42;
    entry.column = 7;
    entry.severity = .@"error";
    const msg = "type mismatch";
    for (msg, 0..) |c, i| {
        entry.message[i] = c;
    }
    entry.message_len = msg.len;
    ring.emit(entry);

    var out: [256]u8 = undefined;
    const written = ring.flush(&out);
    // Expected: "test.sig:42:7: error: type mismatch\n"
    const expected = "test.sig:42:7: error: type mismatch\n";
    if (written != expected.len) @compileError("format compliance: unexpected length");
    for (expected, 0..) |c, i| {
        if (out[i] != c) @compileError("format compliance: character mismatch");
    }
}

test "diagnostic format compliance - warning format" {
    var ring: Diagnostic_Ring = .{ .ring = .{} };
    var entry: Diagnostic_Entry = .{};
    const path = "lib.sig";
    for (path, 0..) |c, i| {
        entry.file_path[i] = c;
    }
    entry.file_path_len = path.len;
    entry.line = 1;
    entry.column = 1;
    entry.severity = .warning;
    const msg = "unused";
    for (msg, 0..) |c, i| {
        entry.message[i] = c;
    }
    entry.message_len = msg.len;
    ring.emit(entry);

    var out: [256]u8 = undefined;
    const written = ring.flush(&out);
    const expected = "lib.sig:1:1: warning: unused\n";
    if (written != expected.len) @compileError("warning format: unexpected length");
    for (expected, 0..) |c, i| {
        if (out[i] != c) @compileError("warning format: character mismatch");
    }
}

// ============================================================================
// Property Tests — Error Accumulation Up to Limit (Task 10.3)
// **Validates: Requirements 11.6**
// ============================================================================

test "error accumulation stops at MAX_ERROR_LIMIT" {
    var ring: Diagnostic_Ring = .{ .ring = .{} };
    var entry: Diagnostic_Entry = .{};
    entry.severity = .@"error";
    entry.file_path_len = 0;
    entry.message_len = 0;
    entry.line = 1;
    entry.column = 1;

    // Emit MAX_ERROR_LIMIT errors
    var i: u32 = 0;
    while (i < Compiler_Capacity_Plan.MAX_ERROR_LIMIT) : (i += 1) {
        ring.emit(entry);
    }
    if (ring.error_count != Compiler_Capacity_Plan.MAX_ERROR_LIMIT)
        @compileError("should have MAX_ERROR_LIMIT errors");

    // Attempting to emit one more error should be rejected (at limit)
    ring.emit(entry);
    if (ring.error_count != Compiler_Capacity_Plan.MAX_ERROR_LIMIT)
        @compileError("error count should not exceed limit");
}

test "warnings still accepted after error limit" {
    var ring: Diagnostic_Ring = .{ .ring = .{} };
    ring.error_count = Compiler_Capacity_Plan.MAX_ERROR_LIMIT; // simulate at limit

    var warn_entry: Diagnostic_Entry = .{};
    warn_entry.severity = .warning;
    warn_entry.file_path_len = 0;
    warn_entry.message_len = 0;
    warn_entry.line = 1;
    warn_entry.column = 1;

    ring.emit(warn_entry);
    if (ring.warning_count != 1) @compileError("warnings should still be accepted at error limit");
}
