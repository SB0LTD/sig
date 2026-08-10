#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <bootstrap-tag> <llvm-tag> <source-commit> <source-workflow-run>" >&2
  exit 2
fi

bootstrap_tag="$1"
llvm_tag="$2"
source_commit="$3"
source_workflow_run="$4"

: "${GH_TOKEN:?GH_TOKEN must authorize release reads and writes}"
: "${GH_REPO:?GH_REPO must identify the owner/repository explicitly}"
[[ "$GH_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
[[ "$bootstrap_tag" =~ ^bootstrap-sig-v[0-9]+$ ]]
[[ "$llvm_tag" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]]
[[ "$source_workflow_run" =~ ^https://github.com/[^/]+/[^/]+/actions/runs/[0-9]+$ ]]

expected=(
  bootstrap-sig-x86_64-linux.tar.zst
  bootstrap-sig-aarch64-linux.tar.zst
  bootstrap-sig-aarch64-macos.tar.zst
  bootstrap-sig-x86_64-windows.tar.zst
)
aggregate_names=(
  BOOTSTRAP-SHA256SUMS.txt
  bootstrap-build-manifest.json
)

workdir="$(mktemp -d)"
trap 'rm -rf -- "$workdir"' EXIT
cd "$workdir"
mkdir checksums provenance

gh release download "$bootstrap_tag" --repo "$GH_REPO" --pattern '*.sha256' --dir checksums
gh release download "$bootstrap_tag" --repo "$GH_REPO" --pattern '*.provenance.txt' --dir provenance
release_json="$(gh release view "$bootstrap_tag" --repo "$GH_REPO" --json assets,isDraft,isPrerelease)"
base_assets_json="$(
  jq '{assets: [.assets[] | select(
    .name != "BOOTSTRAP-SHA256SUMS.txt" and
    .name != "bootstrap-build-manifest.json"
  )]}' <<<"$release_json"
)"
test "$(jq '.assets | length' <<<"$base_assets_json")" -eq 12

: > BOOTSTRAP-SHA256SUMS.txt
for archive in "${expected[@]}"; do
  sidecar="checksums/${archive}.sha256"
  provenance="provenance/${archive}.provenance.txt"
  test -s "$sidecar"
  test -s "$provenance"

  expected_hash="$(awk '{print $1}' "$sidecar")"
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]]
  archive_digest="$(jq -r --arg name "$archive" '.assets[] | select(.name == $name) | .digest' <<<"$base_assets_json")"
  test "$archive_digest" = "sha256:${expected_hash}"

  sidecar_hash="$(sha256sum "$sidecar" | awk '{print $1}')"
  sidecar_digest="$(jq -r --arg name "${archive}.sha256" '.assets[] | select(.name == $name) | .digest' <<<"$base_assets_json")"
  test "$sidecar_digest" = "sha256:${sidecar_hash}"

  provenance_hash="$(sha256sum "$provenance" | awk '{print $1}')"
  provenance_digest="$(jq -r --arg name "${archive}.provenance.txt" '.assets[] | select(.name == $name) | .digest' <<<"$base_assets_json")"
  test "$provenance_digest" = "sha256:${provenance_hash}"
  grep -Fxq 'schema=sb0.sig.bootstrap.v1' "$provenance"
  grep -Fxq "artifact=${archive}" "$provenance"
  grep -Fxq "llvm_artifact_tag=${llvm_tag}" "$provenance"
  grep -Fxq "sig_source_commit=${source_commit}" "$provenance"
  grep -Fxq "workflow_run=${source_workflow_run}" "$provenance"

  printf '%s  %s\n' "$expected_hash" "$archive" >> BOOTSTRAP-SHA256SUMS.txt
done

manifest_assets="$(jq '.assets | sort_by(.name) | map({name, size, digest})' <<<"$base_assets_json")"
jq -n \
  --arg schema 'sb0.sig.bootstrap-release.v1' \
  --arg tag "$bootstrap_tag" \
  --arg llvm_artifact_tag "$llvm_tag" \
  --arg sig_source_commit "$source_commit" \
  --arg workflow_run "$source_workflow_run" \
  --argjson assets "$manifest_assets" \
  '{schema:$schema, tag:$tag, llvm_artifact_tag:$llvm_artifact_tag, sig_source_commit:$sig_source_commit, workflow_run:$workflow_run, assets:$assets}' \
  > bootstrap-build-manifest.json

gh release upload "$bootstrap_tag" --repo "$GH_REPO" --clobber \
  BOOTSTRAP-SHA256SUMS.txt bootstrap-build-manifest.json

final_release="$(gh release view "$bootstrap_tag" --repo "$GH_REPO" --json assets,isDraft,isPrerelease)"
test "$(jq '.assets | length' <<<"$final_release")" -eq 14
for aggregate in "${aggregate_names[@]}"; do
  local_hash="$(sha256sum "$aggregate" | awk '{print $1}')"
  remote_digest="$(jq -r --arg name "$aggregate" '.assets[] | select(.name == $name) | .digest' <<<"$final_release")"
  test "$remote_digest" = "sha256:${local_hash}"
done

if [[ "$(jq -r .isDraft <<<"$final_release")" == true ]]; then
  gh release edit "$bootstrap_tag" --repo "$GH_REPO" --draft=false --prerelease
fi
published_state="$(gh release view "$bootstrap_tag" --repo "$GH_REPO" --json isDraft,isPrerelease)"
test "$(jq -r .isDraft <<<"$published_state")" = false
test "$(jq -r .isPrerelease <<<"$published_state")" = true
