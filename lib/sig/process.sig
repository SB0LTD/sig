//! Process management — spawn, wait, env, exit.
//!
//! Uses os.sig primitives (CreateProcess/fork+exec) instead of std.process.
//! Argv_Iterator and Env_Iterator use inline unicode/environ logic — no std dependency.

const os = @import("os.sig");
const sig_io = @import("io.sig");
const sig_mem = @import("mem.sig");
const SigError = @import("errors.sig").SigError;

const builtin = @import("builtin");
const native_os = builtin.os.tag;

// ── Capacity constants ──────────────────────────────────────────────────

pub const MAX_CMD_ARGS = 256;
pub const MAX_ARG_LEN = 4096;
pub const MAX_CWD_LEN = 4096;
pub const MAX_ENV_PAIRS = 256;
pub const MAX_ENV_KEY_LEN = 256;
pub const MAX_ENV_VALUE_LEN = 4096;

/// Maximum command-line length in UTF-16 code units for Windows CreateProcessW.
const MAX_CMDLINE_WIDE = 32768;

// ── Command_Buffer ──────────────────────────────────────────────────────

/// Fixed-capacity buffer for constructing child process commands.
/// Stores arguments and working directory entirely in stack memory —
/// no heap allocation.
pub const Command_Buffer = struct {
    args: [MAX_CMD_ARGS][MAX_ARG_LEN]u8 = undefined,
    arg_lens: [MAX_CMD_ARGS]usize = @as([MAX_CMD_ARGS]usize, @splat(0)),
    arg_count: usize = 0,
    cwd: [MAX_CWD_LEN]u8 = undefined,
    cwd_len: usize = 0,

    /// Append an argument. Returns `CapacityExceeded` if too many args,
    /// `BufferTooSmall` if the argument is too long.
    pub fn appendArg(self: *Command_Buffer, arg: []const u8) SigError!void {
        if (self.arg_count >= MAX_CMD_ARGS) return error.CapacityExceeded;
        if (arg.len > MAX_ARG_LEN) return error.BufferTooSmall;
        @memcpy(self.args[self.arg_count][0..arg.len], arg);
        self.arg_lens[self.arg_count] = arg.len;
        self.arg_count += 1;
    }

    /// Set the working directory.
    /// Returns `BufferTooSmall` if the path exceeds `MAX_CWD_LEN`.
    pub fn setCwd(self: *Command_Buffer, path: []const u8) SigError!void {
        if (path.len > MAX_CWD_LEN) return error.BufferTooSmall;
        @memcpy(self.cwd[0..path.len], path);
        self.cwd_len = path.len;
    }

    /// Get a slice view of argument `i` (read-only).
    pub fn getArg(self: *const Command_Buffer, i: usize) []const u8 {
        return self.args[i][0..self.arg_lens[i]];
    }
};

// ── Env_Pairs ───────────────────────────────────────────────────────────

/// Fixed-capacity environment variable storage for passing to child processes.
/// Stores keys and values in stack-allocated fixed arrays — no heap allocation.
pub const Env_Pairs = struct {
    keys: [MAX_ENV_PAIRS][MAX_ENV_KEY_LEN]u8 = undefined,
    key_lens: [MAX_ENV_PAIRS]usize = @as([MAX_ENV_PAIRS]usize, @splat(0)),
    values: [MAX_ENV_PAIRS][MAX_ENV_VALUE_LEN]u8 = undefined,
    value_lens: [MAX_ENV_PAIRS]usize = @as([MAX_ENV_PAIRS]usize, @splat(0)),
    count: usize = 0,

    /// Add a key-value pair. Returns `CapacityExceeded` if full,
    /// `BufferTooSmall` if key or value is too long.
    pub fn put(self: *Env_Pairs, key: []const u8, value: []const u8) SigError!void {
        if (self.count >= MAX_ENV_PAIRS) return error.CapacityExceeded;
        if (key.len > MAX_ENV_KEY_LEN) return error.BufferTooSmall;
        if (value.len > MAX_ENV_VALUE_LEN) return error.BufferTooSmall;
        @memcpy(self.keys[self.count][0..key.len], key);
        self.key_lens[self.count] = key.len;
        @memcpy(self.values[self.count][0..value.len], value);
        self.value_lens[self.count] = value.len;
        self.count += 1;
    }

    /// Get the key at index `i`.
    pub fn getKey(self: *const Env_Pairs, i: usize) []const u8 {
        return self.keys[i][0..self.key_lens[i]];
    }

    /// Get the value at index `i`.
    pub fn getValue(self: *const Env_Pairs, i: usize) []const u8 {
        return self.values[i][0..self.value_lens[i]];
    }
};

// ── Spawn_Options ───────────────────────────────────────────────────────

/// Configuration for child process spawning.
pub const Spawn_Options = struct {
    /// Working directory for the child. `null` = inherit parent cwd.
    cwd: ?[]const u8 = null,
    /// Stdio configuration for stdin.
    stdin: Stdio = .inherit,
    /// Stdio configuration for stdout.
    stdout: Stdio = .inherit,
    /// Stdio configuration for stderr.
    stderr: Stdio = .inherit,
    /// Optional environment override. If null, inherits parent environment.
    env: ?*const Env_Pairs = null,

    pub const Stdio = enum { inherit, pipe, close, ignore };
};

