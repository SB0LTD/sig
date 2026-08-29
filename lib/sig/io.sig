//! Sig I/O — freestanding I/O types for the sig build system.
//!
//! Provides: Io, Dir, File, Mutex, Condition, Clock, Thread.
//! Built entirely on lib/sig/os.sig (raw syscalls / kernel32 externs).
//! Zero @import("std") dependency.
//!
//! API contract: matches the exact usage patterns in tools/sig_build/:
//!   - io: Io (passed as parameter, zero-sized context for sync I/O)
//!   - const cwd: Dir = .cwd();
//!   - cwd.openFile(io, path, .{}) → File
//!   - cwd.createFile(io, path, .{}) → File
//!   - Dir.cwd().createDirPath(io, path)
//!   - file.reader(io, &.{}) → Reader
//!   - file.writeStreamingAll(io, data)
//!   - file.close(io)
//!   - File.stdout() / File.stderr()
//!   - Mutex.init, mutex.lockUncancelable(io), mutex.unlock(io)
//!   - Condition.init, cond.waitUncancelable(io, &mutex), cond.signal(io), cond.broadcast(io)
//!   - Clock.awake.now(io).nanoseconds
//!   - Thread.spawn(.{}, fn, .{arg}) → Thread

const os = @import("os.sig");
const SigError = @import("errors.sig").SigError;
const builtin = @import("builtin");

// ══════════════════════════════════════════════════════════════════════════════
// Io — Zero-sized I/O context
// ══════════════════════════════════════════════════════════════════════════════

/// The I/O context type. For synchronous (non-async) I/O this is zero-sized —
/// it exists only for API compatibility. All actual state lives in File/Dir handles.
pub const Io = struct {
    // Zero-sized. No fields needed for synchronous I/O.
    // The sig_build passes this around as a parameter for future async readiness,
    // but all operations are blocking.

    /// Sentinel value for initialization in struct fields.
    pub const undefined_io: Io = .{};
};

// ══════════════════════════════════════════════════════════════════════════════
// Dir — Directory handle
// ══════════════════════════════════════════════════════════════════════════════

