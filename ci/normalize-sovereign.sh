#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# normalize-sovereign.sh
#
# Sig is a sovereign fork of the Zig compiler: the tracked source tree is
# *.sig, imports reference *.sig, and a curated set of identifiers carry the
# sovereign spelling (Sig / sig / SIG) instead of the upstream Zig spelling.
#
# A sig-sync cherry-pick of an upstream (Zig) commit can silently REVERT any of
# these to their upstream form. The sovereign release gate
# (ci/prove-sovereign-source.sh) then fails, and — worse — the compiler may not
# even build, because sovereign-only symbols (e.g. the `.sb0` linker backend,
# the native `cmdBuild` build path, `Ast.Mode.Sig`) disappear.
#
# This script performs the *mechanical, definition-driven* half of the fix
# automatically, and then ALERTS (exits non-zero) on anything it cannot safely
# map so a human converts it by hand rather than shipping broken source.
#
# It is intentionally conservative: it only rewrites tokens whose sovereign
# form is known to exist, and it explicitly PRESERVES the identifiers that are
# legitimately spelled "zig" in the sovereign tree (Zig-compat CLI flags, a
# couple of debug env vars, DWARF/std identifiers that keep the Zig name).
#
# Exit codes:
#   0  clean: tree is sovereign (either already, or after auto-conversion)
#   3  ALERT: residual unmappable `zig` identifiers remain — human review needed
#   1  usage / internal error
#
# Usage:
#   ci/normalize-sovereign.sh            # convert in place, then verify
#   ci/normalize-sovereign.sh --check    # verify only, never mutate (for CI gate)
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
fi

