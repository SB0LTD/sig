#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <sig-executable> <Sig-lib-directory>" >&2
    exit 2
fi

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
sig_dir="$(CDPATH= cd -- "$(dirname -- "$1")" && pwd -P)"
sig="$sig_dir/$(basename -- "$1")"
SIG_LIB_DIR="$(CDPATH= cd -- "$2" && pwd -P)"
proof_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/sig-native-build-proof.XXXXXX")"
default_project="$proof_root/default"
custom_project="$proof_root/custom"
mkdir -p "$default_project" "$custom_project"
cp "$script_dir/fixtures/native-build/build.sig" "$default_project/build.sig"
cp "$script_dir/fixtures/native-build/build.sig" "$custom_project/project.sig"
cp "$script_dir/fixtures/native-build/native_test.sig" "$default_project/native_test.sig"
cp "$script_dir/fixtures/native-build/native_test.sig" "$custom_project/native_test.sig"
cp "$script_dir/fixtures/native-build/target_probe.sig" "$default_project/target_probe.sig"
cp "$script_dir/fixtures/native-build/target_probe.sig" "$custom_project/target_probe.sig"

export SIG_LIB_DIR="$SIG_LIB_DIR"
prove_cross_target="${PROVE_CROSS_TARGET:-1}"

(
    cd "$default_project"
    echo "prove-native-build: running 'sig build --help'..."
    if ! "$sig" build --help \
        --cache-dir "$proof_root/default-cache" \
        --global-cache-dir "$proof_root/global-cache" >help.txt 2>help.err; then
        echo "prove-native-build: 'sig build --help' FAILED (exit $?). stdout:" >&2
        cat help.txt >&2 || true
        echo "prove-native-build: stderr:" >&2
        cat help.err >&2 || true
        exit 1
    fi
    echo "prove-native-build: 'sig build --help' OK"
    grep -q '^Native build file:.*build.sig$' help.txt
    grep -q '^  native-release-proof' help.txt
    grep -q '^  native-release-test' help.txt
    grep -q '^  native-target-proof' help.txt
    test ! -e build.zig
    test ! -e native-sig-build.proof
    "$sig" build native-release-proof \
        -Dregression-sentinel=preserved \
        --cache-dir "$proof_root/default-cache" \
        --global-cache-dir "$proof_root/global-cache"
    grep -qx 'native build.sig executed' native-sig-build.proof
    # Diagnostic: isolate whether the recursive panic is in the build runner or
    # the nested `sig test` it spawns. Run the same test directly first.
    echo "prove-native-build: running native_test.sig directly via 'sig test'..."
    if "$sig" test --stack 33554432 -Mroot=native_test.sig \
        --cache-dir "$proof_root/direct-test-cache" \
        --global-cache-dir "$proof_root/global-cache" \
        --Sig-lib-dir "$SIG_LIB_DIR"; then
        echo "prove-native-build: direct 'sig test' PASSED"
    else
        echo "prove-native-build: direct 'sig test' FAILED with exit $?"
    fi
    echo "prove-native-build: now running build runner 'native-release-test'..."
    "$sig" build native-release-test \
        --cache-dir "$proof_root/default-cache" \
        --global-cache-dir "$proof_root/global-cache"
    if [[ "$prove_cross_target" = 1 ]]; then
        "$sig" build native-target-proof \
            -Dtarget=wasm32-wasi \
            -Doptimize=ReleaseSmall \
            --cache-dir "$proof_root/target-cache" \
            --global-cache-dir "$proof_root/global-cache"
        target_magic="$(od -An -tx1 -N4 sig-out/bin/native-target-proof | awk '{ for (i = 1; i <= NF; i++) printf "%s", $i }')"
        file sig-out/bin/native-target-proof
        echo "native target magic: $target_magic"
        test "$target_magic" = 0061736d
    fi
)

(
    cd "$custom_project"
    "$sig" build --build-file project.sig --help \
        --cache-dir "$proof_root/custom-cache" \
        --global-cache-dir "$proof_root/global-cache" >help.txt
    grep -q '^Native build file:.*project.sig$' help.txt
    grep -q '^  native-release-proof' help.txt
    grep -q '^  native-release-test' help.txt
    grep -q '^  native-target-proof' help.txt
    test ! -e build.sig
    test ! -e build.zig
)

echo "native build.sig package proof passed: $sig"
