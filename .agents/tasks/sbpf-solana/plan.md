# Implementation Plan: Native sBPF (Solana) backend + sBPF link/deploy path in Sig

Derived from the APPROVED `design.md` (revision 2) and `design-review.md` (APPROVED, 3
NIT). All paths are absolute and refer to the worktree
`c:\Just-Things\Projects\sb0\sig\.worktrees\sbpf-solana`. Use
`git -C c:\Just-Things\Projects\sb0\sig\.worktrees\sbpf-solana` for all git operations.
The base branch is `fix/resinator-sig-lib-dir-and-win32-resource`; the working branch is
`feat/sbpf-solana`.

Scope is compiler/toolchain only (development-hierarchy rule): the on-chain zpm library
(entrypoint deserializer, AccountInfo, PDA, syscall wrappers, atomics) is OUT of scope.
Throwaway test modules go under `.build/sbpf-test/` in the worktree, never in zpm.

## Build & verification baseline (discovered during exploration)

- The compiler binary is `src/main.sig`, built by the `sig_build` system via
  `sig build` (see `build.sig`). The sBPF link path uses the self-hosted ELF linker
  `src/link/Elf2.sig`, but BPF *codegen* needs the LLVM backend, so the compiler must be
  built with `enable-llvm` (`sig build -Denable-llvm ...`). A stage0 `sig` is on PATH at
  `C:\Just-Things\Projects\Lib\sig-latest\bin\sig.exe` (reports `sig 0.6.0`).
- Fast front-end-only sanity after target-table edits: `sig targets` with the freshly
  built compiler must list the new arch-alias/os/abi/cpu.
- Full compiler rebuild (gating for linker/codegen edits):
  `sig build -Denable-llvm` from the worktree root, producing a new `sig` under
  `sig-out/bin/` (or the configured cache/output dir). Adding an enum member to
  `EhdrMachine` / `MachineRelocType` turns every exhaustive switch into a compile error
  until handled, so "the compiler compiles" is itself the primary structural check for
  the linker work.
- Pre-coding reference captures (PC1/PC2/PC3/PC-SYS) require the Solana toolchain
  (`cargo build-sbf`, `solana`, `llvm-readelf`/`llvm-objdump`) which runs under WSL.
  These are read-only measurements of an externally produced `.so`; the Solana toolchain
  is NEVER part of the Sig artifact-producing path (bootstrap "no external compiler" rule
  holds).

---

- [ ] 1. Run the four mandatory pre-coding reference captures and record their results
      into `design.md` (§2.1, §4.3, §4.4, §7), overwriting the "expected" tables with
      measured values. PC1: build a trivial Rust `entrypoint` with `cargo build-sbf`,
      `llvm-objdump -d` it, build the same trivial `.sig` entrypoint with
      `sig build-obj -target bpfel -mcpu v3`, diff the opcode multisets, record the delta.
      PC2: `llvm-readelf -r` the reference `.so`; record the exact `R_BPF_*` numeric
      values and the two-slot `lddw` immediate bit layout. PC3: `llvm-readelf -a` the
      reference `.so`; record `e_type`, the PT_LOAD/section contract the loader consumes,
      `DT_REL` vs `DT_RELA`, segment `p_align`, whether a `.hash`/`.gnu.hash` section is
      present (design-review NIT 2), and the `entrypoint` dynamic-symbol attributes.
      PC-SYS: inspect whether the vendored LLVM BPF backend emits a fixed-immediate
      `call` for a no-library extern (objdump a one-line extern-call test), and confirm
      murmur3-32 of a known syscall name matches the reference immediate; decide codegen
      path vs linker `R_BPF_SYSCALL` fallback. If PC1 shows a non-empty opcode delta,
      follow §2.1's fallback ladder and, if an sBPFv3-only opcode is unreachable without a
      backend fork, STOP and escalate.
      Files: `c:\Just-Things\Projects\sb0\sig\.worktrees\sbpf-solana\.agents\tasks\sbpf-solana\design.md` (fill §2.1/§4.3/§4.4/§7 tables); capture logs under `.build/sbpf-test/refcap/`.
      Verify: `design.md` §4.3 has concrete `R_BPF_*` numbers (not "expected"), §4.4 has the measured layout contract, §7 records the PC-SYS decision, and §2.1 records the opcode delta.

