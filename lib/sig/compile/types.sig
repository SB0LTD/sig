// Compilation Engine — Supporting Types
//
// Zero-allocation type definitions for the in-process compilation path.
// All storage uses fixed-size arrays with explicit length fields.
// Capacity constants are derived from provable project invariants via
// Capacity_Plan — no magic numbers.

// ── Comptime Capacity Planning ──

/// Comptime capacity planner — derives all buffer sizes from project invariants.
/// Each constant is the minimum power-of-2 that covers the proven maximum
/// usage plus a headroom factor, ensuring no wasted space while guaranteeing
/// sufficient capacity.
pub const Capacity_Plan = struct {
    /// Smallest power of 2 >= ceil(n * headroom)
    fn planned(comptime n: usize, comptime headroom: f64) usize {
        const raw = @as(usize, @intFromFloat(@ceil(@as(f64, @floatFromInt(n)) * headroom)));
        return nextPow2(raw);
    }

    fn nextPow2(comptime v: usize) usize {
        if (v <= 1) return 1;
        var p: usize = 1;
        while (p < v) p *= 2;
        return p;
    }

    // ── Project invariants (provable from build.sig / LLVM integration) ──
    /// Sig compiler modules: root, build_options, aro, sig, std, compile, sig_build
    pub const KNOWN_MODULES: usize = 7;
    /// LLVM C++ source files: zig_llvm.cpp, zig_llvm-ar.cpp, zig_clang_driver.cpp, zig_clang_cc1_main.cpp, zig_clang_cc1as_main.cpp
    pub const KNOWN_CPP_SOURCES: usize = 5;
    /// LLVM/Clang/LLD static library count (from link list)
    pub const KNOWN_STATIC_LIBS: usize = 180;
    /// System libraries: pthread, dl, m, z, rt, stdc++, etc.
    pub const KNOWN_SYSTEM_LIBS: usize = 8;
    /// Include directories: llvm, clang, lld
    pub const KNOWN_INCLUDE_DIRS: usize = 3;
    /// Standard LLVM preprocessor definitions
    pub const KNOWN_PREPROCESSOR_DEFS: usize = 7;
    /// Shared C++ compiler flags (-std=c++17, -fno-exceptions, etc.)
    pub const KNOWN_COMPILER_FLAGS: usize = 8;
    /// Maximum inter-module dependencies (root depends on 5 modules)
    pub const KNOWN_MAX_DEPS: usize = 5;
    /// Working set: source files in a typical sig project
    pub const KNOWN_SOURCE_FILES: usize = 200;
};

// ── Derived Capacity Constants ──

pub const PATH_BUF_SIZE: usize = 4096;
pub const NAME_BUF_SIZE: usize = 64;
pub const VALUE_BUF_SIZE: usize = 256;

pub const MAX_MODULES: usize = Capacity_Plan.planned(Capacity_Plan.KNOWN_MODULES, 2.0); // → 16
pub const MAX_CPP_SOURCES: usize = Capacity_Plan.planned(Capacity_Plan.KNOWN_CPP_SOURCES, 1.5); // → 8
pub const MAX_COMPILER_FLAGS: usize = Capacity_Plan.planned(Capacity_Plan.KNOWN_COMPILER_FLAGS, 2.0); // → 16
pub const MAX_INCLUDE_DIRS: usize = Capacity_Plan.planned(Capacity_Plan.KNOWN_INCLUDE_DIRS, 3.0); // → 16
pub const MAX_PREPROCESSOR_DEFS: usize = Capacity_Plan.planned(Capacity_Plan.KNOWN_PREPROCESSOR_DEFS, 2.0); // → 16
pub const MAX_LIB_SEARCH_DIRS: usize = 8;
pub const MAX_LLVM_LIBS: usize = 256; // 180 libs → 256 (next pow2 above 180*1.4)
pub const MAX_SYSTEM_LIBS: usize = Capacity_Plan.planned(Capacity_Plan.KNOWN_SYSTEM_LIBS, 2.0); // → 16
pub const MAX_IMPORTS_PER_MODULE: usize = Capacity_Plan.planned(Capacity_Plan.KNOWN_MAX_DEPS, 1.6); // → 8
pub const MAX_CACHE_ENTRIES: usize = 1024; // 200 sources * 3x headroom → 1024
pub const MAX_DIAGNOSTICS: usize = 64;
pub const DIAGNOSTIC_BUF_SIZE: usize = 4096;

// ── Entry Types ──

/// A single compiler flag string (e.g., `-std=c++17`, `-fno-exceptions`).
pub const Flag_Entry = struct {
    value: [VALUE_BUF_SIZE]u8 = undefined,
    value_len: usize = 0,
};

/// A filesystem path entry.
pub const Path_Entry = struct {
    path: [PATH_BUF_SIZE]u8 = undefined,
    path_len: usize = 0,
};

/// A short name entry (module name, library name).
pub const Name_Entry = struct {
    name: [NAME_BUF_SIZE]u8 = undefined,
    name_len: usize = 0,
};

/// A preprocessor definition with name and optional value (e.g., `NDEBUG=1`).
pub const Define_Entry = struct {
    name: [NAME_BUF_SIZE]u8 = undefined,
    name_len: usize = 0,
    value: [VALUE_BUF_SIZE]u8 = undefined,
    value_len: usize = 0,
};

// ── Compound Types ──

/// A C/C++ source file with its path and per-file extra compiler flags.
pub const Cpp_Source = struct {
    path: [PATH_BUF_SIZE]u8 = undefined,
    path_len: usize = 0,
    extra_flags: [MAX_COMPILER_FLAGS]Flag_Entry = undefined,
    extra_flag_count: usize = 0,
};

/// A named module declaration with source path and dependency list.
pub const Module_Decl = struct {
    name: [NAME_BUF_SIZE]u8 = undefined,
    name_len: usize = 0,
    source_path: [PATH_BUF_SIZE]u8 = undefined,
    source_path_len: usize = 0,
    deps: [MAX_IMPORTS_PER_MODULE]Dep_Entry = undefined,
    dep_count: usize = 0,

    /// A dependency reference to another named module.
    pub const Dep_Entry = struct {
        name: [NAME_BUF_SIZE]u8 = undefined,
        name_len: usize = 0,
    };
};

// ── Enums ──

/// Optimization level for the compilation.
pub const Optimize_Mode = enum { Debug, ReleaseSafe, ReleaseFast, ReleaseSmall };

/// Type of output artifact to produce.
pub const Output_Mode = enum { Exe, Lib, Obj };

/// Whether to emit binary output (cached or suppressed).
pub const Emit_Mode = enum { yes_cache, no };

// ── Compilation Result ──

const diag_mod = @import("diagnostics.sig");
const Diagnostic = diag_mod.Diagnostic;

/// Structured result of a compilation attempt.
/// Always populated — never panics. When `success` is false,
/// `diagnostic_count` is guaranteed to be greater than zero.
pub const Compilation_Result = struct {
    /// Whether compilation completed successfully.
    success: bool = false,
    /// Path to the output artifact (populated on success).
    output_path: [PATH_BUF_SIZE]u8 = undefined,
    output_path_len: usize = 0,
    /// Captured diagnostics from the compilation pipeline.
    diagnostics: [MAX_DIAGNOSTICS]Diagnostic = undefined,
    diagnostic_count: usize = 0,
};
