#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_root="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sig-wasm-bootstrap.XXXXXX")"
if [[ "${SIG_WASM_KEEP_WORK:-0}" = 1 ]]; then
  echo "WebAssembly bootstrap work directory: $work_root"
else
  trap 'rm -rf "$work_root"' EXIT
fi

trace_flags=()
if [[ "${SIG_WASM_TRACE:-0}" = 1 ]]; then
  trace_flags=(-DLOG_TRACE=1)
fi

cd "$repo_root"

test "$(od -An -tx1 -N4 stage1/zig1.wasm | tr -d ' \n')" = 0061736d

"${CC:-cc}" -std=c99 -O2 \
  stage1/wasm2c.c \
  -o "$work_root/zig-wasm2c"
"$work_root/zig-wasm2c" \
  stage1/zig1.wasm \
  "$work_root/zig1.c"
"${CC:-cc}" -std=c99 -Os -fno-strict-aliasing \
  "${trace_flags[@]}" \
  "$work_root/zig1.c" \
  stage1/wasi.c \
  -lm \
  -o "$work_root/zig1"

sig_version="$(sed -n 's/^const sig_version_string = "\([^"]*\)".*/\1/p' build.sig | head -1)"
zig_version="$(sed -n 's/^const zig_version:.*major = \([0-9]*\), \.minor = \([0-9]*\), \.patch = \([0-9]*\).*/\1.\2.\3/p' build.sig | head -1)"
test -n "$sig_version"
test -n "$zig_version"
sed \
  -e "s/@RESOLVED_SIG_VERSION@/$sig_version/g" \
  -e "s/@RESOLVED_ZIG_VERSION@/$zig_version/g" \
  stage1/config.zig.in > "$work_root/config.zig"

"$work_root/zig1" "$repo_root/lib" \
  build-exe \
  -ofmt=c \
  -lc \
  -OReleaseSmall \
  --name zig2 \
  "-femit-bin=$work_root/zig2.c" \
  -target x86_64-linux \
  --dep build_options \
  -Mroot=src/main.zig \
  "-Mbuild_options=$work_root/config.zig"

test -s "$work_root/zig2.c"
echo "zig1.wasm host-shim link and execution proof passed"
