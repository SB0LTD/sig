// Compilation_Engine — In-process compilation execution core.
//
// Provides validation, cc_argv construction, and the execute() entry point.
// The actual compilation call (Compilation.create + update) is provided via
// a function pointer (`compile_fn`) set by the build runner. This allows the
// engine module to compile without importing compiler internals directly —
// the build runner (which IS compiled with the compiler module wired) provides
// the implementation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const types = @import("types.sig");
const context_mod = @import("context.sig");
const diag_mod = @import("diagnostics.sig");
const target_mod = @import("target.sig");

const Compilation_Context = context_mod.Compilation_Context;
const Diagnostic = diag_mod.Diagnostic;
const Diagnostic_Buffer = diag_mod.Diagnostic_Buffer;
const captureDiagnostic = diag_mod.captureDiagnostic;
const Target_Triple = target_mod.Target_Triple;

const PATH_BUF_SIZE = types.PATH_BUF_SIZE;
const NAME_BUF_SIZE = types.NAME_BUF_SIZE;
const VALUE_BUF_SIZE = types.VALUE_BUF_SIZE;
const DIAGNOSTIC_BUF_SIZE = types.DIAGNOSTIC_BUF_SIZE;
const MAX_DIAGNOSTICS = types.MAX_DIAGNOSTICS;
const MAX_MODULES = types.MAX_MODULES;
const MAX_CPP_SOURCES = types.MAX_CPP_SOURCES;
const MAX_COMPILER_FLAGS = types.MAX_COMPILER_FLAGS;
const MAX_INCLUDE_DIRS = types.MAX_INCLUDE_DIRS;
const MAX_PREPROCESSOR_DEFS = types.MAX_PREPROCESSOR_DEFS;

/// Maximum number of cc_argv entries per C source file.
/// Accounts for shared flags + per-file extra flags + include dirs (-I) + defines (-D).
pub const MAX_CC_ARGV: usize = MAX_COMPILER_FLAGS + MAX_COMPILER_FLAGS + MAX_INCLUDE_DIRS + MAX_PREPROCESSOR_DEFS;

// ── Compilation_Engine ──

