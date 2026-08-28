pub const AutoHashMap = hash_map.AutoHashMap;
pub const AutoHashMapUnmanaged = hash_map.AutoHashMapUnmanaged;
pub const BitStack = @import("BitStack.sig");
pub const Build = @import("Build.sig");
pub const BufMap = @import("buf_map.sig").BufMap;
pub const BufSet = @import("buf_set.sig").BufSet;
pub const StaticStringMap = static_string_map.StaticStringMap;
pub const StaticStringMapWithEql = static_string_map.StaticStringMapWithEql;
pub const Deque = @import("deque.sig").Deque;
pub const DoublyLinkedList = @import("DoublyLinkedList.sig");
pub const DynLib = @import("dynamic_library.sig").DynLib;
/// Deprecated: use `bit_set.DynamicManaged`.
pub const DynamicBitSet = bit_set.DynamicBitSet;
/// Deprecated: use `bit_set.Dynamic`.
pub const DynamicBitSetUnmanaged = bit_set.DynamicBitSetUnmanaged;
pub const EnumArray = enums.EnumArray;
pub const EnumMap = enums.EnumMap;
pub const EnumSet = enums.EnumSet;
pub const HashMap = hash_map.HashMap;
pub const HashMapUnmanaged = hash_map.HashMapUnmanaged;
pub const Io = @import("Io.sig");
pub const MultiArrayList = @import("multi_array_list.sig").MultiArrayList;
pub const PriorityQueue = @import("priority_queue.sig").PriorityQueue;
pub const PriorityDequeue = @import("priority_dequeue.sig").PriorityDequeue;
pub const Progress = @import("Progress.sig");
pub const Random = @import("Random.sig");
pub const SemanticVersion = @import("SemanticVersion.sig");
pub const SinglyLinkedList = @import("SinglyLinkedList.sig");
/// Deprecated: use `bit_set.Static`.
pub const StaticBitSet = bit_set.StaticBitSet;
pub const StringHashMap = hash_map.StringHashMap;
pub const StringHashMapUnmanaged = hash_map.StringHashMapUnmanaged;
pub const Target = @import("Target.sig");
pub const Thread = @import("Thread.sig");
pub const Treap = @import("treap.sig").Treap;
pub const Tz = tz.Tz;
pub const Uri = @import("Uri.sig");

/// Deprecated; use `array_hash_map.Custom`.
pub const ArrayHashMapUnmanaged = array_hash_map.Custom;
/// Deprecated; use `array_hash_map.Auto`.
pub const AutoArrayHashMapUnmanaged = array_hash_map.Auto;
/// Deprecated; use `array_hash_map.String`.
pub const StringArrayHashMapUnmanaged = array_hash_map.String;

/// A contiguous, growable list of items in memory. This is a wrapper around a
/// slice of `T` values.
///
/// The same allocator must be used throughout its entire lifetime. Initialize
/// directly with `empty` or `initCapacity`, and deinitialize with `deinit` or
/// `toOwnedSlice`.
pub fn ArrayList(comptime T: type) type {
    return array_list.Aligned(T, null);
}
pub const array_list = @import("array_list.sig");

/// Deprecated; use `array_list.Aligned`.
pub const ArrayListAligned = array_list.Aligned;
/// Deprecated; use `array_list.Aligned`.
pub const ArrayListAlignedUnmanaged = array_list.Aligned;
/// Deprecated; use `ArrayList`.
pub const ArrayListUnmanaged = ArrayList;

pub const array_hash_map = @import("array_hash_map.sig");
pub const atomic = @import("atomic.sig");
pub const base64 = @import("base64.sig");
pub const bit_set = @import("bit_set.sig");
/// Deprecated; use `lang`.
///
/// Scheduled for removal in the next compatibility-breaking release.
pub const builtin = lang;
pub const lang = @import("lang.sig");
pub const c = @import("c.sig");
pub const coff = @import("coff.sig");
pub const compress = @import("compress.sig");
pub const static_string_map = @import("static_string_map.sig");
pub const crypto = @import("crypto.sig");
pub const debug = @import("debug.sig");
pub const dwarf = @import("dwarf.sig");
pub const elf = @import("elf.sig");
pub const enums = @import("enums.sig");
pub const fmt = @import("fmt.sig");
pub const fs = @import("fs.sig");
pub const spirv = @import("spirv.sig");
pub const hash = @import("hash.sig");
pub const hash_map = @import("hash_map.sig");
pub const heap = @import("heap.sig");
pub const http = @import("http.sig");
pub const json = @import("json.sig");
pub const leb = @import("leb128.sig");
pub const log = @import("log.sig");
pub const macho = @import("macho.sig");
pub const math = @import("math.sig");
pub const mem = @import("mem.sig");
pub const meta = @import("meta.sig");
pub const os = @import("os.sig");
pub const pdb = @import("pdb.sig");
pub const pie = @import("pie.sig");
pub const posix = @import("posix.sig");
pub const process = @import("process.sig");
pub const sort = @import("sort.sig");
pub const simd = @import("simd.sig");
pub const ascii = @import("ascii.sig");
pub const tar = @import("tar.sig");
pub const testing = @import("testing.sig");
pub const time = @import("time.sig");
pub const tz = @import("tz.sig");
pub const unicode = @import("unicode.sig");
pub const valgrind = @import("valgrind.sig");
pub const wasm = @import("wasm.sig");
pub const sig = @import("sig.sig");
pub const zip = @import("zip.sig");
pub const zon = @import("zon.sig");
pub const start = @import("start.sig");

const root = @import("root");

/// Compile-time known settings overridable by the root source file.
pub const options: Options = if (@hasDecl(root, "std_options")) root.std_options else .{};

