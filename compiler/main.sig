//! Zero-Alloc Compiler — CLI Driver
//! Entry point for the zero-alloc sig compiler.
//! Parses command-line arguments, selects target, and invokes the streaming pipeline.
//! Zero heap allocations — all state is caller-provided or comptime-sized.

const target_mod = @import("core/target.sig");
const streaming_mod = @import("pipeline/streaming.sig");
const Target_Triple = target_mod.Target_Triple;
const Streaming_Controller = streaming_mod.Streaming_Controller;
pub const Pipeline_Workspace = streaming_mod.Pipeline_Workspace;
const File_Entry = streaming_mod.File_Entry;
const Pipeline_Result = streaming_mod.Pipeline_Result;

/// CLI argument parsing result.
pub const Cli_Args = struct {
    target: Target_Triple = .{ .arch = .x86_64, .os = .linux, .abi = .gnu },
    input_files: [64][256]u8 = undefined,
    input_file_lens: [64]u16 = @splat(0),
    input_count: u8 = 0,
    output_path: [256]u8 = undefined,
    output_path_len: u16 = 0,
    emit_elf: bool = false,
    emit_pe: bool = false,
    emit_macho: bool = false,
    emit_wasm: bool = false,
    emit_sb0: bool = false,
    verbose: bool = false,

    pub fn init() Cli_Args {
        return .{};
    }
};

/// Parse command-line arguments from raw argv-style input.
/// Arguments:
///   -target <arch>-<os>-<abi>    (e.g. x86_64-linux-gnu)
///   -o <output_path>
///   --verbose
///   <input_file.sig>
pub fn parseArgs(args: []const []const u8) Cli_Args {
    var result = Cli_Args.init();
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eqlStr(arg, "-target") and i + 1 < args.len) {
            i += 1;
            result.target = parseTargetTriple(args[i]);
        } else if (eqlStr(arg, "-o") and i + 1 < args.len) {
            i += 1;
            copyStr(&result.output_path, &result.output_path_len, args[i]);
        } else if (eqlStr(arg, "--verbose")) {
            result.verbose = true;
        } else {
            // Input file
            if (result.input_count < 64) {
                copyStr(&result.input_files[result.input_count], &result.input_file_lens[result.input_count], arg);
                result.input_count += 1;
            }
        }
    }
    // Auto-detect output format from target
    result.emit_elf = (result.target.outputFormat() == .elf);
    result.emit_pe = (result.target.outputFormat() == .pe_coff);
    result.emit_macho = (result.target.outputFormat() == .macho);
    result.emit_wasm = (result.target.outputFormat() == .wasm);
    result.emit_sb0 = (result.target.outputFormat() == .sb0_native);
    return result;
}

/// Compile source bytes with argv-style options into a caller-provided buffer.
/// File I/O stays outside this zero-alloc core; callers provide source, output,
/// and one pinned fixed-capacity workspace that can be reused across calls.
pub fn compileSourceToBuffer(
    args: []const []const u8,
    source: []const u8,
    output: []u8,
    workspace: *Pipeline_Workspace,
) Pipeline_Result {
    const parsed = parseArgs(args);
    var controller = Streaming_Controller.init(parsed.target, workspace);
    var file = File_Entry{};
    file.source = source.ptr;
    file.source_len = source.len;
    file.is_sig = true;
    if (parsed.input_count > 0) {
        const len: usize = parsed.input_file_lens[0];
        var i: usize = 0;
        while (i < len) : (i += 1) {
            file.path[i] = parsed.input_files[0][i];
        }
        file.path_len = @intCast(len);
    }
    return controller.compileFileToBuffer(file, output);
}

/// Native SB0 compiler service entry. Unlike the multi-target CLI adapter,
/// this path makes the target and artifact kind compile-time invariants so a
/// released SB0K runner contains no foreign target parser or linker emitter.
pub fn compileSb0SourceToBuffer(
    source: []const u8,
    output: []u8,
    workspace: *Pipeline_Workspace,
) Pipeline_Result {
    const target = Target_Triple{ .arch = .aarch64, .os = .sb0, .abi = .sb0 };
    var controller = Streaming_Controller.init(target, workspace);
    var file = File_Entry{};
    file.source = source.ptr;
    file.source_len = source.len;
    file.is_sig = true;
    const path = "native-input.sig";
    for (path, 0..) |byte, index| file.path[index] = byte;
    file.path_len = path.len;
    return controller.compileSb0FileToBuffer(file, output);
}

