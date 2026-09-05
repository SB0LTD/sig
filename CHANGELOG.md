# Changelog

All notable changes to Sig are documented here.

Sig follows [Semantic Versioning](https://semver.org/). Release tags encode both the Sig version and the upstream Zig language-base version: `sig-X.Y.Z-zigA.B.C.<sha>`.

## [0.5.3] — 2026-09-05 — Freestanding AArch64 Links Soft-Float and Symbol-Address Inline Asm
Sig 0.5.3 lands the last pieces a real bare-metal `aarch64-sb0` program needs to
link: PC-relative symbol-address inline assembly, the self-contained compiler_rt
for the SB0 flat-image target, and the `"S"` inline-asm constraint as a true
symbolic operand.
### Fixed
- The AArch64 inline assembler now accepts PC-relative symbol addressing:
  `adrp <reg>, <symbol>`, `adr <reg>, <symbol>`, and `add <reg>, <reg>, :lo12:<symbol>`,
  emitting the correct in-image relocations (page-hi21 / abs-lo12). Symbol
  operands may be written literally or as an `"S"`-constrained `%[name]`
  reference (e.g. `adrp x0, %[sym]`).
- The `"S"` inline-asm constraint is now a symbolic-address operand: `%[name]`
  substitutes the referenced symbol's name into the instruction text, so
  `bl %[main]` lowers to a relocated branch and `adrp x0, %[main]` to a page
  relocation, matching the GCC/Clang `"S"` semantics. Previously `"S"` was
  rejected, then (0.5.2) mis-handled as a register.
- compiler_rt is now injected directly into the compilation for the SB0
  flat-image target for every output mode (not just objects). The SB0 linker
  produces a single self-contained image and never merges a separate
  compiler_rt object, so soft-float routines such as `__cmptf2`/`__cmpxf2`
  (f80/f128 comparisons) are now present in the image instead of being reported
  as undefined symbols.

## [0.5.2] — 2026-09-05 — Freestanding AArch64 Builds Bare-Metal Projects End To End
Sig 0.5.2 lands the remaining self-hosted AArch64 back-end pieces a freestanding
`aarch64-sb0` program actually needs: wide byte swaps, the `S` inline-assembly
constraint, and the `DMB` barrier. 0.5.1 fixed the compiler_rt trigger but the
back end still rejected these when building a real bare-metal image.
### Fixed
- Scalar integer `@byteSwap` wider than 64 bits (e.g. `u72`, `u120`, reached via
  `std.mem.readPackedIntBig`/`writePackedIntBig` for the `f80`/`f128` soft-float
  routines) is now legalized into a byte-wise reconstruction
  (`shr`/`trunc`/`int_cast`/`shl_exact`/`bit_or`) through a new `expand_byte_swap`
  legalize feature, instead of failing instruction selection with
  "too big byte_swap". Enabled for the AArch64 back end.
- The AArch64 back end now accepts the `"S"` inline-assembly input constraint (an
  absolute symbolic-address operand such as `&func`), materializing the symbol
  address into a general register like `"r"`.
- The AArch64 assembler can now encode `DMB <option>` / `DMB #imm` (e.g.
  `dmb ish`); previously only `DSB` and `ISB` had assembler patterns even though
  the `DMB` encoding already existed.

## [0.5.1] — 2026-09-05 — Freestanding AArch64 Builds Projects Using f80/f128 compiler_rt
Sig 0.5.1 fixes the self-hosted AArch64 back end so freestanding `aarch64-sb0`
projects that pull in the soft-float `f80`/`f128` compiler_rt routines build
end to end. 0.5.0 aborted compiler_rt sub-compilation on these targets.
### Fixed
- compiler_rt soft-float `f80`/`f128` ABI conversion no longer round-trips
  through a packed struct, which forced a `>64`-bit packed memory load the
  self-hosted AArch64 back end cannot lower. It now uses a scalar `u80`/`u128`
  integer bitcast plus shifts (bit-identical, ordinary integer ops).
- The self-hosted AArch64 back end now legalizes `div_ceil` (expanded to
  truncating division plus a remainder adjustment) and packed loads/stores
  (expanded to plain load/shift/truncate), so integer `div_ceil` and packed
  integer access — reached via `std` `readPackedInt` for `f80`/`f128` — compile
  instead of failing isel with "unimplemented div_ceil" / non-power-of-two
  `byte_swap`.

## [0.5.0] — 2026-08-29 — Self-Hosted AArch64 Compiles the Whole Compiler for SB0; SB0K Kernel Images

Sig 0.5.0 completes the self-hosted AArch64 back end far enough to compile the
entire compiler for the native `aarch64-sb0` target with no LLVM, no LLD, and no
foreign object container, and teaches the self-hosted SB0 linker to emit a
bootable `SB0K` kernel image in addition to the `SB0X` userspace image. All
release artifacts remain produced by Sig itself.

### Added
- Complete code generation for non-payload optionals (e.g. `?Token`, a 12-byte
  struct payload plus a one-byte has-value flag) in the self-hosted AArch64
  back end (`src/codegen/aarch64/Select.sig`). Optionals whose payload fits one
  general register keep a clean `[payload][flag]` register decomposition
  matching the ABI; larger ones are treated as memory-resident and copied via
  `memcpy`, so `optional_payload`, `wrap_optional`, `is_null`, the error-union
  unwraps, `store`/`load`/`ret`, and equality comparison all handle aggregate
  optional payloads. New `copyFromField`/`copyIntoField` helpers centralize the
  register-vs-`memcpy` field-copy decision. With these in place the whole
  compiler (`compiler/sb0_native_runner.sig`, which imports all of `main.sig`)
  compiles cleanly for `aarch64-sb0`.
- `SB0K` bootable kernel-image emission in the self-hosted SB0 linker
  (`src/link/Sb0.sig`). The SB0 artifact kind is selected by the presence of a
  linker script: an `aarch64-sb0` link with a linker script (e.g.
  `test/sb0_runner.ld`) emits a fixed-layout `SB0K` image — a 64-byte kernel
  header immediately followed by the reset/entry code at offset 64, with
  `entry_offset`/`total_image_bytes` recorded and no segment table — while a
  link without one emits an `SB0X` userspace image as before. For a fixed-layout
  `SB0K` image the linker anchors the relocation base at
  `preferred_physical_base + header size` so absolute relocations resolve to
  correct load-time addresses.
- Inline-assembly support for `b`/`bl <symbol>` branches to named symbols
  (assembled as relocated branches), and the `CurrentEL` AArch64 system register
  for `mrs`.
- Freestanding `memcpy`/`memset` in the SB0 native runner so a self-contained
  SB0 image links with no external runtime.

### Changed
- The self-hosted SB0 `CallAbiIterator` passes non-payload optionals whose
  payload does not fit a single general register indirectly (by reference),
  keeping only single-register optionals in registers.
- `ci/test-sb0-runner.sh` bounds the native SB0K runner at 64 MiB instead of
  64 KiB: the runner embeds the whole self-hosted compiler and is a
  multi-megabyte kernel image, not a tiny shell. All `SB0K` header-field
  assertions are retained.

### Breaking
- The standard-library compiler-frontend namespace has been renamed from
  `std.zig` to `std.sig`, completing the sovereign rename in the public API.
  There is **no `std.zig` compatibility alias** — `std.zig` is removed. Code
  that used the tokenizer/parser/AST/ZIR surface must migrate:

  | 0.4.x and earlier | 0.5.0+ |
  | --- | --- |
  | `std.zig.Tokenizer` | `std.sig.Tokenizer` |
  | `std.zig.Token` | `std.sig.Token` |
  | `std.zig.Ast` | `std.sig.Ast` |
  | `std.zig.Zir` | `std.sig.Zir` |
  | `std.zig.parse` / `std.zig.render` / `std.zig.fmt` | `std.sig.parse` / `std.sig.render` / `std.sig.fmt` |
  | `std.zig.*` (any member) | `std.sig.*` |

  Migration is a mechanical rename of `std.zig` to `std.sig` in your source.
  Any project or tool that manipulates Sig source (formatters, linters, AST
  tooling) built against 0.4.x will fail to compile on 0.5.0 with
  `error: root source file struct 'std' has no member named 'zig'` until
  updated. This is intentional: Sig's standard library is sovereign, and the
  frontend namespace matches the language name.

## [0.4.2] — 2026-08-29 — spork8 Co-existence & Full Array Multiplication

Sig 0.4.2 reconciles the upstream `spork8` raw-backend feature with the native
SB0 backend so both live in the same tree (the consolidated "Option 3"), and
restores full `**` array-multiplication support that had been missing from the
self-hosted `Sema`. All release artifacts remain produced by Sig itself; no
upstream Zig is used in the release pipeline.

### Added
- Full `a ** b` array/tuple multiplication in the self-hosted `Sema`
  (`src/Sema.sig`): the `array_mul` ZIR instruction is now analyzed end to end.
  The comptime path folds to a constant (with a single-element splat fast path
  and sentinel preservation), the tuple path repeats fields, and the runtime
  path emits either a pointer-address-space allocation with element stores or a
  flat aggregate-init. Previously the ZIR `array_mul` tag had no `Sema` handler,
  so any use of `**` failed to compile.
- `std.Target.isSb0()` predicate: true for the consolidated native SB0 identity
  (`aarch64` + `sb0` OS + `sb0` ABI). Used by the SB0 target-contract tests and
  the codegen probe.

### Changed
- Dual raw-backend co-existence (Option 3): the linker's `fromObjectFormat` maps
  the `raw` object format to the native SB0 backend when `os.tag == .sb0` and to
  the upstream `spork8` backend otherwise, so both raw backends ship together
  without one clobbering the other. `.sb0` is re-established as a first-class
  linker tag/type and `dev` feature (`sb0_linker`).
- The SB0 ABI is now the default ABI for a bare `aarch64-sb0` triple
  (`Target.Abi.default`), so `-target aarch64-sb0` resolves to the full SB0
  contract without an explicit `-sb0` ABI suffix. An explicit ABI
  (e.g. `aarch64-sb0-none`) still overrides the default.
- SB0 targets now force-reserve `x18` during target resolution
  (`std.sig.system.resolveTargetQuery`). The reservation is part of the SB0 ABI
  contract and is mandatory even if the caller attempts to subtract the backend
  feature.

### Fixed
- Sovereign-tree reconciliation after the upstream `spork8` merge, which had
  reintroduced `std.zig` references and dropped `.sig`-mode handling: restored
  `.Sig` (vs `.zig`) mode dispatch in `Sema.doImport` and re-sovereignized the
  affected `Target`/`system` paths.

## [0.4.1] — 2026-08-29 — Self-Hosted SB0 Linking

Sig gains a pure-Sig, self-hosted linker for the native SB0 target. Compiling
`aarch64-sb0` code with `-ofmt=raw -fno-llvm` no longer routes through LLD or
panics with "TODO implement raw object format"; the self-hosted backend emits a
complete SB0X image directly.

### Added
- `src/link/Sb0.sig`: a self-hosted SB0 native linker backend built on the
  incremental `MappedFile` node substrate. It collects AArch64 machine code from
  the self-hosted code generator, resolves relocations in place
  (`branch26`, `adrp`, `add_abs_lo12`, `ldst_abs_lo12`, `abs64`) via the shared
  `link/aarch64.sig` relocation writers, and emits a flat SB0X userspace image
  (64-byte header + one RX segment descriptor + payload).
- External, global, and lazy symbol resolution in the SB0 linker: named runtime
  references (`memset`, `memcpy`, `memmove`, compiler-rt helpers, panic handlers)
  are collected during code generation and bound to in-image definitions at
  flush; genuinely undefined symbols are reported rather than silently dropped.
  This lets ordinary Sig programs — slices, loops, `for`, optionals, error
  unions, bounds checks — compile end to end through the self-hosted path with no
  LLVM.
- A canonical SB0X/SB0K image-format encoder published as the pure, dependency
  free `zpm` module `platform/sb0x` (single source of truth), mirrored
  bootstrap-safely in the compiler as `src/link/Sb0Format.sig` and cross-checked
  by byte-pinned tests so the two cannot drift.
- Cross-OS executable emitters in the zero-alloc compiler's linker for the
  shipped target matrix: AArch64 ELF and PE/COFF alongside the existing x86_64
  paths, and a real (previously header-only) Mach-O executable emitter for
  x86_64 and aarch64.
- GNU-style local labels and label-relative branches in the self-hosted AArch64
  inline assembler (`src/codegen/aarch64/Assemble.sig`, `Select.sig`). Numeric
  label definitions (`1:`) and references (`1b` backward, `1f` forward) are now
  understood, and the full family of immediate branches resolves against them:
  `b`, `bl`, `b.<cond>`, `cbz`, `cbnz`, `tbz`, `tbnz`. Displacements are computed
  in forward program order and back-patched after the block is assembled, so
  self-referential loops such as `1: wfe; b 1b` assemble to the exact expected
  encoding under `-fno-llvm`. Previously such asm errored with
  "unable to assemble: '1:'".
- `callconv(.naked)` support in the self-hosted AArch64 code generator
  (`src/codegen/aarch64.sig`). Naked functions now emit only their body with no
  compiler-managed frame — no register saves, no stack allocation, and no
  epilogue/`ret`. Previously every function, naked or not, received a standard
  `stp x29, x30, [sp, #-16]!; mov x29, sp` prologue, which buried a naked entry
  point's instructions and broke bare-metal SB0 reset/entry code.
- Wide-immediate `mov <reg>, #<imm>` in the self-hosted AArch64 inline assembler:
  any immediate expressible as a single `movz`/`movn` (a 16-bit part shifted by
  0/16/32/48) now assembles, e.g. `mov x9, #0x09000000` → `movz x9, #0x900,
  lsl #16`. Character-literal immediates (`#'S'`, `#'\n'`) are accepted too.
  Previously `mov` only encoded a bare 16-bit value.
- `STRB`/`LDRB` (store/load byte) immediate-addressing patterns in the
  self-hosted AArch64 assembler (`instructions.zon`): base, unsigned-offset, and
  (for STRB) pre/post-indexed forms, needed by bare-metal MMIO code such as the
  SB0 runner probe's PL011 UART writes.

### Changed
- `Config.resolve` routes every SB0 target to the self-hosted backend
  exclusively (SB0X is the native container, not an LLVM/LLD object format);
  `-fllvm` on an SB0 target now errors instead of silently selecting LLVM.

### AArch64 self-hosted code generation
The AArch64 instruction selector gained the lowerings that were blocking
ordinary programs. Verified through a category test corpus that compiles each
form for `aarch64-sb0` with `-fno-llvm`:
- Signed saturating `add_sat`/`sub_sat` (32/64-bit).
- Packed-struct field extraction, both the in-register case and loads from
  memory, via `ubfm`/`sbfm` bitfield extract over the host container.
- Safety-checked `@intFromFloat` (`int_from_float_safe` /
  `int_from_float_optimized_safe`).
- Confirmed that 128-bit float arithmetic and conversions lower correctly to the
  standard compiler-rt routines (`__addtf3`, `__trunctfdf2`, `__extenddftf2`);
  those routines are a runtime-library dependency, not a code-generation gap.

The corpus (wide integers, signed saturation, aggregate ABI, packed structs,
switch ranges, native floats plus int/float conversion, and a representative
program using slices, loops, `for`, optionals, and error unions) compiles fully
through the self-hosted path with no LLVM.

### Known limitations
- The self-hosted backend is **not** yet the default or a full LLVM replacement.
  LLVM remains the release backend for the four LLVM platforms;
  `selfHostedBackendIsAsRobustAsLlvm` still blesses only x86_64-ELF, so this
  release does not flip the default backend selection.
- 128-bit float programs require the compiler-rt routines to be linked (as any
  freestanding image must supply its runtime); the compiler emits the calls but
  does not bundle the library into an SB0 image automatically.
- The safety trap for out-of-range `int_from_float_safe` is not yet emitted; the
  converted value is correct for in-range inputs.
- SB0 self-hosted output is verified to produce structurally valid SB0X images
  and to link real programs on this host; runtime execution of that output is
  validated by the SB0 loader/ABI gates, not by the host build.

## [0.4.0] — 2026-08-28 — Sovereign

Sig now owns its native build and release path end to end. The tracked compiler,
standard library, build runner, and tests contain only `.sig` sources. `sig build`
loads `build.sig` through the allocator-free native runner, and the production
graph compiles the compiler, installs the Sig library, and runs the canonical
213-test compiler suite instead of a placeholder step.

### Added
- An allocation-free, cross-platform directory enumeration layer used by the
  native build runner on Linux, macOS, and Windows.
- A source-sovereignty release gate that rejects tracked `.zig` files, `.zig`
  imports, and upstream `zig` executable calls in bootstrap or release scripts.
- Immutable stage0 provenance in bootstrap manifests.

### Changed
- Normalized Sig-native build, package, environment, protocol, and builtin names
  across the compiler and standard library.
- Restored native `build.sig` dispatch and fixed subprocess output, error-pipe
  draining, Windows standard-handle inheritance, fixed-buffer formatting, and
  real compiler test execution.
- Self-hosted Linux bootstrap builds use the portable LLVM 22.1.8 libc++ closure,
  eliminating the mixed libstdc++/libc++ ABI failure in the abandoned 0.3.3
  bootstrap attempt.
- The release remains on stable LLVM 22.1.8; LLVM 23 was still in release-candidate
  status when 0.4.0 was cut.

## [0.3.3] — 2026-08-26 — Pure .sig Bootstrap

Full bootstrap cycle from 0.3.2 to 0.3.3. The compiler now emits
`sig_backend` in generated builtins, the standard library uses `.sig`
file extensions natively, and all renamed identifiers are resolved
(EnvVar, FileExt, DWARF constants, LLVM builder targets). The `sb0`
OS tag and ABI are handled in the LLVM triple builder. Stage1
(self-hosted backend) compiles cleanly; full LLVM release built on CI.

## [0.3.2] — 2026-08-11 — First-Class SB0 Target

Patch release making the consolidated native SB0 ABI a production compiler
target rather than a freestanding compatibility spelling.

### Added
- First-class `aarch64-sb0` parsing and target identity in the production Sig
  compiler, standard target model, and allocator-free native build API.
- `std.Target.Os.Tag.sb0`, `std.Target.Abi.sb0`, and the strict
  `Target.isSb0()` predicate.
- A release-gating SB0 contract test that compiles a real AArch64 image and
  verifies target identity through `@import("builtin")`.
- A native allocator-free `aarch64-sb0` compiler-service release artifact in
  an SB0K v1 container. The gate boots the artifact, submits source through a
  bounded SB0C frame, and proves the in-guest result is SB0X.
- Strict `.sig` request and response tools backed by fixed 64 KiB storage and
  raw syscalls; the native-runner path has no Python client or validator.
- In-place reset operations for fixed-capacity compiler containers. Native
  phase initialization no longer embeds multi-megabyte zero templates, and the
  release gate caps the compiler-service SB0K file at 64 KiB.

### Changed
- Pinned the 0.3.2 release chain to the four-platform
  `bootstrap-sig-v51` set while retaining the immutable
  `llvm-22.1.8-sig-0.3.1` compiler closure.
- `aarch64-sb0` now defaults to the SB0 ABI, native raw output, no dynamic
  linker, no libc, and no libc++.
- AArch64 register x18 is reserved after every command-line CPU-feature
  override, so callers cannot accidentally produce an ABI-incompatible image.
- LLVM code generation lowers SB0 internally through the platform-neutral
  AAPCS64 triple while retaining `sb0/sb0` in Sig's public target identity.

### Fixed
- SB0 kernels with a custom entry such as `_image_start` incorrectly
  instantiating the POSIX `_start` path and `std.Io.Threaded`. `.sb0` now uses
  the same no-runtime startup policy as freestanding targets, with a raw
  custom-entry release regression.
- Nexus builds having to masquerade as `aarch64-freestanding-none` and
  manually request `+reserve_x18`.
- Invalid `x86_64-sb0`, mismatched OS/ABI, and foreign SB0 output-format
  combinations reaching code generation. They now fail with targeted
  diagnostics.
- Native SB0 output being described as complete without a compiler-level gate
  proving that no ELF header survives the output boundary.

## [0.3.1] — 2026-08-11 — Nexus Compatibility

Patch release adding Nexus array repetition support and merging outstanding
compiler branches into the release train.

### Added
- Array repetition (`array_mul`) ZIR instruction printing support for Nexus
  compatibility.

### Changed
- Bumped the Sig language/toolchain version to 0.3.1.
- Pinned the complete release, regeneration, preservation, sync, and watcher
  chain to the four-platform `bootstrap-sig-v49` set and the immutable
  `llvm-22.1.8-sig-0.3.1` closure.
- Merged `codex/nexus-sig-compat` branch: restores `.**` array repetition
  parsing and ZIR generation required by Nexus workloads.

### Fixed
- Upstream Maker migration routing `sig build` through transitional
  `build.sig`/`std.Build` instead of the native fixed-capacity `build.sig`
  runner. Native dispatch is explicit again, supports custom `.sig` build
  files, reports the resolved graph in `--help`, and is package-tested by
  executing both callback and nested compiler steps with no `build.sig`
  present.
- An old-base conflict resolution in the Nexus array-repetition merge that
  replaced modern parser recovery and pointer-modifier behavior. The restored
  `**` grammar now composes with current parser recovery, type-info, and
  formatter semantics.
- Nested compile and test steps sharing the build host's local compiler cache,
  which could poison manifests and make every child command exit silently.
  Each scheduled step now gets a deterministic fixed-capacity local namespace,
  while the global compiler cache remains explicitly shared for reuse.
- `print_zir.sig` missing handler for the `array_mul` instruction (introduced
  alongside `from_backing_int` in the same instruction range).
- Native build-step names borrowing the process iterator's reusable argument
  buffer. A following `-D` option could corrupt a requested step such as
  `update-zig1`; the runner now copies every name into bounded owned storage.
- Per-module target, optimization, and strip flags being appended after the
  root module declaration, which silently emitted a host binary for requested
  cross targets. The package proof now compiles and verifies a wasm target.
- `zig1.wasm` regeneration still routing through the transitional
  `build_wasm.sig`. A native zero-allocation `build_wasm.sig` now owns the
  exact wasm32-wasi command, canonical bootstrap options, and output check.
- The refreshed `zig1.wasm` importing WASI path timestamp operations without a
  matching native host shim. File-descriptor and path timestamp updates now
  implement WASI flag validation and metadata semantics. The stage-1 WASI
  namespace also exposes a host-root preopen so absolute generated modules are
  not silently rebased onto the source directory. Every bootstrap release now
  proves the complete wasm-to-C link and uses the resulting zig1 compiler to
  compile the real compiler entry point before downloading LLVM closures.
- The shared final-release builder expanding an empty Bash array under
  `set -u`, which is accepted by newer Linux Bash but aborts on macOS Bash 3.2.
  Optional platform link arguments now use the shell's always-defined
  positional vector, preserving the Windows libraries without a macOS special
  case. Bootstrap and stable release preflights now regression-test both the
  empty macOS vector and the complete Windows library vector before building.
  Release concurrency is keyed by the complete source identity, so a corrected
  immutable revision can run without cancelling or waiting behind an already
  doomed older revision.
- The shared builder forcing LLD for Mach-O even though the bundled linker only
  supports the ELF/PE release paths. Target policy now selects Apple's native
  linker for aarch64 macOS and retains LLD for Linux and Windows; the preflight
  rejects either policy regressing.
- Upstream sync using fork ancestry even though integration is intentionally
  cherry-pick based. The durable upstream cursor now prevents duplicate
  dispatches from replaying the same commits, and the sync manifest records
  the exact bootstrap/LLVM pair used by subsequent builds and releases.
- Upstream sync blindly reusing the next numeric bootstrap identity and then
  polling a failed draft for three hours. Rebuilds now skip every existing
  draft/tag, track the exact dispatched workflow, fail immediately on any
  terminal non-success conclusion, and require its published four-platform
  manifest plus a fresh consumer probe.
- `setup-sig` still resolving releases from the former repository, deriving a
  Sig toolchain version from Sig manifest metadata, accepting unverified
  downloads, and using an unpinned legacy cache action. Resolution now targets
  immutable SB0LTD release identities, supports Sig semver, verifies aggregate
  release checksums fail-closed, and pins the current Node 24 cache action.
- The Cloud Run sync watcher still consuming the obsolete flat `.tar.gz`
  bootstrap layout while fetching an unrelated library snapshot from master.
  It now compiles its `.sig` source from one checksum-verified bootstrap archive
  and that archive's bundled matching standard library.

## [0.3.0] — 2026-08-10 — Native by Construction

Sig 0.3.0 turns the release pipeline into a fail-closed, four-target release
train and establishes the allocator-free native SB0 compiler foundation.

### Highlights
- **Four full LLVM toolchains** — x86_64 Linux, aarch64 Linux, aarch64 macOS,
  and x86_64 Windows ship with the same LLVM 22.1.8 target closure.
- **Sig builds every final Sig** — the production release stage never invokes
  upstream Sig; Windows is cross-compiled by the proven Linux Sig and then
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
  tree, catching incomplete archives and stale `SIG_LIB_DIR` overrides.
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
  `--Sig-lib=<path>` argument instead of the compiler-subcommand-only
  `--Sig-lib-dir` spelling.
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
- `build_wasm.sig` retaining stale Sig 0.16/Sig 0.1.2 identities; regeneration
  now requires both canonical versions derived from `build.sig`.
- Release executables reporting only the upstream Sig version. `sig version`
  now identifies both toolchains, while the `Sig` alias retains its compatible
  machine-readable semantic-version output.
- Installed compilers crashing in Maker when a process-level `SIG_LIB_DIR`
  selected an older, incompatible library tree; validation now treats that
  version-skew risk as an installation error.
- Source builds feeding Sig's hyphenated release tags into upstream Sig's
  compatibility-version derivation; `git describe` now selects numeric tags.

## [0.2.0] — 2026-06-12 — No More Excuses

Self-sustained release pipeline. Sig builds sig. Three platforms ship.

### Highlights
- **Sig builds sig** — The compiler compiles itself. No cmake, no external Sig, no hand-holding.
- **LLVM 22 on Linux** — Full backend with all LLVM targets. One static binary, zero runtime deps.
- **macOS + Windows ship** — Self-hosted backends for aarch64-macos and x86_64-windows.
- **Two-stage pipeline** — Stage 1 builds natively with the bootstrap. Stage 2 cross-compiles for other targets.
- **Upstream Sig 0.17.0-dev** — Continuous sync from Codeberg, every commit within minutes.

### Changed
- Release pipeline completely rewritten: two-stage architecture (native → cross)
- Linux binary now includes full LLVM 22 (all targets, all backends)
- macOS/Windows binaries use self-hosted backends (no LLVM dependency)
- Bootstrap upgraded to v28 (LLVM-enabled, handles Sig 0.17.0 source)
- build.sig replaces build.sig as the primary build definition
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

LLVM 22 port, self-sustained three-stage release pipeline, and upstream Sig 0.16.0 sync.

### Highlights
- **LLVM 22.1.3** — Full port from LLVM 21, all C++ interface layers updated
- **Three-stage CI pipeline** — `build-llvm` → `build-bootstrap` → `release`, fully automated
- **All 3 platforms** — x86_64-linux, aarch64-macos, x86_64-windows ship from the same pipeline
- **Upstream sync** — Merged latest Sig 0.16.0 from codeberg (including `@cImport` removal, `round_op` rename, incremental compilation fixes)
- **Sub-6-minute releases** — Down from 4+ hours by packaging bootstrap binaries directly

### Changed
- Ported C++ LLVM interface layer from LLVM 21 to LLVM 22
  - `zig_llvm.cpp`: OptBisect API → interval-based, CPU feature filter for unrecognized features
  - `zig_llvm-ar.cpp`: explicit `StringMap<int, MallocAllocator>`, `AllocatorBase` include
  - Clang driver files: `clang/Driver/Options.h` → `clang/Options/Options.h`
  - `zig_clang_cc1_main.cpp`: `createDiagnostics()` and `createFileManager()` signature updates
  - `zig_clang_cc1as_main.cpp`: deprecated Triple APIs → new overloads
- CMake Find modules updated for LLVM 22 (new libs: `clangOptions`, `clangAnalysisLifetimeSafety`, `clangAnalysisScalable`, `clangFormat`, `clangTooling`, etc.)
- Merged upstream Sig 0.16.0: `@cImport` removed, `round_cast` → `round_op`, incremental compilation fixes
- Release pipeline packages bootstrap binaries directly (no 4-hour recompilation)
- `dev.sig`: `.core` now includes `version_command`, `env_command`, `help_command`, `targets_command`, `zen_command`
- `dev.sig`: `.bootstrap` now includes `.legalize` (required by C backend)

### Added
- Three-stage release pipeline: `build-llvm.yaml` → `build-bootstrap.yaml` → `release.yaml`
- Pre-built LLVM 22.1.3 artifacts for all 3 platforms (one-time build, reused across releases)
- `build_wasm.sig` — Minimal build.sig for zig1.wasm generation via Sig build system
- `regen-zig1-wasm.yaml` — Automated zig1.wasm regeneration using `setup-sig` action
- `tools/setup-sig` — GitHub Action for installing sig in CI workflows
- `stage1/float_stubs.c` — f16/f80 soft-float stubs for Windows bootstrap linking
- `environ` and `_environ` added to C backend reserved identifiers (Windows UCRT macro collision)
- Windows: `#undef environ` in `Sig.h`, `_msize` wrapper for const-qualifier mismatch
- Windows: `zig_static_assert` suppressed on MSVC (struct padding mismatch with old zig1.wasm)
- Windows: `/MD` CRT globally for clang-cl compatibility with pre-built LLVM libs
- `CHANGELOG.md` covering all versions from 0.0.1 through 0.1.2

### Fixed
- `process.sig`: `.unknown` variant is `u32`, not enum — removed erroneous `@intFromEnum`
- `Sema.sig`: `cmp_lte_errors_len` typo, `writeToPackedMemory` type, `resolveValue`/`resolveInst` try removal
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
- Bootstrap uses previous sig release (no upstream Sig dependency for non-LLVM builds)

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
- Sig compiler: Sig spoon with `.sig` file extension
- Strict mode: allocator usage diagnostics (warnings in `.sig`, errors in `.sig`)
- Capacity-first standard library APIs (`sig.fmt`, `sig.containers`, `sig.io`)
- Four explicit capacity errors: `BufferTooSmall`, `CapacityExceeded`, `DepthExceeded`, `QuotaExceeded`
- Sig_Sync: continuous upstream Sig integration
- LLVM 21 backend support

## [0.0.1] — 2026-03-24

Initial commit. Sig compiler fork with sig extensions.

### Added
- Forked from upstream Sig (codeberg.org/ziglang/Sig)
- Basic project structure
- License (same as upstream Sig)
