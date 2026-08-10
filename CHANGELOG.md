# Changelog

All notable changes to Sig are documented here.

Sig follows [Semantic Versioning](https://semver.org/). Release tags encode both the sig version and the upstream Zig version: `sig-X.Y.Z-zigA.B.C.<sha>`.

## [0.3.1] — 2026-08-10 — Nexus Compatibility

Patch release adding Nexus array repetition support and merging outstanding
compiler branches into the release train.

### Added
- Array repetition (`array_mul`) ZIR instruction printing support for Nexus
  compatibility.

### Changed
- Bumped the Sig language/toolchain version to 0.3.1.
- Merged `codex/nexus-sig-compat` branch: restores `.**` array repetition
  parsing and ZIR generation required by Nexus workloads.

### Fixed
- Upstream Maker migration routing `sig build` through transitional
  `build.zig`/`std.Build` instead of the native fixed-capacity `build.sig`
  runner. Native dispatch is explicit again, supports custom `.sig` build
  files, reports the resolved graph in `--help`, and is package-tested by
  executing both callback and nested compiler steps with no `build.zig`
  present.
- An old-base conflict resolution in the Nexus array-repetition merge that
  replaced modern parser recovery and pointer-modifier behavior. The restored
  `**` grammar now composes with current parser recovery, type-info, and
  formatter semantics.
- Nested compile and test steps sharing the build host's local compiler cache,
  which could poison manifests and make every child command exit silently.
  Each scheduled step now gets a deterministic fixed-capacity local namespace,
  while the global compiler cache remains explicitly shared for reuse.
- `print_zir.zig` missing handler for the `array_mul` instruction (introduced
  alongside `from_backing_int` in the same instruction range).

## [0.3.0] — 2026-08-10 — Native by Construction

Sig 0.3.0 turns the release pipeline into a fail-closed, four-target release
train and establishes the allocator-free native SB0 compiler foundation.

### Highlights
- **Four full LLVM toolchains** — x86_64 Linux, aarch64 Linux, aarch64 macOS,
  and x86_64 Windows ship with the same LLVM 22.1.8 target closure.
- **Sig builds every final Sig** — the production release stage never invokes
  upstream Zig; Windows is cross-compiled by the proven Linux Sig and then
  executed on a Windows runner.
- **Native SB0 target foundation** — strict, fixed-capacity target modeling,
  parsing, semantic analysis, code generation, linking, and SB0X verification.
- **Immutable provenance** — LLVM, bootstrap, and final releases carry exact
  source commits, workflow runs, per-archive SHA-256 hashes, and aggregate
  machine-readable manifests.

### Added
- Full `aarch64-linux-musl` LLVM closure and release executable.
- Native LLVM bootstrap closures for Linux, macOS, and Windows plus target
  closures and verified bootstrap packages for all four release platforms.
- Packaged execution, strict `.sig` parsing, and AArch64 object-generation
  probes on Linux, macOS, Windows, and QEMU aarch64 Linux.
- Native packages launch the build runner against their own matching library
  tree, catching incomplete archives and stale `ZIG_LIB_DIR` overrides.
- One canonical 210-test compiler graph covering every native compiler module;
  the same graph runs in bootstrap and final-release jobs on every host.
- Fixed-capacity native compiler modules under `compiler/`, including the
  consolidated SB0 ABI target and deterministic SB0X emission/validation.
- Convenience release assets with stable names alongside immutable versioned
  archives.

### Changed
- Bumped the Sig language/toolchain version to 0.3.0.
- Upgraded the pinned LLVM source from 22.1.3 to 22.1.8.
- LLVM 22.1.8 is pinned to the official signed tag's peeled commit
  `ca7933e47d3a3451d81e72ac174dcb5aa28b59d1`; relative to 22.1.7 it carries
  11 upstream patch commits, including LLD symbol initialization and Hexagon,
  BPF, RISC-V, WebAssembly, and vector-code-generation fixes.
- Bootstrap archives now include their matching standard library and Sig build
  runner, and use zstd level 19 for fast extraction.
- Release publication is atomic at the workflow boundary: incomplete builds
  remain drafts and cannot become a public LLVM or bootstrap dependency.
- GitHub Actions used by every workflow are pinned to exact commits; checkout,
  artifact upload, and artifact download use their current Node.js 24 releases
  so the release train has no forced Node.js 20 compatibility fallback.
- LLVM source, zlib, zstd, and host-native TableGen inputs are commit-pinned;
  cross closures cannot start until their native TableGen tools are proven.
- Annotated dependency tags are recorded by their peeled source commits rather
  than tag-object IDs, so provenance checks identify the trees actually built.
- Windows release jobs install the official zstd 1.5.6 executable from an
  immutable SHA-256-pinned archive instead of relying on a nonexistent package.
- Serialized upstream-sync runs resolve the live `master` tip when they start,
  preventing delayed dispatches from replaying already-integrated commits.
- The `zig1.wasm` regeneration bridge accepts the legacy v41 gzip bootstrap
  only after verifying GitHub's recorded SHA-256 digest; v42 and later continue
  to require their release checksum sidecars.
- `zig1.wasm` regeneration now passes Maker's mandatory first
  `--zig-lib=<path>` argument instead of the compiler-subcommand-only
  `--zig-lib-dir` spelling.
- Native LLVM packaging selects GNU `sha256sum` or BSD/macOS `shasum`
  explicitly and verifies the computed digest, so a completed macOS build
  cannot fail merely because GNU coreutils is absent.
- Native LLVM jobs exercise CMake, Ninja, tar, zstd, and a known SHA-256 vector
  before compilation, moving packaging-environment failures ahead of the
  hour-long all-target build.
- Immutable LLVM tag validation derives its prefix from the canonical
  `LLVM_VERSION`, eliminating a duplicated patch-version literal during LLVM
  upgrades while retaining strict Sig semantic-version validation.
- Incomplete LLVM draft releases can be repaired by closure scope after all
  existing asset triples, GitHub digests, provenance, source pins, and release
  commit identity are re-verified. This preserves successful multi-hour builds
  without weakening the immutable published-release boundary.
- LLVM finalization has an explicit no-rebuild recovery scope and repository
  context, so a manifest/publication failure can revalidate a complete draft
  without rerunning any multi-hour closure build.

### Fixed
- Native LLVM closures recording a producer-only absolute static-zstd path in
  `llvm-config`. Native discovery now relocates missing absolute system-library
  entries by basename into the verified closure, fails early when no exact
  replacement exists, and has a focused CMake regression test. Future Linux
  closures also emit portable `-lzstd` metadata and prove it after relocation.
- Native Windows LLVM version verification now captures `llvm-config` output,
  process status, and the normalized version in PowerShell. This replaces a
  silent `cmd | findstr` failure that occurred after an otherwise successful
  5,939-target build and install.
- Stale `bootstrap-sig-v40` sync manifest override that repeatedly selected a
  compiler too old for `@backingInt`, `@fromBackingInt`, and `@divCeil`.
- Missing Windows assets and invalid/non-executable Windows release binaries.
- macOS releases silently using the no-LLVM backend despite release claims.
- Missing aarch64 Linux artifact despite the documented four-target contract.
- Native `.sig` source files being classified as foreign modules during import
  resolution.
- Bounded build graphs leaking module state or failing when repository-scale
  dependency counts exceeded the original small graph.
- Release jobs deleting and recreating tags, accepting partial matrices, or
  publishing without target-native compiler execution.
- Test-only runtime conditions incorrectly expressed as unconditional
  `@compileError` paths, which made hundreds of assertions compile-time no-ops.
- O(capacity) compile-time free-list initialization at the 65,536-node parser
  bound; recycled object-pool indices now use an O(1) bump-plus-stack design.
- Type interning comparing padded structs and inactive union bytes; equality is
  now semantic and tag-directed.
- Hash maps advertising more entries than buckets. Symbol and external maps now
  derive power-of-two capacities with a compile-time load factor at most 1/2.
- Linker format tests allocating less space than the minimum ELF/PE image and
  omitting the four-byte SB0 entry body from the expected image size.
- `zig1.wasm` regeneration downloading an unpinned upstream nightly instead of
  using a verified, checksummed Sig bootstrap.
- `build_wasm.zig` retaining stale Zig 0.16/Sig 0.1.2 identities; regeneration
  now requires both canonical versions derived from `build.sig`.
- Release executables reporting only the upstream Zig version. `sig version`
  now identifies both toolchains, while the `zig` alias retains its compatible
  machine-readable semantic-version output.
- Installed compilers crashing in Maker when a process-level `ZIG_LIB_DIR`
  selected an older, incompatible library tree; validation now treats that
  version-skew risk as an installation error.
- Source builds feeding Sig's hyphenated release tags into upstream Zig's
  compatibility-version derivation; `git describe` now selects numeric tags.

## [0.2.0] — 2026-06-12 — No More Excuses

Self-sustained release pipeline. Sig builds sig. Three platforms ship.

### Highlights
- **Sig builds sig** — The compiler compiles itself. No cmake, no external zig, no hand-holding.
- **LLVM 22 on Linux** — Full backend with all LLVM targets. One static binary, zero runtime deps.
- **macOS + Windows ship** — Self-hosted backends for aarch64-macos and x86_64-windows.
- **Two-stage pipeline** — Stage 1 builds natively with the bootstrap. Stage 2 cross-compiles for other targets.
- **Upstream zig 0.17.0-dev** — Continuous sync from Codeberg, every commit within minutes.

### Changed
- Release pipeline completely rewritten: two-stage architecture (native → cross)
- Linux binary now includes full LLVM 22 (all targets, all backends)
- macOS/Windows binaries use self-hosted backends (no LLVM dependency)
- Bootstrap upgraded to v28 (LLVM-enabled, handles zig 0.17.0 source)
- build.sig replaces build.zig as the primary build definition
- Version tagging: `sig-X.Y.Z-zigA.B.C.<sha>` format

### Added
- Dynamic LLVM library discovery in release pipeline (no hardcoded lib lists)
- libc++ include path injection for C++ cross-compilation
- Disk space optimization for GitHub Actions runners
- GCP Cloud Run watcher for sub-minute upstream sync latency
- `release-nollvm.yaml` — lightweight no-LLVM release for bootstrap binaries

### Fixed
- C++ standard headers (`<type_traits>`, `<optional>`) not found during cross-compilation
- LLVM static libraries not linked in release builds (undefined symbol errors)
- Disk exhaustion on GitHub free runners during cross-compilation
- sig-sync watcher token permissions (403 on repository_dispatch)

## [0.1.2] — 2026-04-16

LLVM 22 port, self-sustained three-stage release pipeline, and upstream zig 0.16.0 sync.

### Highlights
- **LLVM 22.1.3** — Full port from LLVM 21, all C++ interface layers updated
- **Three-stage CI pipeline** — `build-llvm` → `build-bootstrap` → `release`, fully automated
- **All 3 platforms** — x86_64-linux, aarch64-macos, x86_64-windows ship from the same pipeline
- **Upstream sync** — Merged latest zig 0.16.0 from codeberg (including `@cImport` removal, `round_op` rename, incremental compilation fixes)
- **Sub-6-minute releases** — Down from 4+ hours by packaging bootstrap binaries directly

### Changed
- Ported C++ LLVM interface layer from LLVM 21 to LLVM 22
  - `zig_llvm.cpp`: OptBisect API → interval-based, CPU feature filter for unrecognized features
  - `zig_llvm-ar.cpp`: explicit `StringMap<int, MallocAllocator>`, `AllocatorBase` include
  - Clang driver files: `clang/Driver/Options.h` → `clang/Options/Options.h`
  - `zig_clang_cc1_main.cpp`: `createDiagnostics()` and `createFileManager()` signature updates
  - `zig_clang_cc1as_main.cpp`: deprecated Triple APIs → new overloads
- CMake Find modules updated for LLVM 22 (new libs: `clangOptions`, `clangAnalysisLifetimeSafety`, `clangAnalysisScalable`, `clangFormat`, `clangTooling`, etc.)
- Merged upstream zig 0.16.0: `@cImport` removed, `round_cast` → `round_op`, incremental compilation fixes
- Release pipeline packages bootstrap binaries directly (no 4-hour recompilation)
- `dev.zig`: `.core` now includes `version_command`, `env_command`, `help_command`, `targets_command`, `zen_command`
- `dev.zig`: `.bootstrap` now includes `.legalize` (required by C backend)

### Added
- Three-stage release pipeline: `build-llvm.yaml` → `build-bootstrap.yaml` → `release.yaml`
- Pre-built LLVM 22.1.3 artifacts for all 3 platforms (one-time build, reused across releases)
- `build_wasm.zig` — Minimal build.zig for zig1.wasm generation via zig build system
- `regen-zig1-wasm.yaml` — Automated zig1.wasm regeneration using `setup-sig` action
- `tools/setup-sig` — GitHub Action for installing sig in CI workflows
- `stage1/float_stubs.c` — f16/f80 soft-float stubs for Windows bootstrap linking
- `environ` and `_environ` added to C backend reserved identifiers (Windows UCRT macro collision)
- Windows: `#undef environ` in `zig.h`, `_msize` wrapper for const-qualifier mismatch
- Windows: `zig_static_assert` suppressed on MSVC (struct padding mismatch with old zig1.wasm)
- Windows: `/MD` CRT globally for clang-cl compatibility with pre-built LLVM libs
- `CHANGELOG.md` covering all versions from 0.0.1 through 0.1.2

### Fixed
- `process.zig`: `.unknown` variant is `u32`, not enum — removed erroneous `@intFromEnum`
- `Sema.zig`: `cmp_lte_errors_len` typo, `writeToPackedMemory` type, `resolveValue`/`resolveInst` try removal
- `wasm2c.c`: improved error message for invalid wasm magic bytes
- CMakeLists.txt: `-lm` removal on Windows, circular static lib deps, `_CRT_SECURE_NO_WARNINGS`
- CMakeLists.txt: `MSVC_RUNTIME_LIBRARY` set on all targets for clang-cl
- macOS Gatekeeper quarantine handling in bootstrap download
- zig1.wasm: fixed zstd compression issue (wasm2c expects raw wasm, not compressed)

## [0.1.0] — 2026-04-04

First release built entirely by the sig build system. No cmake, no `std.Build`.

### Added
- Self-hosting release pipeline: `sig build` produces release binaries
- Automated 4-target matrix (x86_64-linux, aarch64-linux, aarch64-macos, x86_64-windows)
- Binary verification (PE/ELF format, `have_llvm` check)
- LLVM package caching in CI
- Bootstrap compiler workflow (`build-bootstrap.yaml`)
- Continuous sig-sync integration (every 6 hours)

### Changed
- Release pipeline migrated from cmake to sig build system
- Bootstrap uses previous sig release (no upstream zig dependency for non-LLVM builds)

### Fixed
- Windows stack overflow in bootstrap (128MB stack)
- Cross-platform packaging (tar.xz for Unix, zip for Windows)


## [0.0.4] — 2026-04-01

Build system maturity and CI stabilization.

### Added
- LLVM 21 pre-built artifacts (`build-llvm.yaml`)
- Sig build runner: fixed-capacity step/module registries, binary cache, topological sort scheduler
- `sig build` as primary build command (replaces cmake for sig-specific builds)

### Changed
- Bootstrap pipeline uses sig 0.0.4 release binaries
- Switched from cmake-based release to sig build system (iterative)

### Fixed
- Build runner compilation on all platforms
- Cache ordering in CI (restore before install)

## [0.0.3-dev] — 2026-03-31

Build system bootstrap experiments.

### Added
- First bootstrap compiler binaries (`bootstrap-sig-v1`)
- Initial sig build runner implementation
- `.sig` file extension support in the compiler

### Changed
- Exploring self-hosting: sig builds sig via `sig build`

## [0.0.2] — 2026-03-29

First published release with binaries.

### Added
- Release binaries for x86_64-linux, aarch64-linux, aarch64-macos, x86_64-windows
- Sig compiler: Zig spoon with `.sig` file extension
- Strict mode: allocator usage diagnostics (warnings in `.zig`, errors in `.sig`)
- Capacity-first standard library APIs (`sig.fmt`, `sig.containers`, `sig.io`)
- Four explicit capacity errors: `BufferTooSmall`, `CapacityExceeded`, `DepthExceeded`, `QuotaExceeded`
- Sig_Sync: continuous upstream zig integration
- LLVM 21 backend support

## [0.0.1] — 2026-03-24

Initial commit. Zig compiler fork with sig extensions.

### Added
- Forked from upstream Zig (codeberg.org/ziglang/zig)
- Basic project structure
- License (same as upstream Zig)
