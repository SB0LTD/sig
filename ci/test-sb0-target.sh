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
  -fno-compiler-rt \
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

# SB0X container layout (see src/link/Sb0Format.sig / src/link/Sb0.sig):
#   offset 0  : magic "SB0X" (0x53 0x42 0x30 0x58)
#   offset 4  : format_version (u8) == 1
#   offset 8  : entry_offset (u64 LE) — the entry point's offset within the
#               segment's virtual address space
#   offset 104: start of the RX code payload (payloadOffset(1) == 64+40)
# The `1: wfe; b 1b` self-loop of the entry function is the 8 bytes
# 5f2003d5 ffffff17, located at file offset 104 + entry_offset.

# Read a little-endian u64 from a file at a byte offset (prints a decimal value).
read_u64_le() {
  # od yields 8 space-separated bytes low..high; fold them into a value.
  local bytes
  bytes="$(od -An -tu1 -j"$2" -N8 "$1")"
  local val=0 shift=0 b
  for b in $bytes; do
    val=$(( val + (b << shift) ))
    shift=$(( shift + 8 ))
  done
  printf '%s\n' "$val"
}

codegen_magic="$(od -An -tx1 -N4 "$TMP/sb0-codegen.bin" | tr -d ' \n')"
codegen_fmtver="$(od -An -tx1 -j4 -N1 "$TMP/sb0-codegen.bin" | tr -d ' \n')"
codegen_entry="$(read_u64_le "$TMP/sb0-codegen.bin" 8)"
codegen_code_off=$(( 104 + codegen_entry ))
codegen_code8="$(od -An -tx1 -j"$codegen_code_off" -N8 "$TMP/sb0-codegen.bin" | tr -d ' \n')"
codegen_size="$(wc -c < "$TMP/sb0-codegen.bin" | tr -d ' ')"
echo "sb0-target: codegen probe magic=$codegen_magic fmtver=$codegen_fmtver entry=$codegen_entry code8@$codegen_code_off=$codegen_code8 size=$codegen_size"
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
  -fno-compiler-rt \
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
custom_entry="$(read_u64_le "$TMP/sb0-custom-entry.bin" 8)"
custom_code_off=$(( 104 + custom_entry ))
custom_code8="$(od -An -tx1 -j"$custom_code_off" -N8 "$TMP/sb0-custom-entry.bin" | tr -d ' \n')"
echo "sb0-target: custom-entry magic=$custom_magic fmtver=$custom_fmtver entry=$custom_entry code8@$custom_code_off=$custom_code8"
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

echo "sb0-target: negatives passed, compiling two-segment (data+bss) probe..."

# A userspace app with mutable data + a large zero-init (BSS) buffer must emit
# TWO SB0X segments: a read-execute segment (code/rodata) and a SEPARATE
# read-write segment (data + bss). The BSS tail must be mem-only — its bytes
# must NOT be stored in the file — so a 1 MiB zero buffer costs ~0 image bytes
# and the process can legally write its own globals under SB0 page permissions.
test -f "$ROOT/test/sb0_data_segment_probe.sig"
"$SIG" build-exe "$ROOT/test/sb0_data_segment_probe.sig" \
  -target aarch64-sb0 \
  -ofmt=raw \
  -fno-llvm \
  -fno-compiler-rt \
  -OReleaseSmall \
  -fno-stack-check \
  -fno-stack-protector \
  -fno-unwind-tables \
  -fstrip \
  --Sig-lib-dir "$ROOT/lib" \
  --cache-dir "$TMP/data-seg-cache" \
  --global-cache-dir "$TMP/global-cache" \
  -femit-bin="$TMP/sb0-data-seg.bin"
echo "sb0-target: two-segment probe compiled OK"

read_u16_le() {
  local bytes val=0 shift=0 b
  bytes="$(od -An -tu1 -j"$2" -N2 "$1")"
  for b in $bytes; do val=$(( val + (b << shift) )); shift=$(( shift + 8 )); done
  printf '%s\n' "$val"
}

ds_magic="$(od -An -tx1 -N4 "$TMP/sb0-data-seg.bin" | tr -d ' \n')"
ds_segcount="$(read_u16_le "$TMP/sb0-data-seg.bin" 16)"
ds_size="$(wc -c < "$TMP/sb0-data-seg.bin" | tr -d ' ')"
# Segment descriptors start at offset 64; each is 40 bytes. Fields (LE):
#   +0 file_offset(u64) +8 vaddr_offset(u64) +16 file_size(u64)
#   +24 mem_size(u64)   +32 flags(u32)
seg0_flags="$(od -An -tx1 -j$((64 + 32)) -N4 "$TMP/sb0-data-seg.bin" | tr -d ' \n')"
seg1_off=$((64 + 40))
seg1_vaddr="$(read_u64_le "$TMP/sb0-data-seg.bin" $((seg1_off + 8)))"
seg1_file="$(read_u64_le "$TMP/sb0-data-seg.bin" $((seg1_off + 16)))"
seg1_mem="$(read_u64_le "$TMP/sb0-data-seg.bin" $((seg1_off + 24)))"
seg1_flags="$(od -An -tx1 -j$((seg1_off + 32)) -N4 "$TMP/sb0-data-seg.bin" | tr -d ' \n')"
echo "sb0-target: two-segment magic=$ds_magic segs=$ds_segcount size=$ds_size"
echo "sb0-target:   seg0 flags=$seg0_flags | seg1 vaddr=$seg1_vaddr file=$seg1_file mem=$seg1_mem flags=$seg1_flags"

# Magic and exactly two segments.
test "$ds_magic" = 53423058
test "$ds_segcount" = 2
# seg0 is read-execute (flags 0b101 = 5 → LE u32 "05000000").
test "$seg0_flags" = "05000000"
# seg1 is read-write (flags 0b011 = 3 → LE u32 "03000000").
test "$seg1_flags" = "03000000"
# seg1 carries the 1 MiB BSS in mem_size but NOT in file_size.
test "$seg1_mem" -ge 1048576
test "$seg1_file" -lt "$seg1_mem"
# The whole image must be far smaller than the 1 MiB BSS it maps — proof the
# zero buffer is not materialized on disk. (Generous ceiling: 256 KiB.)
test "$ds_size" -lt 262144
echo "sb0-target: two-segment RX/RW + NOLOAD-BSS assertions passed"

echo "aarch64-sb0 target contract passed: $SIG"
