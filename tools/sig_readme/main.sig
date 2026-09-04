const std = @import("std");
const sig = @import("sig");
const sig_fmt = sig.fmt;
const sig_json = sig.json;
const sig_fs = sig.fs;

/// Sig README Generator (zero allocators)
///
/// Reads sync manifest JSON, then generates README.md.
/// All memory is stack-allocated. No Allocator anywhere.

// ── Data Models (inline, no heap) ────────────────────────────────────────

pub const SyncManifest = struct {
    last_integrated_commit: [40]u8 = [_]u8{0} ** 40,
    last_commit_len: usize = 0,
    last_integration_timestamp: i64 = 0,

    pub fn lastCommit(self: *const SyncManifest) []const u8 {
        return self.last_integrated_commit[0..self.last_commit_len];
    }
};

// ── Manifest Parsing (sig.json, zero allocators) ─────────────────────────

fn parseManifest(json_bytes: []const u8) SyncManifest {
    var manifest = SyncManifest{};
    if (json_bytes.len == 0) return manifest;

    var commit_buf: [40]u8 = undefined;
    const commit = sig_json.extractString(json_bytes, "last_integrated_commit", &commit_buf) catch "";
    if (commit.len > 0 and commit.len <= 40) {
        @memcpy(manifest.last_integrated_commit[0..commit.len], commit);
        manifest.last_commit_len = commit.len;
    }

    manifest.last_integration_timestamp = sig_json.extractInt(json_bytes, "last_integration_timestamp") catch 0;
    return manifest;
}

// ── README Generation (writes to std.Io.Writer, zero allocators) ─────────

pub fn writeReadme(w: *std.Io.Writer, manifest: SyncManifest) std.Io.Writer.Error!void {
    try w.writeAll(
        \\<p align="center">
        \\  <img src="sig.png" alt="Sig" width="420" />
        \\</p>
        \\
        \\<h1 align="center">Sig</h1>
        \\
        \\<p align="center">
        \\  <strong>The Sig compiler that knows how much memory it has.</strong>
        \\</p>
        \\
        \\<p align="center">
        \\  <a href="https://github.com/SB0LTD/sig/releases"><img src="https://img.shields.io/github/v/release/SB0LTD/sig?label=latest&color=f7a41d&style=flat-square" alt="Release"></a>
        \\  <a href="https://codeberg.org/ziglang/zig"><img src="https://img.shields.io/badge/language-base-Zig%200.17.0--dev-blue?style=flat-square" alt="Language base"></a>
        \\  <a href="https://github.com/SB0LTD/sig/actions/workflows/sig-sync.yaml"><img src="https://img.shields.io/github/actions/workflow/status/SB0LTD/sig/sig-sync.yaml?label=sync&style=flat-square" alt="Sync Status"></a>
        \\  <a href="https://github.com/SB0LTD/sig/actions/workflows/release.yaml"><img src="https://img.shields.io/github/actions/workflow/status/SB0LTD/sig/release.yaml?label=release&style=flat-square" alt="Release Status"></a>
        \\</p>
        \\
        \\<p align="center">
        \\  <code>sig</code> retains Zig language compatibility. Rename a file to <code>.sig</code> and the compiler starts caring about where your bytes come from.
        \\</p>
        \\
        \\---
        \\
        \\
    );

    try writeReleaseHighlights(w);
    try writeStrictSection(w);
    try writeSpoonSection(w);
    try writeSyncStatus(w, manifest);
    try writeGettingStarted(w);
    try writeHowItsBuilt(w);

    try w.writeAll(
        \\## License
        \\
        \\Same as upstream Zig — MIT. See [LICENSE](LICENSE).
        \\
    );
}

