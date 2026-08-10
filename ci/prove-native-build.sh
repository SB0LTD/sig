#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <sig-executable> <zig-lib-directory>" >&2
    exit 2
fi

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
sig_dir="$(CDPATH= cd -- "$(dirname -- "$1")" && pwd -P)"
sig="$sig_dir/$(basename -- "$1")"
zig_lib_dir="$(CDPATH= cd -- "$2" && pwd -P)"
proof_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/sig-native-build-proof.XXXXXX")"
default_project="$proof_root/default"
custom_project="$proof_root/custom"
mkdir -p "$default_project" "$custom_project"
cp "$script_dir/fixtures/native-build/build.sig" "$default_project/build.sig"
cp "$script_dir/fixtures/native-build/build.sig" "$custom_project/project.sig"

export ZIG_LIB_DIR="$zig_lib_dir"

(
    cd "$default_project"
    "$sig" build --help \
        --cache-dir "$proof_root/default-cache" \
        --global-cache-dir "$proof_root/global-cache" >help.txt
    grep -q '^Native build file:.*build.sig$' help.txt
    grep -q '^  native-release-proof' help.txt
    test ! -e build.zig
    test ! -e native-sig-build.proof
    "$sig" build native-release-proof \
        --cache-dir "$proof_root/default-cache" \
        --global-cache-dir "$proof_root/global-cache"
    grep -qx 'native build.sig executed' native-sig-build.proof
)

(
    cd "$custom_project"
    "$sig" build --build-file project.sig --help \
        --cache-dir "$proof_root/custom-cache" \
        --global-cache-dir "$proof_root/global-cache" >help.txt
    grep -q '^Native build file:.*project.sig$' help.txt
    grep -q '^  native-release-proof' help.txt
    test ! -e build.sig
    test ! -e build.zig
)

echo "native build.sig package proof passed: $sig"
