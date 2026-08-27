//! OS Primitives — raw syscall/FFI layer for sig's freestanding I/O.
//!
//! Zero std dependency. Uses @import("builtin") for platform detection
//! and extern declarations for OS calls. Provides the foundation for
//! sig.io (File, Dir, Mutex, Condition, Clock, Thread).
//!
//! Supported platforms:
//!   - Windows x86_64 (kernel32 + ntdll)
//!   - Linux x86_64 / aarch64 (inline syscalls)

const builtin = @import("builtin");
const native_os = builtin.os.tag;
const native_arch = builtin.cpu.arch;

// ══════════════════════════════════════════════════════════════════════════════
// Common Types
// ══════════════════════════════════════════════════════════════════════════════

pub const INVALID_HANDLE: fd_t = if (native_os == .windows)
    @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))))
else
    -1;

pub const fd_t = if (native_os == .windows) HANDLE else i32;

// ══════════════════════════════════════════════════════════════════════════════
// Windows Types & Externs
// ══════════════════════════════════════════════════════════════════════════════

pub const HANDLE = *anyopaque;
pub const BOOL = i32;
pub const DWORD = u32;
pub const LPDWORD = *DWORD;
pub const LPVOID = *anyopaque;
pub const LPCVOID = *const anyopaque;
pub const ULONG_PTR = usize;
pub const SIZE_T = usize;
pub const LARGE_INTEGER = i64;
pub const LPCWSTR = [*:0]const u16;
pub const LPWSTR = [*]u16;

// Windows constants
pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const FILE_SHARE_READ: DWORD = 0x00000001;
pub const FILE_SHARE_WRITE: DWORD = 0x00000002;
pub const FILE_SHARE_DELETE: DWORD = 0x00000004;
pub const CREATE_ALWAYS: DWORD = 2;
pub const OPEN_EXISTING: DWORD = 3;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
pub const INVALID_FILE_SIZE: DWORD = 0xFFFFFFFF;
pub const STD_INPUT_HANDLE: DWORD = @as(DWORD, @bitCast(@as(i32, -10)));
pub const STD_OUTPUT_HANDLE: DWORD = @as(DWORD, @bitCast(@as(i32, -11)));
pub const STD_ERROR_HANDLE: DWORD = @as(DWORD, @bitCast(@as(i32, -12)));
pub const INFINITE: DWORD = 0xFFFFFFFF;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const CREATE_NO_WINDOW: DWORD = 0x08000000;
pub const STARTF_USESTDHANDLES: DWORD = 0x00000100;
pub const PROCESS_INFORMATION_SIZE = 24; // placeholder — real struct below
pub const FILE_BEGIN: DWORD = 0;
pub const FILE_CURRENT: DWORD = 1;
pub const FILE_END: DWORD = 2;
pub const DUPLICATE_SAME_ACCESS: DWORD = 0x00000002;
pub const HANDLE_FLAG_INHERIT: DWORD = 0x00000001;
pub const ERROR_FILE_NOT_FOUND: DWORD = 2;
pub const ERROR_PATH_NOT_FOUND: DWORD = 3;
pub const ERROR_ALREADY_EXISTS: DWORD = 183;
pub const MAX_PATH: usize = 260;
pub const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;
pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const PAGE_READWRITE: DWORD = 0x04;
pub const MEM_COMMIT: DWORD = 0x1000;
pub const MEM_RESERVE: DWORD = 0x2000;
pub const MEM_RELEASE: DWORD = 0x8000;
pub const MEM_DECOMMIT: DWORD = 0x4000;

// SRWLOCK is a pointer-sized value (initialized to 0)
pub const SRWLOCK = usize;
pub const SRWLOCK_INIT: SRWLOCK = 0;

// CONDITION_VARIABLE is a pointer-sized value (initialized to 0)
pub const CONDITION_VARIABLE = usize;
pub const CONDITION_VARIABLE_INIT: CONDITION_VARIABLE = 0;

// Security attributes
pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD,
    lpSecurityDescriptor: ?LPVOID,
    bInheritHandle: BOOL,
};

// ── Windows Kernel32 Externs ────────────────────────────────────────────────

