#!/usr/bin/env bash
# Prove the production compiler's consolidated aarch64-sb0 target contract.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 SIG [SIG_SOURCE_ROOT]" >&2
  exit 2
fi

SIG="$(cd "$(dirname "$1")" && printf '%s/%s\n' "$PWD" "$(basename "$1")")"
ROOT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
TMP="$(mktemp -d "${RUNNER_TEMP:-/tmp}/sig-sb0-target.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

test -x "$SIG"
test -f "$ROOT/test/sb0_codegen_probe.sig"
test -f "$ROOT/test/sb0_target_contract.sig"

"$SIG" test "$ROOT/test/sb0_target_contract.sig" \
  --zig-lib-dir "$ROOT/lib" \
  -j1 \
  --cache-dir "$TMP/unit-cache" \
  --global-cache-dir "$TMP/global-cache"

"$SIG" build-exe "$ROOT/test/sb0_codegen_probe.sig" \
  -target aarch64-sb0 \
  -OReleaseFast \
  -fllvm \
  -flld \
  -fno-stack-check \
  -fno-stack-protector \
  -fno-unwind-tables \
  -fstrip \
  --zig-lib-dir "$ROOT/lib" \
  --cache-dir "$TMP/codegen-cache" \
  --global-cache-dir "$TMP/global-cache" \
  -femit-bin="$TMP/sb0-codegen.bin"

test "$(od -An -tx1 -N8 "$TMP/sb0-codegen.bin" | tr -d ' \n')" = 5f2003d5ffffff17
test "$(od -An -tx1 -N4 "$TMP/sb0-codegen.bin" | tr -d ' \n')" != 7f454c46

expect_failure() {
  local expected="$1"
  shift
  if "$@" 2>"$TMP/failure.txt"; then
    echo "expected command to fail: $*" >&2
    exit 1
  fi
  grep -F "$expected" "$TMP/failure.txt"
}

common=(
  "$SIG" build-exe "$ROOT/test/sb0_codegen_probe.sig"
  --zig-lib-dir "$ROOT/lib"
  --global-cache-dir "$TMP/global-cache"
)

expect_failure "SB0 supports only the aarch64 architecture" \
  "${common[@]}" -target x86_64-sb0 \
  --cache-dir "$TMP/negative-arch" -femit-bin="$TMP/negative-arch.bin"

expect_failure "SB0 operating system and ABI must be selected together" \
  "${common[@]}" -target aarch64-sb0-none \
  --cache-dir "$TMP/negative-abi" -femit-bin="$TMP/negative-abi.bin"

expect_failure "SB0 requires the native raw object format" \
  "${common[@]}" -target aarch64-sb0 -ofmt=elf \
  --cache-dir "$TMP/negative-format" -femit-bin="$TMP/negative-format.bin"

echo "aarch64-sb0 target contract passed: $SIG"
