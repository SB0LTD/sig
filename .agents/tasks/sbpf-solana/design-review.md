# Design Review: Native sBPF (Solana) backend + sBPF link/deploy path in Sig

Reviewer: design-review subagent (fresh context, no implementation context).
Design under review: `design.md` revision 2 (self-described as resolving the prior
`design-review.json`, 2 HIGH + 4 MEDIUM).
Authoritative sources: the user's original request and
`c:\Just-Things\Projects\sb0\zpm\.agents\tasks\solana-support-investigation.md`.

Verdict: **APPROVED** (0 HIGH, 0 MEDIUM, 3 NIT).

I verified the design's claims about Sig's own source by reading the cited files and
line ranges in the worktree, not by trusting the design text. Every structural source
claim checked out. The externally-defined contract facts (Solana `R_BPF_*` numeric
values, the `lddw` immediate split, the loader DSO layout, the murmur3 seed, and whether
the LLVM BPF backend can emit a fixed-immediate `call`) are not knowable from this repo;
the design openly marks each as unverified and converts it into a bounded, read-only
pre-coding measurement step (PC1/PC2/PC3/PC-SYS) with a recorded fallback. That is an
honest treatment, not a hand-wave, so it does not block.

---

## Review against the specifically-flagged concerns

### 1. sBPF version decision (deliverable 3) — RESOLVED, not a finding