pub const kernel32 = if (native_os == .windows) struct {
    pub extern "kernel32" fn CreateFileW(
        lpFileName: LPCWSTR,
        dwDesiredAccess: DWORD,
        dwShareMode: DWORD,
        lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;

    pub extern "kernel32" fn ReadFile(
        hFile: HANDLE,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: DWORD,
        lpNumberOfBytesRead: ?LPDWORD,
        lpOverlapped: ?LPVOID,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: DWORD,
        lpNumberOfBytesWritten: ?LPDWORD,
        lpOverlapped: ?LPVOID,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn CloseHandle(
        hObject: HANDLE,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn GetStdHandle(
        nStdHandle: DWORD,
    ) callconv(.winapi) HANDLE;

    pub extern "kernel32" fn GetFileSize(
        hFile: HANDLE,
        lpFileSizeHigh: ?LPDWORD,
    ) callconv(.winapi) DWORD;

    pub extern "kernel32" fn SetFilePointerEx(
        hFile: HANDLE,
        liDistanceToMove: LARGE_INTEGER,
        lpNewFilePointer: ?*LARGE_INTEGER,
        dwMoveMethod: DWORD,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn CreateDirectoryW(
        lpPathName: LPCWSTR,
        lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn GetCurrentDirectoryW(
        nBufferLength: DWORD,
        lpBuffer: LPWSTR,
    ) callconv(.winapi) DWORD;

    pub extern "kernel32" fn GetFileAttributesW(
        lpFileName: LPCWSTR,
    ) callconv(.winapi) DWORD;

    pub extern "kernel32" fn CreateProcessW(
        lpApplicationName: ?LPCWSTR,
        lpCommandLine: ?LPWSTR,
        lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
        lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
        bInheritHandles: BOOL,
        dwCreationFlags: DWORD,
        lpEnvironment: ?LPVOID,
        lpCurrentDirectory: ?LPCWSTR,
        lpStartupInfo: *STARTUPINFOW,
        lpProcessInformation: *PROCESS_INFORMATION,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn WaitForSingleObject(
        hHandle: HANDLE,
        dwMilliseconds: DWORD,
    ) callconv(.winapi) DWORD;

    pub extern "kernel32" fn GetExitCodeProcess(
        hProcess: HANDLE,
        lpExitCode: LPDWORD,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn TerminateProcess(
        hProcess: HANDLE,
        uExitCode: u32,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn CreateThread(
        lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
        dwStackSize: SIZE_T,
        lpStartAddress: *const fn (?LPVOID) callconv(.winapi) DWORD,
        lpParameter: ?LPVOID,
        dwCreationFlags: DWORD,
        lpThreadId: ?LPDWORD,
    ) callconv(.winapi) ?HANDLE;

    pub extern "kernel32" fn WaitForSingleObjectEx(
        hHandle: HANDLE,
        dwMilliseconds: DWORD,
        bAlertable: BOOL,
    ) callconv(.winapi) DWORD;

    pub extern "kernel32" fn QueryPerformanceCounter(
        lpPerformanceCount: *LARGE_INTEGER,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn QueryPerformanceFrequency(
        lpFrequency: *LARGE_INTEGER,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

    pub extern "kernel32" fn ExitProcess(
        uExitCode: u32,
    ) callconv(.winapi) noreturn;

    pub extern "kernel32" fn CreatePipe(
        hReadPipe: *HANDLE,
        hWritePipe: *HANDLE,
        lpPipeAttributes: ?*SECURITY_ATTRIBUTES,
        nSize: DWORD,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn SetHandleInformation(
        hObject: HANDLE,
        dwMask: DWORD,
        dwFlags: DWORD,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;

    pub extern "kernel32" fn DuplicateHandle(
        hSourceProcessHandle: HANDLE,
        hSourceHandle: HANDLE,
        hTargetProcessHandle: HANDLE,
        lpTargetHandle: *HANDLE,
        dwDesiredAccess: DWORD,
        bInheritHandle: BOOL,
        dwOptions: DWORD,
    ) callconv(.winapi) BOOL;

    // SRWLOCK functions (slim reader/writer lock — fast, no kernel transition for uncontested)
    pub extern "kernel32" fn AcquireSRWLockExclusive(
        SRWLock: *SRWLOCK,
    ) callconv(.winapi) void;

    pub extern "kernel32" fn ReleaseSRWLockExclusive(
        SRWLock: *SRWLOCK,
    ) callconv(.winapi) void;

    // Condition variable functions
    pub extern "kernel32" fn SleepConditionVariableSRW(
        ConditionVariable: *CONDITION_VARIABLE,
        SRWLock: *SRWLOCK,
        dwMilliseconds: DWORD,
        Flags: ULONG_PTR,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn WakeConditionVariable(
        ConditionVariable: *CONDITION_VARIABLE,
    ) callconv(.winapi) void;

    pub extern "kernel32" fn WakeAllConditionVariable(
        ConditionVariable: *CONDITION_VARIABLE,
    ) callconv(.winapi) void;

    pub extern "kernel32" fn GetEnvironmentVariableW(
        lpName: LPCWSTR,
        lpBuffer: ?LPWSTR,
        nSize: DWORD,
    ) callconv(.winapi) DWORD;
} else struct {};

// STARTUPINFOW and PROCESS_INFORMATION — needed for CreateProcessW
pub const STARTUPINFOW = extern struct {
    cb: DWORD = @sizeOf(STARTUPINFOW),
    lpReserved: ?LPWSTR = null,
    lpDesktop: ?LPWSTR = null,
    lpTitle: ?LPWSTR = null,
    dwX: DWORD = 0,
    dwY: DWORD = 0,
    dwXSize: DWORD = 0,
    dwYSize: DWORD = 0,
    dwXCountChars: DWORD = 0,
    dwYCountChars: DWORD = 0,
    dwFillAttribute: DWORD = 0,
    dwFlags: DWORD = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};

pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

// ══════════════════════════════════════════════════════════════════════════════
// POSIX / Linux — C Library Externs
// ══════════════════════════════════════════════════════════════════════════════
//
// sig_build is a hosted binary that links libc. We use C library functions
// rather than raw syscalls to avoid inline assembly syntax portability issues.
// For the freestanding kernel (nexus), raw syscalls are in the kernel's own
// entry code — not in this shared library.

pub const posix = if (native_os != .windows) struct {
    // File descriptor type
    pub const mode_t = u32;

    // Open flags
    pub const O_RDONLY: c_int = 0;
    pub const O_WRONLY: c_int = 1;
    pub const O_RDWR: c_int = 2;
    pub const O_CREAT: c_int = 0o100;
    pub const O_TRUNC: c_int = 0o1000;
    pub const O_CLOEXEC: c_int = 0o2000000;

    // Mode bits
    pub const S_IRWXU: mode_t = 0o700;
    pub const S_IRWXG: mode_t = 0o070;
    pub const S_IRWXO: mode_t = 0o007;

    // Clock IDs
    pub const CLOCK_MONOTONIC: c_int = 1;

    // Stat structure (using the libc-compatible layout)
    pub const Stat = extern struct {
        st_dev: u64,
        st_ino: u64,
        st_nlink: u64,
        st_mode: u32,
        st_uid: u32,
        st_gid: u32,
        __pad0: u32,
        st_rdev: u64,
        st_size: i64,
        st_blksize: i64,
        st_blocks: i64,
        st_atim: timespec,
        st_mtim: timespec,
        st_ctim: timespec,
        __unused: [3]i64,
    };

    pub const timespec = extern struct {
        tv_sec: i64,
        tv_nsec: i64,
    };

    // ── C library extern declarations ───────────────────────────────────

    pub extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) callconv(.c) c_int;
    pub extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) callconv(.c) isize;
    pub extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) callconv(.c) isize;
    pub extern "c" fn close(fd: c_int) callconv(.c) c_int;
    pub extern "c" fn fstat(fd: c_int, statbuf: *Stat) callconv(.c) c_int;
    pub extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) callconv(.c) i64;
    pub extern "c" fn mkdir(path: [*:0]const u8, mode: mode_t) callconv(.c) c_int;
    pub extern "c" fn getcwd(buf: [*]u8, size: usize) callconv(.c) ?[*]u8;
    pub extern "c" fn clock_gettime(clk_id: c_int, tp: *timespec) callconv(.c) c_int;
    pub extern "c" fn _exit(status: c_int) callconv(.c) noreturn;
    pub extern "c" fn pthread_create(
        thread: *u64,
        attr: ?*const anyopaque,
        start_routine: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
        arg: ?*anyopaque,
    ) callconv(.c) c_int;
    pub extern "c" fn pthread_join(thread: u64, retval: ?*?*anyopaque) callconv(.c) c_int;
    pub extern "c" fn pthread_mutex_init(mutex: *PthreadMutex, attr: ?*const anyopaque) callconv(.c) c_int;
    pub extern "c" fn pthread_mutex_lock(mutex: *PthreadMutex) callconv(.c) c_int;
    pub extern "c" fn pthread_mutex_unlock(mutex: *PthreadMutex) callconv(.c) c_int;
    pub extern "c" fn pthread_cond_init(cond: *PthreadCond, attr: ?*const anyopaque) callconv(.c) c_int;
    pub extern "c" fn pthread_cond_wait(cond: *PthreadCond, mutex: *PthreadMutex) callconv(.c) c_int;
    pub extern "c" fn pthread_cond_signal(cond: *PthreadCond) callconv(.c) c_int;
    pub extern "c" fn pthread_cond_broadcast(cond: *PthreadCond) callconv(.c) c_int;

    // ── Process control externs ─────────────────────────────────────────

    pub extern "c" fn fork() callconv(.c) c_int;
    pub extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) callconv(.c) c_int;
    pub extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) callconv(.c) c_int;
    pub extern "c" fn pipe(pipefd: *[2]c_int) callconv(.c) c_int;
    pub extern "c" fn dup2(oldfd: c_int, newfd: c_int) callconv(.c) c_int;
    pub extern "c" fn kill(pid: c_int, sig: c_int) callconv(.c) c_int;
    pub extern "c" fn getenv(name: [*:0]const u8) callconv(.c) ?[*:0]const u8;

    // POSIX signal constants
    pub const SIGKILL: c_int = 9;

    // waitpid status macros (Linux)
    pub fn WIFEXITED(status: c_int) bool {
        return (status & 0x7f) == 0;
    }
    pub fn WEXITSTATUS(status: c_int) u8 {
        return @intCast(@as(u32, @bitCast(status)) >> 8 & 0xff);
    }
    pub fn WIFSIGNALED(status: c_int) bool {
        return ((status & 0x7f) + 1) >> 1 > 0;
    }
    pub fn WTERMSIG(status: c_int) u8 {
        return @intCast(@as(u32, @bitCast(status)) & 0x7f);
    }
    pub fn WIFSTOPPED(status: c_int) bool {
        return (status & 0xff) == 0x7f;
    }
    pub fn WSTOPSIG(status: c_int) u8 {
        return @intCast(@as(u32, @bitCast(status)) >> 8 & 0xff);
    }

    // pthread_mutex_t and pthread_cond_t are opaque structures.
    // On Linux x86_64: pthread_mutex_t = 40 bytes, pthread_cond_t = 48 bytes.
    // On Linux aarch64: same sizes.
    // We use a fixed-size byte array to hold them.
    pub const PTHREAD_MUTEX_SIZE = 40;
    pub const PTHREAD_COND_SIZE = 48;

    pub const PthreadMutex = extern struct {
        __data: [PTHREAD_MUTEX_SIZE]u8 = @as([PTHREAD_MUTEX_SIZE]u8, @splat(0)),
    };

    pub const PthreadCond = extern struct {
        __data: [PTHREAD_COND_SIZE]u8 = @as([PTHREAD_COND_SIZE]u8, @splat(0)),
    };
} else struct {};

// ══════════════════════════════════════════════════════════════════════════════
// UTF-8 → UTF-16 Conversion (Windows only, bounded buffer)
// ══════════════════════════════════════════════════════════════════════════════

/// Maximum path length in UTF-16 code units for Windows APIs.
pub const MAX_PATH_WIDE = 32768;

/// Convert a UTF-8 path to a null-terminated UTF-16LE buffer for Windows APIs.
/// Returns the number of u16 code units written (excluding null terminator),
/// or null if the path is too long or contains invalid UTF-8.
pub fn utf8ToWide(utf8: []const u8, out: []u16) ?usize {
    var i: usize = 0;
    var o: usize = 0;
    while (i < utf8.len) {
        const byte = utf8[i];
        var codepoint: u32 = undefined;
        var seq_len: usize = undefined;

        if (byte < 0x80) {
            codepoint = byte;
            seq_len = 1;
        } else if (byte & 0xE0 == 0xC0) {
            if (i + 1 >= utf8.len) return null;
            codepoint = @as(u32, byte & 0x1F) << 6 | @as(u32, utf8[i + 1] & 0x3F);
            seq_len = 2;
        } else if (byte & 0xF0 == 0xE0) {
            if (i + 2 >= utf8.len) return null;
            codepoint = @as(u32, byte & 0x0F) << 12 |
                @as(u32, utf8[i + 1] & 0x3F) << 6 |
                @as(u32, utf8[i + 2] & 0x3F);
            seq_len = 3;
        } else if (byte & 0xF8 == 0xF0) {
            if (i + 3 >= utf8.len) return null;
            codepoint = @as(u32, byte & 0x07) << 18 |
                @as(u32, utf8[i + 1] & 0x3F) << 12 |
                @as(u32, utf8[i + 2] & 0x3F) << 6 |
                @as(u32, utf8[i + 3] & 0x3F);
            seq_len = 4;
        } else {
            return null; // Invalid UTF-8 start byte
        }

        i += seq_len;

        // Convert to path separators: '/' → '\' on Windows
        if (codepoint == '/') codepoint = '\\';

        // Encode as UTF-16
        if (codepoint <= 0xFFFF) {
            if (o >= out.len) return null;
            out[o] = @intCast(codepoint);
            o += 1;
        } else {
            // Surrogate pair
            if (o + 1 >= out.len) return null;
            const cp = codepoint - 0x10000;
            out[o] = @intCast(0xD800 + (cp >> 10));
            out[o + 1] = @intCast(0xDC00 + (cp & 0x3FF));
            o += 2;
        }
    }

    // Null-terminate
    if (o >= out.len) return null;
    out[o] = 0;
    return o;
}

/// Convert a UTF-16LE buffer to UTF-8. Returns the number of bytes written,
/// or null if the buffer is too small.
pub fn wideToUtf8(wide: []const u16, out: []u8) ?usize {
    var i: usize = 0;
    var o: usize = 0;
    while (i < wide.len) {
        const cu = wide[i];
        if (cu == 0) break; // null terminator
        var codepoint: u32 = undefined;

        if (cu >= 0xD800 and cu <= 0xDBFF) {
            // High surrogate — need low surrogate
            if (i + 1 >= wide.len) return null;
            const low = wide[i + 1];
            if (low < 0xDC00 or low > 0xDFFF) return null;
            codepoint = 0x10000 + (@as(u32, cu - 0xD800) << 10) + @as(u32, low - 0xDC00);
            i += 2;
        } else {
            codepoint = cu;
            i += 1;
        }

        // Convert '\' → '/' for platform-neutral paths (caller can decide)
        // Actually, keep as-is — callers should handle separators.

        // Encode as UTF-8
        if (codepoint < 0x80) {
            if (o >= out.len) return null;
            out[o] = @intCast(codepoint);
            o += 1;
        } else if (codepoint < 0x800) {
            if (o + 1 >= out.len) return null;
            out[o] = @intCast(0xC0 | (codepoint >> 6));
            out[o + 1] = @intCast(0x80 | (codepoint & 0x3F));
            o += 2;
        } else if (codepoint < 0x10000) {
            if (o + 2 >= out.len) return null;
            out[o] = @intCast(0xE0 | (codepoint >> 12));
            out[o + 1] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
            out[o + 2] = @intCast(0x80 | (codepoint & 0x3F));
            o += 3;
        } else {
            if (o + 3 >= out.len) return null;
            out[o] = @intCast(0xF0 | (codepoint >> 18));
            out[o + 1] = @intCast(0x80 | ((codepoint >> 12) & 0x3F));
            out[o + 2] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
            out[o + 3] = @intCast(0x80 | (codepoint & 0x3F));
            o += 4;
        }
    }
    return o;
}

// ══════════════════════════════════════════════════════════════════════════════
// High-level File Operations (platform-dispatching)
// ══════════════════════════════════════════════════════════════════════════════

pub const OpenError = error{ FileNotFound, AccessDenied, SystemError };

/// Open a file for reading. Path must be UTF-8 (converted to UTF-16 on Windows).
pub fn openRead(path: []const u8) OpenError!fd_t {
    if (native_os == .windows) {
        var wide_buf: [MAX_PATH_WIDE + 1]u16 = undefined;
        const len = utf8ToWide(path, &wide_buf) orelse return error.SystemError;
        _ = len;
        const wide_path: LPCWSTR = @ptrCast(&wide_buf);
        const handle = kernel32.CreateFileW(
            wide_path,
            GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            null,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (@intFromPtr(handle) == @as(usize, @bitCast(@as(isize, -1)))) {
            const err = kernel32.GetLastError();
            if (err == ERROR_FILE_NOT_FOUND or err == ERROR_PATH_NOT_FOUND) return error.FileNotFound;
            return error.AccessDenied;
        }
        return handle;
    } else {
        // POSIX: use C library open()
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) return error.SystemError;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = path_buf[0..path.len :0];

        const fd = posix.open(path_z, posix.O_RDONLY | posix.O_CLOEXEC);
        if (fd < 0) {
            return error.FileNotFound;
        }
        return fd;
    }
}

/// Create or truncate a file for writing.
pub fn openWrite(path: []const u8) OpenError!fd_t {
    if (native_os == .windows) {
        var wide_buf: [MAX_PATH_WIDE + 1]u16 = undefined;
        const len = utf8ToWide(path, &wide_buf) orelse return error.SystemError;
        _ = len;
        const wide_path: LPCWSTR = @ptrCast(&wide_buf);
        const handle = kernel32.CreateFileW(
            wide_path,
            GENERIC_WRITE,
            FILE_SHARE_READ,
            null,
            CREATE_ALWAYS,
            FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (@intFromPtr(handle) == @as(usize, @bitCast(@as(isize, -1)))) {
            const err = kernel32.GetLastError();
            if (err == ERROR_PATH_NOT_FOUND) return error.FileNotFound;
            return error.AccessDenied;
        }
        return handle;
    } else {
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) return error.SystemError;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = path_buf[0..path.len :0];

        const flags = posix.O_WRONLY | posix.O_CREAT | posix.O_TRUNC | posix.O_CLOEXEC;
        const mode: posix.mode_t = posix.S_IRWXU | posix.S_IRWXG | posix.S_IRWXO;
        const fd = posix.open(path_z, flags, mode);
        if (fd < 0) {
            return error.AccessDenied;
        }
        return fd;
    }
}

/// Read from a file descriptor. Returns number of bytes read, or 0 on EOF/error.
pub fn readFd(fd: fd_t, buf: [*]u8, count: usize) usize {
    if (native_os == .windows) {
        var bytes_read: DWORD = 0;
        const ok = kernel32.ReadFile(fd, buf, @intCast(@min(count, 0x7FFFFFFF)), &bytes_read, null);
        if (ok == FALSE) return 0;
        return bytes_read;
    } else {
        const ret = posix.read(fd, buf, count);
        if (ret < 0) return 0;
        return @intCast(ret);
    }
}

/// Write to a file descriptor. Returns number of bytes written, or 0 on error.
pub fn writeFd(fd: fd_t, buf: [*]const u8, count: usize) usize {
    if (native_os == .windows) {
        var bytes_written: DWORD = 0;
        const ok = kernel32.WriteFile(fd, buf, @intCast(@min(count, 0x7FFFFFFF)), &bytes_written, null);
        if (ok == FALSE) return 0;
        return bytes_written;
    } else {
        const ret = posix.write(fd, buf, count);
        if (ret < 0) return 0;
        return @intCast(ret);
    }
}

/// Write all bytes to a file descriptor, looping on partial writes.
/// Returns true if all bytes were written, false on error.
pub fn writeAll(fd: fd_t, data: []const u8) bool {
    var written: usize = 0;
    while (written < data.len) {
        const n = writeFd(fd, data.ptr + written, data.len - written);
        if (n == 0) return false;
        written += n;
    }
    return true;
}

/// Close a file descriptor.
pub fn closeFd(fd: fd_t) void {
    if (native_os == .windows) {
        _ = kernel32.CloseHandle(fd);
    } else {
        _ = posix.close(fd);
    }
}

/// Get file size. Returns the size in bytes, or 0 on error.
pub fn fileSize(fd: fd_t) u64 {
    if (native_os == .windows) {
        var high: DWORD = 0;
        const low = kernel32.GetFileSize(fd, &high);
        if (low == INVALID_FILE_SIZE and kernel32.GetLastError() != 0) return 0;
        return @as(u64, high) << 32 | @as(u64, low);
    } else {
        var st: posix.Stat = undefined;
        const ret = posix.fstat(fd, &st);
        if (ret != 0) return 0;
        return @intCast(@max(st.st_size, 0));
    }
}

/// Get stdout file descriptor.
pub fn stdoutFd() fd_t {
    if (native_os == .windows) {
        return kernel32.GetStdHandle(STD_OUTPUT_HANDLE);
    } else {
        return 1;
    }
}

/// Get stderr file descriptor.
pub fn stderrFd() fd_t {
    if (native_os == .windows) {
        return kernel32.GetStdHandle(STD_ERROR_HANDLE);
    } else {
        return 2;
    }
}

/// Get stdin file descriptor.
pub fn stdinFd() fd_t {
    if (native_os == .windows) {
        return kernel32.GetStdHandle(STD_INPUT_HANDLE);
    } else {
        return 0;
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Directory Operations
// ══════════════════════════════════════════════════════════════════════════════

/// Create a single directory. Returns true on success or if already exists.
pub fn mkdir(path: []const u8) bool {
    if (native_os == .windows) {
        var wide_buf: [MAX_PATH_WIDE + 1]u16 = undefined;
        const len = utf8ToWide(path, &wide_buf) orelse return false;
        _ = len;
        const wide_path: LPCWSTR = @ptrCast(&wide_buf);
        const ok = kernel32.CreateDirectoryW(wide_path, null);
        if (ok == FALSE) {
            return kernel32.GetLastError() == ERROR_ALREADY_EXISTS;
        }
        return true;
    } else {
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) return false;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = path_buf[0..path.len :0];

        const ret = posix.mkdir(path_z, posix.S_IRWXU | posix.S_IRWXG | posix.S_IRWXO);
        if (ret != 0) {
            // EEXIST (17) is fine — directory already exists
            // We can't reliably distinguish errno without errno access,
            // but if the path exists, consider success.
            return pathExists(path);
        }
        return true;
    }
}

/// Create a directory path recursively (mkdir -p equivalent).
/// Walks the path and creates each component.
pub fn mkdirRecursive(path: []const u8) bool {
    if (path.len == 0) return false;

    // Try the fast path first — maybe the directory already exists
    if (pathExists(path)) return true;

    // Walk the path creating each component
    var i: usize = 0;

    // Skip leading separator or drive letter on Windows
    if (native_os == .windows) {
        // Skip "C:\" or similar drive prefix
        if (path.len >= 3 and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) {
            i = 3;
        } else if (path.len >= 2 and (path[0] == '\\' or path[0] == '/') and (path[1] == '\\' or path[1] == '/')) {
            // UNC path: skip \\server\share
            i = 2;
            // Find end of server name
            while (i < path.len and path[i] != '\\' and path[i] != '/') : (i += 1) {}
            if (i < path.len) i += 1;
            // Find end of share name
            while (i < path.len and path[i] != '\\' and path[i] != '/') : (i += 1) {}
            if (i < path.len) i += 1;
        } else if (path[0] == '\\' or path[0] == '/') {
            i = 1;
        }
    } else {
        if (path[0] == '/') i = 1;
    }

    while (i <= path.len) {
        // Find next separator or end
        while (i < path.len and path[i] != '/' and path[i] != '\\') : (i += 1) {}

        if (i > 0) {
            const component = path[0..i];
            if (!pathExists(component)) {
                if (!mkdir(component)) return false;
            }
        }

        i += 1; // skip separator
    }

    return true;
}

/// Check if a path exists (file or directory).
pub fn pathExists(path: []const u8) bool {
    if (native_os == .windows) {
        var wide_buf: [MAX_PATH_WIDE + 1]u16 = undefined;
        const len = utf8ToWide(path, &wide_buf) orelse return false;
        _ = len;
        const wide_path: LPCWSTR = @ptrCast(&wide_buf);
        const attrs = kernel32.GetFileAttributesW(wide_path);
        return attrs != 0xFFFFFFFF; // INVALID_FILE_ATTRIBUTES
    } else {
        // Use open with O_RDONLY to check existence, then close
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) return false;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = path_buf[0..path.len :0];

        const fd = posix.open(path_z, posix.O_RDONLY | posix.O_CLOEXEC);
        if (fd < 0) return false;
        _ = posix.close(fd);
        return true;
    }
}

/// Get the current working directory into a caller-provided buffer.
/// Returns the slice of the buffer containing the path, or null on failure.
pub fn getCwd(buf: []u8) ?[]u8 {
    if (native_os == .windows) {
        var wide_buf: [MAX_PATH_WIDE]u16 = undefined;
        const n = kernel32.GetCurrentDirectoryW(@intCast(wide_buf.len), @ptrCast(&wide_buf));
        if (n == 0) return null;
        const wide_slice = wide_buf[0..n];
        const utf8_len = wideToUtf8(wide_slice, buf) orelse return null;
        return buf[0..utf8_len];
    } else {
        const result = posix.getcwd(buf.ptr, buf.len);
        if (result == null) return null;
        // getcwd returns a pointer to buf on success, with null-terminated string
        var len: usize = 0;
        while (len < buf.len and buf[len] != 0) : (len += 1) {}
        if (len == 0) return null;
        return buf[0..len];
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Threading
// ══════════════════════════════════════════════════════════════════════════════

pub const ThreadHandle = if (native_os == .windows) HANDLE else u64;

/// Thread start function type for cross-platform thread creation.
/// The thread function receives an opaque context pointer.
pub const ThreadFn = *const fn (?*anyopaque) void;

/// Spawn a new OS thread that executes `func(arg)`.
/// Returns the thread handle on success, or null on failure.
pub fn threadSpawn(func: ThreadFn, arg: ?*anyopaque) ?ThreadHandle {
    if (native_os == .windows) {
        const Wrapper = struct {
            fn threadProc(param: ?LPVOID) callconv(.winapi) DWORD {
                const ctx: *ThreadCtx = @ptrCast(@alignCast(param.?));
                ctx.func(ctx.arg);
                return 0;
            }
        };

        // We need a small trampoline struct on a stable address.
        // Use a static pool of thread contexts (bounded by MAX_THREADS).
        const ctx = allocThreadCtx(func, arg) orelse return null;
        const handle = kernel32.CreateThread(
            null,
            0, // default stack size
            &Wrapper.threadProc,
            @ptrCast(ctx),
            0, // run immediately
            null,
        );
        return handle;
    } else {
        const Wrapper = struct {
            fn threadStart(param: ?*anyopaque) callconv(.c) ?*anyopaque {
                const ctx: *ThreadCtx = @ptrCast(@alignCast(param.?));
                ctx.func(ctx.arg);
                return null;
            }
        };

        const ctx = allocThreadCtx(func, arg) orelse return null;
        var tid: u64 = 0;
        const ret = posix.pthread_create(&tid, null, &Wrapper.threadStart, @ptrCast(ctx));
        if (ret != 0) return null;
        return tid;
    }
}

/// Wait for a thread to finish.
pub fn threadJoin(handle: ThreadHandle) void {
    if (native_os == .windows) {
        _ = kernel32.WaitForSingleObject(handle, INFINITE);
        _ = kernel32.CloseHandle(handle);
    } else {
        _ = posix.pthread_join(handle, null);
    }
}

// Thread context pool — fixed capacity for the build runner's thread pool.
const MAX_THREAD_CONTEXTS = 128;

const ThreadCtx = struct {
    func: ThreadFn,
    arg: ?*anyopaque,
    in_use: bool = false,
};

fn noopThreadFn(_: ?*anyopaque) void {}

var thread_ctx_pool: [MAX_THREAD_CONTEXTS]ThreadCtx = @as([MAX_THREAD_CONTEXTS]ThreadCtx, @splat(.{
    .func = &noopThreadFn,
    .arg = null,
    .in_use = false,
}));

fn allocThreadCtx(func: ThreadFn, arg: ?*anyopaque) ?*ThreadCtx {
    for (&thread_ctx_pool) |*ctx| {
        if (!ctx.in_use) {
            ctx.func = func;
            ctx.arg = arg;
            ctx.in_use = true;
            return ctx;
        }
    }
    return null;
}

// ══════════════════════════════════════════════════════════════════════════════
// Synchronization — Mutex
// ══════════════════════════════════════════════════════════════════════════════

pub const MutexImpl = if (native_os == .windows) struct {
    srwlock: SRWLOCK = SRWLOCK_INIT,

    pub fn lock(self: *MutexImpl) void {
        kernel32.AcquireSRWLockExclusive(&self.srwlock);
    }

    pub fn unlock(self: *MutexImpl) void {
        kernel32.ReleaseSRWLockExclusive(&self.srwlock);
    }
} else struct {
    // Pthread-based mutex for POSIX hosts
    pmutex: posix.PthreadMutex = .{},

    pub fn lock(self: *MutexImpl) void {
        _ = posix.pthread_mutex_lock(&self.pmutex);
    }

    pub fn unlock(self: *MutexImpl) void {
        _ = posix.pthread_mutex_unlock(&self.pmutex);
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Synchronization — Condition Variable
// ══════════════════════════════════════════════════════════════════════════════

pub const ConditionImpl = if (native_os == .windows) struct {
    cond_var: CONDITION_VARIABLE = CONDITION_VARIABLE_INIT,

    pub fn wait(self: *ConditionImpl, mutex: *MutexImpl) void {
        _ = kernel32.SleepConditionVariableSRW(
            &self.cond_var,
            &mutex.srwlock,
            INFINITE,
            0,
        );
    }

    pub fn signal(self: *ConditionImpl) void {
        kernel32.WakeConditionVariable(&self.cond_var);
    }

    pub fn broadcast(self: *ConditionImpl) void {
        kernel32.WakeAllConditionVariable(&self.cond_var);
    }
} else struct {
    // Pthread-based condition variable for POSIX hosts
    pcond: posix.PthreadCond = .{},

    pub fn wait(self: *ConditionImpl, mutex: *MutexImpl) void {
        _ = posix.pthread_cond_wait(&self.pcond, &mutex.pmutex);
    }

    pub fn signal(self: *ConditionImpl) void {
        _ = posix.pthread_cond_signal(&self.pcond);
    }

    pub fn broadcast(self: *ConditionImpl) void {
        _ = posix.pthread_cond_broadcast(&self.pcond);
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Clock
// ══════════════════════════════════════════════════════════════════════════════

/// Returns the current monotonic time in nanoseconds.
pub fn clockMonotonicNs() i64 {
    if (native_os == .windows) {
        var counter: LARGE_INTEGER = 0;
        var frequency: LARGE_INTEGER = 0;
        _ = kernel32.QueryPerformanceCounter(&counter);
        _ = kernel32.QueryPerformanceFrequency(&frequency);
        if (frequency == 0) return 0;
        // Convert to nanoseconds: counter * 1_000_000_000 / frequency
        // Use 128-bit math to avoid overflow
        const ns_per_sec: i64 = 1_000_000_000;
        // Split to avoid overflow: (counter / freq) * 1e9 + (counter % freq) * 1e9 / freq
        const whole = @divTrunc(counter, frequency) * ns_per_sec;
        const remainder = @mod(counter, frequency) * ns_per_sec;
        return whole + @divTrunc(remainder, frequency);
    } else {
        var ts: posix.timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
        _ = posix.clock_gettime(posix.CLOCK_MONOTONIC, &ts);
        return ts.tv_sec * 1_000_000_000 + ts.tv_nsec;
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Process Control
// ══════════════════════════════════════════════════════════════════════════════

/// Terminate the current process with the given exit code. Does not return.
pub fn exitProcess(code: u8) noreturn {
    if (native_os == .windows) {
        kernel32.ExitProcess(code);
    } else {
        posix._exit(@intCast(code));
    }
}
