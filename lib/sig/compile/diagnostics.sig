// Compilation Engine — Diagnostic Capture
//
// Fixed-size diagnostic buffer with ring-buffer overflow behavior.
// Captures diagnostics from the internal Compilation API without heap allocations.
// When more than MAX_DIAGNOSTICS are emitted, the oldest are dropped and a
// synthetic "N additional diagnostics suppressed" entry is appended on finalize.

const types = @import("types.sig");

const PATH_BUF_SIZE = types.PATH_BUF_SIZE;
const DIAGNOSTIC_BUF_SIZE = types.DIAGNOSTIC_BUF_SIZE;
const MAX_DIAGNOSTICS = types.MAX_DIAGNOSTICS;

// ── Diagnostic ──

/// A single captured diagnostic from the compilation pipeline.
/// All fields use fixed-size buffers — zero heap allocations.
pub const Diagnostic = struct {
    level: Level = .@"error",
    file_path: [PATH_BUF_SIZE]u8 = undefined,
    file_path_len: usize = 0,
    line: u32 = 0,
    column: u32 = 0,
    message: [DIAGNOSTIC_BUF_SIZE]u8 = undefined,
    message_len: usize = 0,

    pub const Level = enum { @"error", warning, note };
};

// ── Diagnostic_Buffer (Ring Buffer) ──

/// Fixed-capacity diagnostic ring buffer.
/// When full, drops the oldest entry on each new emit and tracks overflow count.
/// Call `finalize()` after compilation to append a synthetic suppression notice
/// if any diagnostics were dropped.
pub const Diagnostic_Buffer = struct {
    entries: [MAX_DIAGNOSTICS]Diagnostic = undefined,
    count: usize = 0,
    overflow_count: usize = 0,

    /// Add a diagnostic to the buffer.
    /// If the buffer is full, shift all entries left (dropping the oldest)
    /// and place the new diagnostic at the end. Increments overflow_count.
    pub fn emit(self: *Diagnostic_Buffer, diag: Diagnostic) void {
        if (self.count < MAX_DIAGNOSTICS) {
            self.entries[self.count] = diag;
            self.count += 1;
        } else {
            // Ring behavior: shift entries left, drop oldest
            for (0..MAX_DIAGNOSTICS - 1) |i| {
                self.entries[i] = self.entries[i + 1];
            }
            self.entries[MAX_DIAGNOSTICS - 1] = diag;
            self.overflow_count += 1;
        }
    }

    /// Finalize the buffer after compilation completes.
    /// If overflow occurred, replaces the last entry with a synthetic
    /// "N additional diagnostics suppressed" note so the caller knows
    /// diagnostics were lost.
    pub fn finalize(self: *Diagnostic_Buffer) void {
        if (self.overflow_count == 0) return;

        // Build the synthetic message: "N additional diagnostics suppressed"
        const prefix = "additional diagnostics suppressed";
        var msg_buf: [DIAGNOSTIC_BUF_SIZE]u8 = undefined;
        const num_len = formatUsize(self.overflow_count, &msg_buf);
        // Add space after number
        msg_buf[num_len] = ' ';
        const total_len = num_len + 1 + prefix.len;
        const clamped_len = @min(total_len, DIAGNOSTIC_BUF_SIZE);
        // Copy prefix after "<N> "
        const prefix_copy_len = clamped_len - (num_len + 1);
        @memcpy(msg_buf[num_len + 1 ..][0..prefix_copy_len], prefix[0..prefix_copy_len]);

        // Replace the last entry with the synthetic diagnostic
        const last = if (self.count > 0) self.count - 1 else 0;
        self.entries[last] = .{
            .level = .note,
            .message_len = clamped_len,
        };
        @memcpy(self.entries[last].message[0..clamped_len], msg_buf[0..clamped_len]);
    }

    /// Return the populated diagnostics as a const slice.
    pub fn slice(self: *const Diagnostic_Buffer) []const Diagnostic {
        return self.entries[0..self.count];
    }
};

// ── Capture Interface ──

/// Capture a single diagnostic from compilation output.
/// Called by the engine during compilation to record each emitted diagnostic.
/// File path and message are truncated if they exceed their respective buffer sizes.
pub fn captureDiagnostic(
    buf: *Diagnostic_Buffer,
    level: Diagnostic.Level,
    file_path: []const u8,
    line: u32,
    column: u32,
    message: []const u8,
) void {
    var diag: Diagnostic = .{ .level = level };

    // Copy file_path (truncate if needed)
    const fp_len = @min(file_path.len, PATH_BUF_SIZE);
    @memcpy(diag.file_path[0..fp_len], file_path[0..fp_len]);
    diag.file_path_len = fp_len;

    diag.line = line;
    diag.column = column;

    // Copy message (truncate if needed)
    const msg_len = @min(message.len, DIAGNOSTIC_BUF_SIZE);
    @memcpy(diag.message[0..msg_len], message[0..msg_len]);
    diag.message_len = msg_len;

    buf.emit(diag);
}

// ── Helpers ──

/// Format a usize as decimal digits into the given buffer.
/// Returns the number of characters written.
fn formatUsize(value: usize, buf: *[DIAGNOSTIC_BUF_SIZE]u8) usize {
    if (value == 0) {
        buf[0] = '0';
        return 1;
    }
    var v = value;
    var tmp: [20]u8 = undefined; // max digits for u64
    var tmp_len: usize = 0;
    while (v > 0) {
        tmp[tmp_len] = @intCast((v % 10) + '0');
        tmp_len += 1;
        v /= 10;
    }
    // Reverse into output buffer
    for (0..tmp_len) |i| {
        buf[i] = tmp[tmp_len - 1 - i];
    }
    return tmp_len;
}