/// Parse a target triple string like "x86_64-linux-gnu".
fn parseTargetTriple(s: []const u8) Target_Triple {
    var result = Target_Triple{ .arch = .x86_64, .os = .linux, .abi = .gnu };
    // Parse arch
    if (startsWith(s, "x86_64")) {
        result.arch = .x86_64;
    } else if (startsWith(s, "aarch64")) {
        result.arch = .aarch64;
    } else if (startsWith(s, "arm")) {
        result.arch = .arm;
    } else if (startsWith(s, "riscv64")) {
        result.arch = .riscv64;
    } else if (startsWith(s, "riscv32")) {
        result.arch = .riscv32;
    } else if (startsWith(s, "wasm32")) {
        result.arch = .wasm32;
    }
    // Parse OS (look for known substrings)
    if (containsStr(s, "linux")) {
        result.os = .linux;
    } else if (containsStr(s, "windows")) {
        result.os = .windows;
    } else if (containsStr(s, "macos")) {
        result.os = .macos;
    } else if (containsStr(s, "sb0")) {
        result.os = .sb0;
    } else if (containsStr(s, "freestanding")) {
        result.os = .freestanding;
    }
    // Parse ABI
    if (containsStr(s, "gnu")) {
        result.abi = .gnu;
    } else if (containsStr(s, "musl")) {
        result.abi = .musl;
    } else if (containsStr(s, "msvc")) {
        result.abi = .msvc;
    } else if (containsStr(s, "eabi")) {
        result.abi = .eabi;
    } else if (containsStr(s, "sb0")) {
        result.abi = .sb0;
    } else if (containsStr(s, "none")) {
        result.abi = .none;
    }
    return result;
}

fn eqlStr(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    for (prefix, 0..) |c, i| {
        if (haystack[i] != c) return false;
    }
    return true;
}