/// The Compilation Engine namespace.
/// Provides the `execute()` function that drives in-process compilation
/// from a fully-populated `Compilation_Context`.
pub const Compilation_Engine = struct {

    /// Structured result of a compilation attempt.
    /// Always populated — never panics. When `success` is false,
    /// `diagnostic_count` is guaranteed to be greater than zero.
    pub const Result = types.Compilation_Result;

    /// Function pointer type for the actual compilation backend.
    /// The build runner provides this — it calls Compilation.create() + update()
    /// using the compiler internals available in its module graph.
    pub const CompileFn = *const fn (*Compilation_Context, *Result, Io) void;

    /// Execute a compilation from a fully-populated context.
    ///
    /// This is the single entry point that replaces subprocess spawning.
    /// The function performs validation, then delegates to the `compile_fn`
    /// callback stored in the context. The callback is provided by the build
    /// runner which has access to compiler internals (Compilation, Package.Module).
    ///
    /// Never panics — all errors are caught and translated to Result with
    /// `success = false` and at least one diagnostic.
    pub fn execute(ctx: *Compilation_Context, io: Io) Result {
        var diag_buf: Diagnostic_Buffer = .{};
        var result: Result = .{};

        // ── Step 1: Validate context ──

        if (ctx.root_source_path_len == 0) {
            captureDiagnostic(
                &diag_buf,
                .@"error",
                &[_]u8{},
                0,
                0,
                "no root source file specified in Compilation_Context",
            );
            return finalizeResult(&result, &diag_buf, false);
        }

        // ── Step 2: Validate module dependency graph ──

        if (!validateModuleGraph(ctx, &diag_buf)) {
            return finalizeResult(&result, &diag_buf, false);
        }

        // ── Step 3: Validate C++ source entries ──

        if (!validateCppSources(ctx, &diag_buf)) {
            return finalizeResult(&result, &diag_buf, false);
        }

        // ── Step 4: Validate required directories ──
        if (ctx.zig_lib_dir_len == 0) {
            captureDiagnostic(
                &diag_buf,
                .@"error",
                ctx.root_source_path[0..ctx.root_source_path_len],
                0,
                0,
                "zig_lib_dir not set in Compilation_Context",
            );
            return finalizeResult(&result, &diag_buf, false);
        }

        // ── Step 5: Check compile_fn is set ──
        if (ctx.compile_fn == null) {
            captureDiagnostic(
                &diag_buf,
                .@"error",
                ctx.root_source_path[0..ctx.root_source_path_len],
                0,
                0,
                "compile_fn not set — build runner must provide compilation backend",
            );
            return finalizeResult(&result, &diag_buf, false);
        }

        // ── Step 6: Delegate to the compilation backend ──
        ctx.compile_fn.?(ctx, &result, io);
        return result;
    }

    // ── Internal Helpers ──

    /// Validate the module dependency graph.
    /// Checks that every dependency referenced by a module is actually registered
    /// in the context. Returns false if any unresolved dependencies are found
    /// (diagnostics are emitted for each).
    fn validateModuleGraph(ctx: *const Compilation_Context, diag_buf: *Diagnostic_Buffer) bool {
        var all_resolved = true;

        for (0..ctx.module_count) |i| {
            const mod = &ctx.modules[i];
            for (0..mod.dep_count) |d| {
                const dep = &mod.deps[d];
                const dep_name = dep.name[0..dep.name_len];

                if (!isModuleRegistered(ctx, dep_name)) {
                    // Emit diagnostic identifying the unresolved module
                    var msg_buf: [DIAGNOSTIC_BUF_SIZE]u8 = undefined;
                    const msg_len = formatUnresolvedDep(
                        &msg_buf,
                        mod.name[0..mod.name_len],
                        dep_name,
                    );
                    captureDiagnostic(
                        diag_buf,
                        .@"error",
                        mod.source_path[0..mod.source_path_len],
                        0,
                        0,
                        msg_buf[0..msg_len],
                    );
                    all_resolved = false;
                }
            }
        }

        return all_resolved;
    }

    /// Check if a module with the given name is registered in the context.
    fn isModuleRegistered(ctx: *const Compilation_Context, name: []const u8) bool {
        for (0..ctx.module_count) |i| {
            const mod = &ctx.modules[i];
            const mod_name = mod.name[0..mod.name_len];
            if (mod_name.len == name.len and eql(mod_name, name)) {
                return true;
            }
        }
        return false;
    }

    /// Validate C++ source entries.
    /// Checks that each registered C++ source has a non-empty path.
    /// Returns false if any invalid entries are found.
    fn validateCppSources(ctx: *const Compilation_Context, diag_buf: *Diagnostic_Buffer) bool {
        var all_valid = true;

        for (0..ctx.cpp_source_count) |i| {
            const src = &ctx.cpp_sources[i];
            if (src.path_len == 0) {
                var msg_buf: [DIAGNOSTIC_BUF_SIZE]u8 = undefined;
                const prefix = "C++ source file at index ";
                const suffix = " has empty path";
                @memcpy(msg_buf[0..prefix.len], prefix);
                const idx_len = formatUsizeDecimal(i, msg_buf[prefix.len..]);
                @memcpy(msg_buf[prefix.len + idx_len ..][0..suffix.len], suffix);
                const total_len = prefix.len + idx_len + suffix.len;

                captureDiagnostic(
                    diag_buf,
                    .@"error",
                    &[_]u8{},
                    0,
                    0,
                    msg_buf[0..total_len],
                );
                all_valid = false;
            }
        }

        return all_valid;
    }

    /// Format an "unresolved module dependency" diagnostic message.
    /// Returns: "module '<mod_name>' has unresolved dependency '<dep_name>'"
    fn formatUnresolvedDep(buf: *[DIAGNOSTIC_BUF_SIZE]u8, mod_name: []const u8, dep_name: []const u8) usize {
        const p1 = "module '";
        const p2 = "' has unresolved dependency '";
        const p3 = "'";

        var pos: usize = 0;

        const p1_len = @min(p1.len, DIAGNOSTIC_BUF_SIZE - pos);
        @memcpy(buf[pos..][0..p1_len], p1[0..p1_len]);
        pos += p1_len;

        const mn_len = @min(mod_name.len, DIAGNOSTIC_BUF_SIZE - pos);
        @memcpy(buf[pos..][0..mn_len], mod_name[0..mn_len]);
        pos += mn_len;

        const p2_len = @min(p2.len, DIAGNOSTIC_BUF_SIZE - pos);
        @memcpy(buf[pos..][0..p2_len], p2[0..p2_len]);
        pos += p2_len;

        const dn_len = @min(dep_name.len, DIAGNOSTIC_BUF_SIZE - pos);
        @memcpy(buf[pos..][0..dn_len], dep_name[0..dn_len]);
        pos += dn_len;

        const p3_len = @min(p3.len, DIAGNOSTIC_BUF_SIZE - pos);
        @memcpy(buf[pos..][0..p3_len], p3[0..p3_len]);
        pos += p3_len;

        return pos;
    }

    /// Build cc_argv for a C++ source file.
    /// Combines shared flags, per-file extra flags, include directories (as -I<path>),
    /// and preprocessor definitions (as -D<name>=<value> or -D<name>).
    /// Returns the number of argv entries written, or null if the buffer overflows.
    pub fn buildCcArgv(
        ctx: *const Compilation_Context,
        src_index: usize,
        argv_buf: *[MAX_CC_ARGV][VALUE_BUF_SIZE]u8,
        argv_lens: *[MAX_CC_ARGV]usize,
    ) ?usize {
        var argc: usize = 0;
        const src = &ctx.cpp_sources[src_index];

        // 1. Shared flags
        for (0..ctx.shared_flag_count) |f| {
            if (argc >= MAX_CC_ARGV) return null;
            const flag = &ctx.shared_flags[f];
            @memcpy(argv_buf[argc][0..flag.value_len], flag.value[0..flag.value_len]);
            argv_lens[argc] = flag.value_len;
            argc += 1;
        }

        // 2. Per-file extra flags
        for (0..src.extra_flag_count) |f| {
            if (argc >= MAX_CC_ARGV) return null;
            const flag = &src.extra_flags[f];
            @memcpy(argv_buf[argc][0..flag.value_len], flag.value[0..flag.value_len]);
            argv_lens[argc] = flag.value_len;
            argc += 1;
        }

        // 3. Include directories as -I<path>
        for (0..ctx.include_dir_count) |d| {
            if (argc >= MAX_CC_ARGV) return null;
            const dir = &ctx.include_dirs[d];
            const prefix = "-I";
            const total = prefix.len + dir.path_len;
            if (total > VALUE_BUF_SIZE) return null;
            @memcpy(argv_buf[argc][0..prefix.len], prefix);
            @memcpy(argv_buf[argc][prefix.len..][0..dir.path_len], dir.path[0..dir.path_len]);
            argv_lens[argc] = total;
            argc += 1;
        }

        // 4. Preprocessor definitions as -D<name>=<value> or -D<name>
        for (0..ctx.definition_count) |d| {
            if (argc >= MAX_CC_ARGV) return null;
            const def = &ctx.definitions[d];
            const prefix = "-D";
            var pos: usize = 0;

            @memcpy(argv_buf[argc][pos..][0..prefix.len], prefix);
            pos += prefix.len;

            if (pos + def.name_len > VALUE_BUF_SIZE) return null;
            @memcpy(argv_buf[argc][pos..][0..def.name_len], def.name[0..def.name_len]);
            pos += def.name_len;

            if (def.value_len > 0) {
                if (pos + 1 + def.value_len > VALUE_BUF_SIZE) return null;
                argv_buf[argc][pos] = '=';
                pos += 1;
                @memcpy(argv_buf[argc][pos..][0..def.value_len], def.value[0..def.value_len]);
                pos += def.value_len;
            }

            argv_lens[argc] = pos;
            argc += 1;
        }

        return argc;
    }

    /// Finalize a Result by copying diagnostics from the buffer and setting success.
    pub fn finalizeResult(result: *Result, diag_buf: *Diagnostic_Buffer, success: bool) Result {
        diag_buf.finalize();
        const diags = diag_buf.slice();
        const count = @min(diags.len, MAX_DIAGNOSTICS);
        for (0..count) |i| {
            result.diagnostics[i] = diags[i];
        }
        result.diagnostic_count = count;
        result.success = success;
        return result.*;
    }

    /// Byte-for-byte equality check for slices.
    fn eql(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (0..a.len) |i| {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    /// Format a usize as decimal digits into a slice. Returns number of chars written.
    fn formatUsizeDecimal(value: usize, buf: []u8) usize {
        if (value == 0) {
            if (buf.len > 0) {
                buf[0] = '0';
                return 1;
            }
            return 0;
        }
        var v = value;
        var tmp: [20]u8 = undefined;
        var tmp_len: usize = 0;
        while (v > 0) {
            tmp[tmp_len] = @intCast((v % 10) + '0');
            tmp_len += 1;
            v /= 10;
        }
        const write_len = @min(tmp_len, buf.len);
        for (0..write_len) |i| {
            buf[i] = tmp[tmp_len - 1 - i];
        }
        return write_len;
    }
};