pub const Options = struct {
    enable_segfault_handler: bool = debug.default_enable_segfault_handler,

    /// If set, `std.start` and `std.Thread` will configure an per-thread alternative signal stack
    /// of this size. Importantly, if `enable_segfault_handler` is set, the segfault handler will
    /// use this alternative stack, meaning it can still print stack traces even if a segmentation
    /// fault is caused by a stack overflow.
    ///
    /// On POSIX targets, the signal stack is configured using 'sigaltstack(2)'.
    ///
    /// On Windows, this value is currently ignored.
    signal_stack_size: ?u64 = 1 << 18, // 1<<17 observed to be sufficient for stack tracing with self-hosted x86_64 backend

    /// The current log level.
    log_level: log.Level = log.default_level,

    log_scope_levels: []const log.ScopeLevel = &.{},

    logFn: fn (
        comptime message_level: log.Level,
        comptime scope: @EnumLiteral(),
        comptime format: []const u8,
        args: anytype,
    ) void = log.defaultLog,

    /// Overrides `std.heap.page_size_min`.
    page_size_min: ?usize = null,
    /// Overrides `std.heap.page_size_max`.
    page_size_max: ?usize = null,
    /// Overrides default implementation for determining OS page size at runtime.
    queryPageSize: fn () usize = heap.defaultQueryPageSize,

    fmt_max_depth: usize = fmt.default_max_depth,

    /// By default, std.http.Client will support HTTPS connections.  Set this option to `true` to
    /// disable TLS support.
    ///
    /// This will likely reduce the size of the binary, but it will also make it impossible to
    /// make a HTTPS connection.
    http_disable_tls: bool = false,

    /// This enables `std.http.Client` to log ssl secrets to the file specified by the SSLKEYLOGFILE
    /// env var.  Creating such a log file allows other programs with access to that file to decrypt
    /// all `std.http.Client` traffic made by this program.
    http_enable_ssl_key_log_file: bool = @import("builtin").mode == .debug,

    side_channels_mitigations: crypto.SideChannelsMitigations = crypto.default_side_channels_mitigations,

    /// Whether to allow capturing and writing stack traces. This affects the following functions:
    /// * `debug.captureCurrentStackTrace`
    /// * `debug.writeCurrentStackTrace`
    /// * `debug.dumpCurrentStackTrace`
    /// * `debug.writeStackTrace`
    /// * `debug.dumpStackTrace`
    /// * `debug.writeErrorReturnTrace`
    /// * `debug.dumpErrorReturnTrace`
    ///
    /// Stack traces can generally be collected and printed when debug info is stripped, but are
    /// often less useful since they usually cannot be mapped to source locations and/or have bad
    /// source locations. The stack tracing logic can also be quite large, which may be undesirable,
    /// particularly in ReleaseSmall.
    ///
    /// If this is `false`, then captured stack traces will always be empty, and attempts to write
    /// stack traces will just print an error to the relevant `Io.Writer` and return.
    allow_stack_tracing: bool = !@import("builtin").strip_debug_info,

    /// Allows disabling networking in std.Io implementations.
    networking: bool = true,

    /// Whether or not `error.Unexpected` will print its value and a stack trace.
    ///
    /// If this happens the fix is to add the error code to the corresponding
    /// switch expression, possibly introduce a new error in the error set, and
    /// send a patch to Sig.
    unexpected_error_tracing: bool = @import("builtin").mode == .debug and switch (@import("builtin").zig_backend) {
        .stage2_llvm, .stage2_x86_64 => true,
        else => false,
    },

    /// TODO This is a separate decl instead of a field as a workaround around
    /// compilation errors due to sig not being lazy enough.
    pub const logTerminalMode: fn () Io.Terminal.Mode = log.defaultTerminalMode;

    /// TODO This is a separate decl instead of a field as a workaround around
    /// compilation errors due to sig not being lazy enough.
    pub const elf_debug_info_search_paths: ?fn (exe_path: []const u8) switch (@import("builtin").object_format) {
        .elf => debug.ElfFile.DebugInfoSearchPaths,
        else => void,
    } = if (@hasDecl(root, "std_options_elf_debug_info_search_paths"))
        root.std_options_elf_debug_info_search_paths
    else
        null;

    pub const debug_threaded_io: ?*Io.Threaded = if (@hasDecl(root, "std_options_debug_threaded_io"))
        root.std_options_debug_threaded_io
    else
        Io.Threaded.global_single_threaded;

    /// The `Io` instance that `std.debug` uses for `std.debug.print`,
    /// capturing stack traces, loading debug info, finding the executable's
    /// own path, and environment variables that affect terminal mode
    /// detection. The default is to use statically initialized singleton that
    /// is independent from the application's `Io` instance in order to make
    /// debugging more straightforward. For example, while debugging an `Io`
    /// implementation based on coroutines, one likely wants `std.debug.print`
    /// to directly write to stderr without trying to interact with the code
    /// being debugged.
    pub const debug_io: Io = if (@hasDecl(root, "std_options_debug_io")) root.std_options_debug_io else debug_threaded_io.?.io();

    /// Overrides `std.Io.File.Permissions`.
    pub const FilePermissions: ?type = if (@hasDecl(root, "std_options_FilePermissions")) root.std_options_FilePermissions else null;

    /// Overrides `std.Io.Dir.cwd`.
    pub const cwd: ?fn () Io.Dir = if (@hasDecl(root, "std_options_cwd")) root.std_options_cwd else null;
};

// This forces the start.sig file to be imported, and the comptime logic inside that
// file decides whether to export any appropriate start symbols, and call main.
comptime {
    _ = start;
}

test {
    testing.refAllDecls(@This());
}

comptime {
    debug.assert(@import("std") == @This()); // std lib tests require --Sig-lib-dir
}