fn writeReleaseHighlights(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(
        \\## 0.5.0 — Self-Hosted AArch64 Compiles the Whole Compiler for SB0
        \\
        \\The self-hosted AArch64 back end is now complete enough to compile the
        \\**entire compiler** for the native `aarch64-sb0` target — with no LLVM, no
        \\LLD, and no foreign object container. The self-hosted SB0 linker also emits a
        \\bootable `SB0K` kernel image (selected by the presence of a linker script)
        \\alongside the `SB0X` userspace image.
        \\
        \\```
        \\$ sig version
        \\sig 0.5.0 (zig 0.17.0)
        \\```
        \\
        \\Under the hood this required full code generation for aggregate optionals
        \\(e.g. `?Token`), tagged-union field extraction, and correct sret/aggregate
        \\field stores in the AArch64 code generator — enough that
        \\`compiler/sb0_native_runner.sig`, which imports all of `main.sig`, compiles
        \\cleanly for `aarch64-sb0` and boots in QEMU as the compiler service itself.
        \\
        \\**Dependency resolution in `sig build`.** A project's `build.sig.zon` can now
        \\declare dependencies as fetched tarballs; `sig build` fetches each into the
        \\global cache, verifies its SHA-256, extracts it, and exposes its modules to
        \\`build.sig` via `ctx.getDependency(name).modulePath("src/...")` — no vendored
        \\source, no hardcoded paths. See the [changelog](CHANGELOG.md) for the full
        \\0.5.0 capability set and limitations.
        \\
        \\## 0.4.1 — Self-Hosted SB0 Linking
        \\
        \\Sig gained a pure-Sig, self-hosted linker for the native SB0 target.
        \\Compiling `aarch64-sb0` with `-ofmt=raw -fno-llvm` emits a complete SB0X
        \\image directly — no LLD, no ELF/PE intermediate.
        \\
        \\## 0.4.0 — Sovereign
        \\
        \\The compiler, standard library, native build runner, and canonical test suite
        \\are Sig source. The repository tracks no `.zig` source files, and the
        \\bootstrap and release stages invoke Sig — not an upstream Zig executable.
        \\
        \\`sig build` executes `build.sig` through the fixed-capacity native runner. The
        \\packaged `Sig` alias preserves the upstream-compatible machine-readable
        \\version-only output, while `sig version` identifies both the Sig and Zig-base
        \\versions.
        \\
        \\| Platform | Backend | Download |
        \\|---|---|---|
        \\| x86_64-linux | Full LLVM 22.1.8 | [tar.xz](https://github.com/SB0LTD/sig/releases/latest/download/sig-x86_64-linux.tar.xz) |
        \\| aarch64-linux | Full LLVM 22.1.8 | [tar.xz](https://github.com/SB0LTD/sig/releases/latest/download/sig-aarch64-linux.tar.xz) |
        \\| aarch64-macos | Full LLVM 22.1.8 | [tar.xz](https://github.com/SB0LTD/sig/releases/latest/download/sig-aarch64-macos.tar.xz) |
        \\| x86_64-windows | Full LLVM 22.1.8 | [zip](https://github.com/SB0LTD/sig/releases/latest/download/sig-x86_64-windows.zip) |
        \\| aarch64-sb0 | Native allocator-free SB0K runner | [sb0k](https://github.com/SB0LTD/sig/releases/latest/download/sig-aarch64-sb0-runner.sb0k) |
        \\
        \\The final release is produced by Sig itself. CMake and upstream Zig are absent
        \\from the bootstrap and release stages: an immutable native Sig stage0 creates
        \\the four verified bootstraps, and those bootstraps compile the final
        \\LLVM-backed Sig executables with immutable LLVM closures.
        \\
        \\---
        \\
        \\
    );
}

fn writeStrictSection(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(
        \\## What makes it strict
        \\
        \\The `.sig` extension activates strict mode. Same syntax. Same parser. Same compiler. But allocator usage becomes a compile error.
        \\
        \\```Sig
        \\// foo.sig — business as usual
        \\var list = std.ArrayList(u8).init(allocator);
        \\try list.appendSlice(data);
        \\
        \\// foo.sig — you bring the buffer, you know the cost
        \\var buf: [4096]u8 = undefined;
        \\const result = try sig.fmt.formatInto(&buf, "{s}: {d}", .{ name, count });
        \\```
        \\
        \\Four errors replace silent reallocation:
        \\
        \\| Error | When |
        \\|---|---|
        \\| `BufferTooSmall` | Output exceeds the caller-provided buffer |
        \\| `CapacityExceeded` | Bounded container is full |
        \\| `DepthExceeded` | Recursion hit its limit |
        \\| `QuotaExceeded` | Resource cap reached |
        \\
        \\Standard Sig error unions. `try`, `catch`, `orelse`. Nothing new to learn.
        \\
        \\---
        \\
        \\
    );
}

fn writeSpoonSection(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(
        \\## The Spoon
        \\
        \\Sig stays synchronized with upstream Zig while maintaining its sovereign
        \\compiler, strict-mode, build-runner, and release layers.
        \\
        \\When a new commit lands in `ziglang/zig`, it fires a GitHub dispatch. The
        \\sig-sync workflow cherry-picks the commit, resolves conflicts (keeping
        \\Sig-owned files), validates the bootstrap, and pushes. If the standard
        \\library changed in a way that breaks the bootstrap, it triggers a rebuild
        \\chain automatically.
        \\
        \\The result: sig never drifts. You get upstream bug fixes, optimizations, and
        \\new features without waiting.
        \\
        \\<!-- Updated automatically by sig-sync workflow -->
        \\
        \\
    );
}

fn writeSyncStatus(w: *std.Io.Writer, manifest: SyncManifest) std.Io.Writer.Error!void {
    // The sig-sync workflow keeps these rows fresh in place via targeted regex
    // replacements on the "**Latest upstream commit**", "**Last sync**", and
    // "**Base version**" lines, so their shapes must be preserved exactly.
    if (manifest.last_commit_len > 0) {
        const commit = manifest.lastCommit();
        const short = if (commit.len >= 8) commit[0..8] else commit;
        try w.writeAll("| | |\n|---|---|\n");
        try w.writeAll("| **Latest upstream commit** | [`");
        try w.writeAll(short);
        try w.writeAll("`](https://codeberg.org/ziglang/zig/commit/");
        try w.writeAll(commit);
        try w.writeAll(") |\n");
        try w.writeAll("| **Last sync** | ");
        if (manifest.last_integration_timestamp > 0) {
            var ts_buf: [20]u8 = undefined;
            const ts_str = sig_fmt.formatInto(&ts_buf, "{d}", .{manifest.last_integration_timestamp}) catch "—";
            try w.writeAll(ts_str);
        } else {
            try w.writeAll("—");
        }
        try w.writeAll(" |\n");
        try w.writeAll("| **Upstream** | [codeberg.org/ziglang/zig](https://codeberg.org/ziglang/zig) |\n");
        try w.writeAll("| **Base version** | Sig 0.17.0-dev · LLVM 22.1.8 |\n");
        try w.writeAll("| **Sync frequency** | Every commit (< 1 min latency) |\n\n");
    } else {
        try w.writeAll("No sync data available.\n\n");
    }

    try w.writeAll("---\n\n");
}

fn writeGettingStarted(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(
        \\## Getting started
        \\
        \\```bash
        \\# Download the latest release
        \\mkdir -p sig-toolchain
        \\curl -sL https://github.com/SB0LTD/sig/releases/latest/download/sig-x86_64-linux.tar.xz \
        \\  | tar -xJ -C sig-toolchain --strip-components=1
        \\export PATH="$PWD/sig-toolchain/bin:$PATH"
        \\
        \\# Or build from source (requires an existing Sig compiler)
        \\git clone https://github.com/SB0LTD/sig.git && cd sig
        \\sig build -OReleaseFast
        \\```
        \\
        \\The executable and `lib/` directory are a matched toolchain unit. Normally Sig
        \\finds the adjacent library automatically. If `SIG_LIB_DIR` is set globally,
        \\unset it or point it at the extracted `sig-toolchain/lib`; mixing compiler and
        \\library versions can make the build runner fail before your build begins.
        \\
        \\It's language-compatible by design. Existing `.zig` files compile unchanged;
        \\rename a source file to `.sig` when you're ready to enable strict mode.
        \\
        \\
    );
}

fn writeHowItsBuilt(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(
        \\## How it's built
        \\
        \\```
        \\build-llvm                 →  build-bootstrap              →  release
        \\7 immutable LLVM closures    4 verified host bootstraps      4 LLVM-backed toolchains
        \\```
        \\
        \\Each stage publishes an exact manifest, SHA-256 set, source commit, producer,
        \\and workflow run. Drafts become visible only after every required artifact and
        \\target-specific execution probe succeeds. Bootstrap and final compilers also
        \\run the canonical 224-test native compiler graph with an explicit fixed stack
        \\budget, then cross-compile and validate an AArch64 object.
        \\
        \\
    );
}

// ── Main (zero allocators) ───────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Read manifest into a stack buffer.
    var manifest_buf: [65536]u8 = undefined;
    const manifest_json = sig_fs.readFile(io, "tools/sig_sync/manifest.json", &manifest_buf) catch "";
    const manifest = parseManifest(manifest_json);

    // Write README directly to file — stream through the Io.Writer.
    var out_file = try std.Io.Dir.cwd().createFile(io, "README.md", .{});
    defer out_file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = out_file.writerStreaming(io, &write_buf);
    try writeReadme(&writer.interface, manifest);
    try writer.interface.flush();
}

// ── Tests (zero allocators) ──────────────────────────────────────────────

test "parseManifest extracts commit and timestamp" {
    const json =
        \\{
        \\  "last_integrated_commit": "abc1234567890def1234567890abcdef12345678",
        \\  "last_integration_timestamp": 1700000000
        \\}
    ;
    const manifest = parseManifest(json);
    try std.testing.expectEqualStrings("abc1234567890def1234567890abcdef12345678", manifest.lastCommit());
    try std.testing.expectEqual(@as(i64, 1700000000), manifest.last_integration_timestamp);
}

test "parseManifest empty returns default" {
    const manifest = parseManifest("");
    try std.testing.expectEqual(@as(usize, 0), manifest.last_commit_len);
    try std.testing.expectEqual(@as(i64, 0), manifest.last_integration_timestamp);
}
