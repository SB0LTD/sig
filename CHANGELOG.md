# Changelog

All notable changes to Sig are documented here.

Sig follows [Semantic Versioning](https://semver.org/). The version string includes the upstream Zig version it tracks: `sig X.Y.Z+zigA.B.C.<sha>`.

## [0.1.2] — 2026-04-14

LLVM 22 upgrade and self-sustained release pipeline.

### Changed
- Ported C++ LLVM interface layer from LLVM 21 to LLVM 22
  - `zig_llvm.cpp`: OptBisect API → interval-based `setIntervals()`
  - `zig_llvm-ar.cpp`: explicit `StringMap<int, MallocAllocator>`
  - Clang driver files: `clang/Driver/Options.h` → `clang/Options/Options.h`
  - `zig_clang_cc1_main.cpp`: `GetResourcesPath` moved to `clang/Options/OptionUtils.h`, `createDiagnostics()` and `createFileManager()` signature updates
  - `zig_clang_cc1as_main.cpp`: deprecated StringRef APIs → Triple overloads
- CMake Find modules updated for LLVM 22 (new libs: `clangOptions`, `clangAnalysisLifetimeSafety`, `clangFormat`, `clangTooling`, etc.)
- Sig build runner LLVM discovery updated for version 22
- All documentation and build references updated from LLVM 21 to LLVM 22

### Added
- Three-stage release pipeline: `build-llvm` → `build-bootstrap` → `release`
- Pre-built LLVM 22.1.3 artifacts for x86_64-linux, aarch64-macos, x86_64-windows
- LLVM-enabled bootstrap compiler via cmake+ninja
- `update-zig1-wasm` workflow for seed compiler regeneration
- Matrix CI builds for LLVM and bootstrap across all platforms
- `CHANGELOG.md`

### Fixed
- `process.zig`: signal enum → u32 casts for zig2 type strictness
- `Sema.zig`: erroneous `try` on `resolveValue`/`resolveInst`
- CMakeLists.txt: `-lm` removal on Windows, circular static lib deps
- macOS Gatekeeper quarantine handling

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
