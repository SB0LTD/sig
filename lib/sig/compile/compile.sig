// compile.sig — Entry point for lib/sig/compile/
//
// Single import path for the build runner: @import("compile")
// Re-exports all public types from the compilation engine module.

// ── Engine ──

pub const Compilation_Engine = @import("engine.sig").Compilation_Engine;

// ── Context ──

pub const Compilation_Context = @import("context.sig").Compilation_Context;

// ── Target ──

const target_mod = @import("target.sig");
pub const Target_Triple = target_mod.Target_Triple;
pub const ResolvedTarget = target_mod.ResolvedTarget;

// ── Diagnostics ──

const diag_mod = @import("diagnostics.sig");
pub const Diagnostic = diag_mod.Diagnostic;
pub const Diagnostic_Buffer = diag_mod.Diagnostic_Buffer;
pub const captureDiagnostic = diag_mod.captureDiagnostic;

// ── Supporting Types ──

const types = @import("types.sig");

pub const Flag_Entry = types.Flag_Entry;
pub const Path_Entry = types.Path_Entry;
pub const Name_Entry = types.Name_Entry;
pub const Define_Entry = types.Define_Entry;
pub const Cpp_Source = types.Cpp_Source;
pub const Module_Decl = types.Module_Decl;
pub const Optimize_Mode = types.Optimize_Mode;
pub const Output_Mode = types.Output_Mode;
pub const Emit_Mode = types.Emit_Mode;

// ── Capacity Constants ──

pub const Capacity_Plan = types.Capacity_Plan;
pub const PATH_BUF_SIZE = types.PATH_BUF_SIZE;
pub const NAME_BUF_SIZE = types.NAME_BUF_SIZE;
pub const VALUE_BUF_SIZE = types.VALUE_BUF_SIZE;
pub const MAX_MODULES = types.MAX_MODULES;
pub const MAX_CPP_SOURCES = types.MAX_CPP_SOURCES;
pub const MAX_COMPILER_FLAGS = types.MAX_COMPILER_FLAGS;
pub const MAX_INCLUDE_DIRS = types.MAX_INCLUDE_DIRS;
pub const MAX_PREPROCESSOR_DEFS = types.MAX_PREPROCESSOR_DEFS;
pub const MAX_LIB_SEARCH_DIRS = types.MAX_LIB_SEARCH_DIRS;
pub const MAX_LLVM_LIBS = types.MAX_LLVM_LIBS;
pub const MAX_SYSTEM_LIBS = types.MAX_SYSTEM_LIBS;
pub const MAX_IMPORTS_PER_MODULE = types.MAX_IMPORTS_PER_MODULE;
pub const MAX_DIAGNOSTICS = types.MAX_DIAGNOSTICS;
pub const DIAGNOSTIC_BUF_SIZE = types.DIAGNOSTIC_BUF_SIZE;
pub const MAX_CACHE_ENTRIES = types.MAX_CACHE_ENTRIES;

// ── Cache ──

pub const Content_Hash_Cache = @import("cache.sig").Content_Hash_Cache;
