// Sig Installation Layout — single source of truth
//
// Defines the canonical installation structure and resolves all paths
// from the compiler binary's location. Zero allocations, zero probing,
// zero ambiguity.
//
// Canonical layout (guaranteed by installer and release packaging):
//
//   <prefix>/
//   ├── bin/
//   │   └── sig(.exe)       — compiler binary
//   ├── lib/
//   │   ├── std/            — standard library (std/std.sig)
//   │   ├── sig/            — sig extensions (this file lives here)
//   │   ├── compiler/       — compiler runtime modules
//   │   ├── compiler_rt/    — compiler runtime
//   │   ├── libc/           — C library headers/import libs
//   │   │   └── mingw/      — Windows import libraries (ntdll, kernel32, etc.)
//   │   ├── include/        — C headers
//   │   └── ...
//   └── tools/
//       └── sig_build/      — build runner sources
//           ├── main.sig
//           ├── build_host.sig
//           ├── cli.sig
//           └── build_api.sig
//
// Resolution contract:
//   prefix = parent(parent(self_exe_path))
//   lib    = prefix / "lib"
//   tools  = prefix / "tools"
//   std    = lib / "std" / "std.sig"
//   sig    = lib / "sig" / "sig.sig"
//   runner = tools / "sig_build" / "main.sig"
//
// This module is authoritative. No other code should guess these paths.

const std = @import("std");
const SigError = @import("errors.sig").SigError;

/// Maximum path length for install paths (covers all platforms).
pub const MAX_PATH: usize = 4096;

/// Resolved installation paths — all derived from the binary location.
/// Zero allocations; all paths stored in inline buffers.
pub const Install = struct {
    /// Installation prefix (parent of bin/).
    prefix: [MAX_PATH]u8 = undefined,
    prefix_len: u16 = 0,

    /// Library directory: <prefix>/lib
    lib: [MAX_PATH]u8 = undefined,
    lib_len: u16 = 0,

    /// Tools directory: <prefix>/tools
    tools: [MAX_PATH]u8 = undefined,
    tools_len: u16 = 0,

    /// Standard library root: <prefix>/lib/std/std.sig
    std_root: [MAX_PATH]u8 = undefined,
    std_root_len: u16 = 0,

    /// Sig library root: <prefix>/lib/sig/sig.sig
    sig_root: [MAX_PATH]u8 = undefined,
    sig_root_len: u16 = 0,

    /// Build runner source: <prefix>/tools/sig_build/main.sig
    build_runner: [MAX_PATH]u8 = undefined,
    build_runner_len: u16 = 0,

    /// Get prefix as a slice.
    pub fn getPrefix(self: *const Install) []const u8 {
        return self.prefix[0..self.prefix_len];
    }

    /// Get lib directory as a slice.
    pub fn getLib(self: *const Install) []const u8 {
        return self.lib[0..self.lib_len];
    }

    /// Get tools directory as a slice.
    pub fn getTools(self: *const Install) []const u8 {
        return self.tools[0..self.tools_len];
    }

    /// Get std root path as a slice.
    pub fn getStdRoot(self: *const Install) []const u8 {
        return self.std_root[0..self.std_root_len];
    }

    /// Get sig root path as a slice.
    pub fn getSigRoot(self: *const Install) []const u8 {
        return self.sig_root[0..self.sig_root_len];
    }

    /// Get build runner path as a slice.
    pub fn getBuildRunner(self: *const Install) []const u8 {
        return self.build_runner[0..self.build_runner_len];
    }
};

/// Resolve the full installation layout from an executable path.
/// This is the ONLY way to determine where sig's files live.
/// No env vars, no probing, no fallbacks. The layout is fixed.
pub fn resolve(exe_path: []const u8) SigError!Install {
    var install: Install = .{};

    // Step 1: exe_dir = dirname(exe_path)
    const exe_dir_len = lastSep(exe_path) orelse return error.BufferTooSmall;

    // Step 2: prefix = dirname(exe_dir) = parent of bin/
    const prefix_len = lastSep(exe_path[0..exe_dir_len]) orelse return error.BufferTooSmall;
    if (prefix_len >= MAX_PATH) return error.BufferTooSmall;

    @memcpy(install.prefix[0..prefix_len], exe_path[0..prefix_len]);
    install.prefix_len = @intCast(prefix_len);

    // Step 3: lib = prefix / "lib"
    install.lib_len = @intCast(joinInto(&install.lib, exe_path[0..prefix_len], "lib"));

    // Step 4: tools = prefix / "tools"
    install.tools_len = @intCast(joinInto(&install.tools, exe_path[0..prefix_len], "tools"));

    // Step 5: std_root = lib / "std" / "std.sig"
    install.std_root_len = @intCast(joinInto3(&install.std_root, exe_path[0..prefix_len], "lib", "std" ++ sep_str ++ "std.sig"));

    // Step 6: sig_root = lib / "sig" / "sig.sig"
    install.sig_root_len = @intCast(joinInto3(&install.sig_root, exe_path[0..prefix_len], "lib", "sig" ++ sep_str ++ "sig.sig"));

    // Step 7: build_runner = tools / "sig_build" / "main.sig"
    install.build_runner_len = @intCast(joinInto3(&install.build_runner, exe_path[0..prefix_len], "tools", "sig_build" ++ sep_str ++ "main.sig"));

    return install;
}

/// Validate that a resolved installation is complete.
/// Returns true if all critical paths were computed successfully.
pub fn isValid(install: *const Install) bool {
    return install.prefix_len > 0 and
        install.lib_len > 0 and
        install.tools_len > 0 and
        install.std_root_len > 0 and
        install.build_runner_len > 0;
}

// ── Path helpers (zero allocation, platform-aware) ──

const sep: u8 = if (@import("builtin").os.tag == .windows) '\\' else '/';
const sep_str: []const u8 = if (@import("builtin").os.tag == .windows) "\\" else "/";

fn lastSep(path: []const u8) ?usize {
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == sep or path[i] == '/') return i;
    }
    return null;
}

fn joinInto(buf: *[MAX_PATH]u8, base: []const u8, component: []const u8) usize {
    if (base.len + 1 + component.len > MAX_PATH) return 0;
    @memcpy(buf[0..base.len], base);
    buf[base.len] = sep;
    @memcpy(buf[base.len + 1 ..][0..component.len], component);
    return base.len + 1 + component.len;
}

fn joinInto3(buf: *[MAX_PATH]u8, base: []const u8, mid: []const u8, tail: []const u8) usize {
    const total = base.len + 1 + mid.len + 1 + tail.len;
    if (total > MAX_PATH) return 0;
    var off: usize = 0;
    @memcpy(buf[off..][0..base.len], base);
    off += base.len;
    buf[off] = sep;
    off += 1;
    @memcpy(buf[off..][0..mid.len], mid);
    off += mid.len;
    buf[off] = sep;
    off += 1;
    @memcpy(buf[off..][0..tail.len], tail);
    off += tail.len;
    return off;
}
