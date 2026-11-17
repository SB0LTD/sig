#!/usr/bin/env bash
# Execute aggregate, optional, atomic and wire-reader regressions as native SB0K.
set -euo pipefail
if [[ $# != 2 ]]; then
  echo "usage: $0 SIG OUTPUT_DIRECTORY" >&2
  exit 2
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIG="$(realpath "$1")"
mkdir -p "$2"
WORK="$(realpath "$2")"
QEMU="${SB0_QEMU:-qemu-system-aarch64}"
cd "$ROOT"
for mode in ReleaseSafe ReleaseSmall; do
  image="$WORK/database-$mode.sb0k"
  runtime=()
  if [[ "$mode" == ReleaseSafe ]]; then runtime=(-fno-compiler-rt); fi
  "$SIG" build-exe test/sb0_database_codegen_probe.sig \
    -target aarch64-sb0 -mcpu=baseline "-O$mode" \
    --Sig-lib-dir "$ROOT/lib" --script test/sb0_runner.ld \
    -fno-stack-check -fno-stack-protector -fno-unwind-tables -fstrip "${runtime[@]}" \
    --cache-dir "$WORK/cache-$mode" "-femit-bin=$image"
  python3 - "$QEMU" "$image" "$WORK/$mode.serial.log" <<'PY'
import pathlib, struct, subprocess, sys
qemu, path, log = sys.argv[1:]
data = pathlib.Path(path).read_bytes()
assert data[:4] == b'SB0K' and len(data) >= 64
assert struct.unpack_from('<HHH', data, 4) == (1, 64, 1)
entry, size = struct.unpack_from('<QQ', data, 16)
assert size == len(data) and 64 <= entry < size
words = struct.unpack_from(f'<{(len(data) - 64) // 4}I', data, 64)
# Verify order, access width and the retry in the emitted baseline machine code.
# Operand register fields vary with the optimizer and are masked here.
encodings = {
    'LDAR X': (0xfffffc00, 0xc8dffc00),
    'LDAR W (unused value)': (0xfffffc00, 0x88dffc00),
    'STLR X': (0xfffffc00, 0xc89ffc00),
    'LDAXRB': (0xfffffc00, 0x085ffc00),
    'STLRB': (0xfffffc00, 0x089ffc00),
    'LDXR X': (0xfffffc00, 0xc85f7c00),
    'STXR X': (0xffe0fc00, 0xc8007c00),
    'LDAXRH': (0xfffffc00, 0x485ffc00),
    'STLXRH': (0xffe0fc00, 0x4800fc00),
    'CLREX': (0xffffffff, 0xd5033f5f),
    'CBNZ -12': (0xffffffe0, 0x35ffffa0),
}
for name, (mask, encoding) in encodings.items():
    assert any(word & mask == encoding for word in words), f'missing {name}: {path}'
command = [qemu, '-machine', 'virt', '-cpu', 'cortex-a57', '-m', '128M',
           '-display', 'none', '-monitor', 'none', '-serial', 'stdio', '-no-reboot',
           '-device', f'loader,file={path},addr=0x40200000,force-raw=on',
           '-device', f'loader,addr={0x40200000 + entry:#x},cpu-num=0']
process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    output, errors = process.communicate(timeout=8)
except subprocess.TimeoutExpired:
    process.terminate()
    try:
        output, errors = process.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        output, errors = process.communicate(timeout=3)
pathlib.Path(log).write_bytes(output + errors)
assert b'SB0-DATABASE-CODEGEN-PASS\n' in output, (output, errors)
assert b'SB0-DATABASE-CODEGEN-FAIL' not in output, output
print(f'native database codegen passed: {path}')
PY
done
