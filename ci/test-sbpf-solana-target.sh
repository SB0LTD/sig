#!/usr/bin/env bash
# Prove the production compiler's Solana sBPF (sbf-solana-solana) target: build
# the on-chain entrypoint probe into a loadable ELF `.so` and byte-verify both
# the loader-contract layout (FEAT-001 PC3) and the SIMD-0178 static-syscall
# immediate (FEAT-004 / PC-SYS).
#
# The authoritative assertions are raw byte reads (od), so this script needs no
# external disassembler — the cross LLVM release closures are built with
# LLVM_BUILD_TOOLS=OFF and ship no bin/llvm-objdump. If an llvm-objdump IS on
# PATH (or in an optional LLVM_PREFIX/bin), it is used for a human-readable
# cross-check only; its absence never fails the gate.
#
# Usage: test-sbpf-solana-target.sh SIG [SIG_SOURCE_ROOT] [LLVM_PREFIX]
#
#   SIG              the LLVM-backed Sig compiler under test (BPF codegen needs LLVM)
#   SIG_SOURCE_ROOT  repository root (defaults to this script's parent)
#   LLVM_PREFIX      optional LLVM closure root; if it has bin/llvm-objdump it is
#                    used for a cross-check only
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 SIG [SIG_SOURCE_ROOT] [LLVM_PREFIX]" >&2
  exit 2
fi

SIG="$(cd "$(dirname "$1")" && printf '%s/%s\n' "$PWD" "$(basename "$1")")"
ROOT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
LLVM_PREFIX="${3:-}"
TMP="$(mktemp -d "${RUNNER_TEMP:-/tmp}/sig-sbpf-solana.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

test -x "$SIG"
test -f "$ROOT/test/sbpf_solana_entrypoint_probe.sig"

OUT="$TMP/sbpf-solana-program.so"

# sBPF programs are shared objects (ET_DYN). The Solana target is served
# exclusively by the self-hosted ELF linker (Elf2) — the vendored LLD rejects
# EM_BPF (247), so -flld must NOT be used. compiler_rt is off by default for
# the solana os/tag (its soft-float helpers fail to lower for BPF); the whole
# syscall surface is resolved by the loader, so no runtime libraries are linked.
echo "sbpf-solana: compiling entrypoint probe to a loadable .so ..."
"$SIG" build-lib \
  -dynamic \
  -target sbf-solana-solana \
  -OReleaseSmall \
  -fstrip \
  --Sig-lib-dir "$ROOT/lib" \
  --cache-dir "$TMP/cache" \
  --global-cache-dir "$TMP/global-cache" \
  -femit-bin="$OUT" \
  "$ROOT/test/sbpf_solana_entrypoint_probe.sig"
echo "sbpf-solana: compiled OK -> $OUT"

# ── ELF loader-contract layout (FEAT-001 PC3, design §4.4) ────────────────
# e_ident / header fields are at fixed offsets:
#   +0  magic      7f 45 4c 46 ("\x7fELF")
#   +4  EI_CLASS   == 2 (ELFCLASS64)
#   +5  EI_DATA    == 1 (ELFDATA2LSB, little-endian)
#   +16 e_type     (u16 LE) == 3 (ET_DYN)        -> bytes "03 00"
#   +18 e_machine  (u16 LE) == 247 (EM_BPF)      -> bytes "f7 00"
magic="$(od -An -tx1 -N4 "$OUT" | tr -d ' \n')"
ei_class="$(od -An -tx1 -j4 -N1 "$OUT" | tr -d ' \n')"
ei_data="$(od -An -tx1 -j5 -N1 "$OUT" | tr -d ' \n')"
e_type="$(od -An -tx1 -j16 -N2 "$OUT" | tr -d ' \n')"
e_machine="$(od -An -tx1 -j18 -N2 "$OUT" | tr -d ' \n')"
size="$(wc -c < "$OUT" | tr -d ' ')"
echo "sbpf-solana: magic=$magic class=$ei_class data=$ei_data e_type=$e_type e_machine=$e_machine size=$size"
test "$magic" = 7f454c46
test "$ei_class" = 02
test "$ei_data" = 01
test "$e_type" = 0300       # ET_DYN, u16 LE
test "$e_machine" = f700    # EM_BPF (247), u16 LE
echo "sbpf-solana: ELF header assertions passed"

# ── SIMD-0189 program-header shape (finalizeBpfSolanaObject output) ───────
# The sBPF finalizer rewrites the generic multi-segment image into the strict
# SIMD-0189 layout the loader's header parser requires. Assert that shape here
# so this gate matches the committed finalizer and a regression that bypasses
# it (reverting to the pre-SIMD-0189 e_phoff=65536 / 7-phdr layout) fails CI:
#   +32 e_phoff     (u64 LE) == 64   -> "40 00 00 00 00 00 00 00"
#   +40 e_shoff     (u64 LE) == 0    (no section headers; loader ignores them)
#   +54 e_phentsize (u16 LE) == 56   -> "38 00"
#   +56 e_phnum     (u16 LE) == 2    -> "02 00"
#   +60 e_shnum     (u16 LE) == 0
# The two program headers are PT_LOAD (p_type==1): phdr[0] PF_R at vaddr 0,
# phdr[1] PF_X at vaddr 0x1_0000_0000. phdr table starts at offset 64, each
# Elf64_Phdr is 56 bytes: p_type@+0 (u32), p_flags@+4 (u32), p_vaddr@+16 (u64).
e_phoff="$(od -An -tx1 -j32 -N8 "$OUT" | tr -d ' \n')"
e_shoff="$(od -An -tx1 -j40 -N8 "$OUT" | tr -d ' \n')"
e_phentsize="$(od -An -tx1 -j54 -N2 "$OUT" | tr -d ' \n')"
e_phnum="$(od -An -tx1 -j56 -N2 "$OUT" | tr -d ' \n')"
e_shnum="$(od -An -tx1 -j60 -N2 "$OUT" | tr -d ' \n')"
echo "sbpf-solana: e_phoff=$e_phoff e_shoff=$e_shoff e_phentsize=$e_phentsize e_phnum=$e_phnum e_shnum=$e_shnum"
test "$e_phoff" = 4000000000000000      # 64, u64 LE
test "$e_shoff" = 0000000000000000      # 0  (no section headers)
test "$e_phentsize" = 3800              # 56, u16 LE
test "$e_phnum" = 0200                  # 2,  u16 LE
test "$e_shnum" = 0000                  # 0,  u16 LE