- [ ] 2. Add the first-class Solana sBPF target so the triple `sbf-solana-solana` parses
      to `{ .bpfel, .solana, .solana }` and `sig targets` lists it. Add `Os.Tag.solana`
      and `Abi.solana`; add a `.solana` arm at every `.sb0` site in `lib/std/Target.sig`
      (verified lines 162, 403, 844, 2335, 2501, 2942, 3251) mirroring freestanding-like
      `.sb0` behavior, with the override at line 1091 so `.solana` keeps the ELF object
      format (NOT `.raw`). Add the `Abi.solana` member and its arms. Add `isSolana` next
      to `isSb0` (~2251): `os.tag == .solana and abi == .solana and (arch == .bpfel or
      .bpfeb)`. Add a default-CPU branch `os.tag == .solana => &bpf.cpu.sbpfv3` ahead of
      the existing `.bpfel, .bpfeb => &bpf.cpu.v3` default (~2120). Accept `sbf` as an
      input arch alias mapping to `.bpfel` and `solana` as os+abi in the triple-parse
      path (name the arch-name lookup used by `std.Target.Query.parse`; design-review
      NIT 1). After editing, re-grep `\.sb0` to confirm each site has a matching `.solana`
      arm or a deliberate override.
      Files: `lib/std/Target.sig`.
      Verify: build the compiler (`sig build -Denable-llvm`), then run `sig targets` and
      confirm `bpfel`+`solana` os/abi appear and the triple resolves; add/extend a unit
      test asserting `-target sbf-solana-solana` resolves to `{ .bpfel, .solana, .solana }`
      with default `-mcpu sbpfv3`.

- [ ] 3. Add the Solana CPU models to `lib/std/Target/bpf.sig`: `sbpfv1` (`llvm_name "v1"`,
      no features), `sbpfv2` (`llvm_name "v2"`, no features), `sbpfv3` (`llvm_name "v3"`,
      features `.alu32`), each under `pub const cpu`, with a comment noting the manual
      addition so a future `tools/update_cpu_features.sig` run preserves it. Add a
      synthetic `static_syscalls` member to `Feature` and include it in `sbpfv3` ONLY if
      step 1's PC-SYS selected a codegen-visible toggle; otherwise do not.
      Files: `lib/std/Target/bpf.sig`.
      Verify: rebuild and run `sig targets`; confirm `sbpfv1/sbpfv2/sbpfv3` appear as
      selectable BPF CPU models.

- [ ] 4. Make the sBPF target dynamically linkable and route it through the self-hosted
      linker with no compiler_rt. In `src/target.sig` change `canDynamicLink` (~line 14)
      so `.bpfeb, .bpfel => target.os.tag == .solana` (generic `bpfel-freestanding` stays
      non-dynamic). In `src/Compilation/Config.sig`, in the `use_lld` block (~410) force
      `use_lld = false` for `os.tag == .solana` (error if the user explicitly passed
      `-fuse-lld`), and in the `use_new_linker` block (~461) force it `true` for
      `os.tag == .solana`. In `src/Compilation.sig` (~1807) change the compiler_rt default
      to `const want = options.want_compiler_rt orelse (is_exe_or_dyn_lib and
      target.os.tag != .solana);`. Audit the `.bpfel/.bpfeb` PIE/stack-protector/red-zone
      arms in `src/target.sig` and leave them BPF-wide.
      Files: `src/target.sig`, `src/Compilation/Config.sig`, `src/Compilation.sig`.
      Verify: rebuild; add/extend unit tests asserting `canDynamicLink` is true for the
      solana target and false for `bpfel-freestanding`, `want_compiler_rt` default resolves
      false for solana, and `use_new_linker`/`!use_lld` are forced for solana. Confirm
      `sig build-lib -dynamic -target sbf-solana-solana ...` no longer errors with
      `TargetCannotDynamicLink` or `unsupported e_machine value: 247` via LLD (it now
      routes through Elf2).

