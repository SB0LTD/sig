#!/usr/bin/env bash
# Boot a compiler-produced aarch64-sb0 image as the sole native payload.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 SIG [SIG_SOURCE_ROOT]" >&2
  exit 2
fi

SIG="$(cd "$(dirname "$1")" && printf '%s/%s\n' "$PWD" "$(basename "$1")")"
ROOT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
QEMU="${SB0_QEMU_SYSTEM_AARCH64:-$(command -v qemu-system-aarch64 || true)}"
TMP="$(mktemp -d "${RUNNER_TEMP:-/tmp}/sig-sb0-runner.XXXXXX")"
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

test -x "$SIG"
test -x "$QEMU"

compile_runner() {
  local source="$1"
  local output="$2"
  local cache="$3"
  "$SIG" build-exe "$source" \
  -target aarch64-sb0 \
  -mcpu=baseline \
  -OReleaseFast \
  -fllvm \
  -flld \
  -fno-stack-check \
  -fno-stack-protector \
  -fno-unwind-tables \
  -fstrip \
  -ffunction-sections \
  --script "$ROOT/test/sb0_runner.ld" \
  --zig-lib-dir "$ROOT/lib" \
  --cache-dir "$cache" \
  --global-cache-dir "$TMP/global-cache" \
  -femit-bin="$output"
}

compile_runner \
  "$ROOT/test/sb0_runner_probe.sig" \
  "$TMP/runner.sb0" \
  "$TMP/codegen-cache"

compile_runner \
  "$ROOT/compiler/sb0_native_runner.sig" \
  "$TMP/compiler-runner.sb0" \
  "$TMP/compiler-cache"

test "$(od -An -tx1 -N4 "$TMP/runner.sb0" | tr -d ' \n')" = 5342304b
test "$(od -An -tx1 -N4 "$TMP/compiler-runner.sb0" | tr -d ' \n')" = 5342304b
test "$(od -An -tu2 -j4 -N6 "$TMP/compiler-runner.sb0" | xargs)" = '1 64 1'
test "$(od -An -tu4 -j12 -N4 "$TMP/compiler-runner.sb0" | xargs)" = 1
test "$(od -An -tu8 -j16 -N8 "$TMP/compiler-runner.sb0" | xargs)" = 64
test "$(od -An -tu8 -j24 -N8 "$TMP/compiler-runner.sb0" | xargs)" = \
  "$(stat -c %s "$TMP/compiler-runner.sb0")"
test "$(stat -c %s "$TMP/compiler-runner.sb0")" -le 65536
test "$(od -An -tu8 -j32 -N8 "$TMP/compiler-runner.sb0" | xargs)" = 0
test "$(od -An -tu4 -j40 -N8 "$TMP/compiler-runner.sb0" | xargs)" = '0 0'

for marker in ELF PE-COFF Mach-O linux windows macos android tegu; do
  if LC_ALL=C grep -aFqi "$marker" "$TMP/compiler-runner.sb0"; then
    echo "foreign marker survived in native SB0K runner: $marker" >&2
    exit 1
  fi
done

boot_runner() {
  local image="$1"
  local success="$2"
  local serial="$3"
  local qemu_log="$4"
  local input="$5"
  set +e
  timeout 10s "$QEMU" \
    -machine virt \
    -cpu cortex-a57 \
    -m 128M \
    -display none \
    -monitor none \
    -serial stdio \
    -no-reboot \
    -device "loader,file=$image,addr=0x40200000,force-raw=on" \
    -device "loader,addr=0x40200040,cpu-num=0" \
    <"$input" >"$serial" 2>"$qemu_log"
  status=$?
  set -e

  # Each probe intentionally parks after reporting success, so timeout(1)'s
  # 124 is the only expected termination status.
  if [ "$status" -ne 124 ]; then
    cat "$qemu_log" >&2
    exit "$status"
  fi
  if [ -n "$success" ] && ! grep -Fqx "$success" "$serial"; then
    cat "$serial" >&2
    cat "$qemu_log" >&2
    return 1
  fi
}