// ── Child Process ───────────────────────────────────────────────────────

/// Result of waiting for a child process to terminate.
pub const TermResult = union(enum) {
    exited: u8,
    signal: u32,
    stopped: u32,
    unknown: u32,
};

/// Child process handle. Wraps the OS process handle (HANDLE on Windows, pid on POSIX)
/// and optional piped file descriptors for stdout/stderr capture.
pub const Child = struct {
    handle: if (native_os == .windows) os.HANDLE else i32,
    /// Readable end of stdout pipe (if spawned with stdout = .pipe).
    stdout: ?os.fd_t = null,
    /// Readable end of stderr pipe (if spawned with stderr = .pipe).
    stderr: ?os.fd_t = null,

    /// Wait for the child process to exit and return the termination result.
    pub fn wait(self: *Child, io: sig_io.Io) SigError!TermResult {
        _ = io;
        if (native_os == .windows) {
            _ = os.kernel32.WaitForSingleObject(self.handle, os.INFINITE);
            var exit_code: os.DWORD = 0;
            const ok = os.kernel32.GetExitCodeProcess(self.handle, &exit_code);
            if (ok == os.FALSE) return error.BufferTooSmall;
            return .{ .exited = @intCast(exit_code & 0xFF) };
        } else {
            var status: c_int = 0;
            const ret = os.posix.waitpid(self.handle, &status, 0);
            if (ret < 0) return error.BufferTooSmall;
            if (os.posix.WIFEXITED(status)) {
                return .{ .exited = os.posix.WEXITSTATUS(status) };
            } else if (os.posix.WIFSIGNALED(status)) {
                return .{ .signal = @as(u32, os.posix.WTERMSIG(status)) };
            } else if (os.posix.WIFSTOPPED(status)) {
                return .{ .stopped = @as(u32, os.posix.WSTOPSIG(status)) };
            } else {
                return .{ .unknown = @as(u32, @bitCast(status)) };
            }
        }
    }

    /// Terminate the child process and close all handles.
    pub fn kill(self: *Child, io: sig_io.Io) void {
        _ = io;
        if (native_os == .windows) {
            _ = os.kernel32.TerminateProcess(self.handle, 1);
            _ = os.kernel32.CloseHandle(self.handle);
            if (self.stdout) |h| _ = os.kernel32.CloseHandle(h);
            if (self.stderr) |h| _ = os.kernel32.CloseHandle(h);
        } else {
            _ = os.posix.kill(self.handle, os.posix.SIGKILL);
            if (self.stdout) |fd| _ = os.posix.close(fd);
            if (self.stderr) |fd| _ = os.posix.close(fd);
        }
        self.stdout = null;
        self.stderr = null;
    }
};

// ── Unicode / WTF-8 Helpers ──────────────────────────────────────────────

/// Check if a UTF-16 code unit is a high surrogate (U+D800..U+DBFF).
fn isUtf16HighSurrogate(cu: u16) bool {
    return cu >= 0xD800 and cu <= 0xDBFF;
}

/// Check if a UTF-16 code unit is a low surrogate (U+DC00..U+DFFF).
fn isUtf16LowSurrogate(cu: u16) bool {
    return cu >= 0xDC00 and cu <= 0xDFFF;
}

