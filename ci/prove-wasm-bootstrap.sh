#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_root="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sig-wasm-bootstrap.XXXXXX")"
trap 'rm -rf "$work_root"' EXIT

cd "$repo_root"

test "$(od -An -tx1 -N4 stage1/zig1.wasm | tr -d ' \n')" = 0061736d

"${CC:-cc}" -std=c99 -O2 \
  stage1/wasm2c.c \
  -o "$work_root/zig-wasm2c"
"$work_root/zig-wasm2c" \
  stage1/zig1.wasm \
  "$work_root/zig1.c"
"${CC:-cc}" -std=c99 -Os -fno-strict-aliasing \
  "$work_root/zig1.c" \
  stage1/wasi.c \
  -lm \
  -o "$work_root/zig1"

"$work_root/zig1" "$repo_root/lib" \
  build-obj \
  -ofmt=c \
  -OReleaseSmall \
  --name wasm-bootstrap-probe \
  "-femit-bin=$work_root/probe.c" \
  -target x86_64-linux-gnu \
  -Mroot=test/behavior/import/empty.zig

test -s "$work_root/probe.c"
echo "zig1.wasm host-shim link and execution proof passed"
