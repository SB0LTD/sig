#!/usr/bin/env bash
# Execute aggregate, optional and wire-reader regressions as native SB0K.
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
