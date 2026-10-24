#!/usr/bin/env bash
# Build and execute the aarch64-sb0 native backend runtime probes as SB0K images under QEMU.
# Every probe is built in ReleaseSafe (-fno-compiler-rt) and ReleaseSmall, must print its PASS
# marker and must not print its FAIL marker. The compile step runs under `timeout` so a compiler
# hang (for example a non-terminating FieldPartIterator request) fails the test instead of the job.
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
COMPILE_TIMEOUT="${SB0_COMPILE_TIMEOUT:-120}"
cd "$ROOT"
# name|probe source|PASS marker (the FAIL marker is the PASS marker with PASS replaced by FAIL)
PROBES=(
  "database|test/sb0_database_codegen_probe.sig|SB0-DATABASE-CODEGEN-PASS"
  "partsplit|test/sb0_partsplit_probe.sig|SB0-PARTSPLIT-PASS"
  "float-eu|test/sb0_float_errunion_probe.sig|SB0-FLOAT-EU-PASS"
  "aggregate|test/sb0_aggregate_load_probe.sig|SB0-AGG-PASS"
  "overflow|test/sb0_overflow_probe.sig|SB0-OVF-PASS"
)
for entry in "${PROBES[@]}"; do
  IFS='|' read -r name source marker <<<"$entry"
  for mode in ReleaseSafe ReleaseSmall; do
    image="$WORK/$name-$mode.sb0k"
    runtime=()
    if [[ "$mode" == ReleaseSafe ]]; then runtime=(-fno-compiler-rt); fi
    timeout "$COMPILE_TIMEOUT" "$SIG" build-exe "$source" \
      -target aarch64-sb0 -mcpu=baseline "-O$mode" \
      --Sig-lib-dir "$ROOT/lib" --script test/sb0_runner.ld \
      -fno-stack-check -fno-stack-protector -fno-unwind-tables -fstrip "${runtime[@]}" \
      --cache-dir "$WORK/cache-$name-$mode" "-femit-bin=$image"
    python3 - "$QEMU" "$image" "$WORK/$name-$mode.serial.log" "$marker" <<'PY'
import pathlib, struct, subprocess, sys
qemu, path, log, marker = sys.argv[1:]
assert marker.endswith('-PASS')
fail_marker = marker[:-len('PASS')] + 'FAIL'
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
assert (marker + '\n').encode() in output, (output, errors)
assert fail_marker.encode() not in output, output
print(f'native backend probe passed: {path}')
PY
  done
done

# Vectors are not supported by the aarch64-sb0 backend: `@mulWithOverflow` of vectors has to be rejected
# with a diagnostic (compiler exit status 1 and an error line naming the vector type), not crash the compiler.
cat >"$WORK/vector_mulo.sig" <<'SIG'
const std = @import("std");
pub const panic = std.debug.no_panic;
export fn _start() callconv(.c) noreturn {
    var a: @Vector(4, u32) = .{ 1, 2, 3, 4 };
    _ = &a;
    const r = @mulWithOverflow(a, a);
    const flag: [4]u1 = r[1];
    while (flag[0] == 0) {}
    while (true) {}
}
SIG
set +e
negative_output="$(timeout "$COMPILE_TIMEOUT" "$SIG" build-exe "$WORK/vector_mulo.sig" \
  -target aarch64-sb0 -mcpu=baseline -OReleaseSmall --Sig-lib-dir "$ROOT/lib" --script test/sb0_runner.ld \
  -fno-stack-check -fno-stack-protector -fno-unwind-tables -fstrip \
  --cache-dir "$WORK/cache-vector-mulo" "-femit-bin=$WORK/vector_mulo.sb0k" 2>&1)"
negative_status=$?
set -e
if [[ "$negative_status" != 1 ]] || ! grep -Eq 'error:.*Vector' <<<"$negative_output"; then
  echo "vector @mulWithOverflow must fail with a diagnostic (status $negative_status):" >&2
  echo "$negative_output" >&2
  exit 1
fi
echo "native backend negative test passed: vector @mulWithOverflow is rejected"