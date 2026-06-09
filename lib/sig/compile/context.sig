// Compilation_Context — Stack-allocated parameter accumulator for in-process compilation.
//
// Collects all compilation parameters (root source, modules, C++ sources, flags,
// libraries, target, optimization mode) before handing off to the Compilation_Engine.
// All storage is fixed-size — zero heap allocations.

const std = @import("std");
const types = @import("types.sig");
const target_mod = @import("target.sig");

const Target_Triple = target_mod.Target_Triple;
const Module_Decl = types.Module_Decl;
const Cpp_Source = types.Cpp_Source;
const Flag_Entry = types.Flag_Entry;
const Path_Entry = types.Path_Entry;
const Name_Entry = types.Name_Entry;
const Define_Entry = types.Define_Entry;
const Optimize_Mode = types.Optimize_Mode;
const Output_Mode = types.Output_Mode;
const Emit_Mode = types.Emit_Mode;

/// Stack-allocated struct that accumulates all compilation parameters before
/// invoking the Compilation_Engine. Replaces command-line argument construction.
pub const Compilation_Context = struct {
    // ── Source ──

    /// Root source file path (e.g., `src/main.zig`)
    root_source_path: [types.PATH_BUF_SIZE]u8 = undefined,
    root_source_path_len: usize = 0,

    /// Output artifact name (e.g., `sig`)
    output_name: [types.NAME_BUF_SIZE]u8 = undefined,
    output_name_len: usize = 0,

    // ── Target ──

    /// Cross-compilation target triple — defaults to native
    target: Target_Triple = .{},

    // ── Mode ──

    /// Optimization level for the compilation
    optimize: Optimize_Mode = .Debug,
    /// Strip debug info from the output binary
    strip: bool = false,
    /// Build as single-threaded (disables thread safety checks)
    single_threaded: bool = false,

    // ── Output ──

    /// Type of output artifact to produce
    output_mode: Output_Mode = .Exe,
    /// Whether to emit binary output (cached or suppressed)
    emit_bin: Emit_Mode = .yes_cache,

    // ── Modules ──

    /// Named module declarations with source paths and dependency lists
    modules: [types.MAX_MODULES]Module_Decl = undefined,
    module_count: usize = 0,

    // ── C/C++ Sources ──

    /// C/C++ source files to compile via internal Clang
    cpp_sources: [types.MAX_CPP_SOURCES]Cpp_Source = undefined,
    cpp_source_count: usize = 0,

    // ── Compiler Flags (shared across C++ sources) ──

    /// Shared compiler flags applied to all C++ source files
    shared_flags: [types.MAX_COMPILER_FLAGS]Flag_Entry = undefined,
    shared_flag_count: usize = 0,

    // ── Include Directories ──

    /// Include search paths for C/C++ header resolution
    include_dirs: [types.MAX_INCLUDE_DIRS]Path_Entry = undefined,
    include_dir_count: usize = 0,

    // ── Preprocessor Definitions ──

    /// Preprocessor definitions passed to C/C++ compilation
    definitions: [types.MAX_PREPROCESSOR_DEFS]Define_Entry = undefined,
    definition_count: usize = 0,

    // ── Libraries ──

    /// Filesystem paths to search for static libraries
    lib_search_paths: [types.MAX_LIB_SEARCH_DIRS]Path_Entry = undefined,
    lib_search_path_count: usize = 0,

    /// Static library names to link (e.g., `LLVMCore`, `clangAST`)
    static_libs: [types.MAX_LLVM_LIBS]Name_Entry = undefined,
    static_lib_count: usize = 0,

    /// System library names to link (e.g., `pthread`, `dl`, `m`)
    system_libs: [types.MAX_SYSTEM_LIBS]Name_Entry = undefined,
    system_lib_count: usize = 0,

    // ── Linking ──

    /// Link the target platform's C standard library
    link_libc: bool = false,
    /// Link the target platform's C++ standard library
    link_libcpp: bool = false,

    // ── Directories ──

    /// Path to the Zig standard library directory
    zig_lib_dir: [types.PATH_BUF_SIZE]u8 = undefined,
    zig_lib_dir_len: usize = 0,

    /// Path to the local build cache directory
    cache_dir: [types.PATH_BUF_SIZE]u8 = undefined,
    cache_dir_len: usize = 0,

    /// Path to the global shared cache directory
    global_cache_dir: [types.PATH_BUF_SIZE]u8 = undefined,
    global_cache_dir_len: usize = 0,

    // ── Thread Control ──

    /// Maximum number of threads for parallel compilation (0 = auto-detect)
    thread_limit: usize = 0,

    // ── Verbose Flags ──

    /// Emit verbose C/C++ compiler invocation details
    verbose_cc: bool = false,
    /// Emit verbose linker invocation details
    verbose_link: bool = false,

    // ── Compilation Backend ──

    /// Function pointer to the actual compilation implementation.
    /// Set by the build runner to a function that calls Compilation.create() + update().
    /// When null, execute() returns an error.
    compile_fn: ?*const fn (*Compilation_Context, std.Io) types.Compilation_Result = null,

    /// Path to the compiler binary (used for self_exe_path in Compilation.create).
    compiler_path: [types.PATH_BUF_SIZE]u8 = undefined,
    compiler_path_len: usize = 0,

    /// Opaque pointer to the process environment map (*const std.process.Environ.Map).
    /// Set by the build runner before invoking compile steps. Required by
    /// Compilation.create() for system tool discovery.
    environ_map_ptr: ?*const anyopaque = null,

    // ── Builder Methods ──

    /// Set the root source file path for compilation.
    /// Returns `error.BufferTooSmall` if the path exceeds `PATH_BUF_SIZE`.
    pub fn setRootSource(self: *Compilation_Context, path: []const u8) error{BufferTooSmall}!void {
        if (path.len > types.PATH_BUF_SIZE) return error.BufferTooSmall;
        @memcpy(self.root_source_path[0..path.len], path);
        self.root_source_path_len = path.len;
    }

    /// Set the output artifact name.
    /// Returns `error.BufferTooSmall` if the name exceeds `NAME_BUF_SIZE`.
    pub fn setOutputName(self: *Compilation_Context, name: []const u8) error{BufferTooSmall}!void {
        if (name.len > types.NAME_BUF_SIZE) return error.BufferTooSmall;
        @memcpy(self.output_name[0..name.len], name);
        self.output_name_len = name.len;
    }

    /// Register a named module declaration.
    /// Returns `error.CapacityExceeded` if the module list is full.
    pub fn addModule(self: *Compilation_Context, decl: Module_Decl) error{CapacityExceeded}!void {
        if (self.module_count >= types.MAX_MODULES) return error.CapacityExceeded;
        self.modules[self.module_count] = decl;
        self.module_count += 1;
    }

    /// Register a C/C++ source file for compilation.
    /// Returns `error.CapacityExceeded` if the source list is full.
    pub fn addCppSource(self: *Compilation_Context, src: Cpp_Source) error{CapacityExceeded}!void {
        if (self.cpp_source_count >= types.MAX_CPP_SOURCES) return error.CapacityExceeded;
        self.cpp_sources[self.cpp_source_count] = src;
        self.cpp_source_count += 1;
    }

    /// Add a shared compiler flag applied to all C++ sources.
    /// Returns `error.CapacityExceeded` if the flag list is full.
    /// Returns `error.BufferTooSmall` if the flag value exceeds `VALUE_BUF_SIZE`.
    pub fn addSharedFlag(self: *Compilation_Context, flag: []const u8) error{ CapacityExceeded, BufferTooSmall }!void {
        if (self.shared_flag_count >= types.MAX_COMPILER_FLAGS) return error.CapacityExceeded;
        if (flag.len > types.VALUE_BUF_SIZE) return error.BufferTooSmall;
        var entry: Flag_Entry = .{};
        @memcpy(entry.value[0..flag.len], flag);
        entry.value_len = flag.len;
        self.shared_flags[self.shared_flag_count] = entry;
        self.shared_flag_count += 1;
    }

    /// Add an include directory path for C/C++ header resolution.
    /// Returns `error.CapacityExceeded` if the include directory list is full.
    /// Returns `error.BufferTooSmall` if the path exceeds `PATH_BUF_SIZE`.
    pub fn addIncludeDir(self: *Compilation_Context, path: []const u8) error{ CapacityExceeded, BufferTooSmall }!void {
        if (self.include_dir_count >= types.MAX_INCLUDE_DIRS) return error.CapacityExceeded;
        if (path.len > types.PATH_BUF_SIZE) return error.BufferTooSmall;
        var entry: Path_Entry = .{};
        @memcpy(entry.path[0..path.len], path);
        entry.path_len = path.len;
        self.include_dirs[self.include_dir_count] = entry;
        self.include_dir_count += 1;
    }

    /// Add a preprocessor definition for C/C++ compilation.
    /// Returns `error.CapacityExceeded` if the definition list is full.
    /// Returns `error.BufferTooSmall` if name or value exceeds their respective buffer sizes.
    pub fn addDefinition(self: *Compilation_Context, name: []const u8, value: []const u8) error{ CapacityExceeded, BufferTooSmall }!void {
        if (self.definition_count >= types.MAX_PREPROCESSOR_DEFS) return error.CapacityExceeded;
        if (name.len > types.NAME_BUF_SIZE) return error.BufferTooSmall;
        if (value.len > types.VALUE_BUF_SIZE) return error.BufferTooSmall;
        var entry: Define_Entry = .{};
        @memcpy(entry.name[0..name.len], name);
        entry.name_len = name.len;
        @memcpy(entry.value[0..value.len], value);
        entry.value_len = value.len;
        self.definitions[self.definition_count] = entry;
        self.definition_count += 1;
    }

    /// Add a library search path for static library resolution.
    /// Returns `error.CapacityExceeded` if the search path list is full.
    /// Returns `error.BufferTooSmall` if the path exceeds `PATH_BUF_SIZE`.
    pub fn addLibSearchPath(self: *Compilation_Context, path: []const u8) error{ CapacityExceeded, BufferTooSmall }!void {
        if (self.lib_search_path_count >= types.MAX_LIB_SEARCH_DIRS) return error.CapacityExceeded;
        if (path.len > types.PATH_BUF_SIZE) return error.BufferTooSmall;
        var entry: Path_Entry = .{};
        @memcpy(entry.path[0..path.len], path);
        entry.path_len = path.len;
        self.lib_search_paths[self.lib_search_path_count] = entry;
        self.lib_search_path_count += 1;
    }

    /// Add a static library name to link (e.g., `LLVMCore`, `clangAST`).
    /// Returns `error.CapacityExceeded` if the static library list is full.
    /// Returns `error.BufferTooSmall` if the name exceeds `NAME_BUF_SIZE`.
    pub fn addStaticLib(self: *Compilation_Context, name: []const u8) error{ CapacityExceeded, BufferTooSmall }!void {
        if (self.static_lib_count >= types.MAX_LLVM_LIBS) return error.CapacityExceeded;
        if (name.len > types.NAME_BUF_SIZE) return error.BufferTooSmall;
        var entry: Name_Entry = .{};
        @memcpy(entry.name[0..name.len], name);
        entry.name_len = name.len;
        self.static_libs[self.static_lib_count] = entry;
        self.static_lib_count += 1;
    }

    /// Add a system library name to link (e.g., `pthread`, `dl`, `m`).
    /// Returns `error.CapacityExceeded` if the system library list is full.
    /// Returns `error.BufferTooSmall` if the name exceeds `NAME_BUF_SIZE`.
    pub fn addSystemLib(self: *Compilation_Context, name: []const u8) error{ CapacityExceeded, BufferTooSmall }!void {
        if (self.system_lib_count >= types.MAX_SYSTEM_LIBS) return error.CapacityExceeded;
        if (name.len > types.NAME_BUF_SIZE) return error.BufferTooSmall;
        var entry: Name_Entry = .{};
        @memcpy(entry.name[0..name.len], name);
        entry.name_len = name.len;
        self.system_libs[self.system_lib_count] = entry;
        self.system_lib_count += 1;
    }

    // ── Directory Setters ──

    /// Set the Zig standard library directory path.
    /// Returns `error.BufferTooSmall` if the path exceeds `PATH_BUF_SIZE`.
    pub fn setZigLibDir(self: *Compilation_Context, path: []const u8) error{BufferTooSmall}!void {
        if (path.len > types.PATH_BUF_SIZE) return error.BufferTooSmall;
        @memcpy(self.zig_lib_dir[0..path.len], path);
        self.zig_lib_dir_len = path.len;
    }

    /// Set the local build cache directory path.
    /// Returns `error.BufferTooSmall` if the path exceeds `PATH_BUF_SIZE`.
    pub fn setCacheDir(self: *Compilation_Context, path: []const u8) error{BufferTooSmall}!void {
        if (path.len > types.PATH_BUF_SIZE) return error.BufferTooSmall;
        @memcpy(self.cache_dir[0..path.len], path);
        self.cache_dir_len = path.len;
    }

    /// Set the global shared cache directory path.
    /// Returns `error.BufferTooSmall` if the path exceeds `PATH_BUF_SIZE`.
    pub fn setGlobalCacheDir(self: *Compilation_Context, path: []const u8) error{BufferTooSmall}!void {
        if (path.len > types.PATH_BUF_SIZE) return error.BufferTooSmall;
        @memcpy(self.global_cache_dir[0..path.len], path);
        self.global_cache_dir_len = path.len;
    }
};