/// Encode a single UTF-16 code unit as WTF-8 into the buffer.
/// WTF-8 is identical to UTF-8 for valid codepoints (U+0000..U+D7FF, U+E000..U+FFFF).
/// For unpaired surrogates (U+D800..U+DFFF), it encodes them as 3-byte sequences
/// (same bit pattern as UTF-8 would use for those values).
/// Returns the number of bytes written, or null if buffer too small.
fn encodeWtf8(code_unit: u16, buf: []u8) ?usize {
    const cp: u32 = code_unit;
    if (cp < 0x80) {
        if (buf.len < 1) return null;
        buf[0] = @intCast(cp);
        return 1;
    } else if (cp < 0x800) {
        if (buf.len < 2) return null;
        buf[0] = @intCast(0xC0 | (cp >> 6));
        buf[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    } else {
        // 3-byte: covers BMP (0x800..0xFFFF) including surrogates (WTF-8)
        if (buf.len < 3) return null;
        buf[0] = @intCast(0xE0 | (cp >> 12));
        buf[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
}

// ── Posix_Argv_Iterator ─────────────────────────────────────────────────

/// Zero-copy iterator over POSIX argv. Wraps the native `[]const [*:0]const u8`
/// vector and returns a null-terminated slice for each argument.
pub const Posix_Argv_Iterator = struct {
    remaining: []const [*:0]const u8,

    pub fn init(argv: []const [*:0]const u8) Posix_Argv_Iterator {
        return .{ .remaining = argv };
    }

    /// Returns the next argument as a `[:0]const u8` slice, or `null` if done.
    pub fn next(self: *Posix_Argv_Iterator) SigError!?[:0]const u8 {
        if (self.remaining.len == 0) return null;
        const arg = self.remaining[0];
        self.remaining = self.remaining[1..];
        // Manual null-terminated slice: scan for sentinel.
        var len: usize = 0;
        while (arg[len] != 0) : (len += 1) {}
        return arg[0..len :0];
    }

    /// Skip one argument without decoding. Returns `true` if skipped, `false` if done.
    pub fn skip(self: *Posix_Argv_Iterator) bool {
        if (self.remaining.len == 0) return false;
        self.remaining = self.remaining[1..];
        return true;
    }
};

// ── Windows_Argv_Iterator ───────────────────────────────────────────────

/// Decodes WTF-16 command-line arguments into WTF-8 using a caller-provided
/// buffer. Implements the post-2008 C runtime parsing rules (same algorithm
/// as `lib/std/process/Args.sig` `Iterator.Windows`), but writes into a
/// fixed buffer instead of heap-allocating.
pub const Windows_Argv_Iterator = struct {
    cmd_line: []const u16,
    index: usize = 0,
    buffer: []u8,
    end: usize = 0,
    /// True after the first argument (exe name) has been parsed.
    past_first: bool = false,

    pub fn init(cmd_line: []const u16, buf: []u8) Windows_Argv_Iterator {
        return .{
            .cmd_line = cmd_line,
            .buffer = buf,
        };
    }

    /// Returns the next argument as a `[:0]const u8` slice pointing into the
    /// caller-provided buffer, or `null` if done.
    /// Returns `SigError.BufferTooSmall` if the buffer cannot hold the decoded argument.
    pub fn next(self: *Windows_Argv_Iterator) SigError!?[:0]const u8 {
        return self.nextWithStrategy(next_strategy);
    }

    /// Skip one argument without decoding. Returns `true` if skipped, `false` if done.
    pub fn skip(self: *Windows_Argv_Iterator) bool {
        return self.nextWithStrategy(skip_strategy) catch false orelse false;
    }

    // -- Strategy types for next vs skip (mirrors std approach) --

    const next_strategy = struct {
        const T = SigError!?[:0]const u8;
        const eof: T = null;

        fn emitBackslashes(self: *Windows_Argv_Iterator, count: usize, last: ?u16) SigError!?u16 {
            for (0..count) |_| {
                if (self.end >= self.buffer.len) return error.BufferTooSmall;
                self.buffer[self.end] = '\\';
                self.end += 1;
            }
            return if (count != 0) @as(?u16, '\\') else last;
        }

        fn emitCharacter(self: *Windows_Argv_Iterator, code_unit: u16, last: ?u16) SigError!?u16 {
            // Surrogate pair combining: high surrogate (last) + low surrogate (current)
            if (last != null and
                isUtf16LowSurrogate(code_unit) and
                isUtf16HighSurrogate(last.?))
            {
                // Decode surrogate pair to codepoint
                const codepoint: u32 = 0x10000 + (@as(u32, last.? - 0xD800) << 10) + @as(u32, code_unit - 0xDC00);
                // Overwrite the 3-byte unpaired high surrogate with a 4-byte sequence
                if (self.end + 1 > self.buffer.len) return error.BufferTooSmall;
                const dest = self.buffer[self.end - 3 ..];
                dest[0] = @intCast(0xF0 | (codepoint >> 18));
                dest[1] = @intCast(0x80 | ((codepoint >> 12) & 0x3F));
                dest[2] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
                dest[3] = @intCast(0x80 | (codepoint & 0x3F));
                self.end += 1;
                return null;
            }

            // WTF-8 encode a single code unit (BMP or unpaired surrogate)
            const wtf8_len = encodeWtf8(code_unit, self.buffer[self.end..]) orelse
                return error.BufferTooSmall;
            self.end += wtf8_len;
            return code_unit;
        }

        fn yieldArg(self: *Windows_Argv_Iterator) SigError!?[:0]const u8 {
            if (self.end >= self.buffer.len) return error.BufferTooSmall;
            self.buffer[self.end] = 0;
            const arg = self.buffer[0..self.end :0];
            self.end = 0;
            return arg;
        }
    };

    const skip_strategy = struct {
        const T = SigError!?[:0]const u8;
        const eof: T = null;

        fn emitBackslashes(_: *Windows_Argv_Iterator, _: usize, last: ?u16) SigError!?u16 {
            return last;
        }

        fn emitCharacter(_: *Windows_Argv_Iterator, _: u16, last: ?u16) SigError!?u16 {
            return last;
        }

        fn yieldArg(self: *Windows_Argv_Iterator) SigError!?[:0]const u8 {
            _ = self;
            // Return a non-null sentinel to indicate "skipped successfully".
            // The caller (skip()) checks for non-null.
            return @as([:0]const u8, "");
        }
    };

    fn nextWithStrategy(self: *Windows_Argv_Iterator, comptime strategy: type) strategy.T {
        var last_emitted: ?u16 = null;

        // First argument (executable name): different parsing rules.
        if (!self.past_first) {
            self.past_first = true;

            if (self.cmd_line.len == 0 or self.cmd_line[0] == 0) {
                return strategy.eof;
            }

            var inside_quotes = false;
            while (true) : (self.index += 1) {
                const char: u16 = if (self.index != self.cmd_line.len)
                    self.cmd_line[self.index]
                else
                    0;
                switch (char) {
                    0 => {
                        return strategy.yieldArg(self);
                    },
                    '"' => {
                        inside_quotes = !inside_quotes;
                    },
                    ' ', '\t' => {
                        if (inside_quotes) {
                            last_emitted = strategy.emitCharacter(self, char, last_emitted) catch |e| return e;
                        } else {
                            self.index += 1;
                            return strategy.yieldArg(self);
                        }
                    },
                    else => {
                        last_emitted = strategy.emitCharacter(self, char, last_emitted) catch |e| return e;
                    },
                }
            }
        }

        // Skip leading whitespace. Complete if we reach end of string.
        while (true) : (self.index += 1) {
            const char: u16 = if (self.index != self.cmd_line.len)
                self.cmd_line[self.index]
            else
                0;
            switch (char) {
                0 => return strategy.eof,
                ' ', '\t' => continue,
                else => break,
            }
        }

        // Subsequent arguments: backslash-quote escaping rules.
        var backslash_count: usize = 0;
        var inside_quotes = false;
        while (true) : (self.index += 1) {
            const char: u16 = if (self.index != self.cmd_line.len)
                self.cmd_line[self.index]
            else
                0;
            switch (char) {
                0 => {
                    last_emitted = strategy.emitBackslashes(self, backslash_count, last_emitted) catch |e| return e;
                    return strategy.yieldArg(self);
                },
                ' ', '\t' => {
                    last_emitted = strategy.emitBackslashes(self, backslash_count, last_emitted) catch |e| return e;
                    backslash_count = 0;
                    if (inside_quotes) {
                        last_emitted = strategy.emitCharacter(self, char, last_emitted) catch |e| return e;
                    } else return strategy.yieldArg(self);
                },
                '"' => {
                    const char_is_escaped_quote = backslash_count % 2 != 0;
                    last_emitted = strategy.emitBackslashes(self, backslash_count / 2, last_emitted) catch |e| return e;
                    backslash_count = 0;
                    if (char_is_escaped_quote) {
                        last_emitted = strategy.emitCharacter(self, '"', last_emitted) catch |e| return e;
                    } else {
                        if (inside_quotes and
                            self.index + 1 != self.cmd_line.len and
                            self.cmd_line[self.index + 1] == '"')
                        {
                            last_emitted = strategy.emitCharacter(self, '"', last_emitted) catch |e| return e;
                            self.index += 1;
                        } else {
                            inside_quotes = !inside_quotes;
                        }
                    }
                },
                '\\' => {
                    backslash_count += 1;
                },
                else => {
                    last_emitted = strategy.emitBackslashes(self, backslash_count, last_emitted) catch |e| return e;
                    backslash_count = 0;
                    last_emitted = strategy.emitCharacter(self, char, last_emitted) catch |e| return e;
                },
            }
        }
    }
};

// ── Argv_Iterator ───────────────────────────────────────────────────────

/// Platform-dispatching argv iterator. On Windows, decodes WTF-16 into a
/// caller-provided buffer. On POSIX, wraps native argv pointers (zero-copy).
pub const Argv_Iterator = struct {
    inner: Inner,

    const Inner = switch (native_os) {
        .windows => Windows_Argv_Iterator,
        else => Posix_Argv_Iterator,
    };

    /// Initialize from platform-native argv. On POSIX, `buf` is unused.
    /// On Windows, `buf` is used for WTF-16 → WTF-8 decoding.
    pub fn init(argv: switch (native_os) {
        .windows => []const u16,
        else => []const [*:0]const u8,
    }, buf: []u8) Argv_Iterator {
        return .{
            .inner = switch (native_os) {
                .windows => Windows_Argv_Iterator.init(argv, buf),
                else => Posix_Argv_Iterator.init(argv),
            },
        };
    }

    /// Returns the next argument as a `[:0]const u8` slice, or `null` if done.
    /// On Windows, returns `SigError.BufferTooSmall` if the buffer is too small.
    pub fn next(self: *Argv_Iterator) SigError!?[:0]const u8 {
        return self.inner.next();
    }

    /// Skip one argument without decoding. Returns `true` if skipped, `false` if done.
    pub fn skip(self: *Argv_Iterator) bool {
        return self.inner.skip();
    }
};

// Environment pointer — null-terminated array of "KEY=VALUE\0" strings.
// Available on both POSIX (libc environ) and Windows (UCRT environ).
extern "c" var environ: [*:null]?[*:0]u8;

// ── Posix_Env_Iterator ──────────────────────────────────────────────────

/// Zero-copy iterator over POSIX environment variables.
/// Walks the `environ` pointer and splits each entry on the first `=`.
const Posix_Env_Iterator = struct {
    index: usize = 0,

    fn init() Posix_Env_Iterator {
        return .{};
    }

    fn next(self: *Posix_Env_Iterator, _: []u8, _: []u8) SigError!?Env_Iterator.Entry {
        const env_ptr = environ;
        // Walk until we find a non-null entry or reach the sentinel.
        while (true) {
            const entry_opt: ?[*:0]u8 = env_ptr[self.index];
            const entry = entry_opt orelse return null;
            self.index += 1;

            // Manual null-terminated slice scan
            var len: usize = 0;
            while (entry[len] != 0) : (len += 1) {}
            const entry_slice = entry[0..len];
            // Split on first '='
            if (sig_mem.indexOfScalar(u8, entry_slice, '=')) |eq_pos| {
                return .{
                    .key = entry_slice[0..eq_pos],
                    .value = entry_slice[eq_pos + 1 ..],
                };
            }
            // Malformed entry (no '='), skip it
        }
    }
};

// ── Windows_Env_Iterator ────────────────────────────────────────────────

/// Iterator over Windows environment variables.
/// Uses the C runtime `environ` pointer and copies key/value into
/// caller-provided buffers since the environment block encoding may differ.
const Windows_Env_Iterator = struct {
    index: usize = 0,

    fn init() Windows_Env_Iterator {
        return .{};
    }

    fn next(self: *Windows_Env_Iterator, key_buf: []u8, value_buf: []u8) SigError!?Env_Iterator.Entry {
        const env_ptr = environ;
        while (true) {
            const entry_opt: ?[*:0]u8 = env_ptr[self.index];
            const entry = entry_opt orelse return null;
            self.index += 1;

            // Manual null-terminated slice scan
            var len: usize = 0;
            while (entry[len] != 0) : (len += 1) {}
            const entry_slice = entry[0..len];
            // Split on first '='
            if (sig_mem.indexOfScalar(u8, entry_slice, '=')) |eq_pos| {
                const key = entry_slice[0..eq_pos];
                const value = entry_slice[eq_pos + 1 ..];

                if (key.len > key_buf.len) return error.BufferTooSmall;
                if (value.len > value_buf.len) return error.BufferTooSmall;

                @memcpy(key_buf[0..key.len], key);
                @memcpy(value_buf[0..value.len], value);

                return .{
                    .key = key_buf[0..key.len],
                    .value = value_buf[0..value.len],
                };
            }
            // Malformed entry (no '='), skip it
        }
    }
};

// ── Env_Iterator ────────────────────────────────────────────────────────

/// Iterates over all environment variables.
/// On POSIX: walks `environ` pointer, splits on first `=`, returns zero-copy slices.
/// On Windows: walks `environ` (via UCRT), copies key/value into caller-provided buffers.
pub const Env_Iterator = struct {
    inner: Inner,

    const Inner = switch (native_os) {
        .windows => Windows_Env_Iterator,
        else => Posix_Env_Iterator,
    };

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    /// Initialize the environment iterator.
    pub fn init() Env_Iterator {
        return .{
            .inner = switch (native_os) {
                .windows => Windows_Env_Iterator.init(),
                else => Posix_Env_Iterator.init(),
            },
        };
    }

    /// Returns the next key-value pair, or `null` if done.
    /// On Windows, key and value are written into the caller-provided buffers.
    /// On POSIX, key and value point into the native environ memory (zero-copy).
    pub fn next(
        self: *Env_Iterator,
        key_buf: []u8,
        value_buf: []u8,
    ) SigError!?Entry {
        return self.inner.next(key_buf, value_buf);
    }
};

// ── Spawn / RunCommand ──────────────────────────────────────────────────

/// Convert a signal number to an exit code: `min(128 + signal, 255)`.
/// For signal 0 (normal exit), returns 0.
pub fn signalToExitCode(signal: u32) u8 {
    if (signal == 0) return 0;
    const sum: u32 = 128 + signal;
    return @intCast(@min(sum, 255));
}

/// Spawn a child process from a Command_Buffer.
/// Uses CreateProcessW on Windows, posix_spawnp on POSIX.
/// Returns a Child handle that the caller must .wait() and .kill() on.
pub fn spawn(
    io: sig_io.Io,
    cmd: *const Command_Buffer,
    options: Spawn_Options,
) SigError!Child {
    _ = io;
    if (cmd.arg_count == 0) return error.BufferTooSmall;

    if (native_os == .windows) {
        return spawnWindows(cmd, options);
    } else {
        return spawnPosix(cmd, options);
    }
}

/// Windows implementation: CreateProcessW with optional pipe setup.
fn spawnWindows(cmd: *const Command_Buffer, options: Spawn_Options) SigError!Child {
    // Build the command line as a single UTF-8 string first, then convert to UTF-16.
    var cmdline_buf: [MAX_CMDLINE_WIDE]u8 = undefined;
    var cmdline_len: usize = 0;

    for (0..cmd.arg_count) |i| {
        if (i > 0) {
            if (cmdline_len >= cmdline_buf.len) return error.BufferTooSmall;
            cmdline_buf[cmdline_len] = ' ';
            cmdline_len += 1;
        }

        const arg = cmd.args[i][0..cmd.arg_lens[i]];
        const needs_quoting = argNeedsQuoting(arg);

        if (needs_quoting) {
            if (cmdline_len >= cmdline_buf.len) return error.BufferTooSmall;
            cmdline_buf[cmdline_len] = '"';
            cmdline_len += 1;
        }

        // Copy arg bytes, escaping backslashes before quotes per Windows rules.
        var backslashes: usize = 0;
        for (arg) |c| {
            if (c == '\\') {
                backslashes += 1;
            } else if (c == '"') {
                // Emit 2N+1 backslashes + escaped quote
                const emit_bs = backslashes * 2 + 1;
                if (cmdline_len + emit_bs + 1 > cmdline_buf.len) return error.BufferTooSmall;
                for (0..emit_bs) |_| {
                    cmdline_buf[cmdline_len] = '\\';
                    cmdline_len += 1;
                }
                cmdline_buf[cmdline_len] = '"';
                cmdline_len += 1;
                backslashes = 0;
            } else {
                // Emit pending backslashes as-is
                if (cmdline_len + backslashes + 1 > cmdline_buf.len) return error.BufferTooSmall;
                for (0..backslashes) |_| {
                    cmdline_buf[cmdline_len] = '\\';
                    cmdline_len += 1;
                }
                cmdline_buf[cmdline_len] = c;
                cmdline_len += 1;
                backslashes = 0;
            }
        }

        // If closing quote, need to escape trailing backslashes (2N)
        if (needs_quoting) {
            const emit_bs = backslashes * 2;
            if (cmdline_len + emit_bs + 1 > cmdline_buf.len) return error.BufferTooSmall;
            for (0..emit_bs) |_| {
                cmdline_buf[cmdline_len] = '\\';
                cmdline_len += 1;
            }
            cmdline_buf[cmdline_len] = '"';
            cmdline_len += 1;
        } else {
            // Emit any trailing backslashes as-is
            if (cmdline_len + backslashes > cmdline_buf.len) return error.BufferTooSmall;
            for (0..backslashes) |_| {
                cmdline_buf[cmdline_len] = '\\';
                cmdline_len += 1;
            }
        }
    }

    // Convert to UTF-16 for CreateProcessW.
    var wide_cmdline: [MAX_CMDLINE_WIDE + 1]u16 = undefined;
    const wide_len = os.utf8TextToWide(cmdline_buf[0..cmdline_len], &wide_cmdline) orelse
        return error.BufferTooSmall;
    _ = wide_len;

    // Set up CWD in wide form if specified.
    var wide_cwd_buf: [os.MAX_PATH_WIDE + 1]u16 = undefined;
    var cwd_ptr: ?os.LPCWSTR = null;
    const cwd_path = if (options.cwd) |p| p else if (cmd.cwd_len > 0) cmd.cwd[0..cmd.cwd_len] else null;
    if (cwd_path) |p| {
        const cwd_wide_len = os.utf8ToWide(p, &wide_cwd_buf) orelse return error.BufferTooSmall;
        _ = cwd_wide_len;
        cwd_ptr = @ptrCast(&wide_cwd_buf);
    }

    // Create pipes for stdout/stderr if requested.
    var stdout_read: ?os.HANDLE = null;
    var stderr_read: ?os.HANDLE = null;
    var stdout_write: ?os.HANDLE = null;
    var stderr_write: ?os.HANDLE = null;

    var sa = os.SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(os.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = os.TRUE,
    };

    if (options.stdout == .pipe) {
        var read_h: os.HANDLE = undefined;
        var write_h: os.HANDLE = undefined;
        if (os.kernel32.CreatePipe(&read_h, &write_h, &sa, 0) == os.FALSE)
            return error.BufferTooSmall;
        // Prevent read end from being inherited by child.
        _ = os.kernel32.SetHandleInformation(read_h, os.HANDLE_FLAG_INHERIT, 0);
        stdout_read = read_h;
        stdout_write = write_h;
    }

    if (options.stderr == .pipe) {
        var read_h: os.HANDLE = undefined;
        var write_h: os.HANDLE = undefined;
        if (os.kernel32.CreatePipe(&read_h, &write_h, &sa, 0) == os.FALSE)
            return error.BufferTooSmall;
        _ = os.kernel32.SetHandleInformation(read_h, os.HANDLE_FLAG_INHERIT, 0);
        stderr_read = read_h;
        stderr_write = write_h;
    }

    // Set up STARTUPINFOW.
    var si: os.STARTUPINFOW = .{};
    si.cb = @sizeOf(os.STARTUPINFOW);
    // Explicit standard handles are required for redirected parent terminals
    // (including CI and Codex). With CREATE_NO_WINDOW, leaving these fields
    // unset can make an otherwise successful child silently lose all output.
    si.dwFlags = os.STARTF_USESTDHANDLES;
    si.hStdInput = if (options.stdin == .inherit) os.kernel32.GetStdHandle(os.STD_INPUT_HANDLE) else null;
    si.hStdOutput = if (stdout_write) |h| h else if (options.stdout == .inherit) os.kernel32.GetStdHandle(os.STD_OUTPUT_HANDLE) else null;
    si.hStdError = if (stderr_write) |h| h else if (options.stderr == .inherit) os.kernel32.GetStdHandle(os.STD_ERROR_HANDLE) else null;

    var pi: os.PROCESS_INFORMATION = undefined;

    const ok = os.kernel32.CreateProcessW(
        null,
        @ptrCast(&wide_cmdline),
        null,
        null,
        os.TRUE, // inherit handles
        os.CREATE_NO_WINDOW,
        null, // inherit environment
        cwd_ptr,
        &si,
        &pi,
    );

    // Close write ends of pipes in parent — child has the handles now.
    if (stdout_write) |h| _ = os.kernel32.CloseHandle(h);
    if (stderr_write) |h| _ = os.kernel32.CloseHandle(h);

    if (ok == os.FALSE) {
        // Cleanup read handles on failure.
        if (stdout_read) |h| _ = os.kernel32.CloseHandle(h);
        if (stderr_read) |h| _ = os.kernel32.CloseHandle(h);
        return error.BufferTooSmall;
    }

    // Close the thread handle — we only need the process handle.
    _ = os.kernel32.CloseHandle(pi.hThread);

    return Child{
        .handle = pi.hProcess,
        .stdout = stdout_read,
        .stderr = stderr_read,
    };
}

/// Check if a command-line argument needs quoting on Windows.
fn argNeedsQuoting(arg: []const u8) bool {
    if (arg.len == 0) return true;
    for (arg) |c| {
        switch (c) {
            ' ', '\t', '"', '&', '|', '^', '<', '>', '(' , ')' => return true,
            else => {},
        }
    }
    return false;
}

/// POSIX implementation: posix_spawn (fork+exec atomically inside libc) with
/// optional pipe setup. Avoids fork-without-exec, which is unsafe on macOS.
fn spawnPosix(cmd: *const Command_Buffer, options: Spawn_Options) SigError!Child {
    // Build null-terminated argv array on the stack.
    // Each arg needs a null-terminated copy.
    var arg_bufs: [MAX_CMD_ARGS][MAX_ARG_LEN + 1]u8 = undefined;
    var argv_ptrs: [MAX_CMD_ARGS + 1]?[*:0]const u8 = undefined;

    for (0..cmd.arg_count) |i| {
        const arg = cmd.args[i][0..cmd.arg_lens[i]];
        @memcpy(arg_bufs[i][0..arg.len], arg);
        arg_bufs[i][arg.len] = 0;
        argv_ptrs[i] = @ptrCast(&arg_bufs[i]);
    }
    argv_ptrs[cmd.arg_count] = null;

    // Create pipes if stdout/stderr are .pipe.
    var stdout_pipe: [2]c_int = .{ -1, -1 };
    var stderr_pipe: [2]c_int = .{ -1, -1 };

    if (options.stdout == .pipe) {
        if (os.posix.pipe(&stdout_pipe) != 0) return error.BufferTooSmall;
    }
    if (options.stderr == .pipe) {
        if (os.posix.pipe(&stderr_pipe) != 0) {
            if (stdout_pipe[0] >= 0) {
                _ = os.posix.close(stdout_pipe[0]);
                _ = os.posix.close(stdout_pipe[1]);
            }
            return error.BufferTooSmall;
        }
    }

    // Prepare CWD null-terminated buffer for chdir in child.
    var cwd_z_buf: [MAX_CWD_LEN + 1]u8 = undefined;
    var cwd_z: ?[*:0]const u8 = null;
    const cwd_path = if (options.cwd) |p| p else if (cmd.cwd_len > 0) cmd.cwd[0..cmd.cwd_len] else null;
    if (cwd_path) |p| {
        if (p.len > MAX_CWD_LEN) return error.BufferTooSmall;
        @memcpy(cwd_z_buf[0..p.len], p);
        cwd_z_buf[p.len] = 0;
        cwd_z = @ptrCast(&cwd_z_buf);
    }

    // Use posix_spawn rather than fork()+exec. fork-without-exec is unsafe on
    // macOS (the child aborts the instant it touches malloc/libdispatch), and
    // posix_spawn performs the fork+exec atomically inside libc. All the child
    // setup (pipe dup2/close, cwd) is expressed declaratively via a file-actions
    // object, so no non-async-signal-safe code runs in the child.
    var actions: os.posix.PosixSpawnFileActions = .{};
    if (os.posix.posix_spawn_file_actions_init(&actions) != 0) {
        if (stdout_pipe[0] >= 0) {
            _ = os.posix.close(stdout_pipe[0]);
            _ = os.posix.close(stdout_pipe[1]);
        }
        if (stderr_pipe[0] >= 0) {
            _ = os.posix.close(stderr_pipe[0]);
            _ = os.posix.close(stderr_pipe[1]);
        }
        return error.BufferTooSmall;
    }
    defer _ = os.posix.posix_spawn_file_actions_destroy(&actions);

    // Change directory in the child before exec, if requested. addchdir_np is
    // available on macOS 10.15+ and glibc 2.29+.
    if (cwd_z) |cz| {
        _ = os.posix.posix_spawn_file_actions_addchdir_np(&actions, cz);
    }

    // Redirect the pipe write ends onto stdout(1)/stderr(2) in the child, then
    // close both original pipe fds in the child so it doesn't leak them.
    if (options.stdout == .pipe) {
        _ = os.posix.posix_spawn_file_actions_adddup2(&actions, stdout_pipe[1], 1);
        _ = os.posix.posix_spawn_file_actions_addclose(&actions, stdout_pipe[0]);
        _ = os.posix.posix_spawn_file_actions_addclose(&actions, stdout_pipe[1]);
    }
    if (options.stderr == .pipe) {
        _ = os.posix.posix_spawn_file_actions_adddup2(&actions, stderr_pipe[1], 2);
        _ = os.posix.posix_spawn_file_actions_addclose(&actions, stderr_pipe[0]);
        _ = os.posix.posix_spawn_file_actions_addclose(&actions, stderr_pipe[1]);
    }

    var pid: c_int = -1;
    // posix_spawnp searches PATH for the executable, matching execvp semantics.
    const spawn_rc = os.posix.posix_spawnp(
        &pid,
        argv_ptrs[0].?,
        &actions,
        null,
        @ptrCast(&argv_ptrs),
        os.posix.environ,
    );
    if (spawn_rc != 0 or pid < 0) {
        if (stdout_pipe[0] >= 0) {
            _ = os.posix.close(stdout_pipe[0]);
            _ = os.posix.close(stdout_pipe[1]);
        }
        if (stderr_pipe[0] >= 0) {
            _ = os.posix.close(stderr_pipe[0]);
            _ = os.posix.close(stderr_pipe[1]);
        }
        return error.BufferTooSmall;
    }

    // ── Parent process ──
    // Close write ends of pipes (the spawned child owns its own copies).
    if (stdout_pipe[1] >= 0) _ = os.posix.close(stdout_pipe[1]);
    if (stderr_pipe[1] >= 0) _ = os.posix.close(stderr_pipe[1]);

    return Child{
        .handle = pid,
        .stdout = if (options.stdout == .pipe) stdout_pipe[0] else null,
        .stderr = if (options.stderr == .pipe) stderr_pipe[0] else null,
    };
}

/// Convenience: spawn, capture stderr, wait, return exit code as `u8`.
/// Maps POSIX signal termination to `min(128 + signal, 255)`.
/// Maps all OS errors to `SigError` for simplified error handling.
pub fn runCommand(
    io: sig_io.Io,
    cmd: *const Command_Buffer,
    stderr_buf: []u8,
    stderr_len: *usize,
    options: Spawn_Options,
) SigError!u8 {
    // Force stderr to pipe for capture, inherit the rest from options.
    var spawn_opts = options;
    spawn_opts.stderr = .pipe;

    var child = try spawn(io, cmd, spawn_opts);
    defer child.kill(io);

    // Read stderr from the child into the caller-provided buffer.
    stderr_len.* = 0;
    if (child.stderr) |stderr_fd| {
        var discard: [1024]u8 = undefined;
        while (true) {
            if (stderr_len.* < stderr_buf.len) {
                const remaining = stderr_buf.len - stderr_len.*;
                const n = os.readFd(stderr_fd, stderr_buf.ptr + stderr_len.*, remaining);
                if (n == 0) break;
                stderr_len.* += n;
            } else {
                // Retain a bounded diagnostic prefix but keep draining the
                // pipe. Stopping at capacity deadlocks children that emit more
                // than STDERR_CAPTURE_SIZE before they exit.
                const n = os.readFd(stderr_fd, &discard, discard.len);
                if (n == 0) break;
            }
        }
    }

    // Wait for the child to exit and extract the exit code.
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| signalToExitCode(sig),
        .stopped => |sig| signalToExitCode(sig),
        .unknown => |val| signalToExitCode(val),
    };
}

// ── Environment ─────────────────────────────────────────────────────────

/// Look up an environment variable by name.
/// On POSIX: wraps libc getenv(), returns a pointer into the process
/// environment block (zero-copy). The `buf` parameter is unused on POSIX.
/// On Windows: uses GetEnvironmentVariableW, copies the value into `buf`.
/// Returns `null` when the variable does not exist.
/// Returns `SigError.BufferTooSmall` when `buf` is too small (Windows only).
pub fn getenv(name: []const u8, buf: []u8) SigError!?[]const u8 {
    if (native_os == .windows) {
        // Convert name to UTF-16 for GetEnvironmentVariableW.
        var name_wide: [MAX_ENV_KEY_LEN + 1]u16 = undefined;
        const name_wide_len = os.utf8TextToWide(name, &name_wide) orelse return error.BufferTooSmall;
        _ = name_wide_len;

        // Query the variable length first.
        var value_wide: [MAX_ENV_VALUE_LEN]u16 = undefined;
        const n = os.kernel32.GetEnvironmentVariableW(
            @ptrCast(&name_wide),
            @ptrCast(&value_wide),
            @intCast(value_wide.len),
        );
        if (n == 0) return null; // Variable not found.

        // Convert UTF-16 result back to UTF-8 into caller buffer.
        const value_wide_slice = value_wide[0..n];
        const utf8_len = os.wideToUtf8(value_wide_slice, buf) orelse return error.BufferTooSmall;
        return buf[0..utf8_len];
    } else {
        // POSIX: use libc getenv.
        var name_buf: [MAX_ENV_KEY_LEN + 1]u8 = undefined;
        if (name.len > MAX_ENV_KEY_LEN) return error.BufferTooSmall;
        @memcpy(name_buf[0..name.len], name);
        name_buf[name.len] = 0;
        const name_z: [*:0]const u8 = name_buf[0..name.len :0];

        const result = os.posix.getenv(name_z);
        if (result) |ptr| {
            // Walk the null-terminated string to get the length.
            var len: usize = 0;
            while (ptr[len] != 0) : (len += 1) {}
            return ptr[0..len];
        }
        return null;
    }
}

/// Get the current working directory into a caller-provided buffer.
/// Returns the path slice on success, or `SigError.BufferTooSmall` on failure.
pub fn getCwd(buf: []u8) SigError![]u8 {
    const result = os.getCwd(buf) orelse return error.BufferTooSmall;
    return result;
}

/// Terminate the current process with the given exit code.
/// This function does not return.
pub fn exit(code: u8) noreturn {
    os.exitProcess(code);
}
