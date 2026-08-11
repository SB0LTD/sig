#!/usr/bin/env bash
# Build a full LLVM-backed Sig release binary using an existing Sig compiler.
# Usage: build-self-hosted-release.sh BOOTSTRAP LLVM_PREFIX TARGET OUTPUT CACHE
set -euo pipefail

if [ "$#" -ne 5 ]; then
  echo "usage: $0 BOOTSTRAP LLVM_PREFIX TARGET OUTPUT CACHE" >&2
  exit 2
fi

absolute_existing() {
  local input="$1"
  local directory
  local leaf
  directory="$(dirname "$input")"
  leaf="$(basename "$input")"
  (cd "$directory" && printf '%s/%s\n' "$PWD" "$leaf")
}

absolute_output() {
  local input="$1"
  local directory
  local leaf
  directory="$(dirname "$input")"
  leaf="$(basename "$input")"
  mkdir -p "$directory"
  (cd "$directory" && printf '%s/%s\n' "$PWD" "$leaf")
}

BOOTSTRAP="$(absolute_existing "$1")"
LLVM_PREFIX="$(absolute_existing "$2")"
TARGET="$3"
OUTPUT="$(absolute_output "$4")"
CACHE="$(absolute_output "$5")"
ROOT="$(absolute_existing "${SB0_SIG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}")"
OPTIMIZE="${SIG_RELEASE_OPTIMIZE:-ReleaseFast}"
STRIP="${SIG_RELEASE_STRIP:-true}"

case "$TARGET" in
  x86_64-linux-musl|aarch64-linux-musl|aarch64-macos-none|x86_64-windows-gnu) ;;
  *) echo "unsupported release target: $TARGET" >&2; exit 2 ;;
esac

case "$OPTIMIZE" in
  Debug|ReleaseSafe|ReleaseFast|ReleaseSmall) ;;
  *) echo "unsupported optimization mode: $OPTIMIZE" >&2; exit 2 ;;
esac

case "$STRIP" in
  true) strip_flag=-fstrip ;;
  false) strip_flag=-fno-strip ;;
  *) echo "SIG_RELEASE_STRIP must be true or false" >&2; exit 2 ;;
esac

test -x "$BOOTSTRAP"
test -f "$LLVM_PREFIX/include/llvm/Config/llvm-config.h"
test -f "$LLVM_PREFIX/lib/libLLVMCore.a"
test -f "$ROOT/src/main.zig"
test -f "$ROOT/lib/std/std.zig"
mkdir -p "$(dirname "$OUTPUT")" "$CACHE"

ZIG_VERSION="$(sed -n 's/^const zig_version:.*major = \([0-9]*\), \.minor = \([0-9]*\), \.patch = \([0-9]*\).*/\1.\2.\3/p' "$ROOT/build.sig" | head -1)"
SIG_VERSION="$(sed -n 's/^const sig_version_string = "\([^"]*\)".*/\1/p' "$ROOT/build.sig" | head -1)"
test -n "$ZIG_VERSION"
test -n "$SIG_VERSION"

BUILD_OPTIONS="$CACHE/release_build_options.zig"
cat > "$BUILD_OPTIONS" <<EOF
pub const have_llvm: bool = true;
pub const llvm_has_m68k: bool = true;
pub const llvm_has_csky: bool = true;
pub const llvm_has_arc: bool = true;
pub const llvm_has_xtensa: bool = true;
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
pub const version: [:0]const u8 = "$ZIG_VERSION";
pub const sig_version: [:0]const u8 = "$SIG_VERSION";
pub const semver: @import("std").SemanticVersion = .{ .major = 0, .minor = 17, .patch = 0 };
pub const dev: enum { full, bootstrap, ast_gen, sema, cbe, @"aarch64-linux", @"powerpc-linux", @"riscv64-linux", spirv, wasm, @"x86_64-linux" } = .full;
EOF

llvm_link_flags=()
for library in "$LLVM_PREFIX"/lib/lib*.a; do
  [ -f "$library" ] || continue
  [[ "$library" == *.dll.a ]] && continue
  name="$(basename "$library" .a)"
  llvm_link_flags+=("-l${name#lib}")
done
if [ "${#llvm_link_flags[@]}" -eq 0 ]; then
  echo "no static LLVM libraries found under $LLVM_PREFIX/lib" >&2
  exit 1
fi

# Bash 3.2 (the system shell on macOS runners) treats an empty array expansion
# as an unbound variable under `set -u`. Positional parameters are defined even
# when empty, so use them as the optional platform-link-flag vector.
lld_flag=-flld
set --
case "$TARGET" in
  aarch64-macos-none)
    # Zig's bundled LLD does not implement Mach-O linking. A native macOS
    # release must use Apple's system linker from the runner toolchain.
    lld_flag=-fno-lld
    ;;
  x86_64-windows-gnu)
    set -- \
      -lole32 -luuid -lversion -ladvapi32 -lshell32 -luser32 -lws2_32
    ;;
esac

cd "$ROOT"
"$BOOTSTRAP" build-exe \
  -target "$TARGET" \
  -mcpu=baseline \
  "-O$OPTIMIZE" \
  "$strip_flag" \
  -fllvm \
  "$lld_flag" \
  -cflags \
    -std=c++17 \
    -fno-exceptions \
    -fno-rtti \
    -fno-stack-protector \
    -DNDEBUG \
    -D__STDC_CONSTANT_MACROS \
    -D__STDC_FORMAT_MACROS \
    -D__STDC_LIMIT_MACROS \
    "-I$LLVM_PREFIX/include" \
    -isystem lib/libcxx/include \
    -isystem lib/libcxxabi/include \
  -- \
  src/zig_llvm.cpp \
  src/zig_llvm-ar.cpp \
  src/zig_clang_driver.cpp \
  src/zig_clang_cc1_main.cpp \
  src/zig_clang_cc1as_main.cpp \
  --dep build_options \
  --dep aro \
  -Mroot=src/main.zig \
  "-Mbuild_options=$BUILD_OPTIONS" \
  -Maro=lib/compiler/aro/aro.zig \
  --name sig \
  --zig-lib-dir "$ROOT/lib" \
  --cache-dir "$CACHE/compiler" \
  -lc \
  -lc++ \
  "$@" \
  -L "$LLVM_PREFIX/lib" \
  "${llvm_link_flags[@]}" \
  "-femit-bin=$OUTPUT"

case "$TARGET" in
  x86_64-windows-gnu)
    test "$(od -An -tx1 -N2 "$OUTPUT" | tr -d ' \n')" = 4d5a
    file "$OUTPUT" | grep -q 'PE32+.*x86-64'
    ;;
  x86_64-linux-musl)
    test "$(od -An -tx1 -N4 "$OUTPUT" | tr -d ' \n')" = 7f454c46
    file "$OUTPUT" | grep -q 'ELF 64-bit.*x86-64'
    ;;
  aarch64-linux-musl)
    test "$(od -An -tx1 -N4 "$OUTPUT" | tr -d ' \n')" = 7f454c46
    file "$OUTPUT" | grep -q 'ELF 64-bit.*ARM aarch64'
    ;;
  aarch64-macos-none)
    file "$OUTPUT" | grep -q 'Mach-O 64-bit executable arm64'
    ;;
esac

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$OUTPUT"
else
  shasum -a 256 "$OUTPUT"
fi
