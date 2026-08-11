#!/usr/bin/env bash
# [sig] setup-sig — Linux/macOS setup script for the Sig compiler
set -euo pipefail

ACTION="$1"
GITHUB_REPOSITORY="SB0LTD/sig"
GITHUB_RELEASE_BASE="https://github.com/${GITHUB_REPOSITORY}/releases"
GITHUB_API_BASE="https://api.github.com/repos/${GITHUB_REPOSITORY}"

# --- Helpers ---

detect_platform() {
  local os arch machine
  machine="$(uname -m)"
  case "$(uname -s)" in
    Linux*)  os="linux" ;;
    Darwin*) os="macos" ;;
    *)       echo "::error::Unsupported OS: $(uname -s)"; exit 1 ;;
  esac
  case "$machine" in
    x86_64)  arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *)       echo "::error::Unsupported architecture: $machine"; exit 1 ;;
  esac
  if [ "$os" = macos ] && [ "$arch" != aarch64 ]; then
    echo "::error::Sig releases currently support macOS on aarch64 only"
    exit 1
  fi
  echo "${arch}-${os}"
}

resolve_version_from_manifest() {
  local manifest=""
  if [ -f "build.sig.zon" ]; then
    manifest="build.sig.zon"
  elif [ -f "build.zig.zon" ]; then
    manifest="build.zig.zon"
  fi
  if [ -n "$manifest" ]; then
    sed -n 's/.*\.minimum_sig_version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -1
  fi
}

resolve_latest_version() {
  local tag
  tag="$(curl -fsSL "${GITHUB_API_BASE}/releases/latest" \
    | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1)"
  tag="${tag#sig-}"
  echo "$tag"
}

resolve_requested_version() {
  local requested="$1" tag release
  requested="${requested#sig-}"
  if [ -z "$requested" ] || [ "$requested" = latest ]; then
    resolve_latest_version
    return
  fi
  if [ "$requested" = master ]; then
    echo "::error::'master' is not an immutable Sig release; use 'latest' or a version" >&2
    return 1
  fi
  if [[ "$requested" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    while IFS= read -r tag; do
      [ -n "$tag" ] || continue
      release="$(curl -fsSL "${GITHUB_API_BASE}/releases/tags/${tag}")"
      if grep -q '"draft":[[:space:]]*false' <<<"$release" &&
         grep -q '"prerelease":[[:space:]]*false' <<<"$release"; then
        echo "${tag#sig-}"
        return
      fi
    done < <(curl -fsSL "${GITHUB_API_BASE}/releases?per_page=100" \
      | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' \
      | grep -E "^sig-${requested}-zig" \
      || true)
    echo "::error::No stable Sig ${requested} release was found" >&2
    return 1
  fi
  curl -fsSL "${GITHUB_API_BASE}/releases/tags/sig-${requested}" >/dev/null || {
    echo "::error::No published Sig release has identity ${requested}" >&2
    return 1
  }
  echo "$requested"
}

compute_download_url() {
  local version="$1" mirror="$2" triple="$3"
  local base_url="${mirror:-${GITHUB_RELEASE_BASE}/download/sig-${version}}"
  echo "${base_url}/sig-${version}-${triple}.tar.xz"
}

get_zig_cache_dir() {
  case "$(uname -s)" in
    Linux*)  echo "${HOME}/.cache/zig" ;;
    Darwin*) echo "${HOME}/Library/Caches/zig" ;;
  esac
}

# --- Actions ---

action_resolve() {
  local input_version="$2" mirror="${3:-}"
  local version="$input_version"
  local triple
  triple=$(detect_platform)

  if [ -z "$version" ]; then
    version=$(resolve_version_from_manifest)
  fi
  version="$(resolve_requested_version "${version:-latest}")"
  if [ -z "$version" ]; then
    echo "::error::Could not resolve Sig version. Specify one explicitly."
    exit 1
  fi

  local url
  url=$(compute_download_url "$version" "$mirror" "$triple")

  echo "resolved-version=${version}" >> "$GITHUB_OUTPUT"
  echo "download-url=${url}" >> "$GITHUB_OUTPUT"
  echo "platform-triple=${triple}" >> "$GITHUB_OUTPUT"
  echo "Resolved Sig version: ${version} for ${triple}"
}

action_install() {
  local version="$2" url="$3" tool_dir="$4" cache_hit="${5:-false}"

  if [ "$cache_hit" = "true" ] && [ -x "${tool_dir}/bin/sig" ]; then
    echo "Sig ${version} restored from cache"
    return 0
  fi

  echo "Downloading Sig ${version} from ${url}"
  local tmpdir
  tmpdir=$(mktemp -d)
  local tarball="${tmpdir}/sig.tar.xz"

  curl -fsSL "$url" -o "$tarball"

  local checksums_file="${tmpdir}/SHA256SUMS.txt" checksums_name expected actual tarball_name
  checksums_name=""
  for candidate in SHA256SUMS.txt sha256sums.txt; do
    if curl -fsSL "${url%/*}/${candidate}" -o "$checksums_file" 2>/dev/null; then
      checksums_name="$candidate"
      break
    fi
  done
  if [ -z "$checksums_name" ]; then
    echo "::error::Release checksum manifest is unavailable" >&2
    rm -rf "$tmpdir"
    exit 1
  fi
  tarball_name="$(basename "$url")"
  expected="$(awk -v name="$tarball_name" '$2 == name { print $1; exit }' "$checksums_file")"
  if ! [[ "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    echo "::error::${tarball_name} is absent from ${checksums_name}" >&2
    rm -rf "$tmpdir"
    exit 1
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$tarball" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "$tarball" | awk '{print $1}')"
  fi
  if [ "$expected" != "$actual" ]; then
    echo "::error::Checksum mismatch! Expected: ${expected}, Got: ${actual}" >&2
    rm -rf "$tmpdir"
    exit 1
  fi
  echo "Checksum verified via ${checksums_name}"

  # Extract
  mkdir -p "$tool_dir"
  tar -xJf "$tarball" -C "$tool_dir" --strip-components=1
  rm -rf "$tmpdir"

  echo "Sig ${version} installed to ${tool_dir}"
}

action_cache_limit() {
  local limit_mib="$2"
  local cache_dir
  cache_dir=$(get_zig_cache_dir)

  if [ ! -d "$cache_dir" ]; then
    return 0
  fi

  local size_bytes size_mib
  if du -sb "$cache_dir" &>/dev/null; then
    size_bytes=$(du -sb "$cache_dir" | awk '{print $1}')
  else
    # macOS: du -sk gives kilobytes
    size_bytes=$(( $(du -sk "$cache_dir" | awk '{print $1}') * 1024 ))
  fi
  size_mib=$((size_bytes / 1048576))

  if [ "$size_mib" -gt "$limit_mib" ]; then
    echo "Zig cache (${size_mib} MiB) exceeds limit (${limit_mib} MiB) — clearing"
    rm -rf "$cache_dir"
  else
    echo "Zig cache size: ${size_mib} MiB (limit: ${limit_mib} MiB)"
  fi
}

# --- Dispatch ---

case "$ACTION" in
  resolve)     action_resolve "$@" ;;
  install)     action_install "$@" ;;
  cache-limit) action_cache_limit "$@" ;;
  *)           echo "::error::Unknown action: $ACTION"; exit 1 ;;
esac
