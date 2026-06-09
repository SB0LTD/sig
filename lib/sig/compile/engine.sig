// Compilation_Engine — In-process compilation execution core.
//
// Translates a fully-populated Compilation_Context into internal Compilation API
// calls. This is the single entry point that replaces subprocess spawning.
// Never panics — all errors are caught and translated into a Result with
// success = false and populated diagnostics.

const std = @import("std");
const compiler = @import("compiler");
const Compilation = compiler.Compilation;
const Package = compiler.Package;
const Cache = std.Build.Cache;
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
const MAX_CC_ARGV: usize = MAX_COMPILER_FLAGS + MAX_COMPILER_FLAGS + MAX_INCLUDE_DIRS + MAX_PREPROCESSOR_DEFS;

// ── Compilation_Engine ──

/// The Compilation Engine namespace.
/// Provides the `execute()` function that drives in-process compilation
/// from a fully-populated `Compilation_Context`.
pub const Compilation_Engine = struct {

    /// Structured result of a compilation attempt.
    /// Always populated — never panics. When `success` is false,
    /// `diagnostic_count` is guaranteed to be greater than zero.
    pub const Result = struct {
        /// Whether compilation completed successfully.
        success: bool = false,
        /// Path to the output artifact (populated on success).
        output_path: [PATH_BUF_SIZE]u8 = undefined,
        output_path_len: usize = 0,
        /// Captured diagnostics from the compilation pipeline.
        diagnostics: [MAX_DIAGNOSTICS]Diagnostic = undefined,
        diagnostic_count: usize = 0,
    };

    /// Execute a compilation from a fully-populated context.
    ///
    /// This is the single entry point that replaces subprocess spawning.
    /// The function performs the following steps:
    ///   1. Validates the context (root source, compiler infrastructure)
    ///   2. Resolves the target triple
    ///   3. Validates and constructs the module dependency graph
    ///   4. Prepares C++ source file entries with cc_argv (flags/includes/defines)
    ///   5. Creates own allocators, resolves Compilation.Config, creates modules,
    ///      wires dependencies, and invokes Compilation.create()
    ///   6. Drives compilation via comp.update() and captures output path
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

        // ── Step 2: Resolve target triple ──

        const local_resolved = ctx.target.resolve();

        // ── Step 3: Validate module dependency graph ──

        if (!validateModuleGraph(ctx, &diag_buf)) {
            return finalizeResult(&result, &diag_buf, false);
        }

        // ── Step 4: Prepare C++ source entries ──
        // Validate that all C++ sources have non-empty paths and build cc_argv
        // (includes, defines, shared flags, per-file flags).

        if (!validateCppSources(ctx, &diag_buf)) {
            return finalizeResult(&result, &diag_buf, false);
        }

        // ── Step 4b: Validate required directories ──
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

        // ── Step 5: Own allocators ──
        var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_impl.deinit();
        const arena = arena_impl.allocator();
        const gpa = std.heap.page_allocator;

        // ── 5a: Resolve target for Package.Module ──
        const resolved_target: Package.Module.ResolvedTarget = .{
            .result = .{
                .cpu = .{
                    .arch = local_resolved.cpu_arch,
                    .model = std.Target.Cpu.Model.generic(local_resolved.cpu_arch),
                    .features = std.Target.Cpu.Feature.Set.empty,
                },
                .os = .{
                    .tag = local_resolved.os_tag,
                    .version_range = std.Target.Os.VersionRange.default(local_resolved.os_tag, local_resolved.cpu_arch),
                },
                .abi = local_resolved.abi,
                .ofmt = local_resolved.ofmt,
                .dynamic_linker = std.Target.DynamicLinker.none,
            },
            .is_native_os = (local_resolved.os_tag == @import("builtin").os.tag),
            .is_native_abi = (local_resolved.abi == @import("builtin").abi),
        };

        // ── 5b: Map optimize mode ──
        const opt_mode: std.builtin.OptimizeMode = switch (ctx.optimize) {
            .Debug => .Debug,
            .ReleaseSafe => .ReleaseSafe,
            .ReleaseFast => .ReleaseFast,
            .ReleaseSmall => .ReleaseSmall,
        };

        // ── 5c: Resolve Compilation.Config ──
        const output_mode: Compilation.Config.OutputMode = switch (ctx.output_mode) {
            .Exe => .Exe,
            .Lib => .Lib,
            .Obj => .Obj,
        };

        const config = Compilation.Config.resolve(.{
            .output_mode = output_mode,
            .root_optimize_mode = opt_mode,
            .root_strip = ctx.strip,
            .resolved_target = resolved_target,
            .link_libc = ctx.link_libc,
            .link_libcpp = ctx.link_libcpp,
            .have_zcu = true,
            .emit_bin = true,
            .is_test = false,
        }) catch {
            captureDiagnostic(
                &diag_buf,
                .@"error",
                ctx.root_source_path[0..ctx.root_source_path_len],
                0,
                0,
                "failed to resolve Compilation.Config",
            );
            return finalizeResult(&result, &diag_buf, false);
        };

        // ── 5d: Resolve directories ──
        const zig_lib_dir_path = ctx.zig_lib_dir[0..ctx.zig_lib_dir_len];
        const cache_dir_path = ctx.cache_dir[0..ctx.cache_dir_len];
        const global_cache_dir_path = ctx.global_cache_dir[0..ctx.global_cache_dir_len];

        const dirs: Compilation.Directories = .{
            .zig_lib = .{ .path = if (zig_lib_dir_path.len > 0) zig_lib_dir_path else null, .handle = .{ .handle = std.posix.AT.FDCWD } },
            .local_cache = .{ .path = if (cache_dir_path.len > 0) cache_dir_path else null, .handle = .{ .handle = std.posix.AT.FDCWD } },
            .global_cache = .{ .path = if (global_cache_dir_path.len > 0) global_cache_dir_path else null, .handle = .{ .handle = std.posix.AT.FDCWD } },
        };

        // ── 5e: Create root module ──
        const root_src_path = ctx.root_source_path[0..ctx.root_source_path_len];

        const root_mod = Package.Module.create(arena, .{
            .paths = .{
                .root = .{ .path = ".", .handle = .{ .handle = std.posix.AT.FDCWD } },
                .root_src_path = root_src_path,
            },
            .fully_qualified_name = "root",
            .cc_argv = &.{},
            .inherited = .{
                .resolved_target = resolved_target,
                .optimize_mode = opt_mode,
                .strip = ctx.strip,
                .single_threaded = ctx.single_threaded,
            },
            .global = config,
            .parent = null,
        }) catch {
            captureDiagnostic(
                &diag_buf,
                .@"error",
                root_src_path,
                0,
                0,
                "failed to create root Package.Module",
            );
            return finalizeResult(&result, &diag_buf, false);
        };

        // ── 5f: Create named modules and wire dependencies ──
        // First pass: create all modules
        var pkg_modules: [MAX_MODULES]*Package.Module = undefined;
        var mod_create_failed = false;

        for (0..ctx.module_count) |i| {
            const mod_decl = &ctx.modules[i];
            const mod_src_path = mod_decl.source_path[0..mod_decl.source_path_len];
            const mod_name = mod_decl.name[0..mod_decl.name_len];

            // Build fully qualified name: "root.<mod_name>"
            var fqn_buf: [NAME_BUF_SIZE + 5]u8 = undefined;
            const fqn_prefix = "root.";
            @memcpy(fqn_buf[0..fqn_prefix.len], fqn_prefix);
            const fqn_name_len = @min(mod_name.len, fqn_buf.len - fqn_prefix.len);
            @memcpy(fqn_buf[fqn_prefix.len..][0..fqn_name_len], mod_name[0..fqn_name_len]);
            const fqn = fqn_buf[0 .. fqn_prefix.len + fqn_name_len];

            pkg_modules[i] = Package.Module.create(arena, .{
                .paths = .{
                    .root = .{ .path = ".", .handle = .{ .handle = std.posix.AT.FDCWD } },
                    .root_src_path = mod_src_path,
                },
                .fully_qualified_name = fqn,
                .cc_argv = &.{},
                .inherited = .{},
                .global = config,
                .parent = root_mod,
            }) catch {
                captureDiagnostic(
                    &diag_buf,
                    .@"error",
                    mod_src_path,
                    0,
                    0,
                    "failed to create Package.Module",
                );
                mod_create_failed = true;
                break;
            };
        }

        if (mod_create_failed) {
            return finalizeResult(&result, &diag_buf, false);
        }

        // Second pass: wire dependencies between modules and root
        var dep_wire_failed = false;

        for (0..ctx.module_count) |i| {
            const mod_decl = &ctx.modules[i];
            const mod_name = mod_decl.name[0..mod_decl.name_len];

            // Wire this module as a dependency of root
            root_mod.deps.put(arena, mod_name, pkg_modules[i]) catch {
                captureDiagnostic(
                    &diag_buf,
                    .@"error",
                    mod_decl.source_path[0..mod_decl.source_path_len],
                    0,
                    0,
                    "failed to wire module dependency on root",
                );
                dep_wire_failed = true;
                break;
            };

            // Wire inter-module dependencies
            for (0..mod_decl.dep_count) |d| {
                const dep = &mod_decl.deps[d];
                const dep_name = dep.name[0..dep.name_len];

                // Find the target module by name
                var found_dep: ?*Package.Module = null;
                for (0..ctx.module_count) |j| {
                    const candidate = &ctx.modules[j];
                    const candidate_name = candidate.name[0..candidate.name_len];
                    if (candidate_name.len == dep_name.len and eql(candidate_name, dep_name)) {
                        found_dep = pkg_modules[j];
                        break;
                    }
                }

                if (found_dep) |target_mod_ptr| {
                    pkg_modules[i].deps.put(arena, dep_name, target_mod_ptr) catch {
                        captureDiagnostic(
                            &diag_buf,
                            .@"error",
                            mod_decl.source_path[0..mod_decl.source_path_len],
                            0,
                            0,
                            "failed to wire inter-module dependency",
                        );
                        dep_wire_failed = true;
                        break;
                    };
                }
                // Note: unresolved deps already caught by validateModuleGraph in Step 3
            }
            if (dep_wire_failed) break;
        }

        if (dep_wire_failed) {
            return finalizeResult(&result, &diag_buf, false);
        }

        // ── 5g: Build cc_argv for C++ sources ──
        // The CSourceFiles are passed via the c_source_files field in CreateOptions.
        // We need to build cc_argv arrays for each C++ source file.
        var c_source_files: [MAX_CPP_SOURCES]Compilation.CSourceFile = undefined;

        for (0..ctx.cpp_source_count) |i| {
            var argv_buf: [MAX_CC_ARGV][VALUE_BUF_SIZE]u8 = undefined;
            var argv_lens: [MAX_CC_ARGV]usize = undefined;

            const argc = buildCcArgv(ctx, i, &argv_buf, &argv_lens) orelse {
                captureDiagnostic(
                    &diag_buf,
                    .@"error",
                    ctx.cpp_sources[i].path[0..ctx.cpp_sources[i].path_len],
                    0,
                    0,
                    "cc_argv overflow for C++ source file",
                );
                return finalizeResult(&result, &diag_buf, false);
            };

            // Convert to slice pointers that Compilation expects
            var cc_argv_ptrs: [MAX_CC_ARGV][]const u8 = undefined;
            for (0..argc) |a| {
                cc_argv_ptrs[a] = argv_buf[a][0..argv_lens[a]];
            }

            c_source_files[i] = .{
                .src_path = ctx.cpp_sources[i].path[0..ctx.cpp_sources[i].path_len],
                .owner = root_mod,
                .cc_argv = cc_argv_ptrs[0..argc],
            };
        }

        // ── 5h: Call Compilation.create ──
        const output_name = ctx.output_name[0..ctx.output_name_len];
        const emit_bin: Compilation.EmitBin = switch (ctx.emit_bin) {
            .yes_cache => .yes_cache,
            .no => .no,
        };

        var create_diag: Compilation.CreateDiagnostic = undefined;
        const comp = Compilation.create(gpa, arena, io, &create_diag, .{
            .dirs = dirs,
            .root_name = if (output_name.len > 0) output_name else "a",
            .config = config,
            .root_mod = root_mod,
            .main_mod = root_mod,
            .emit_bin = emit_bin,
            .thread_limit = ctx.thread_limit,
            .verbose_cc = ctx.verbose_cc,
            .verbose_link = ctx.verbose_link,
            .c_source_files = if (ctx.cpp_source_count > 0) c_source_files[0..ctx.cpp_source_count] else &.{},
        }) catch |err| {
            const msg = switch (err) {
                error.CreateFail => "Compilation.create failed: see diagnostics",
                else => "Compilation.create returned unexpected error",
            };
            captureDiagnostic(
                &diag_buf,
                .@"error",
                root_src_path,
                0,
                0,
                msg,
            );
            return finalizeResult(&result, &diag_buf, false);
        };
        defer comp.destroy();

        // ── Step 6: Drive compilation via update ──
        comp.update(.main) catch |err| {
            const msg = switch (err) {
                error.CompileErrorsReported => "compilation failed: errors reported",
                else => "compilation update failed with unexpected error",
            };
            captureDiagnostic(
                &diag_buf,
                .@"error",
                root_src_path,
                0,
                0,
                msg,
            );
            return finalizeResult(&result, &diag_buf, false);
        };

        // ── Capture output path on success ──
        if (comp.emit_bin) |bin_path| {
            const path_str = bin_path;
            const copy_len = @min(path_str.len, PATH_BUF_SIZE);
            @memcpy(result.output_path[0..copy_len], path_str[0..copy_len]);
            result.output_path_len = copy_len;
        } else if (comp.digest) |digest| {
            // Build output path from cache: "o/<hex_digest>/<output_name>"
            const hex = &Cache.binToHex(digest);
            const prefix = "o/";
            var pos: usize = 0;
            @memcpy(result.output_path[pos..][0..prefix.len], prefix);
            pos += prefix.len;
            @memcpy(result.output_path[pos..][0..hex.len], hex);
            pos += hex.len;
            result.output_path[pos] = '/';
            pos += 1;
            const name_len = @min(output_name.len, PATH_BUF_SIZE - pos);
            @memcpy(result.output_path[pos..][0..name_len], output_name[0..name_len]);
            pos += name_len;
            result.output_path_len = pos;
        }

        return finalizeResult(&result, &diag_buf, true);
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

        // "module '"
        const p1_len = @min(p1.len, DIAGNOSTIC_BUF_SIZE - pos);
        @memcpy(buf[pos..][0..p1_len], p1[0..p1_len]);
        pos += p1_len;

        // module name
        const mn_len = @min(mod_name.len, DIAGNOSTIC_BUF_SIZE - pos);
        @memcpy(buf[pos..][0..mn_len], mod_name[0..mn_len]);
        pos += mn_len;

        // "' has unresolved dependency '"
        const p2_len = @min(p2.len, DIAGNOSTIC_BUF_SIZE - pos);
        @memcpy(buf[pos..][0..p2_len], p2[0..p2_len]);
        pos += p2_len;

        // dep name
        const dn_len = @min(dep_name.len, DIAGNOSTIC_BUF_SIZE - pos);
        @memcpy(buf[pos..][0..dn_len], dep_name[0..dn_len]);
        pos += dn_len;

        // trailing "'"
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
            // Format: "-I" + path
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

            // "-D"
            @memcpy(argv_buf[argc][pos..][0..prefix.len], prefix);
            pos += prefix.len;

            // name
            if (pos + def.name_len > VALUE_BUF_SIZE) return null;
            @memcpy(argv_buf[argc][pos..][0..def.name_len], def.name[0..def.name_len]);
            pos += def.name_len;

            // "=value" (only if value is non-empty)
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
    fn finalizeResult(result: *Result, diag_buf: *Diagnostic_Buffer, success: bool) Result {
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