boot_runner "$TMP/runner.sb0" 'SB0-RUNNER-PASS' \
  "$TMP/serial.txt" "$TMP/qemu.txt" /dev/null

"$SIG" build-exe "$ROOT/ci/sb0_runner_request.sig" \
  -target x86_64-linux-musl \
  -OReleaseFast \
  -fllvm \
  -flld \
  -fno-stack-protector \
  -fstrip \
  --zig-lib-dir "$ROOT/lib" \
  --cache-dir "$TMP/request-cache" \
  --global-cache-dir "$TMP/global-cache" \
  -femit-bin="$TMP/sb0-runner-request"

"$SIG" build-exe "$ROOT/ci/sb0_runner_client.sig" \
  -target x86_64-linux-musl \
  -OReleaseFast \
  -fllvm \
  -flld \
  -fno-stack-protector \
  -fstrip \
  --zig-lib-dir "$ROOT/lib" \
  --cache-dir "$TMP/client-cache" \
  --global-cache-dir "$TMP/global-cache" \
  -femit-bin="$TMP/sb0-runner-client"

: > "$TMP/empty.sig"
if "$TMP/sb0-runner-request" "$TMP/empty.sig" > /dev/null 2>&1; then
  echo "pure-Sig request tool accepted empty source" >&2
  exit 1
fi
dd if=/dev/zero of="$TMP/oversized.sig" bs=65537 count=1 status=none
if "$TMP/sb0-runner-request" "$TMP/oversized.sig" > /dev/null 2>&1; then
  echo "pure-Sig request tool exceeded its fixed source capacity" >&2
  exit 1
fi
printf 'BAD!' > "$TMP/invalid-response.sb0r"
if "$TMP/sb0-runner-client" "$TMP/invalid-output.sb0x" \
    < "$TMP/invalid-response.sb0r" > /dev/null 2>&1; then
  echo "pure-Sig response tool accepted an invalid frame" >&2
  exit 1
fi
test ! -e "$TMP/invalid-output.sb0x"

"$TMP/sb0-runner-request" \
  "$ROOT/test/sb0_runner_input.sig" > "$TMP/compiler-request.bin"
test "$(od -An -tx1 -N4 "$TMP/compiler-request.bin" | tr -d ' \n')" = 53423043
test "$(od -An -tu2 -j4 -N2 "$TMP/compiler-request.bin" | xargs)" = 1
test "$(od -An -tu4 -j6 -N4 "$TMP/compiler-request.bin" | xargs)" = \
  "$(wc -c < "$ROOT/test/sb0_runner_input.sig")"

set +e
timeout 10s "$QEMU" \
  -machine virt \
  -cpu cortex-a57 \
  -m 128M \
  -display none \
  -monitor none \
  -no-reboot \
  -serial "file:$TMP/compiler-response.bin" \
  -device "loader,file=$TMP/compiler-runner.sb0,addr=0x40200000,force-raw=on" \
  -device "loader,file=$TMP/compiler-request.bin,addr=0x41000000,force-raw=on" \
  -device "loader,addr=0x40200040,cpu-num=0" \
  >"$TMP/compiler-qemu-stdout.txt" 2>"$TMP/compiler-qemu.txt"
status=$?
set -e
test "$status" -eq 124
"$TMP/sb0-runner-client" \
  "$TMP/compiler-output.sb0x" < "$TMP/compiler-response.bin"
test "$(od -An -tx1 -N4 "$TMP/compiler-output.sb0x" | tr -d ' \n')" = 53423058

if [ -n "${SB0_RUNNER_OUTPUT:-}" ]; then
  mkdir -p "$(dirname "$SB0_RUNNER_OUTPUT")"
  cp "$TMP/compiler-runner.sb0" "$SB0_RUNNER_OUTPUT"
fi
echo "aarch64-sb0 native runner passed: $SIG"
