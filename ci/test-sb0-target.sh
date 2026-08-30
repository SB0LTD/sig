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
test -f "$ROOT/test/sb0_custom_entry_probe.sig"
test -f "$ROOT/test/sb0_target_contract.sig"

"$SIG" test "$ROOT/test/sb0_target_contract.sig" \
  --Sig-lib-dir "$ROOT/lib" \
  -j1 \
  --cache-dir "$TMP/unit-cache" \
  --global-cache-dir "$TMP/global-cache"

# SB0 targets are served by the self-hosted backend and its native SB0X linker
# (src/link/Sb0.sig): -fllvm/-flld are rejected, and the emitted container is a
# 64-byte SB0X header + one 40-byte RX segment descriptor + the code payload
# (which begins at Sb0Format.payloadOffset(1) == 104).
echo "sb0-target: unit tests passed, now compiling aarch64-sb0 codegen probe..."
"$SIG" build-exe "$ROOT/test/sb0_codegen_probe.sig" \
  -target aarch64-sb0 \
  -ofmt=raw \
  -fno-llvm \
  -OReleaseFast \
  -fno-stack-check \
  -fno-stack-protector \
  -fno-unwind-tables \
  -fstrip \
  --Sig-lib-dir "$ROOT/lib" \
  --cache-dir "$TMP/codegen-cache" \
  --global-cache-dir "$TMP/global-cache" \
  -femit-bin="$TMP/sb0-codegen.bin"
echo "sb0-target: codegen probe compiled OK"

# Offset 0: SB0X magic "SB0X" (0x53 0x42 0x30 0x58). Offset 4: format_version 1.
# The wfe;b. loop payload (5f2003d5 ffffff17) sits at the segment payload
# offset payloadOffset(1) == 104.
codegen_magic="$(od -An -tx1 -N4 "$TMP/sb0-codegen.bin" | tr -d ' \n')"
codegen_fmtver="$(od -An -tx1 -j4 -N1 "$TMP/sb0-codegen.bin" | tr -d ' \n')"
codegen_code8="$(od -An -tx1 -j104 -N8 "$TMP/sb0-codegen.bin" | tr -d ' \n')"
codegen_size="$(wc -c < "$TMP/sb0-codegen.bin" | tr -d ' ')"
echo "sb0-target: codegen probe magic=$codegen_magic fmtver=$codegen_fmtver code8=$codegen_code8 size=$codegen_size"
test "$codegen_magic" = 53423058
test "$codegen_magic" != 7f454c46
test "$codegen_fmtver" = 01
test "$codegen_code8" = 5f2003d5ffffff17
echo "sb0-target: codegen byte assertions passed, compiling custom-entry probe..."

# A first-class SB0 kernel supplies its own reset symbol. The standard library
# must not synthesize a POSIX _start or instantiate host I/O merely because the
# symbol is named something other than `_start`.
"$SIG" build-exe "$ROOT/test/sb0_custom_entry_probe.sig" \
  -target aarch64-sb0 \
  -ofmt=raw \
  -fno-llvm \
  -OReleaseFast \
  -fentry=_image_start \
  -fno-stack-check \
  -fno-stack-protector \
  -fno-unwind-tables \
  -fstrip \
  --Sig-lib-dir "$ROOT/lib" \
  --cache-dir "$TMP/custom-entry-cache" \
  --global-cache-dir "$TMP/global-cache" \
  -femit-bin="$TMP/sb0-custom-entry.bin"
echo "sb0-target: custom-entry probe compiled OK"

custom_magic="$(od -An -tx1 -N4 "$TMP/sb0-custom-entry.bin" | tr -d ' \n')"
custom_fmtver="$(od -An -tx1 -j4 -N1 "$TMP/sb0-custom-entry.bin" | tr -d ' \n')"
custom_code8="$(od -An -tx1 -j104 -N8 "$TMP/sb0-custom-entry.bin" | tr -d ' \n')"
echo "sb0-target: custom-entry magic=$custom_magic fmtver=$custom_fmtver code8=$custom_code8"
test "$custom_magic" = 53423058
test "$custom_magic" != 7f454c46
test "$custom_fmtver" = 01
test "$custom_code8" = 5f2003d5ffffff17
echo "sb0-target: custom-entry assertions passed, running negative target tests..."

expect_failure() {
  local expected="$1"
  shift
  if "$@" 2>"$TMP/failure.txt"; then
    echo "expected command to fail: $*" >&2
    exit 1
  fi
  echo "sb0-target: negative case produced expected failure, checking message for: $expected"
  if ! grep -F "$expected" "$TMP/failure.txt"; then
    echo "sb0-target: MISSING expected message '$expected'. Actual stderr was:" >&2
    cat "$TMP/failure.txt" >&2
    return 1
  fi
}

common=(
  "$SIG" build-exe "$ROOT/test/sb0_codegen_probe.sig"
  --Sig-lib-dir "$ROOT/lib"
  --global-cache-dir "$TMP/global-cache"
)

expect_failure "Sb0 backend requires aarch64 target" \
  "${common[@]}" -target x86_64-sb0 \
  --cache-dir "$TMP/negative-arch" -femit-bin="$TMP/negative-arch.bin"

expect_failure "Sb0 backend requires sb0 ABI" \
  "${common[@]}" -target aarch64-sb0-none \
  --cache-dir "$TMP/negative-abi" -femit-bin="$TMP/negative-abi.bin"

expect_failure "Sb0 backend requires native object format" \
  "${common[@]}" -target aarch64-sb0 -ofmt=elf \
  --cache-dir "$TMP/negative-format" -femit-bin="$TMP/negative-format.bin"

# SB0 is a self-hosted-only target: requesting the LLVM backend must be rejected.
expect_failure "Sb0 targets are served by the self-hosted backend" \
  "${common[@]}" -target aarch64-sb0 -fllvm \
  --cache-dir "$TMP/negative-fllvm" -femit-bin="$TMP/negative-fllvm.bin"

echo "aarch64-sb0 target contract passed: $SIG"
