#!/bin/bash
set -e

cd "$(dirname "$0")/.."
echo "=== Cross-compile sig for Windows from Linux ==="
echo "Working dir: $(pwd)"

# Extract bootstrap
rm -rf /tmp/bootstrap
mkdir -p /tmp/bootstrap
tar -xf bootstrap-sig-x86_64-linux.tar.gz -C /tmp/bootstrap
SIG=$(find /tmp/bootstrap -type f -name "sig" | head -1)
chmod +x "$SIG"
ln -sf "$(pwd)/lib" "$(dirname "$(dirname "$SIG")")/lib"

echo "=== Bootstrap version ==="
"$SIG" version || echo "WARNING: version returned non-zero"

echo "=== Setting up build options ==="
ulimit -s unlimited
mkdir -p .build-gen stage3-out/bin

cat > .build-gen/build_options.zig << 'EOF'
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
pub const sig_version: [:0]const u8 = "test";
pub const semver: @import("std").SemanticVersion = .{ .major = 0, .minor = 17, .patch = 0 };
pub const dev: enum { full, bootstrap, ast_gen, sema, cbe, @"aarch64-linux", @"powerpc-linux", @"riscv64-linux", spirv, wasm, @"x86_64-linux" } = .full;
EOF

echo "=== Cross-compiling sig for x86_64-windows ==="
"$SIG" build-exe \
  --dep build_options --dep aro \
  -Mroot=src/main.zig \
  -Mbuild_options=.build-gen/build_options.zig \
  -Maro=lib/compiler/aro/aro.zig \
  --name sig \
  -OReleaseFast \
  -fstrip \
  -flld \
  --zig-lib-dir lib \
  -target x86_64-windows \
  --cache-dir .zig-cache \
  -femit-bin=stage3-out/bin/sig.exe

echo "=== Verifying output ==="
ls -la stage3-out/bin/sig.exe
file stage3-out/bin/sig.exe
echo "=== SUCCESS: Cross-compilation produced sig.exe ==="