§2 makes the decision explicitly: target sBPFv3 as the sole first-class output, do NOT
reuse `bpfel -mcpu v3/v4`, introduce a dedicated Solana target/CPU. The reasoning is
sound and tied to the SIMDs: `-mcpu v{1..4}` selects an LLVM eBPF *ISA generation*
(instruction selection, e.g. `alu32`), whereas "sBPFv3" is a Solana loader/ABI/verifier
version that fixes the relocation contract, the SIMD-0178 static-syscall call encoding,
the SIMD-0219 input-region alignment, and the SIMD-0267 `rent_epoch = u64::MAX`
constant. The design correctly concludes the two axes are orthogonal and that an LLVM
`-mcpu` cannot express the loader contract, so a Solana-specific target is mandatory.
This directly answers deliverable 3's required explicit decision ("whether `bpfel -mcpu
v3/v4` can ever map to sBPFv3 — it cannot"). This is the opposite of hand-waved.

The design also keeps `cpu.arch == .bpfel` internally and distinguishes Solana by
`os/abi == solana` plus an `sbpfv3` CPU model whose `llvm_name` maps back to `v3`. I
verified this is coherent with the tree: `toElfMachine` maps `.bpfeb, .bpfel => .BPF`
(`lib/std/Target.sig:1110`), and the default BPF CPU is `&bpf.cpu.v3`
(`lib/std/Target.sig:2120`).

### 2. LLD approach / "no external forked LLVM in the release path" — consistent

§4.1 routes sBPF links through the self-hosted linker `src/link/Elf2.sig` and bans the
vendored LLVM LLD for the Solana target, forcing `use_lld = false` /
`use_new_linker = true` in `Config.sig`. This is the only approach consistent with the
user's directive ("teach the SB0LTD LLD to accept EM_BPF ... full sig") and the
bootstrap "no external compiler" rule. The Solana forked LLVM / `cargo build-sbf` /
Solana CLI are used only as read-only reference-measurement and runtime-deploy tools
(§8.4), never in the artifact-producing path. Verified consistent: `hasLldSupport(.elf)`
and `hasNewLinker(.elf)` both return `true` (`src/target.sig:284`, `:292`), so forcing
the self-hosted linker for the solana ELF target is compatible with the format gates.

### 3. Target/triple design names concrete files/lines and a reachable surface — yes

§3 names `lib/std/Target.sig` with specific line sites, `lib/std/Target/bpf.sig` for CPU
models, and a reachable `-target sbf-solana-solana -mcpu sbpfv3` surface that `sig
targets` enumerates by reflection. I verified every cited site (see Verified Assumptions).

### 4. compiler_rt / soft-float avoidance and static-syscall lowering — specified, not deferred

§5 specifies the exact one-line default change in `src/Compilation.sig` (verified at
line 1807: `const want = options.want_compiler_rt orelse is_exe_or_dyn_lib;`) so
`want_compiler_rt` defaults to `false` for `os.tag == .solana`. §7 commits to the
SIMD-0178 static-syscall `call imm` codegen path as the primary mechanism (murmur3-32 of
the syscall name as the immediate, no relocation), with a linker-side `R_BPF_SYSCALL`
fallback retained only as a contingency that PC-SYS decides before coding. The mechanism
is committed, not "whichever of two works," which is what the prior review (finding 4)
required.

### 5. Development-hierarchy boundary — respected

All changes are compiler/toolchain (`lib/std/Target.sig`, `lib/std/Target/bpf.sig`,
`lib/std/elf.sig`, `src/target.sig`, `src/Compilation/Config.sig`, `src/Compilation.sig`,
`src/link/Elf2.sig`, `src/codegen/*`, `compiler/SBPF_SOLANA_TARGET.md`,
`tools/build-sbpf.ps1`). The on-chain library (entrypoint deserializer, AccountInfo,
PDA, syscall wrappers) stays in zpm (§6, §10). murmur3-32 is placed in the compiler
because it is codegen/link machinery, not on-chain library logic — a correct boundary
call. §10 explicitly lists what is NOT touched (`Lld.sig`, `src/link/Elf/*`, vendored
LLVM, zpm).

---

## Findings

1. **NIT — arch-spelling alias (`sbf`) parse site is not pinned to a file/function.**
   §3.2 states `sbf` is accepted as an input alias for the `.bpfel` arch "at parse time"
   and `solana` as os and abi, referencing "`parse`/`resolveTargetQuery` consumers"
   without naming the concrete function/line the way every other edit site is named.
   Every other edit in the design cites a verified line; this one is looser.
   CONCRETE FIX: name the arch-parse seam (the arch-name lookup used by
   `std.Target.Query.parse` / the arch `fromName`-style table in `lib/std/Target.sig`)
   and state exactly where the `sbf -> .bpfel` alias is added, mirroring how `sbf-solana-
   solana` must round-trip through `sig targets`/display back to the canonical
   `{ .bpfel, .solana, .solana }`.

2. **NIT — `.hash`/`.gnu.hash` dynamic-symbol-hash section not mentioned in the DSO
   layout contract.** `Elf2.sig` couples `.dynsym` to a hash section
   (`ensureDynsymHashCapacity`, `targetDynsymHashInfo`, `appendDynsymHashEntry`), so any
   DSO that exports the `entrypoint` dynamic symbol will carry one. §4.4's PC3 capture
   list enumerates `.dynamic`/`.dynsym`/`.dynstr`/`.rel(a).dyn` but does not list
   `.hash`/`.gnu.hash`, and does not say whether a Solana loader tolerates or ignores it.
   CONCRETE FIX: add `.hash`/`.gnu.hash` to the PC3 `readelf -a` capture checklist in
   §4.4 and record whether the reference Solana `.so` carries one; if the loader rejects
   it, note that the hash section must be suppressed for the solana target.

3. **NIT — `R_BPF` numeric values and the `lddw` split remain unverified (carried over
   as PC2).** `lib/std/elf.sig` has `EM.BPF = 247` (verified at line 2223) but no `R_BPF`
   enum, so the values in §4.3's table (`R_BPF_64_64 = 1`, `R_BPF_64_RELATIVE = 8`, etc.)
   and the two-slot `lddw` immediate layout are the design's expected values, pinned by
   PC2 before coding. This is acceptable as a pre-coding measurement, but it is an
   unverified assumption by construction.
   CONCRETE FIX: none required beyond running PC2 and overwriting §4.3's table with the
   measured `readelf -r` values before any `src/link/Elf2.sig` code is written, exactly
   as the design already states.

---

## Verified Assumptions (read against worktree source)

- **`.sb0` arm inventory in `lib/std/Target.sig`** — VERIFIED. `grep \.sb0` returns the
  exact sites the design enumerates: `Os.Tag` member (line 23), os/abi switches at 162,
  403, 844 (`.sb0 => .sb0` default-ABI), 1091 (`.sb0 => .raw` object format), and 2335,
  2501, 2942, 3251. The `Abi` enum is at line 805 with the `.sb0` member at 808. The
  design's "add a `.solana` arm everywhere `.sb0` has one, with three overrides" rule is
  grep-checkable and accurate.
- **`isSb0` predicate** — VERIFIED at `lib/std/Target.sig:2252`
  (`target.os.tag == .sb0 and target.abi == .sb0 and target.cpu.arch == .aarch64`); the
  proposed `isSolana` mirrors it correctly.
- **Object-format override (line 1091)** — VERIFIED: `.sb0 => .raw`; the design correctly
  overrides so `.solana` keeps ELF rather than `.raw`.
- **`toElfMachine` maps `.bpfel => .BPF`** — VERIFIED at `lib/std/Target.sig:1110`; no
  change needed there, the fix is in the linker.
- **Default BPF CPU `&bpf.cpu.v3`** — VERIFIED at `lib/std/Target.sig:2120`.
- **`lib/std/Target/bpf.sig` CPU models + Feature enum** — VERIFIED: `Feature` =
  `{ allows_misaligned_mem_access, alu32, dummy, dwarfris }`; `cpu` struct defines
  `generic/probe/v1/v2/v3/v4` with `v3`/`v4` carrying `.alu32`. The proposed
  `sbpfv1/sbpfv2/sbpfv3` models (sbpfv3 with `.alu32`, `llvm_name = "v3"`) are consistent
  with the existing shape. File header confirms it is auto-generated by
  `tools/update_cpu_features.sig`, matching the design's note to flag the manual edit.
- **`lib/std/elf.sig`: `EM.BPF = 247` exists, no `R_BPF` enum** — VERIFIED (EM.BPF at
  line 2223). Adding `R_BPF` is genuinely new work, as the design states.
- **`src/target.sig` `canDynamicLink` returns `false` for `.bpfeb/.bpfel`** — VERIFIED
  (lines 16-21): BPF arches fall in the `=> false` group unconditionally. The proposed
  rewrite (BPF dynamic iff `os.tag == .solana`) is a minimal, correct change.
- **`hasLldSupport(.elf) == true` / `hasNewLinker(.elf) == true`** — VERIFIED at
  `src/target.sig:284` and `:292`.
- **`src/Compilation/Config.sig`** — VERIFIED: `TargetCannotDynamicLink` returned at
  line 262 under `!canDynamicLink && link_mode == .dynamic`; the `use_lld` decision block
  begins at line 410; the `use_new_linker` block at line 461. The design's insertion
  points are accurate, and the `use_lld` block's existing early guard
  (`!hasLldSupport(ofmt)`) does not short-circuit the solana ELF target (ELF has LLD
  support), so the explicit solana override is required and correctly placed.
- **`src/Compilation.sig` want_compiler_rt default** — VERIFIED at line 1807:
  `const want = options.want_compiler_rt orelse is_exe_or_dyn_lib;`. An sBPF `.so` is a
  dynamic lib so `is_exe_or_dyn_lib` is true, confirming compiler_rt is pulled in by
  default — the exact failure path. The proposed `and target.os.tag != .solana` fix is
  correct and minimal.
- **`src/link/Elf2.sig` `EhdrMachine` enum** — VERIFIED at line 5603: `enum(u16)` with
  exactly `AARCH64/LOONGARCH/PPC64/RISCV/SPARCV9/X86_64`, no `BPF`, with the doc comment
  about exhaustive switches. `fromElf` uses `std.enums.fromInt`, so adding
  `BPF = @backingInt(std.elf.EM.BPF)` makes `fromElf(.BPF)` return `.BPF`, as claimed.
- **`src/link/Elf2.sig` panic seam** — VERIFIED at line 3752:
  `EhdrMachine.fromElf(target.toElfMachine()) orelse std.debug.panic("TODO(Elf2): add
  support for target machine ...")`. The design's correction of the prior draft's "comes
  for free" claim is accurate: without the enum member this path panics.
- **`src/link/Elf2.sig` `MachineRelocType` union + exhaustive switches** — VERIFIED at
  line 929. The union fields are `AARCH64/LARCH/PPC64/RISCV/SPARC/X86_64` (field name
  `LARCH`, enum member `LOONGARCH` — the design's union snippet correctly uses `LARCH`).
  Every function the design enumerates exists and is exhaustive with no `else`:
  `Format.format`, `none`, `copy`, `relative`, `jumpSlot`, `globDat`, `dtpMod`, `dtpOff`,
  `tpOff`, `absAddr` (dispatches by class — correctly needs no arm), `abs32`, `abs64`,
  `rel32`, `rel64`, `size32` (`...=> null`), `size64` (`...=> null`), `wrap`, `unwrap`.
  Adding `BPF` to the enum will turn each into a compile error until handled, exactly as
  the design claims (resolving prior findings 1 and 2).
- **`targetPageAlign`** — VERIFIED at line 5657 with the commented `//.BPF => 0x100000`
  arm; the design's `0x1000` live arm (pinned by PC3) replaces it.
- **DSO emission machinery already present** — VERIFIED: `Elf2.sig` has `.dynsym`,
  `.dynstr`, `.dynamic`, `.rela.dyn`, `.rela.plt`, GOT, dynsym hash, and `DT_TEXTREL`
  handling. The design's claim that only the sBPF-specific reloc arms + layout config are
  new (not the DSO scaffolding) is accurate.
- **Entrypoint / input-region split of responsibility** — VERIFIED against the
  investigation report §4: the byte-level layout (account count, per-account records,
  `rent_epoch = u64::MAX` per SIMD-0267, 8-byte alignment per SIMD-0219, instruction
  data, program id) is zpm's job; the compiler only lowers `export fn entrypoint(input:
  [*]u8) callconv(.c) u64` as a dynamic symbol. Consistent with the report and the
  user's "NOT asking for" list.

## Unverified / Wrong Assumptions

No *wrong* assumptions were found: every claim the design makes about Sig's own source
matched the worktree. The following are *unverified by construction* — they depend on
Solana's externally-defined contract, which cannot be checked from this repo. The design
flags each and pins it to a read-only pre-coding capture; they are listed here for the
implementer, not as blocking defects.

- **A1 (PC1): sBPFv3 opcode set ⊇ LLVM `bpfel -mcpu v3` output.** Unverified; pinned by
  disassembling a `cargo build-sbf` reference and diffing. Fallback ladder incl.
  stop-and-escalate is specified (§2.1). The expected empty-delta outcome is plausible
  (on-chain code uses the common eBPF subset) but genuinely unconfirmed.
- **A5/A… (PC2): exact `R_BPF_*` numeric values and `lddw` immediate split.** Unverified;
  the §4.3 table carries conventional values to be confirmed by `readelf -r` before
  coding. (See NIT 3.)
- **A6/A4 (PC3): loader DSO layout — `e_type`, PT_LOAD vs section-only consumption,
  `DT_REL` vs `DT_RELA`, segment alignment, entrypoint dynsym attributes, and (NIT 2)
  the hash section.** Unverified; pinned by `readelf -a` of a reference `.so`.
- **A9 (PC-SYS): whether the vendored LLVM BPF backend can emit a fixed-immediate `call`
  for a no-library extern.** Unverified; decides whether the committed codegen path or
  the `R_BPF_SYSCALL` linker fallback is physically necessary. Both are in-house.
- **A2/A7/A8/A10:** loader acceptance of static-syscall calls, absence of
  `legalize_compiler_rt_call` for float-free programs (incl. 128-bit integer ops), the
  `.c`/`bpf_std` entrypoint register ABI (ptr in r1, ret in r0), and the absence of a
  mandatory post-link transformation. All deferred to the integration/validator gate,
  which is appropriate since each requires a running `solana-test-validator` to confirm
  and none is a structural design decision.

---

## Gate rationale

The one risk the review brief singled out as a potential HIGH — an unresolved or
hand-waved sBPF-version decision — is explicitly resolved in §2 with correct reasoning
tied to SIMD-0178/0219/0267. The LLD approach is concrete and consistent with the
no-forked-LLVM constraint; the target/triple edits are pinned to verified file/line
sites; compiler_rt avoidance and static-syscall lowering are specified with a committed
primary path; the development-hierarchy boundary holds. The remaining open items are
external-contract facts the design honestly marks unverified and pins to bounded,
read-only pre-coding measurements with recorded fallbacks — a legitimate approach, not a
gap in the design's reasoning.

Only 3 NIT findings. 0 HIGH, 0 MEDIUM. **APPROVED.**