/// Directory handle. In the sig_build usage pattern, directories are primarily
/// used as anchors for opening files relative to CWD.
pub const Dir = struct {
    /// Marker for "current working directory" mode.
    _is_cwd: bool = false,

    /// Get the current working directory handle.
    /// Usage: `const cwd: Dir = .cwd();`
    pub fn cwd() Dir {
        return .{ ._is_cwd = true };
    }

    /// Open options (matches std.Io.Dir.openFile signature).
    pub const OpenOptions = struct {};

    /// Open a file for reading, relative to this directory.
    /// Usage: `cwd.openFile(io, path, .{}) catch ...`
    pub fn openFile(self: Dir, io: Io, path: []const u8, opts: OpenOptions) !File {
        _ = self;
        _ = io;
        _ = opts;
        const fd = os.openRead(path) catch return error.FileNotFound;
        return File{ .handle = fd };
    }

    /// Create options (matches std.Io.Dir.createFile signature).
    pub const CreateOptions = struct {};

    /// Create or truncate a file for writing, relative to this directory.
    /// Usage: `cwd.createFile(io, path, .{}) catch ...`
    pub fn createFile(self: Dir, io: Io, path: []const u8, opts: CreateOptions) !File {
        _ = self;
        _ = io;
        _ = opts;
        const fd = os.openWrite(path) catch return error.FileNotFound;
        return File{ .handle = fd };
    }

    /// Create a directory path recursively (mkdir -p).
    /// Usage: `Dir.cwd().createDirPath(io, path) catch ...`
    pub fn createDirPath(self: Dir, io: Io, path: []const u8) !void {
        _ = self;
        _ = io;
        if (!os.mkdirRecursive(path)) return error.SystemError;
    }

    /// Open a subdirectory for iteration.
    /// Returns a Dir handle representing that path.
    pub fn openDir(self: Dir, io: Io, path: []const u8, opts: anytype) !Dir {
        _ = self;
        _ = io;
        _ = opts;
        if (!os.pathExists(path)) return error.FileNotFound;
        return Dir{ ._is_cwd = false };
    }

    /// Close a directory handle (no-op for CWD-based dirs).
    pub fn close(self: Dir, io: Io) void {
        _ = self;
        _ = io;
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// File — File handle with reader/writer interface
// ══════════════════════════════════════════════════════════════════════════════

/// File handle wrapping an OS file descriptor / HANDLE.
/// Provides the reader/writer interface expected by sig_build.
pub const File = struct {
    handle: os.fd_t,

    /// Reader options (matches std file.reader(io, &.{}) signature).
    pub const ReaderOptions = struct {};

    /// Get a Reader interface for this file.
    /// Usage: `var reader = file.reader(io, &.{});`
    pub fn reader(self: File, io: Io, opts: *const ReaderOptions) Reader {
        _ = io;
        _ = opts;
        return Reader{ .interface = ReaderInterface{ .file_handle = self.handle } };
    }

    /// Writer options placeholder.
    pub const WriterOptions = struct {};

    /// Get a Writer interface for this file.
    pub fn writer(self: File, io: Io, opts: *const WriterOptions) Writer {
        _ = io;
        _ = opts;
        return Writer{ .file_handle = self.handle };
    }

    /// Write all bytes to this file. Loops on partial writes.
    /// Usage: `file.writeStreamingAll(io, data) catch ...`
    pub fn writeStreamingAll(self: File, io: Io, data: []const u8) !void {
        _ = io;
        if (!os.writeAll(self.handle, data)) return error.WriteFailed;
    }

    /// Close this file handle.
    /// Usage: `file.close(io)`
    pub fn close(self: File, io: Io) void {
        _ = io;
        os.closeFd(self.handle);
    }

    /// Get the stdout file handle.
    /// Usage: `const stdout = File.stdout();`
    pub fn stdout() File {
        return File{ .handle = os.stdoutFd() };
    }

    /// Get the stderr file handle.
    /// Usage: `const stderr = File.stderr();`
    pub fn stderr() File {
        return File{ .handle = os.stderrFd() };
    }

    /// Get the stdin file handle.
    pub fn stdin() File {
        return File{ .handle = os.stdinFd() };
    }

    /// Get the file size.
    pub fn stat(self: File) FileStat {
        return FileStat{ .size = os.fileSize(self.handle) };
    }
};

pub const FileStat = struct {
    size: u64,
};

// ══════════════════════════════════════════════════════════════════════════════
// Reader — matches `reader.interface.readSliceShort(buf)` pattern
// ══════════════════════════════════════════════════════════════════════════════

/// Reader returned by File.reader(). Contains a `.interface` field with
/// the `readSliceShort` method, matching the sig_build usage pattern:
///   `reader.interface.readSliceShort(buf[0..remaining]) catch break;`
pub const Reader = struct {
    interface: ReaderInterface,
};

/// The actual reader interface with read methods.
pub const ReaderInterface = struct {
    file_handle: os.fd_t,

    /// Read into the provided buffer. Returns number of bytes read (0 = EOF).
    /// Matches the `readSliceShort(buf)` pattern used throughout sig_build.
    pub fn readSliceShort(self: *const ReaderInterface, buf: []u8) !usize {
        const n = os.readFd(self.file_handle, buf.ptr, buf.len);
        return n;
    }

    /// Read into a buffer, returning number of bytes read.
    pub fn read(self: *const ReaderInterface, buf: []u8) !usize {
        return self.readSliceShort(buf);
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Writer
// ══════════════════════════════════════════════════════════════════════════════

/// Writer interface for file output.
pub const Writer = struct {
    file_handle: os.fd_t,

    /// Write data to the file. Returns number of bytes written.
    pub fn write(self: *const Writer, data: []const u8) !usize {
        const n = os.writeFd(self.file_handle, data.ptr, data.len);
        if (n == 0 and data.len > 0) return error.WriteFailed;
        return n;
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Mutex — matches `std.Io.Mutex` API
// ══════════════════════════════════════════════════════════════════════════════

/// Mutual exclusion lock. Matches the sig_build usage:
///   mutex: Mutex = Mutex.init,
///   self.mutex.lockUncancelable(self.io);
///   self.mutex.unlock(self.io);
pub const Mutex = struct {
    impl: os.MutexImpl = .{},

    /// Constant for field initialization: `mutex: Mutex = Mutex.init,`
    pub const init: Mutex = .{ .impl = .{} };

    /// Explicitly initialize the underlying OS primitive. Safe to call on a
    /// default-constructed Mutex. Required on macOS, where a zeroed
    /// pthread_mutex_t is not a valid object; a no-op on Windows.
    pub fn reset(self: *Mutex) void {
        self.impl.initInPlace();
    }

    /// Acquire the lock. The `io` parameter is accepted for API compatibility
    /// but unused (synchronous blocking operation).
    pub fn lockUncancelable(self: *Mutex, io: Io) void {
        _ = io;
        self.impl.lock();
    }

    /// Release the lock.
    pub fn unlock(self: *Mutex, io: Io) void {
        _ = io;
        self.impl.unlock();
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Condition — matches `std.Io.Condition` API
// ══════════════════════════════════════════════════════════════════════════════

/// Condition variable. Matches the sig_build usage:
///   cond: Condition = Condition.init,
///   self.cond.waitUncancelable(self.io, &self.mutex);
///   self.cond.signal(self.io);
///   self.cond.broadcast(self.io);
pub const Condition = struct {
    impl: os.ConditionImpl = .{},

    /// Constant for field initialization: `cond: Condition = Condition.init,`
    pub const init: Condition = .{ .impl = .{} };

    /// Explicitly initialize the underlying OS primitive. Safe to call on a
    /// default-constructed Condition. Required on macOS; a no-op on Windows.
    pub fn reset(self: *Condition) void {
        self.impl.initInPlace();
    }

    /// Wait on this condition, releasing the mutex atomically.
    /// Re-acquires the mutex before returning.
    pub fn waitUncancelable(self: *Condition, io: Io, mutex: *Mutex) void {
        _ = io;
        self.impl.wait(&mutex.impl);
    }

    /// Wake one waiting thread.
    pub fn signal(self: *Condition, io: Io) void {
        _ = io;
        self.impl.signal();
    }

    /// Wake all waiting threads.
    pub fn broadcast(self: *Condition, io: Io) void {
        _ = io;
        self.impl.broadcast();
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Clock — matches `std.Io.Clock.awake.now(io).nanoseconds`
// ══════════════════════════════════════════════════════════════════════════════

/// Clock interface. Matches the sig_build usage:
///   `const sig_start_ns = Clock.awake.now(io).nanoseconds;`
pub const Clock = struct {
    pub const awake = struct {
        pub fn now(io: Io) Timestamp {
            _ = io;
            return Timestamp{ .nanoseconds = os.clockMonotonicNs() };
        }
    };
};

pub const Timestamp = struct {
    nanoseconds: i64,
};

// ══════════════════════════════════════════════════════════════════════════════
// Thread — matches `std.Thread.spawn(.{}, fn, .{arg})` / `.join()`
// ══════════════════════════════════════════════════════════════════════════════

/// Thread handle. Matches the sig_build usage:
///   `threads: [MAX_THREADS]Thread = undefined,`
///   `self.threads[i] = Thread.spawn(.{}, workerLoop, .{self}) catch ...;`
///   `self.threads[i].join();`
pub const Thread = struct {
    handle: os.ThreadHandle,

    /// Spawn options (matches the `.{}` first argument in std.Thread.spawn).
    pub const SpawnOptions = struct {};

    /// Spawn a new thread executing `func(args)`.
    /// Matches: `std.Thread.spawn(.{}, workerLoop, .{self})`
    ///
    /// The function signature must be `fn(*T) void` where T matches
    /// the tuple element type. We use a comptime trampoline to erase
    /// the type into the os.ThreadFn `fn(?*anyopaque) void` form.
    pub fn spawn(opts: SpawnOptions, comptime func: anytype, args: anytype) !Thread {
        _ = opts;
        // Extract the single argument (sig_build always passes .{self} — one pointer)
        const arg = args[0];
        const ArgType = @TypeOf(arg);

        const Trampoline = struct {
            fn entry(ctx: ?*anyopaque) void {
                const typed: ArgType = @ptrCast(@alignCast(ctx.?));
                func(typed);
            }
        };

        const handle = os.threadSpawn(&Trampoline.entry, @ptrCast(@alignCast(arg))) orelse
            return error.SystemError;
        return Thread{ .handle = handle };
    }

    /// Wait for this thread to finish.
    pub fn join(self: Thread) void {
        os.threadJoin(self.handle);
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Utility functions (preserved from the original io.sig)
// ══════════════════════════════════════════════════════════════════════════════

/// Reads data into a caller-provided buffer. Returns the filled slice.
/// Returns error.BufferTooSmall if the source has more data than the buffer can hold.
pub fn readInto(reader_iface: anytype, buf: []u8) SigError![]u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n = reader_iface.read(buf[total..]) catch return error.BufferTooSmall;
        if (n == 0) break;
        total += n;
    }

    // If we filled the buffer, check whether the source has more data.
    if (total == buf.len) {
        var probe: [1]u8 = undefined;
        const extra = reader_iface.read(&probe) catch return error.BufferTooSmall;
        if (extra != 0) return error.BufferTooSmall;
    }

    return buf[0..total];
}

/// Reads up to `max_bytes` into a caller-provided buffer.
/// The buffer must be at least `max_bytes` in size.
pub fn readAtMost(reader_iface: anytype, buf: []u8, max_bytes: usize) SigError![]u8 {
    const limit = @min(max_bytes, buf.len);
    var total: usize = 0;
    while (total < limit) {
        const n = reader_iface.read(buf[total..limit]) catch return error.BufferTooSmall;
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

/// A streaming reader that processes data in fixed-size chunks.
/// RAM usage is bounded to exactly `chunk_size` bytes for the internal buffer.
pub fn StreamReader(comptime chunk_size: usize) type {
    return struct {
        buf: [chunk_size]u8 = undefined,

        const Self = @This();

        /// Reads the next chunk from the reader. Returns the filled slice,
        /// or null when the reader has reached EOF.
        pub fn next(self: *Self, reader_iface: anytype) ?[]const u8 {
            var total: usize = 0;
            while (total < chunk_size) {
                const n = reader_iface.read(self.buf[total..]) catch return null;
                if (n == 0) break;
                total += n;
            }
            if (total == 0) return null;
            return self.buf[0..total];
        }
    };
}

// ── Write operations ─────────────────────────────────────────────────────

/// Writes the entire contents of a caller-provided buffer to a writer.
/// The writer must have a `write([]const u8) !usize` method.
/// Returns `BufferTooSmall` if the writer fails before all bytes are written.
pub fn writeAll(writer_iface: anytype, data: []const u8) SigError!void {
    var written: usize = 0;
    while (written < data.len) {
        const n = writer_iface.write(data[written..]) catch return error.BufferTooSmall;
        if (n == 0) return error.BufferTooSmall;
        written += n;
    }
}

/// Writes a formatted string into a caller-provided buffer, then writes
/// the buffer contents to a writer. Zero heap allocation.
/// Returns `BufferTooSmall` if the format output exceeds `buf` or the writer fails.
pub fn writeFormatted(writer_iface: anytype, buf: []u8, comptime fmt_str: []const u8, args: anytype) SigError!void {
    const sig_fmt = @import("fmt.sig");
    const formatted = sig_fmt.bufPrint(buf, fmt_str, args) catch return error.BufferTooSmall;
    return writeAll(writer_iface, formatted);
}

/// Returns a stdout writer. No allocator needed.
/// Requires an Io context (unused for sync I/O, accepted for API compat).
pub fn stdoutWriter(io: Io) FdWriter {
    _ = io;
    return .{ .file = File.stdout() };
}

/// Returns a stderr writer. No allocator needed.
pub fn stderrWriter(io: Io) FdWriter {
    _ = io;
    return .{ .file = File.stderr() };
}

/// Cross-platform file writer using OS file handles directly.
/// No allocator.
pub const FdWriter = struct {
    file: File,

    pub fn write(self: FdWriter, data: []const u8) !usize {
        self.file.writeStreamingAll(.{}, data) catch return error.BufferTooSmall;
        return data.len;
    }
};

/// Format directly to stdout through a fixed-size stack buffer.
/// Diagnostic output is deliberately best-effort and never allocates.
pub fn print(io: Io, comptime format: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const sig_fmt = @import("fmt.sig");
    const rendered = sig_fmt.bufPrint(&buf, format, args) catch return;
    File.stdout().writeStreamingAll(io, rendered) catch {};
}
