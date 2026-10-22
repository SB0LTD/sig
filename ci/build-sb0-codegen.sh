#!/usr/bin/env bash
# Build a small native AArch64/SB0 compiler with the published Sig bootstrap.
# This compiler profile has no LLVM dependency; the bootstrap uses its own
# LLVM backend to build the Linux host executable. SB0 output stays native.
set -euo pipefail
if [[ $# != 3 ]]; then
  echo "usage: $0 BOOTSTRAP OUTPUT CACHE" >&2
  exit 2
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$(realpath "$1")"
mkdir -p "$(dirname "$2")" "$3"
OUTPUT="$(realpath -m "$2")"
CACHE="$(realpath "$3")"
OPTIONS="$CACHE/build_options.sig"
cat > "$OPTIONS" <<'EOF'
pub const have_llvm: bool = false;
pub const llvm_has_m68k: bool = false;
pub const llvm_has_csky: bool = false;
pub const llvm_has_arc: bool = false;
pub const llvm_has_xtensa: bool = false;
pub const enable_logging: bool = false;
pub const enable_debug_extensions: bool = false;
pub const enable_link_snapshots: bool = false;
pub const debug_gpa: bool = false;
pub const enable_tracy: bool = false;
pub const enable_tracy_callstack: bool = false;
pub const enable_tracy_allocation: bool = false;
pub const tracy_callstack_depth: u32 = 6;
pub const value_tracing: bool = false;
pub const mem_leak_frames: u32 = 0;
pub const io_mode: enum { threaded, evented } = .threaded;
pub const value_interpret_mode: enum { direct, by_name } = .direct;
pub const version: [:0]const u8 = "0.17.0";
pub const sig_version: [:0]const u8 = "0.6.3-ramsql-native";
pub const semver: @import("std").SemanticVersion = .{ .major = 0, .minor = 17, .patch = 0 };
pub const dev: enum { full, bootstrap, ast_gen, sema, cbe, @"aarch64-linux", @"powerpc-linux", @"riscv64-linux", spirv, wasm, @"x86_64-linux" } = .@"aarch64-linux";
EOF
cd "$ROOT"
"$BOOTSTRAP" build-exe -mcpu=baseline -OReleaseFast -fllvm -flld \
  --dep build_options --dep aro --dep std -Mroot=src/main.sig \
  "-Mbuild_options=$OPTIONS" -Maro=lib/compiler/aro/aro.sig \
  "-Mstd=$ROOT/lib/std/std.sig" --cache-dir "$CACHE/objects" -lc "-femit-bin=$OUTPUT"
"$OUTPUT" version
