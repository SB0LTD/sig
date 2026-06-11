# Changelog

All notable changes to Sig are documented here.

Sig follows [Semantic Versioning](https://semver.org/). Release tags encode both the sig version and the upstream Zig version: `sig-X.Y.Z-zigA.B.C.<sha>`.

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