# phdr[0] @ file offset 64: PT_LOAD (p_type==1) PF_R (p_flags==4) vaddr 0.
p0_type="$(od -An -tx1 -j64 -N4 "$OUT" | tr -d ' \n')"
p0_flags="$(od -An -tx1 -j68 -N4 "$OUT" | tr -d ' \n')"
p0_vaddr="$(od -An -tx1 -j80 -N8 "$OUT" | tr -d ' \n')"
# phdr[1] @ file offset 120 (64+56): PT_LOAD PF_X (p_flags==1) vaddr 1<<32.
p1_type="$(od -An -tx1 -j120 -N4 "$OUT" | tr -d ' \n')"
p1_flags="$(od -An -tx1 -j124 -N4 "$OUT" | tr -d ' \n')"
p1_vaddr="$(od -An -tx1 -j136 -N8 "$OUT" | tr -d ' \n')"
echo "sbpf-solana: phdr[0] type=$p0_type flags=$p0_flags vaddr=$p0_vaddr | phdr[1] type=$p1_type flags=$p1_flags vaddr=$p1_vaddr"
test "$p0_type" = 01000000               # PT_LOAD
test "$p0_flags" = 04000000              # PF_R
test "$p0_vaddr" = 0000000000000000      # rodata segment mapped at VA 0
test "$p1_type" = 01000000               # PT_LOAD
test "$p1_flags" = 01000000              # PF_X
test "$p1_vaddr" = 0000000001000000      # bytecode segment at 0x1_0000_0000, u64 LE
echo "sbpf-solana: SIMD-0189 program-header layout assertions passed"

# ── SIMD-0178 static-syscall immediate (FEAT-004 / PC-SYS) ────────────────
# A BPF static syscall is the 8-byte instruction:
#   opcode 0x85 | regs 0x00 (src reg 0) | off 0x0000 | imm32 (LE)
# For sol_log_, imm32 == murmur3_32("sol_log_") == 0x207559bd, so the exact
# instruction bytes are:  85 00 00 00 bd 59 75 20
# Scanning the raw image for this literal sequence proves two things at once:
#   (1) the call lowered to a fixed immediate equal to the murmur3 hash, and
#   (2) no syscall relocation was emitted — a relocated call would carry a zero
#       (or placeholder) immediate plus a reloc entry, not the baked hash.
# This is tool-free (no llvm-objdump needed) and version-independent.
image_hex="$(od -An -tx1 "$OUT" | tr -d ' \n')"
# 85 00 00 00 (call, src reg 0) + bd 59 75 20 (imm 0x207559bd little-endian).
needle="85000000bd597520"
echo "sbpf-solana: searching image for static-syscall instruction bytes $needle"
if ! printf '%s' "$image_hex" | grep -iq "$needle"; then
  echo "sbpf-solana: FAIL — did not find the 'call 0x207559bd' instruction bytes ($needle)" >&2
  echo "sbpf-solana: image hex dump follows:" >&2
  od -An -tx1 "$OUT" >&2
  exit 1
fi
echo "sbpf-solana: static-syscall immediate 0x207559bd confirmed in .text (SIMD-0178, no relocation)"

# Publish the exact byte-verified .so as the release artifact when requested
# (mirrors SB0_RUNNER_OUTPUT in test-sb0-runner.sh) so the shipped program is
# precisely the one these assertions ran against — never a second rebuild.
if [ -n "${SBPF_SOLANA_OUTPUT:-}" ]; then
  mkdir -p "$(dirname "$SBPF_SOLANA_OUTPUT")"
  cp "$OUT" "$SBPF_SOLANA_OUTPUT"
fi

# ── Optional human-readable cross-check (never gates) ─────────────────────
objdump=""
if [ -n "$LLVM_PREFIX" ] && [ -x "$LLVM_PREFIX/bin/llvm-objdump" ]; then
  objdump="$LLVM_PREFIX/bin/llvm-objdump"
elif command -v llvm-objdump >/dev/null 2>&1; then
  objdump="$(command -v llvm-objdump)"
fi
if [ -n "$objdump" ]; then
  echo "sbpf-solana: llvm-objdump cross-check ($objdump) ->"
  "$objdump" -d --mcpu=v3 "$OUT" 2>/dev/null | grep -iE '\bcall\b' || true
else
  echo "sbpf-solana: no llvm-objdump available; byte-level assertion above is authoritative"
fi

echo "sbf-solana-solana target contract passed: $SIG"