- [ ] 5. Add the `R_BPF` relocation enum to `lib/std/elf.sig` next to `EM.BPF` (247, line
      2223), using the exact numeric values recorded by PC2 in step 1 (expected:
      `NONE=0`, `@"64_64"=1`, `@"64_ABS64"=2`, `@"64_ABS32"=3`, `@"64_RELATIVE"=8`; add
      `SYSCALL` only if step 1's PC-SYS selected the linker fallback).
      Files: `lib/std/elf.sig`.
      Verify: rebuild compiles; the new enum is referenced by `Elf2.sig` in step 6.

- [ ] 6. Teach the self-hosted linker `src/link/Elf2.sig` to accept and link EM_BPF.
      Add `BPF = @backingInt(std.elf.EM.BPF)` to the `EhdrMachine` enum (~5604) so
      `EhdrMachine.fromElf(.BPF)` stops returning null and the seam at ~3753 no longer
      panics. Add `BPF: std.elf.R_BPF` to the `MachineRelocType` union (~930). Then add a
      `.BPF` arm to EVERY exhaustive `switch (elf.ehdrMachine())` the new enum member
      breaks — the design enumerates the `MachineRelocType` family (`Format.format`,
      `none`→`.NONE`, `copy`/`jumpSlot`/`globDat`/`dtpMod`/`dtpOff`/`tpOff`→`unreachable`,
      `relative`→`.@"64_RELATIVE"`, `abs32`→`.@"64_ABS32"`, `abs64`→`.@"64_ABS64"`,
      `rel32`/`rel64`→`unreachable`, `size32`/`size64`→join the `null` arm, `wrap`/`unwrap`
      generic) plus `targetPageAlign` (~5658) `.BPF => 0x1000` (or the PC3 value). NOTE:
      exploration found additional `ehdrMachine()`/machine switch sites beyond the ~18 in
      the design (around lines 5692, 5743, 5764, 5776, 6444, 6888, 7851, 8327, 8726-8791,
      8983, 9039, 10759, 10919). Do NOT rely on the design list alone: iterate
      `sig build -Denable-llvm` and add a correct `.BPF` arm (real mapping or justified
      `unreachable`) at each compile error until the compiler builds clean.
      Files: `src/link/Elf2.sig`.
      Verify: `sig build -Denable-llvm` compiles with zero switch-exhaustiveness errors.

- [ ] 7. Implement sBPF relocation apply + DSO layout in `src/link/Elf2.sig` to the exact
      contract PC2/PC3 recorded. In the relocation resolve/apply path, add a `.BPF` case:
      `R_BPF_64_64` writes `(S+A)` low 32 bits into the first `lddw` slot imm and high 32
      into the following slot (bit offsets from PC2); `R_BPF_64_ABS64`/`R_BPF_64_ABS32`
      write `S+A` as plain 64/32-bit data; `R_BPF_64_RELATIVE` emits a `.rela.dyn` (or
      `.rel.dyn` per PC3's `DT_REL`/`DT_RELA`) dynamic entry the loader applies at deploy.
      Configure DSO emission to PC3's contract: `e_type` (ET_DYN), segment/section set,
      `DT_RELA`-vs-`DT_REL`, `p_align`, entrypoint `GLOBAL FUNC` dynamic symbol; suppress
      TLS/GOT/PLT synthetics (natural from the `unreachable` arms); suppress the
      `.hash`/`.gnu.hash` section if PC3 showed the loader rejects it (design-review NIT 2).
      Files: `src/link/Elf2.sig` (reloc apply + DSO config paths).
      Verify: rebuild; add unit tests over the `R_BPF_*` apply with crafted symbol/addend
      inputs asserting the `lddw` split and the `.rela.dyn`/`.rel.dyn` `R_BPF_64_RELATIVE`
      emission byte-for-byte against PC2 values; assert `EhdrMachine.fromElf(.BPF)` returns
      `.BPF` and a crafted EM_BPF object loads past line ~3753 without panic.

- [ ] 8. Implement static-syscall lowering per the path PC-SYS committed in step 1. PRIMARY
      (codegen): in `src/codegen/llvm.sig` (extern/`genNavRef` handling, ~487/793/869/1017)
      recognize an `extern fn ... callconv(.c)` with no library name under
      `os.tag == .solana` as a static syscall, compute `imm = murmur3_32(symbol_name)`
      (add the murmur3-32 helper here, seed/encoding confirmed by PC-SYS), and materialize
      a `call imm` with no relocation (SIMD-0178). FALLBACK (only if PC-SYS proved LLVM
      emits only a symbol-relocated call): codegen emits a normal external-call relocation;
      add `R_BPF_SYSCALL` to `lib/std/elf.sig` and step 7's table and resolve it in
      `src/link/Elf2.sig` by rewriting the `call` immediate to `murmur3_32(name)` with no
      dynamic relocation (murmur3-32 helper lives in `Elf2.sig` for this path).
      Files: `src/codegen/llvm.sig` (primary) or `src/link/Elf2.sig` + `lib/std/elf.sig`
      (fallback); murmur3-32 helper in the selected seam.
      Verify: rebuild; add a unit test of murmur3-32 against known syscall names matching
      the PC-SYS-captured reference immediates; `llvm-objdump -d` the emitted `.o`/`.so`
      for a test extern call and confirm the immediate equals `murmur3_32(name)` with no
      residual syscall relocation (or the documented fallback reloc for the fallback path).

- [ ] 9. Build the compiler and produce the gating artifacts. Build with
      `sig build -Denable-llvm` from the worktree root. Write a trivial
      `.build/sbpf-test/entry.sig` exporting
      `export fn entrypoint(input: [*]u8) callconv(.c) u64` and a larger module exercising
      `sol_log_` + `sol_sha256` (declared as no-lib `extern ... callconv(.c)`), then build
      each with the freshly built compiler: `sig build-lib -dynamic -target
      sbf-solana-solana -mcpu sbpfv3 -O ReleaseSmall -femit-bin=program.so ...`. Byte-verify
      the output `.so` against PC2/PC3: ELFCLASS64, `EI_DATA=1`, `e_machine=247`, `e_type`
      per PC3, the `R_BPF_*` relocation values and `lddw` split, the dynamic symbol table
      entry for `entrypoint`, and the absence of a soft-float compiler_rt helper
      (`__negxf2` et al.) and of TLS/GOT/PLT synthetics (A7 check — document any banned
      128-bit-int ops that still pull compiler_rt).
      Files: `.build/sbpf-test/entry.sig`, `.build/sbpf-test/syscalls_demo.sig` (throwaway,
      not committed to zpm).
      Verify: both `.so` artifacts emit with exit 0; `llvm-readelf -a -r` output matches
      the PC2/PC3 contract byte-for-byte; no `compiler_rt.__negxf2`/soft-float symbol
      present.

- [ ] 10. Write the reproducible build-and-deploy recipe and driver. Create
      `compiler/SBPF_SOLANA_TARGET.md` (parallel to `compiler/SB0_ABI_TARGET.md`)
      documenting: the `sbf-solana-solana` triple, the sBPFv3 version decision (§2), the
      required flags, the float-free / no-compiler_rt profile and banned types/ops, the
      syscall contract (SIMD-0178), the PC2/PC3 ELF/relocation/dynsym layout tables, and
      the exact `solana program deploy program.so` + `solana-test-validator` steps for WSL
      (Solana CLI is a runtime/deploy tool only). Create `tools/build-sbpf.ps1` mirroring
      the android `build-lib -dynamic -target ... -femit-bin=...so` driver shape (no
      Android SDK), with the pure `sig` invocation that works on Windows and all Sig hosts.
      Files: `compiler/SBPF_SOLANA_TARGET.md`, `tools/build-sbpf.ps1`.
      Verify: run `tools/build-sbpf.ps1` end-to-end and confirm it produces `program.so`;
      the doc's commands reproduce the step 9 artifact; (integration/acceptance, requires a
      running `solana-test-validator` under WSL) `solana program deploy` + invoke of the
      trivial program succeeds and logs/returns 0.

## Notes & assumptions

- Steps 2-8 each leave the compiler buildable; the enum-member additions in steps 5-6
  deliberately use "build until clean" because the design's switch inventory is a lower
  bound (exploration found more `ehdrMachine()` switch sites than the design lists).
- The acceptance gate (step 10 integration) requires `solana-test-validator`, which runs
  under WSL. If the validator is unavailable in the execution environment, the byte-level
  verification of steps 7 and 9 is the maximal in-environment proof; mark the validator
  run as a documented manual acceptance step and say so explicitly.
- If PC1 (step 1) reveals an sBPFv3-only opcode unreachable without a forked LLVM backend,
  the no-forked-LLVM constraint cannot produce a loadable program for that instruction —
  STOP and escalate per design §2.1(c) rather than shipping a non-loadable artifact.
