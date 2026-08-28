#!/usr/bin/env bash
# Prove the release is sourced and orchestrated by Sig rather than upstream Zig.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if git ls-files '*.zig' | grep -q .; then
  echo 'tracked upstream .zig source is forbidden in a Sovereign release' >&2
  git ls-files '*.zig' >&2
  exit 1
fi

sig_sources="$(git ls-files '*.sig' | wc -l | tr -d ' ')"
test "$sig_sources" -ge 3000
test -f build.sig
test -f src/main.sig
test -f lib/std/std.sig
test -f lib/sig/sig.sig
test -f tools/sig_build/main.sig
test -f tools/sig_build/build_host.sig

grep -Fq 'const sig_build = @import("sig_build");' build.sig
grep -Fq 'return cmdBuild(gpa, arena, io, cmd_args, environ_map);' src/main.sig

if git grep -En '@import\("[^"]*\.zig"\)' -- '*.sig'; then
  echo 'Sig source imports an upstream .zig file' >&2
  exit 1
fi

if git grep -En '(^|[[:space:]])zig(\.exe)?[[:space:]]' -- \
  .github/workflows/release.yaml \
  .github/workflows/build-bootstrap.yaml \
  ci/build-self-hosted-release.sh; then
  echo 'release orchestration invokes upstream Zig' >&2
  exit 1
fi

printf 'Sovereign source proof passed: %s tracked .sig files, zero tracked .zig files\n' "$sig_sources"