log()  { printf '[sovereign] %s\n' "$*"; }
warn() { printf '[sovereign] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# ALLOWLIST — identifiers that are legitimately spelled with "zig" in the
# sovereign tree and MUST NOT be rewritten. Each entry is a grep -E pattern.
# These come from the last known-good sovereign state; extend deliberately.
# ---------------------------------------------------------------------------
ALLOW_PATTERNS=(
  # Zig-compat CLI flags accepted alongside their --Sig-* aliases.
  '--zig-lib-dir'
  '--zig-lib'
  # Debug/introspection env vars intentionally kept on the upstream name so
  # existing tooling and muscle-memory keep working.
  'ZIG_DEBUG_CMD'
  'ZIG_IS_DETECTING_LIBC_PATHS'
  # The CMake version shim still uses ZIG_VERSION_* keys (build.sig is the
  # release authority; this is only the compat-version source).
  'ZIG_VERSION_(MAJOR|MINOR|PATCH)'
  # DWARF language constant registered upstream under the Zig name; the
  # sovereign LANG enum keeps `Sig` but comments/DW references may mention Zig.
  'DW_LANG_Zig'
  # Historical strings in user-facing help/error text that quote the word
  # "zig" as part of a compatibility explanation are matched here loosely;
  # keep this list tight and prefer converting real identifiers.
)

# ---------------------------------------------------------------------------
# NAME MAP — sovereign identifier rewrites. Format: "PATTERN=>REPLACEMENT"
# applied with perl word-boundary-aware substitution over tracked *.sig files.
# Only add mappings whose REPLACEMENT is a real sovereign symbol.
# ---------------------------------------------------------------------------
NAME_MAP=(
  # std namespace: the sovereign standard library is std.sig, referenced as
  # `std.sig.` (never `std.zig.`).
  'std\.zig\.=>std.sig.'
  # Environment variable enum members carrying the SIG_ prefix.
  'EnvVar\.ZIG_LIB_DIR\b=>EnvVar.SIG_LIB_DIR'
  'EnvVar\.ZIG_GLOBAL_CACHE_DIR\b=>EnvVar.SIG_GLOBAL_CACHE_DIR'
  'EnvVar\.ZIG_LOCAL_CACHE_DIR\b=>EnvVar.SIG_LOCAL_CACHE_DIR'
  'EnvVar\.ZIG_VERBOSE_LINK\b=>EnvVar.SIG_VERBOSE_LINK'
  'EnvVar\.ZIG_VERBOSE_CC\b=>EnvVar.SIG_VERBOSE_CC'
  'EnvVar\.ZIG_VERBOSE_CMD\b=>EnvVar.SIG_VERBOSE_CMD'
  'EnvVar\.ZIG_LIBC\b=>EnvVar.sig_libC'
  # Directories struct field + Compilation.Path.Root enum member.
  '\.override_zig_lib\b=>.override_sig_lib'
  '\bzig_lib_path\b=>sig_lib_path'
  '\.zig_lib\b=>.sig_lib'
  # Ast.Mode / Compilation.FileExt sovereign member is `.Sig` (capital).
  # Only the enum-literal switch prong / assignment form is converted; the
  # `.zon` sibling and `.zig` file-extension *strings* are left untouched.
  '^(\s*)\.zig =>=>\1.Sig =>'
  # DWARF LANG constant member.
  'DW\.LANG\.Zig\b=>DW.LANG.Sig'
  # Command enum members for the test subcommands.
  '\bzig_test_obj\b=>Sig_test_obj'
  '\bzig_test\b=>Sig_test'
  # jitCmd option field names.
  '\bprepend_zig_lib_dir_path\b=>prepend_SIG_LIB_DIR_path'
  '\bprepend_zig_exe_path\b=>prepend_Sig_exe_path'
  # The maker JIT root source file.
  '"Maker\.zig"=>"Maker.sig"'
)

changed=0

# --- 1. tracked .zig files -------------------------------------------------
NEW_ZIG="$(git ls-files '*.zig' || true)"
if [ -n "$NEW_ZIG" ]; then
  while IFS= read -r zf; do
    [ -z "$zf" ] && continue
    if [ "$CHECK_ONLY" = "1" ]; then
      warn "tracked upstream .zig source present: $zf"
      changed=1
      continue
    fi
    if [ "$zf" = "build.zig" ]; then
      # build.sig is the sovereign build authority; drop the upstream file.
      log "rm build.zig (superseded by build.sig)"
      git rm -q "$zf"
    else
      log "rename $zf -> ${zf%.zig}.sig"
      git mv "$zf" "${zf%.zig}.sig"
    fi
    changed=1
  done <<< "$NEW_ZIG"
fi

# --- 2. @import("*.zig") path strings -------------------------------------
ZIG_IMPORTERS="$(git grep -l -E '@import\("[^"]*\.zig"\)' -- '*.sig' || true)"
if [ -n "$ZIG_IMPORTERS" ]; then
  while IFS= read -r sf; do
    [ -z "$sf" ] && continue
    if [ "$CHECK_ONLY" = "1" ]; then
      warn "sovereign source imports an upstream .zig file: $sf"
      changed=1
      continue
    fi
    log "rewrite @import(...zig) -> .sig in $sf"
    perl -0777 -pi -e 's/(\@import\("[^"]*)\.zig("\))/$1.sig$2/g' "$sf"
    git add "$sf"
    changed=1
  done <<< "$ZIG_IMPORTERS"
fi

# The strict sovereign identifier map is enforced ONLY over the compiler
# proper (src/, tools/). lib/std/Build/* and lib/std/sig/* deliberately keep
# some upstream-compatible spellings (e.g. `std.Build.Step.Run.zig_test`,
# `std.zig.Ast` parser-compat tests, Maker's ZIG_* build env vars), and test
# fixtures reference them. Applying the map there would corrupt legitimate,
# always-sovereign code that never carried the Sig spelling.
STRICT_PATHSPECS=(':(glob)src/**/*.sig' ':(glob)tools/**/*.sig' 'build.sig')

# --- 3. identifier NAME MAP ------------------------------------------------
if [ "$CHECK_ONLY" != "1" ]; then
  for entry in "${NAME_MAP[@]}"; do
    pat="${entry%%=>*}"
    rep="${entry##*=>}"
    # Find files containing the upstream form, then rewrite them.
    hits="$(git grep -lE "$pat" -- "${STRICT_PATHSPECS[@]}" || true)"
    [ -z "$hits" ] && continue
    while IFS= read -r sf; do
      [ -z "$sf" ] && continue
      log "map /$pat/ -> $rep in $sf"
      perl -0777 -pi -e "s/${pat}/${rep}/mg" "$sf"
      git add "$sf"
      changed=1
    done <<< "$hits"
  done
fi

# --- 4. ALERT on residual unmappable `zig` identifiers ---------------------
# Build an allow-regex, then look for the token `zig`/`Zig`/`ZIG` in tracked
# *.sig source that is NOT part of an allowed pattern. This is the "if deeper,
# it should alert" gate: anything the mechanical map didn't catch is surfaced
# for human conversion instead of being shipped.
allow_re="$(printf '%s|' "${ALLOW_PATTERNS[@]}")"
allow_re="${allow_re%|}"

# Candidate residual patterns that indicate a real reversion the map missed.
RESIDUAL_PATTERNS=(
  'std\.zig\.'
  'EnvVar\.ZIG_[A-Z_]+'
  '\.override_zig_lib\b'
  '\.zig_lib\b'
  '\bzig_lib_path\b'
  'DW\.LANG\.Zig\b'
  '\bzig_test(_obj)?\b'
  '\bprepend_zig_(lib_dir|exe)_path\b'
  '"Maker\.zig"'
)

residual=0
# Write the residual report OUTSIDE the working tree when possible, so a
# subsequent `git add -A` (e.g. in sig-sync) never accidentally commits this
# scratch artifact. Prefer the CI runner temp dir, then the system temp dir,
# and only fall back to the repo's ignored-ish .build/ as a last resort.
report_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
if [ ! -d "$report_dir" ] || [ ! -w "$report_dir" ]; then
  report_dir="$ROOT/.build"
  mkdir -p "$report_dir"
fi
residual_report="$report_dir/sovereign-residual.txt"
: > "$residual_report"

# 4a. Identifier residuals are only an error inside the strict compiler tree
#     (src/, tools/, build.sig). Elsewhere these tokens are legitimate.
for pat in "${RESIDUAL_PATTERNS[@]}"; do
  matches="$(git grep -nE "$pat" -- "${STRICT_PATHSPECS[@]}" | grep -Ev -e "$allow_re" || true)"
  if [ -n "$matches" ]; then
    residual=1
    {
      printf '### residual /%s/ (strict tree: src/, tools/, build.sig)\n' "$pat"
      printf '%s\n\n' "$matches"
    } >> "$residual_report"
  fi
done

# 4b. Tree-wide absolutes: no tracked .zig source, no @import of a .zig file.
#     These hold for the ENTIRE repository regardless of subtree.
if git ls-files '*.zig' | grep -q .; then
  residual=1
  { printf '### tracked .zig files remain (forbidden anywhere)\n'; git ls-files '*.zig'; printf '\n'; } >> "$residual_report"
fi
zig_imports="$(git grep -nE '@import\("[^"]*\.zig"\)' -- '*.sig' || true)"
if [ -n "$zig_imports" ]; then
  residual=1
  { printf '### @import of a .zig file remains (forbidden anywhere)\n'; printf '%s\n\n' "$zig_imports"; } >> "$residual_report"
fi

if [ "$residual" = "1" ]; then
  warn "ALERT: residual upstream 'zig' identifiers remain after auto-conversion."
  warn "The mechanical NAME MAP could not safely resolve these; human review required."
  warn "See $residual_report:"
  cat "$residual_report" >&2 || true
  exit 3
fi

if [ "$CHECK_ONLY" = "1" ]; then
  log "check passed: source is sovereign, no residual upstream zig identifiers."
  exit 0
fi

if [ "$changed" = "1" ]; then
  log "sovereign normalization applied; changes staged."
else
  log "nothing to normalize; source already sovereign."
fi
exit 0
