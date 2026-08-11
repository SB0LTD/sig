#!/usr/bin/env bash
# Regression test for the shared LLVM-backed release command line. Uses a
# recording compiler so argument-vector behavior is tested without a full link.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p \
  "$TMP/bin" \
  "$TMP/llvm/include/llvm/Config" \
  "$TMP/llvm/lib" \
  "$TMP/source/src" \
  "$TMP/source/lib/std"

touch "$TMP/llvm/include/llvm/Config/llvm-config.h"
touch "$TMP/llvm/lib/libLLVMCore.a"
touch "$TMP/source/src/main.zig" "$TMP/source/lib/std/std.zig"

cat > "$TMP/source/build.sig" <<'EOF'
const zig_version: std.SemanticVersion = .{ .major = 0, .minor = 17, .patch = 0 };
const sig_version_string = "0.3.1";
EOF

cat > "$TMP/bin/recording-sig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$FAKE_ARGS_OUT"
output=""
for arg in "$@"; do
  case "$arg" in
    -femit-bin=*) output="${arg#-femit-bin=}" ;;
  esac
done
test -n "$output"
mkdir -p "$(dirname "$output")"
case "$FAKE_TARGET" in
  x86_64-windows-gnu) printf '\115\132' > "$output" ;;
  *) printf '\177ELF' > "$output" ;;
esac
EOF

cat > "$TMP/bin/file" <<'EOF'
#!/usr/bin/env bash
case "$FAKE_TARGET" in
  aarch64-macos-none) echo "$1: Mach-O 64-bit executable arm64" ;;
  x86_64-windows-gnu) echo "$1: PE32+ executable x86-64" ;;
  *) echo "$1: ELF 64-bit LSB executable x86-64" ;;
esac
EOF
chmod +x "$TMP/bin/recording-sig" "$TMP/bin/file"

run_probe() {
  local target="$1"
  local args="$TMP/${target}.args"
  PATH="$TMP/bin:$PATH" \
    FAKE_ARGS_OUT="$args" \
    FAKE_TARGET="$target" \
    SB0_SIG_ROOT="$TMP/source" \
    "$ROOT/ci/build-self-hosted-release.sh" \
      "$TMP/bin/recording-sig" \
      "$TMP/llvm" \
      "$target" \
      "$TMP/out/$target/sig" \
      "$TMP/cache/$target"
  echo "$args"
}

mac_args="$(run_probe aarch64-macos-none | tail -1)"
if grep -qFx -- '-lole32' "$mac_args"; then
  echo "macOS release received Windows link libraries" >&2
  exit 1
fi
grep -qFx -- '-fno-lld' "$mac_args" || {
  echo "macOS release did not select the native Mach-O linker" >&2
  exit 1
}
if grep -qFx -- '-flld' "$mac_args"; then
  echo "macOS release selected unsupported Mach-O LLD" >&2
  exit 1
fi

windows_args="$(run_probe x86_64-windows-gnu | tail -1)"
grep -qFx -- '-flld' "$windows_args" || {
  echo "Windows release did not select LLD" >&2
  exit 1
}
for flag in -lole32 -luuid -lversion -ladvapi32 -lshell32 -luser32 -lws2_32; do
  grep -qFx -- "$flag" "$windows_args" || {
    echo "Windows release is missing $flag" >&2
    exit 1
  }
done

echo "shared release builder optional-argument probes passed"
