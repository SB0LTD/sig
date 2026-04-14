# Changelog

All notable changes to Sig are documented here.

Sig follows [Semantic Versioning](https://semver.org/). The version string includes the upstream Zig version it tracks: `sig X.Y.Z (zig A.B.C-dev)`.

## [0.1.2] — 2026-04-14

The first LLVM 22 release. Sig now builds against LLVM 22.1.3 across all platforms, with a fully self-sustained release pipeline (no upstream zig dependency at release time).

### Changed
- Ported C++ LLVM interface layer from LLVM 21 to LLVM 22
  - `zig_llvm.cpp`: OptBisect API migrated to interval-based `setIntervals()`
  - `zig_llvm-ar.cpp`: explicit `StringMap<int, MallocAllocator>` for LLVM 22 forward declaration compatibility
  - `zig_clang_driver.cpp`, `zig_clang_cc1_main.cpp`, `zig_clang_cc1as_main.cpp`: header path migration (`clang/Driver/Options.h` → `clang/Options/Options.h`), namespace updates, deprecated API replacements
- CMake Find modules updated for LLVM 22 (Findllvm, Findclang, Findlld)
- Added new LLVM 22 clang libraries: `clangOptions`, `clangAnalysisLifetimeSafety`, `clangAnalysisFlowSensitive`, `clangFormat`, `clangTooling`, and others
- Sig build runner LLVM discovery updated for version 22
- All documentation references updated from LLVM 21 to LLVM 22

### Added
- Three-stage release pipeline: `build-llvm` → `build-bootstrap` → `release`
- Pre-built LLVM 22 artifacts for x86_64-linux, aarch64-macos, x86_64-windows
- LLVM-enabled bootstrap compiler (zig2 with LLVM backend)
- `update-zig1-wasm` workflow for regenerating the seed compiler
- Matrix CI builds for LLVM and bootstrap across all platforms

### Fixed
- `process.zig`: signal enum type casts for zig2 compiler strictness
- `Sema.zig`: removed erroneous `try` on `resolveValue` and `resolveInst` (non-error-union returns)
- CMakeLists.txt: `find_package` version bumped to 22, `-lm` removal on Windows, double-listed libs for circular dependency resolution
- macOS Gatekeeper quarantine handling for downloaded binaries

### Infrastructure
- Replaced apt.llvm.org packages with official LLVM release archives (consistent headers across platforms)
- Windows LLVM build uses MSVC dev shell via `Enter-VsDevShell`
- Build timeouts tuned for each platform (up to 6h for Windows LLVM from source)


## [0.1.1] — 2026-04-05

CI and release pipeline improvements.

### Added
- Self-hosting release pipeline: sig builds sig (transitional zig bootstrap for stage 1)
- GitHub Actions release workflow with 4-target matrix (x86_64-linux, aarch64-linux, aarch64-macos, x86_64-windows)
- Binary verification steps (PE/ELF format check, `have_llvm` validation)
- LLVM package caching across CI runs
- Bootstrap compiler workflow (`build-bootstrap.yaml`)

### Fixed
- Windows stack overflow in bootstrap (64MB → 128MB stack)
- Cross-platform packaging (tar.xz for Unix, zip for Windows)
- Cache ordering in CI (restore before install)

## [0.1.0-dev] — 2026-03-24

Initial development releases. Continuous pre-releases tracking upstream zig.

### Added
- Sig compiler: Zig spoon with `.sig` file extension support
- Strict mode: allocator usage diagnostics (warnings in `.zig`, errors in `.sig`)
- Sig build runner (`sig build`): zero-allocation build system
  - Fixed-capacity step/module registries (104KB for 256 steps)
  - Binary cache with O(1) lookup
  - Sub-10ms configure phase
- Capacity-first standard library APIs (`sig.fmt.formatInto`, `sig.containers.BoundedVec`, `sig.io.StreamReader`)
- Sig_Sync: continuous upstream zig integration (every 6 hours)
- Four explicit capacity errors: `BufferTooSmall`, `CapacityExceeded`, `DepthExceeded`, `QuotaExceeded`
- LLVM 21 backend support
- Release binaries for x86_64-linux, aarch64-linux, aarch64-macos, x86_64-windows