fn containsStr(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, j| {
            if (haystack[i + j] != c) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn copyStr(dst: *[256]u8, dst_len: *u16, src: []const u8) void {
    const len = @min(src.len, 256);
    for (0..len) |i| {
        dst[i] = src[i];
    }
    dst_len.* = @intCast(len);
}

// ============================================================================
// Tests
// ============================================================================

const testing = @import("std").testing;

test "parseArgs basic input file" {
    const args = [_][]const u8{"main.sig"};
    const result = parseArgs(&args);
    try testing.expect(!(result.input_count != 1)); // expected 1 input file
}

test "parseArgs target and output" {
    const args = [_][]const u8{ "-target", "aarch64-macos-none", "-o", "out.bin", "lib.sig" };
    const result = parseArgs(&args);
    try testing.expect(!(result.target.arch != .aarch64)); // expected aarch64
    try testing.expect(!(result.target.os != .macos)); // expected macos
    try testing.expect(!(result.emit_macho != true)); // should auto-detect macho
    try testing.expect(!(result.input_count != 1)); // expected 1 input
}

test "parseTargetTriple x86_64-linux-gnu" {
    const t = parseTargetTriple("x86_64-linux-gnu");
    try testing.expect(!(t.arch != .x86_64)); // expected x86_64
    try testing.expect(!(t.os != .linux)); // expected linux
    try testing.expect(!(t.abi != .gnu)); // expected gnu
}

test "parseTargetTriple wasm32-freestanding-none" {
    const t = parseTargetTriple("wasm32-freestanding-none");
    try testing.expect(!(t.arch != .wasm32)); // expected wasm32
    try testing.expect(!(t.os != .freestanding)); // expected freestanding
}

test "parseTargetTriple aarch64-sb0" {
    const t = parseTargetTriple("aarch64-sb0");
    try testing.expect(!(t.arch != .aarch64)); // expected aarch64
    try testing.expect(!(t.os != .sb0)); // expected sb0 os
    try testing.expect(!(t.abi != .sb0)); // expected sb0 abi
    try testing.expect(!(!t.isSb0())); // expected consolidated sb0 target
}

test "parseArgs verbose flag" {
    const args = [_][]const u8{ "--verbose", "input.sig" };
    const result = parseArgs(&args);
    try testing.expect(!(result.verbose != true)); // expected verbose true
    try testing.expect(!(result.input_count != 1)); // expected 1 input file
}

test "parseArgs auto-detect elf for linux" {
    const args = [_][]const u8{ "-target", "x86_64-linux-gnu", "test.sig" };
    const result = parseArgs(&args);
    try testing.expect(!(result.emit_elf != true)); // should auto-detect elf for linux
    try testing.expect(!(result.emit_pe != false)); // should not emit pe for linux
}

test "parseArgs auto-detect pe for windows" {
    const args = [_][]const u8{ "-target", "x86_64-windows-msvc", "test.sig" };
    const result = parseArgs(&args);
    try testing.expect(!(result.emit_pe != true)); // should auto-detect pe for windows
    try testing.expect(!(result.emit_elf != false)); // should not emit elf for windows
}

test "parseArgs auto-detect wasm" {
    const args = [_][]const u8{ "-target", "wasm32-freestanding-none", "test.sig" };
    const result = parseArgs(&args);
    try testing.expect(!(result.emit_wasm != true)); // should auto-detect wasm
}

test "parseArgs auto-detect sb0 native" {
    const args = [_][]const u8{ "-target", "aarch64-sb0", "app.sig" };
    const result = parseArgs(&args);
    try testing.expect(!(result.emit_sb0 != true)); // should auto-detect sb0 native
    try testing.expect(!(result.emit_elf != false)); // sb0 should not emit elf
    try testing.expect(!(result.emit_pe != false)); // sb0 should not emit pe
    try testing.expect(!(result.emit_macho != false)); // sb0 should not emit macho
}

test "parseTargetTriple riscv64-linux-gnu" {
    const t = parseTargetTriple("riscv64-linux-gnu");
    try testing.expect(!(t.arch != .riscv64)); // expected riscv64
    try testing.expect(!(t.os != .linux)); // expected linux
    try testing.expect(!(t.abi != .gnu)); // expected gnu
}

test "parseArgs multiple input files" {
    const args = [_][]const u8{ "a.sig", "b.sig", "c.sig" };
    const result = parseArgs(&args);
    try testing.expect(!(result.input_count != 3)); // expected 3 input files
}

test "parseArgs output path stored correctly" {
    const args = [_][]const u8{ "-o", "build/output.bin" };
    const result = parseArgs(&args);
    try testing.expect(!(result.output_path_len != 16)); // expected output path length 16
}

test "eqlStr basic" {
    try testing.expect(!(!eqlStr("hello", "hello"))); // equal strings should match
    try testing.expect(!(eqlStr("hello", "world"))); // different strings should not match
    try testing.expect(!(eqlStr("hi", "hello"))); // different length strings should not match
}

test "startsWith basic" {
    try testing.expect(!(!startsWith("x86_64-linux", "x86_64"))); // should start with x86_64
    try testing.expect(!(startsWith("arm-linux", "x86_64"))); // should not start with x86_64
    try testing.expect(!(startsWith("x86", "x86_64"))); // shorter haystack should not match longer prefix
}

test "containsStr basic" {
    try testing.expect(!(!containsStr("x86_64-linux-gnu", "linux"))); // should contain linux
    try testing.expect(!(containsStr("x86_64-linux-gnu", "windows"))); // should not contain windows
    try testing.expect(!(!containsStr("linux", "linux"))); // exact match should contain
}

// Property 20: Cross-platform output determinism
// **Validates: Requirements 1.6, 12.6**
test "cross-platform output determinism - same args same result" {
    const args = [_][]const u8{ "-target", "x86_64-linux-gnu", "-o", "out.elf", "main.sig" };
    const result1 = parseArgs(&args);
    const result2 = parseArgs(&args);
    // Same arguments should produce identical parsing results
    try testing.expect(!(result1.target.arch != result2.target.arch)); // arch should be deterministic
    try testing.expect(!(result1.target.os != result2.target.os)); // os should be deterministic
    try testing.expect(!(result1.target.abi != result2.target.abi)); // abi should be deterministic
    try testing.expect(!(result1.input_count != result2.input_count)); // input_count should be deterministic
    try testing.expect(!(result1.emit_elf != result2.emit_elf)); // emit_elf should be deterministic
    try testing.expect(!(result1.output_path_len != result2.output_path_len)); // output_path_len should be deterministic
}

test "cross-platform output determinism - different targets produce different formats" {
    const linux_args = [_][]const u8{ "-target", "x86_64-linux-gnu", "a.sig" };
    const win_args = [_][]const u8{ "-target", "x86_64-windows-msvc", "a.sig" };
    const linux_result = parseArgs(&linux_args);
    const win_result = parseArgs(&win_args);
    try testing.expect(!(linux_result.emit_elf != true)); // linux should emit elf
    try testing.expect(!(win_result.emit_pe != true)); // windows should emit pe
    try testing.expect(!(linux_result.emit_pe)); // linux should not emit pe
    try testing.expect(!(win_result.emit_elf)); // windows should not emit elf
}
