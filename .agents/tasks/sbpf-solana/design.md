# Design: Native sBPF (Solana) backend + sBPF link/deploy path in Sig

Status: revision 2 (addresses `design-review.json`, verdict CHANGES_REQUESTED, 2 HIGH
+ 4 MEDIUM findings — all resolved; responses recorded in §12).
Scope: compiler/toolchain only. The on-chain zpm library (entrypoint deserializer,
AccountInfo views, PDA finder, syscall wrappers, atomics helpers) is explicitly out
of scope and belongs in `SB0LTD/zpm`, per the development-hierarchy rule.

All paths are absolute and refer to the worktree
`c:\Just-Things\Projects\sb0\sig\.worktrees\sbpf-solana`.

---

## 1. Overview

Today Sig can already *lower* Sig source to BPF bytecode: `sig build-obj -target
bpfel-freestanding -mcpu v3` emits a valid 64-bit little-endian `EM_BPF` (247) ELF
object (verified in the investigation report). What is missing is everything after
codegen: a linker that accepts `EM_BPF`, the dynamic/shared-object output path that
Solana loaders require, a Solana-specific target (not generic `bpfel`), a float-free
on-chain profile, and a documented build recipe.

The design makes six coordinated changes, all inside the Sig toolchain with no
external compiler dependency:

1. Add a **first-class Solana sBPF target** reachable as
   `-target sbf-solana-solana` (plus `-mcpu sbpfv3`), distinct from `bpfel`.
2. Route sBPF links through the **self-hosted ELF linker** (`src/link/Elf2.sig`,
   the "new linker"), never through the vendored LLVM LLD, and teach it the sBPF
   relocation set and shared-object ELF layout Solana loaders expect. This requires
   extending the linker's `EhdrMachine` enum and ~18 exhaustive relocation switches —
   this is the bulk of the gating work and is enumerated in §4.
3. Make the sBPF target **dynamically linkable** so a `.so` can be produced.
4. Default the sBPF target to a **no-compiler_rt, float-free profile** so the
   soft-float helpers that fail to lower (`__negxf2` et al.) are never pulled in.
5. Lower Solana **syscalls** (`sol_log_`, `sol_sha256`, …) using the SIMD-0178
   static-syscall call encoding, so no runtime syscall relocations are emitted.
6. Ship a **documented, reproducible build-and-deploy recipe** (`compiler/SBPF_SOLANA_TARGET.md`
   + a PowerShell driver mirroring `build-android.ps1`), validated on Windows.

The gating decision (sBPF version) is made first, in §2, because it determines the
relocation model, the call encoding, and the ELF layout the rest of the design emits.

### 1.1 Mandatory pre-coding verification (gates the implementation)

Three contracts the authoritative sources (the investigation report + the Solana SIMD
docs) describe at the semantic level but do NOT pin at the byte level: the sBPFv3
opcode set, the exact `R_BPF_*` numeric values + `lddw` split, and the loader-enforced
DSO layout. The review correctly flags that deferring these to post-coding integration
is a structural risk. **Therefore implementation does not start until the three
reference-capture steps below are run and their results recorded in this doc.** Each
produces a concrete artifact that pins an otherwise-open assumption:

- **PC1 (pins A1, §2):** build a reference Solana program with
  `cargo build-sbf`/`solana-sdk`, disassemble it (`llvm-objdump -d` from the Solana
  toolchain, or `sbpf dump`), and build the *same* trivial program with
  `sig build-obj -target bpfel -mcpu v3`; diff the opcode sets. Record the delta in
  §2.1.
- **PC2 (pins A5/finding 2/7, §4.3):** `readelf -r` / `llvm-readelf -r` the reference
  `.so`; record the exact `R_BPF_*` numbers used and, for one `lddw`-based reloc, the
  two-slot immediate split. Fill the numeric table in §4.3.
- **PC3 (pins A6, §4.4):** `readelf -a` the reference `.so`; record `e_type`, the
  program-header/section set the loader consumes, `DT_REL` vs `DT_RELA`, and the
  entrypoint dynamic-symbol attributes. Fill the layout contract in §4.4.

These are read-only inspections of an externally produced artifact (the Solana
toolchain is a *reference/measurement* tool here, never part of the Sig release path —
see §8.4), so they do not violate the bootstrap "no external compiler" rule.

---

## 2. sBPF version decision (deliverable 3 — made explicitly, with reasoning)

**Decision: target sBPFv3 as the sole first-class output. Do NOT reuse `bpfel -mcpu
v3/v4`; introduce a dedicated Solana target/CPU. The v3 CPU model on the generic
`bpfel` arch is retained only as the codegen *feature* substrate, never as a user-
facing deploy target.**

Reasoning:

- **`bpfel -mcpu v3/v4` cannot map to sBPFv3.** The `-mcpu` version on the upstream
  `bpf` arch (`lib/std/Target/bpf.sig`: `v1..v4`) selects LLVM eBPF *ISA generations*
  (e.g. `alu32`), i.e. which instructions the backend may emit. "sBPFv3" is a Solana
  **loader/ABI/verifier version**: it fixes the relocation contract, the static-
  syscall call encoding (SIMD-0178), the input-region alignment (SIMD-0219), and the
  `rent_epoch = u64::MAX` serialization constant (SIMD-0267). These are properties of
  the *linked artifact and loader contract*, not of the instruction-selection CPU.
  An LLVM `-mcpu` cannot express them, so the two version axes are orthogonal and
  conflating them would silently emit non-loadable programs. This is the core reason
  the task says a Solana-specific target is mandatory. (This satisfies deliverable 3's
  "explicit decision: whether `bpfel -mcpu v3/v4` can ever map to sBPFv3" — it cannot;
  a Solana-specific target/CPU is mandatory.)

- **sBPFv3 is the forward-looking deploy format** (loaders are converging on it per
  the report's §4 "converging on sBPFv3 as the standard deploy format"), so it is the
  version we commit the target to.

- **How the two axes combine in practice:** the new Solana target keeps `cpu.arch ==
  .bpfel` internally (so the existing verified LLVM BPF codegen path is reused
  unchanged) but is distinguished by **os/abi = `solana`** and a Solana CPU model
  `sbpfv3` added to `bpf.sig`. The CPU model carries the LLVM feature bits codegen
  needs (`alu32`, and a new synthetic `static_syscalls` marker feature — see §7);
  the os/abi carries the loader-contract decisions (relocations, layout, no-float,
  dynamic output). This keeps codegen reuse while making the ABI contract first-class.

### 2.1 A1 — opcode-set reuse: verification and fallback (resolves finding 3)

The "reuse `.bpfel` arch unchanged" premise (§3.1) depends on **A1**: that the sBPFv3
instruction encoding a logging + account-reading + CPI program needs is a *superset of*
what LLVM `bpfel -mcpu v3` already emits — i.e. no sBPFv3-only opcode is required that
stock LLVM BPF cannot produce. The sources describe sBPF as a "custom eBPF variant" but
do not enumerate the opcode delta, so A1 is **unverified until PC1 is run** (§1.1).

A1 is treated as a potentially *structural* risk, not a localized feature-flag tweak:

- **PC1 procedure (run before coding):** compile `entry.sig`'s trivial entrypoint both
  ways and diff the instruction streams:
  - reference: `cargo build-sbf` on an equivalent Rust `entrypoint` → `llvm-objdump -d`
    the resulting `.so`;
  - Sig: `sig build-obj -target bpfel -mcpu v3 entry.sig` → `sig objdump -d` / `llvm-
    objdump -d` the `.o`.
  Record the opcode multiset difference in a table here.
- **If the delta is empty (expected):** A1 holds; proceed with §3.1 unchanged.
- **If sBPFv3 requires an opcode stock `bpfel` cannot emit:** the fallback is **not** a
  feature flag. It escalates to one of, in order of preference: (a) add the missing
  encoding behind the synthetic `sbpfv3` CPU feature if LLVM's BPF backend can be
  coaxed to emit it via existing intrinsics; (b) post-process the specific instruction
  in `Elf2.sig` during section emission (a narrow, mechanical rewrite keyed off the
  reloc/opcode); (c) if neither is possible without a backend fork, **stop and
  re-open the version decision** — this would be a finding that the "no forked LLVM"
  constraint cannot produce sBPFv3 for the required instruction, which the user must
  adjudicate. The design records (c) as the explicit escape hatch rather than silently
  shipping a non-loadable program.

Expected outcome is the empty delta (on-chain code uses the common eBPF subset:
loads/stores, ALU, jumps, `call`), but the verification is mandatory and its result is
recorded here before §3–§7 are implemented.

#### Measured result (PC1) — A1 HOLDS, delta is structurally empty

Run 2026-10-11. Toolchain: Solana `cargo-build-sbf` 4.4.0 / platform-tools **v1.57**
(LLVM 22.1.2-rust-dev), `solana-cli` 4.3.0; Sig stage0 **sig 0.6.0 (zig 0.17.0)** at
`C:\Just-Things\Projects\Lib\sig-latest\bin\sig.exe`. The Rust reference program is a
trivial `entrypoint!`/`msg!`-then-`Ok(())` crate (`crate-type = cdylib`,
`solana-program` 2.1) built for `sbpfv3-solana-solana`; its deploy artifact
`target/deploy/trivial.so` is `EM_BPF`, ELFCLASS64, LE, `ET_DYN`. The Sig side is
`.build/sbpf-test/entry.sig` (`export fn entrypoint(input: [*]u8) callconv(.c) u64`)
built with `sig build-obj -target bpfel-freestanding -mcpu v3 -OReleaseSmall
-fno-compiler-rt` → `EM_BPF` relocatable object. Logs:
`.build/sbpf-test/refcap/pc1-objdump-reference.txt`, `pc1-objdump-sig.txt`,
`pc1-sig-header.txt`.

- The Sig trivial entrypoint lowers to exactly two instructions: `b7 mov64 r0, 0x0`
  (opcode `0xb7`) and `95 exit` (opcode `0x95`). Both are a strict subset of the
  reference opcode set.
- The reference `.so` uses **48 distinct opcodes**, *all* of which the stock LLVM BPF
  backend (`llvm-objdump --mcpu=v3`) decodes cleanly — **zero** `<unknown>`/`.byte`/
  invalid instructions. The set is the ordinary eBPF v1–v3 ISA:
  `bf/b7 mov64`, `79 ldxdw`, `7b stxdw`, `7a stdw` (store-imm-dword), `07/0f add64`,
  `85 call`, `8d callx`, `18 lddw`, `05 ja`, `15/55/1d/5d jeq/jne`,
  `25/2d/35/3d/65/a5/ad/b5/bd jgt/jge/jsgt/jlt/jle`, `c5 jslt`, `d5 jsle`,
  `57/5f and64`, `47/4f or64`, `a7 xor64`, `67 lsh64`, `77 rsh64`, `c7 arsh64`,
  `27/2f mul64`, `37 div64`, `87 neg64`, `71/69/61 ldx{b,h,w}`, `73/6b/63 stx{b,h,w}`,
  `6a sth`, `1f/1d sub64`, `dc be64` (byteswap). The `0f/1f/2f` ALU-x and the signed
  jumps are reachable on `v3` via `.alu32` and the v2/v3 jump set.
- **Opcode multiset delta that stock `bpfel -mcpu v3` cannot emit: EMPTY.** The Solana
  platform-tools BPF backend is a fork of this same LLVM 22 BPF backend, so the ISA it
  emits is a superset of nothing beyond what upstream `-mcpu v3` already produces for
  this program class. No sBPFv3-only opcode is required and none is unreachable.

Conclusion: **A1 holds; the §2.1 fallback ladder is not triggered and no escalation is
needed.** The §3.1 "reuse `.bpfel` arch unchanged" decision stands. (The sBPFv3 contract
difference is in *linking/syscall encoding/layout*, pinned by PC2/PC3/PC-SYS below — not
in the instruction set.)

---

## 3. Target / triple definition (deliverable 2)

The target must be reachable exactly like other targets: `-target sbf-solana-solana`
with `-mcpu sbpfv3`, and must appear in `sig targets`.

### 3.1 Arch

Do **not** add a new `Arch` enum member. Reuse `.bpfel`. Rationale: a new arch would
require duplicating the entire BPF codegen registration (`src/codegen/llvm.sig`
LLVMInitializeBPF*, the `bpf_std` calling convention in `Sema.sig`/`llvm.sig`, the
`no_builtin` default in `Module.sig`), all of which already work for `.bpfel`. The
Solana-ness is an OS+ABI+CPU property, matching how the SB0 target keeps `aarch64`
and distinguishes via os/abi (per `compiler/SB0_ABI_TARGET.md`, "keep OS/ABI identity
separate from output container").

This premise is contingent on A1/PC1 (§2.1): if the opcode delta is non-empty, §2.1's
fallback ladder applies before this reuse decision stands.

### 3.2 OS tag and ABI

Add a `solana` OS tag and a `solana` ABI so the triple parses as
`<arch>-<os>-<abi>` = `bpfel-solana-solana`, and expose `sbf-solana-solana` as a
recognized **alias** that normalizes to it (the task and the Solana ecosystem both
spell it `sbf-solana-solana`; `sbf` is treated as an input alias for the `bpfel`
arch at parse time, canonicalized internally to `.bpfel`).

**Concrete inventory rule (resolves finding 5).** Adding `Os.Tag.solana` and
`Abi.solana` forces every exhaustive `Os.Tag`/`Abi` switch in `lib/std/Target.sig`
(and consumers) to compile. There is a proven in-tree precedent: the `sb0` custom
OS/ABI was added the same way. **The rule is: add a `.solana` arm everywhere `.sb0`
currently has one, mirroring `.sb0`/freestanding behavior (no libc, no dynamic-loader
path, no OS version range), EXCEPT the three explicit overrides below.** The `.sb0`
arms were enumerated by grepping `\.sb0` in `lib/std/Target.sig` and are, verified in
the current tree:

- line 24 — `Os.Tag` enum member declaration → add `solana` member.
- line 162 — default-ABI / os-family switch → add `.solana` arm (freestanding-like).
- line 403 — os-family switch → add `.solana` arm.
- line 844 — `aarch64-sb0` → `.sb0 => .sb0` default-ABI mapping → add
  `.solana => .solana` so a bare `bpfel-solana`/`sbf-solana` triple defaults ABI to
  `.solana`.
- line 1091 — default object format (`.sb0 => .raw`) → **override: `.solana` does NOT
  map to `.raw`; it keeps the normal ELF object format** (sBPF ships an ELF `.so`).
  Add `.solana` to the `else`/ELF branch, not the `.sb0` raw branch.
- lines 2335, 2501, 2942, 3251 — the remaining exhaustive os switches (version-range,
  C-type, float/abi defaults, dynamic-linker family) → add `.solana` alongside `.sb0`
  (freestanding-like).
- `Abi` enum (the `.sb0` ABI member) → add `.solana` ABI member and its arms in the
  same switches.

Three explicit overrides on top of the freestanding-like default:

1. **Object format (line 1091):** ELF, not `.raw` (above).
2. **Default CPU (§3.3):** `os == .solana` → `&bpf.cpu.sbpfv3`.
3. **compiler_rt (§5):** `os == .solana` → default `want_compiler_rt = false`.

Add an `isSolana` predicate next to `isSb0` (`lib/std/Target.sig:2252`):
`target.os.tag == .solana and target.abi == .solana and target.cpu.arch == .bpfel`
(or `.bpfeb`), for use by the linker/config gates below.

Triple parsing (`parse`/`resolveTargetQuery` consumers): accept `sbf` as an arch
spelling that maps to `.bpfel`, and `solana` as os and abi. The canonical internal
target becomes `{ .arch = .bpfel, .os = .solana, .abi = .solana }`.

This converts the previous open-ended "A3 deferral" into a bounded, grep-checkable
checklist; the implementer should re-grep `\.sb0` after the edit to confirm every arm
has a matching `.solana` (or deliberate override). Any newly-added `.sb0` arm upstream
would show up in that grep.

### 3.3 CPU model

In `lib/std/Target/bpf.sig` (auto-generated header; we extend it by hand and note the
manual addition with a comment so a future `update_cpu_features.sig` run preserves it),
add CPU models under `pub const cpu` (the existing block defines
`generic/probe/v1/v2/v3/v4` with `v3`/`v4` carrying `.alu32`):

```
pub const sbpfv1: CpuModel = .{ .name = "sbpfv1", .llvm_name = "v1",
    .features = featureSet(&[_]Feature{}) };
pub const sbpfv2: CpuModel = .{ .name = "sbpfv2", .llvm_name = "v2",
    .features = featureSet(&[_]Feature{}) };
pub const sbpfv3: CpuModel = .{ .name = "sbpfv3", .llvm_name = "v3",
    .features = featureSet(&[_]Feature{ .alu32 }) };
```

The `llvm_name` deliberately maps back to the upstream `v1/v2/v3` so LLVM codegen is
driven by the known-good generation; the Sig-facing `name` is the Solana version the
user selects. `sig targets` enumerates CPU models by their Sig `name`, so these appear
as selectable `-mcpu` values.

(If §7's static-syscall lowering is implemented as a codegen-visible toggle, add a
synthetic `static_syscalls` member to `Feature` here and include it in `sbpfv3`; see
§7's decision — the chosen path does NOT require a new LLVM feature, so this is only a
contingency.)

Default CPU for `os == .solana`: `sbpfv3`. The existing default
(`lib/std/Target.sig` ~line 2120, `.bpfel, .bpfeb => &bpf.cpu.v3`) stays for non-solana
BPF; add an earlier branch keyed on `os.tag == .solana => &bpf.cpu.sbpfv3`.

### 3.4 `sig targets` listing

`sig targets` builds its arch/os/abi/cpu lists by reflecting over the enums above, so
adding the enum members and CPU models makes them appear automatically. Add a one-line
note in the generated help so `sbf-solana-solana` is discoverable. No separate code
path is needed beyond the enum/CPU additions.

### 3.5 `toElfMachine`

`lib/std/Target.sig` `toElfMachine` already maps `.bpfel => .BPF` (247). Since the
Solana target keeps `.bpfel`, the ELF machine stays `EM_BPF = 247`. No change needed
here — the fix is in the *linker* (§4), which currently rejects/panics on 247.

---

## 4. Linker: accept EM_BPF, emit sBPF relocations + shared-object layout (deliverable 1 — gating)

### 4.1 Which linker

There are two linkers in the tree:

- `src/link/Lld.sig` — a thin wrapper that shells out to the **vendored LLVM LLD**
  (`.build/llvm-22-*/lib/liblldELF.a`). This is the component that emits
  `error: ld.lld: unsupported e_machine value: 247`. We are told **not** to vendor
  Solana's forked LLD and not to add external compiler deps, and patching the vendored
  LLVM LLD binary is out of our control. So **LLD is not the path.**
- `src/link/Elf2.sig` — Sig's **self-hosted "new linker"** (gated by
  `use_new_linker` / `-fnew-linker` in `src/Compilation/Config.sig` and
  `src/main.sig`). It already has a machine-dispatched relocation layer
  (`MachineRelocType` union over `AARCH64/LARCH/PPC64/RISCV/SPARC/X86_64`) and emits
  DSOs (`.rela.dyn`, `.rela.plt`, copy relocations, `DT_*`). **This is where sBPF link
  support goes, and `Elf2.sig` is the authoritative linker for the Solana target.**
  The older `src/link/Elf/` object/shared-object path is NOT used for Solana; it is not
  modified by this design.

**Decision: the Solana target forces the self-hosted ELF linker and bans LLD.** This
mirrors how the self-hosted backend already forces `use_lld = false` when there is a
ZCU and no LLVM backend. We make the choice explicit for sBPF regardless of backend.
Verified consistency: `hasLldSupport(.elf)` and `hasNewLinker(.elf)` both return `true`
(`src/target.sig:281/289`), so forcing the self-hosted linker for the solana ELF target
is compatible with the format gates.

Change in `src/Compilation/Config.sig`, in the `use_lld` decision block (verified
around lines 409–443): add, before the generic fallbacks, a hard rule:

```
if (target.os.tag == .solana) {
    if (options.use_lld == true) return error.LldIncompatibleObjectFormat; // sBPF needs the self-hosted linker
    break :b false;
}
```

and in the `use_new_linker` block (verified ~line 461) force it on for solana:

```
if (target.os.tag == .solana) break :b true;
```

This guarantees sBPF always flows through `Elf2.sig`.

### 4.2 Make the self-hosted linker accept EM_BPF (resolves finding 1 — HIGH)

**Correction of the prior draft's false claim.** The previous design asserted BPF
acceptance "comes for free" in the self-hosted linker. That is **wrong**, verified
against source. `Elf2.sig` deliberately restricts the machines it handles through a
closed enum so that its relocation switches can be exhaustive:

- `EhdrMachine` (`Elf2.sig:5603`) is an `enum(u16)` with members for exactly
  `AARCH64/LOONGARCH/PPC64/RISCV/SPARCV9/X86_64` — **no `BPF`**, and a doc comment
  stating it "only includes the ELF machine architectures we support, so that we can
  use exhaustive `switch` statements."
- At `Elf2.sig:3752` the linker does
  `const machine = EhdrMachine.fromElf(target.toElfMachine()) orelse
  std.debug.panic("TODO(Elf2): add support for target machine '{t}'", …);`.
  For a `.bpfel`/solana target, `target.toElfMachine()` is `.BPF`, `fromElf(.BPF)`
  returns `null`, and the self-hosted linker **panics**. (The old draft also cited
  `src/link/Elf/Object.sig:143`, which is the *other*, LLD-era linker file — a
  conflation of two codebases. That file is irrelevant to the Solana path per §4.1.)

Required changes to make `Elf2.sig` accept EM_BPF:

1. **Add BPF to the `EhdrMachine` enum** (`Elf2.sig:5603`):
   `BPF = @backingInt(std.elf.EM.BPF),` (`std.elf.EM.BPF == 247`, verified in
   `lib/std/elf.sig:2223`). This makes `EhdrMachine.fromElf(.BPF)` return `.BPF`
   instead of `null`, so the seam at line 3752 no longer panics.
2. **Make every exhaustive switch over `ehdrMachine()` handle `.BPF`.** Adding the enum
   member turns ~18 currently-exhaustive switches into compile errors until each gains
   a `.BPF` arm. These are enumerated in §4.3 (the `MachineRelocType` family) and §4.2a
   (the non-reloc switches). This is the real cost of acceptance — not "free."

#### 4.2a Non-relocation `ehdrMachine()` switches

- `targetPageAlign` (`Elf2.sig:5657`): the arm is currently commented
  `//.BPF => 0x100000`. **Add a live arm `.BPF => 0x1000`.** Decision: Solana sBPF
  programs are not paged like a native OS executable; the loader maps text/rodata by
  segment. 4 KiB (`0x1000`) segment alignment avoids the `.so` bloat a 1 MiB alignment
  would add. (A4: the exact alignment the loader tolerates is pinned by PC3/§4.4; if
  the loader demands a different value, change this single arm.)
- `Format.format` printer (`Elf2.sig` ~944): add
  `.BPF => try w.print("R_BPF_{t}", .{f.rt.BPF})`.
- Input-object machine validation lives in `Elf2.sig`'s own loading path keyed off
  `ehdrMachine()`; once `EhdrMachine` includes `.BPF`, the object is accepted. (The
  `src/link/Elf/Object.sig:143` check is the LLD-era path and is not on the Solana
  route; it is left unchanged.)

### 4.3 sBPF relocation set and the full switch inventory (resolves finding 2 — HIGH, folds finding 7)

Extend the `MachineRelocType` union (`Elf2.sig:929`) with a `BPF` arm:

```
pub const MachineRelocType = union {
    AARCH64: std.elf.R_AARCH64,
    LARCH:   std.elf.R_LARCH,
    PPC64:   std.elf.R_PPC64,
    RISCV:   std.elf.R_RISCV,
    SPARC:   std.elf.R_SPARC,
    X86_64:  std.elf.R_X86_64,
    BPF:     std.elf.R_BPF,   // new (R_BPF enum added to lib/std/elf.sig, below)
};
```

Add `std.elf.R_BPF` to `lib/std/elf.sig` (verified: `EM.BPF = 247` exists, but there is
**no** `R_BPF` enum today — this is new work).

#### Measured result (PC2) — MEASURED R_SBF VALUES (overrides the prior "expected")

Run 2026-10-11; source object: the `EM_BPF` relocatable extracted from the sBPFv3
`solana-program` rlib (`libsolana_program-*.rlib` →
`solana_program-*.solana_program.*-cgu.0.rcgu.o`), produced by the same build as the
reference `.so`. Logs: `.build/sbpf-test/refcap/pc2-relocs-sbf.txt`,
`pc2-sections.txt`, and the `lddw` bytes in `pc1-objdump-reference.txt`.

Two findings override the prior guesses:

1. **The symbols are named `R_SBF_*`, not `R_BPF_*`** (Solana's LLVM fork names its
   relocation family `R_SBF`). The in-tree Sig enum should use the names the toolchain
   emits (`R_SBF_*`) with these numeric values.
2. **Only three relocation types actually appear**, and the numeric assignment is NOT
   the conventional upstream-eBPF `NONE=0/64_64=1/ABS64=2/ABS32=3/RELATIVE=8` set. The
   measured values (low byte of `r_info`, confirmed against the type names
   `llvm-readelf` prints) are:

| name | value (MEASURED, PC2) | count in ref obj | meaning |
|---|---|---|---|
| `R_SBF_NONE` | 0 | 0 (not emitted) | no-op |
| `R_SBF_64_64` | **1** (`0x01`) | 109 | 64-bit address split across the two `lddw` 8-byte halves (see split below) |
| `R_SBF_64_ABS64` | **2** (`0x02`) | 57 | full 64-bit absolute written at the data slot |
| `R_SBF_64_32` | **10** (`0x0a`) | 138 | 32-bit value written into a single instruction's imm field (call targets / 32-bit refs); dominant type |

Notes for the implementer:
- There is **no `R_SBF_64_ABS32` and no `R_SBF_64_RELATIVE`** in this sBPFv3 object. The
  32-bit case is `R_SBF_64_32 = 10`, not `3`. Do not emit the upstream-eBPF numbering.
- Relocation sections are **`.rel.*` (SHT_REL), entry size `0x10` (8-byte `r_offset` +
  8-byte `r_info`, NO explicit addend)** — i.e. the Solana reloc form is **REL, not
  RELA**; addends are implicit (read from the instruction/data slot). This directly
  settles the DT_REL-vs-DT_RELA question (see §4.4): the object/relocatable form is REL.

**Measured `lddw` immediate split (R_SBF_64_64).** From a disassembled `lddw` in the
reference `.so` (`pc1-objdump-reference.txt`), the instruction pair
`18 03 00 00 00 00 00 00  00 00 00 00 03 00 00 00` decodes to `lddw r3, 0x300000000`.
The 64-bit immediate is split across the two 8-byte instruction slots' imm fields
(bytes 4–7 of each slot, little-endian):
- **slot 1 imm (first instruction, bytes [4..8)) = LOW 32 bits** of the value
  (`0x00000000` here);
- **slot 2 imm (following instruction, bytes [4..8)) = HIGH 32 bits** of the value
  (`0x00000003` here);
- combined = `0x0000000300000000`.

So `R_SBF_64_64` apply writes `(S + A) & 0xffffffff` into slot-1's imm and
`(S + A) >> 32` into slot-2's imm. The opcode byte of the first slot is `0x18` (`lddw`);
the second slot is a pseudo-instruction carrying only the high half.

**The complete set of exhaustive `switch (elf.ehdrMachine())` functions in the
`MachineRelocType` union that each MUST gain a `.BPF` arm** (verified by reading
`Elf2.sig:929–1187`; none has an `else`, so all are hard compile errors until handled).
For each, the mapping and justification:

| function (`Elf2.sig`) | `.BPF` arm | note |
|---|---|---|
| `Format.format` (~944) | `R_BPF_{t}` printer | §4.2a |
| `none` (~958) | `.{ .BPF = .NONE }` | **hot path** — called in `relaAddOneAssumeCapacity` (694/789/813/834/858); must compile. |
| `copy` (~970) | `unreachable` | no copy relocations on sBPF (no shared-lib data imports). |
| `relative` (~982) | `.{ .BPF = .@"64_RELATIVE" }` | base-relative fixups the loader applies. |
| `jumpSlot` (~994) | `unreachable` | no PLT on sBPF. |
| `globDat` (~1007) | `unreachable` | no GOT on sBPF. |
| `dtpMod` (~1028) | `unreachable` | no TLS: on-chain code is single-threaded. |
| `dtpOff` (~1055) | `unreachable` | no TLS. |
| `tpOff` (~1082) | `unreachable` | no TLS. |
| `abs32` (~1116) | `.{ .BPF = .@"64_ABS32" }` | 32-bit absolute. |
| `abs64` (~1127) | `.{ .BPF = .@"64_ABS64" }` | 64-bit absolute. |
| `rel32` (~1138) | `unreachable` | no PC-relative data relocs needed; sBPF uses `lddw`+relative. Mark unreachable unless PC2 shows otherwise. |
| `rel64` (~1149) | `unreachable` | as above (LOONGARCH/RISCV already `unreachable` here — same treatment). |
| `size32` (~1160) | `null` | join the `AARCH64/LOONGARCH/PPC64/RISCV => null` arm. |
| `size64` (~1172) | `null` | join the same `null` arm. |
| `wrap` (~1176) | `.{ .BPF = @fromBackingInt(int) }` | generic reloc handling (used at 2439). |
| `unwrap` (~1184) | `@backingInt(rt.BPF)` | generic reloc handling (used at 6797). |

`absAddr` (~1105) needs no arm (it dispatches to `abs32`/`abs64` by class).

**Relocation apply logic.** The arch dispatch that resolves/applies relocations (the
AARCH64/X86_64 cases in `Elf2.sig`'s resolve/apply paths) gains a `.BPF` case:

- `R_BPF_64_64`: write the low 32 bits of `(S + A)` into the imm field of the first
  instruction slot and the high 32 bits into the imm field of the following slot (the
  two halves of a `lddw`). **The exact bit offsets are pinned by PC2** (confirm against
  one disassembled `lddw` reloc in the reference `.so`).
- `R_BPF_64_ABS64` / `R_BPF_64_ABS32`: write `S + A` as a plain 64/32-bit value at the
  relocation offset (data).
- `R_BPF_64_RELATIVE`: emit a corresponding dynamic relocation in `.rela.dyn` whose
  computation the loader performs (`B + A`) at deploy time, rather than resolving it at
  link time. This is how a Solana `.so`'s absolute data pointers (e.g. into rodata) are
  fixed up.

**Decision on syscalls vs relocations:** with SIMD-0178 static syscalls (§7), syscall
*calls* are NOT relocations — they are `call imm` instructions whose immediate encodes
the syscall. So the linker's relocation job is only data/address relocations, not
syscall resolution. This is why we commit to sBPFv3 (static syscalls): it keeps the
linker's relocation set to the five types above and avoids runtime syscall relocations.
(If §7's A9 check forces the linker-side syscall path, a `R_BPF_SYSCALL` entry is added
to the table above and to §10 — see §7.)

### 4.4 Shared-object ELF layout the loader expects (resolves finding 6 — MEDIUM)

The gating deliverable is "produces a *loadable* Solana program," so the exact
byte-layout the loader enforces is the whole contract — and it is **not** stated in the
authoritative sources. The prior draft asserted a layout while admitting it did not
know whether the loader reads by section or by `PT_LOAD`, and hedged by "emitting both."
That hedge is replaced by a concrete measurement step.

**PC3 (run before coding; §1.1).** `readelf -a` / `llvm-readelf -a` a known-good Solana
`.so` (output of `cargo build-sbf` for a trivial program) and record, in this section,
the observed contract:

- exact `e_type` (expected `ET_DYN`), `e_machine` (`EM_BPF` 247), class/endianness;
- the **program-header set** the loader consumes (how many `PT_LOAD`s, their flags,
  `p_align`) **vs** whether the loader reads purely by section header — this
  distinction decides whether `Elf2.sig` must emit specific `PT_LOAD`s or only the
  section table;
- the section set actually present (`.text`, `.rodata`, `.dynamic`, `.dynsym`,
  `.dynstr`, `.rel.dyn`/`.rela.dyn`) and whether `.data.rel.ro` is separate or folded;
- `DT_REL` vs `DT_RELA` (which relocation entry form the `.dynamic` advertises) — this
  determines which Sig DSO path (`REL` vs `RELA`) the linker uses;
- the entrypoint dynamic-symbol attributes (name, binding `GLOBAL`, type `FUNC`,
  visibility) so the exported `entrypoint` matches what the loader resolves.

Once recorded, `Elf2.sig`'s DSO emission is configured to that exact contract (it
already builds `.rela.dyn`, `.dynamic`, `.dynsym` for other arches, so the sBPF-specific
work is: the §4.3 reloc arms, the §4.2a page alignment, selecting `REL`/`RELA` per PC3,
and suppressing TLS/GOT/PLT synthetics — which fall away naturally because the §4.3
TLS/PLT/GOT arms are `unreachable` and on-chain code imports no dynamic symbols except
the exported `entrypoint`).

#### Measured result (PC3) — MEASURED DSO LAYOUT CONTRACT (overrides the "expected")

Run 2026-10-11; `llvm-readelf -a/-l/-S/-s` of the sBPFv3 deploy artifact
`target/deploy/trivial.so` and its unstripped sibling
`target/sbpfv3-solana-solana/release/deps/trivial.so`. Logs:
`.build/sbpf-test/refcap/pc3-readelf-a-deploy.txt`, `pc3-deps-layout.txt`,
`pc3-deps-symtab.txt`. **The measured sBPFv3 contract is substantially simpler and
MORE STATIC than the prior "expected" draft — the biggest single surprise of FEAT-001;
later features must implement against this, not the guesses.**

ELF header:
- `e_type = ET_DYN` (3), `e_machine = EM_BPF` (247), **ELFCLASS64, little-endian**,
  OS/ABI `UNIX - System V`, `e_version = 1`, `e_flags = 0x3`.
- `e_entry = 0x100000308` → **the loader enters via `e_entry`, not a dynamic-symbol
  lookup.** The symbol at that address is `entrypoint`.

Sections (deploy artifact, stripped): **only four** — `NULL`, `.rodata` (PROGBITS,
flags `WAMS`, `addr 0x0`, align 8), `.text` (PROGBITS, flags `AX`, `addr 0x100000000`,
align 8), `.shstrtab`. There is **NO `.dynamic`, NO `.dynsym`, NO `.dynstr`, NO
`.hash`/`.gnu.hash`, NO `.plt`, NO `.got`, and NO relocation section at all** in the
final `.so` — `llvm-readelf -r` reports "There are no relocations in this file." All
`R_SBF_*` relocations (§4.3) are **resolved statically at link time** by the Solana
linker; the deployed artifact carries none. The unstripped sibling additionally has a
`.symtab`/`.strtab` (plain, not dynamic). `.data.rel.ro` is **folded into `.rodata`**
(no separate section).

Program headers: **3 entries**, `e_phentsize = 56`:
- `LOAD` #0: offset `0xe8`, vaddr `0x0`, filesz=memsz `0x488`, flags **`R`**, **`p_align
  = 0x8`** → maps `.rodata`.
- `LOAD` #1: offset `0x570`, vaddr `0x100000000`, filesz=memsz `0x3bc8`, flags **`E`**
  (execute-only), **`p_align = 0x8`** → maps `.text`.
- `NULL` #2: empty terminator.

Two decisions this pins:
- **`targetPageAlign` for BPF must be `0x8`, NOT `0x1000`** (correct the §4.2a arm). The
  Solana loader uses an 8-byte segment alignment; `.text` lives at a fixed high VA
  (`0x100000000`) and `.rodata` at VA `0`. The two LOAD segments are `R` and `E`
  (execute-only text, read-only rodata) — no `RW` segment and no writable data in a
  trivial program.
- **The loader consumes the layout via program headers + `e_entry`**, with the final
  artifact fully resolved and relocation-free. `Elf2.sig`'s DSO path for Solana must
  therefore (a) emit `ET_DYN` + `EM_BPF`, (b) emit exactly these LOAD segments at
  `vaddr 0` (rodata, R) and `vaddr 0x100000000` (text, E) with `p_align 8`, (c) set
  `e_entry` to the `entrypoint` address, (d) **resolve all `R_SBF_*` relocations at link
  time and emit no `.dynamic`/relocation section** (the SIMD-0178/0219 static-link
  model), and (e) emit NO `.plt`/`.got`/TLS synthetics.

DT_REL vs DT_RELA: **moot for the final artifact — there is no `.dynamic` and no dynamic
relocation table.** At the *relocatable-object* level (§4.3) the form is **REL** (SHT_REL,
16-byte entries, implicit addends). So the linker reads REL input relocations and
resolves them into the section contents; it emits no dynamic reloc table on output.

Entrypoint symbol attributes (from the unstripped `.symtab`,
`pc3-deps-symtab.txt`): name **`entrypoint`**, binding **`GLOBAL`**, type **`FUNC`**,
visibility **`DEFAULT`**, section `.text`, value `0x100000308` (== `e_entry`),
size `272`. (The Rust runtime also exports `custom_panic` and `abort` as
`GLOBAL FUNC`; a Sig program only needs the single `entrypoint` export.) So the Sig
`export fn entrypoint(...)` must become a `GLOBAL FUNC DEFAULT`-visibility symbol in
`.text` and `e_entry` must point at it — a *static* symbol/entry, not a dynamic one.

### 4.5 Make the target dynamically linkable (deliverable 1, blocker #2)

The error `dynamic linking unavailable on the specified target` comes from
`error.TargetCannotDynamicLink` in `src/Compilation/Config.sig` (~line 262), gated by
`src/target.sig` `canDynamicLink`, which (verified) returns `false` for `.bpfeb/.bpfel`
unconditionally.

Change `src/target.sig` `canDynamicLink` so the BPF arches are dynamically linkable
*only* when `os.tag == .solana`:

```
pub fn canDynamicLink(target: *const std.Target) bool {
    return switch (target.cpu.arch) {
        .bpfeb, .bpfel => target.os.tag == .solana, // sBPF programs are shared objects
        .nvptx, .nvptx64, .spirv32, .spirv64 => false,
        .wasm32, .wasm64 => true,
        else => switch (target.os.tag) {
            .freestanding, .uefi => false,
            else => true,
        },
    };
}
```

Generic `bpfel-freestanding` stays non-dynamic (unchanged behavior); only the Solana
target opts in. This is the minimal, targeted change that unblocks
`sig build-lib -dynamic -target sbf-solana-solana`.

Audit the other `.bpfel, .bpfeb` arms in `src/target.sig` (around lines 211, 369, 420 —
stack protector / PIE / red-zone defaults): keep them BPF-wide (harmless for solana).
Only `canDynamicLink` must change behavior for the solana case; flag during
implementation any additional predicate that specifically gates dynamic output.

---

## 5. compiler_rt / soft-float avoidance (deliverable 4)

The failure `compiler_rt.__negxf2 … stack arguments are not supported` is an `f80`
soft-float helper that the BPF backend cannot lower. On-chain code must never pull it
in.

The default is set in `src/Compilation.sig` (verified ~line 1807):
`const want = options.want_compiler_rt orelse is_exe_or_dyn_lib;`. Because an sBPF
program is a dynamic lib, `is_exe_or_dyn_lib` is true, so compiler_rt is pulled in by
default — exactly the failure path.

**Decision: for `os.tag == .solana`, default `want_compiler_rt` to `false`.** Change
the default resolution to:

```
const want = options.want_compiler_rt orelse
    (is_exe_or_dyn_lib and target.os.tag != .solana);
```

This makes `-fno-compiler-rt` the implicit default for the sBPF target (the user can
still force `-fcompiler-rt`, but it will fail to lower, which is acceptable and
documented). This matches the task's "make -fno-compiler-rt the sane default." No change
to `canBuildLibCompilerRt` is required — we simply don't request compiler_rt.

**Belt-and-suspenders (float ban).** On-chain code should be float-free anyway. We do
**not** add a hard compile error for float use in this step (that is a language-level
policy change beyond the toolchain gap, and strict `.sig` mode already discourages the
patterns that pull in soft-float). Instead:

- Document in `compiler/SBPF_SOLANA_TARGET.md` that `f16/f32/f64/f80/f128` must not
  appear in on-chain code, because any soft-float legalization
  (`Air.Legalize` `soft_f16`/`soft_f32`/… → `legalize_compiler_rt_call`) emits a
  compiler_rt call the BPF backend cannot lower.
- **A7 (verified in §9):** with compiler_rt disabled *and* no float in source, confirm
  no `legalize_compiler_rt_call` is emitted for the trivial + syscall test programs. If
  a non-float path still emits a compiler_rt helper (e.g. 128-bit integer mul/div, which
  route through compiler_rt), document the banned integer-width operations too. This is
  a verification item, not a structural risk: the mitigation is documentation + the
  no-compiler_rt default, both already in this design.

---

## 6. Entrypoint and input region (context for codegen; library lives in zpm)

The compiler's only responsibility here is that an exported
`export fn entrypoint(input: [*]u8) callconv(.c) u64` is lowered with the C calling
convention and exported as a dynamic symbol the loader can call with the single
input-region pointer. Object emission is already verified. The byte-level parsing of
the input region (account count, per-account records, `rent_epoch = u64::MAX` per
SIMD-0267, 8-byte alignment per SIMD-0219, instruction data, program id — the exact
layout in §4 of the investigation report) is **zpm library code** and is out of scope.

The compiler must ensure the C calling convention for `.bpfel` (`bpf_std` in
`Sema.sig`/`llvm.sig`) places the single pointer argument in the register the Solana VM
uses for the entrypoint and returns the `u64` status in the result register. **A8
(verified in §9):** the existing `bpf_std`/`.c` lowering already matches the Solana
entrypoint ABI (single pointer in r1, return in r0, standard eBPF). This is the
conventional eBPF convention and almost certainly correct; §9 confirms it with a running
program. It is a verification item, not a structural decision.

---

## 7. Syscall lowering (deliverable 5 — one path committed, resolves finding 4)

On-chain syscalls are declared in zpm like
`extern fn sol_log_(ptr: [*]const u8, len: u64) callconv(.c) void;` with **no library
name**, because the Solana runtime resolves them.

**Decision: lower syscalls using the SIMD-0178 static-syscall encoding — a `call imm`
instruction whose 32-bit immediate is the Murmur3-32 hash of the syscall name, emitting
NO relocation for the call. The hashing + immediate materialization is done in codegen
(`src/codegen/llvm.sig`), not in the linker.** This is the sBPFv3 contract and the
direct reason §2 commits to v3. The design commits to the codegen path (not "whichever
of two works"); the linker-side fallback is retained only as a contingency, chosen
*only if* the pre-coding check PC-SYS below proves codegen cannot emit a fixed-immediate
`call`.

**PC-SYS — the A9 resolution check (run before coding this section).** Determine
whether the vendored LLVM BPF backend can emit a `call imm` with a compile-time-fixed
immediate for a no-library extern:

- inspect `src/codegen/llvm.sig`'s BPF call/extern handling (the point where an extern
  function reference is materialized, near `genNavRef`/extern handling in
  `src/codegen.sig`), and/or emit a one-line test that calls such an extern and
  `llvm-objdump -d` the object to see whether LLVM renders it as `call <imm>` or as a
  symbol-relocated call.
- **If LLVM emits (or can be driven to emit, via a BPF intrinsic / inline-asm `call`)
  a fixed-immediate call:** implement the committed codegen path — recognize an
  `extern fn … callconv(.c)` with no lib name under `os.tag == .solana` as a static
  syscall, compute `imm = murmur3_32(symbol_name)`, and materialize the `call imm`.
- **If LLVM will ONLY emit a symbol-relocated call for externs:** fall back to the
  linker path — codegen emits the call as a normal external-call relocation; add a new
  `R_BPF_SYSCALL` relocation type to §4.3's table (and to `lib/std/elf.sig` and §10),
  and `Elf2.sig`'s apply logic resolves it to `imm = murmur3_32(name)` and rewrites the
  `call` immediate at link time, emitting no dynamic relocation.

Both options keep everything in-house. **The committed primary is the codegen path**;
PC-SYS decides at implementation start which is physically possible, and its result is
recorded here. The two options are not loader-equivalent (a residual relocation vs a
pure `call imm` is the SIMD-0178 distinction), which is exactly why the choice is pinned
by measurement before coding rather than shipped as a runtime branch.

**murmur3-32 placement.** The Murmur3-32 helper (and the exact seed / name-string
encoding of the Solana syscall registry) is **compiler** code — it is codegen/link
machinery, not general on-chain library logic — so it lives in whichever seam PC-SYS
selects (`src/codegen/llvm.sig` for the primary path, or `src/link/Elf2.sig` for the
fallback). zpm only *declares* the externs; it never computes hashes. The seed/encoding
is the Solana registry convention and is confirmed against the reference program during
PC-SYS (hash a known syscall name and compare to the immediate the reference `.so`'s
`call` carries).

**Legacy fallback for pre-v3 loaders (A2):** if a target loader still expects relocated
syscalls, the `sbpfv1`/`sbpfv2` CPU models (§3.3) select a mode where syscalls are
emitted as relocations resolved against the loader's syscall symbol table. The design
keeps this available but defaults to v3 static syscalls; the committed path above is the
sBPFv3 one.

#### Measured result (PC-SYS) — STATIC `call imm` CONFIRMED; murmur3-32 seed 0

Run 2026-10-11; `llvm-objdump -d` of the reference `.so`
(`.build/sbpf-test/refcap/pc1-objdump-reference.txt`) + a murmur3-32 oracle over the
Solana syscall-name registry (`.build/sbpf-test/refcap/mm3.py`, outputs in
`pcsys-murmur3-table.txt` / `pcsys-murmur3-matches.txt`).

The sBPFv3 reference uses **two distinct `call` forms**, distinguished by the source-reg
nibble of the `0x85` call opcode:
- `85 10 00 00 <rel32>` (src reg = 1): a **PC-relative internal call** to another
  function in `.text` (e.g. `call 0x72b`, `call -0x6b`). These are resolved at link
  time, not syscalls.
- `85 00 00 00 <imm32>` (src reg = 0): a **static syscall** whose 32-bit immediate is a
  fixed hash — NO relocation attached in the final artifact.

Three measured syscall immediates in the reference and their murmur3-32 pre-images
(standard MurmurHash3 x86 32-bit, **seed = 0**, name bytes = the ASCII syscall symbol,
little-endian) match **exactly**:

| reference `call` imm | signed form shown by objdump | murmur3_32(name, seed=0) | name |
|---|---|---|---|
| `0x207559bd` | `call 0x207559bd` | `0x207559bd` | `sol_log_` |
| `0x717cc4a3` | `call 0x717cc4a3` | `0x717cc4a3` | `sol_memcpy_` |
| `0xb6fc1a11` | `call -0x4903e5ef` | `0xb6fc1a11` | `abort` |

(`-0x4903e5ef` is the signed-32 rendering of `0xb6fc1a11`.) The match is bit-exact for
all three, nailing the registry convention: **MurmurHash3_x86_32, seed 0, hashing the
raw syscall name string**, immediate stored directly in the call's imm32.

**DECISION (resolves A9): the committed codegen `call imm` path is physically
realizable and is the chosen path — NO linker-side `R_BPF_SYSCALL`/`R_SBF_*` fallback is
needed for syscalls.** The platform-tools BPF backend (same LLVM 22 family Sig vendors)
already renders a no-library static syscall as a fixed-immediate `call` with no residual
relocation, which is exactly the SIMD-0178 encoding. FEAT-004 therefore implements, in
`src/codegen/llvm.sig`: recognize an `extern fn … callconv(.c)` with no lib name under
`os.tag == .solana` as a static syscall, compute `imm = murmur3_32(name, 0)`, and emit
`call imm` (opcode `0x85`, src reg 0) with no relocation. The murmur3-32 helper is
compiler code (per the placement note above). The `R_SBF_*` linker fallback in §4.3/§7
is retained in the doc only as a dead contingency and need not be implemented for the
syscall path. (Note: this does not remove the §4.3 data relocations `R_SBF_64_64/
64_ABS64/64_32` — those are still needed for address/data references; PC-SYS only
settles the *syscall-call* mechanism.)

---

## 8. Build-and-deploy recipe (deliverable 6)

### 8.1 Doc location

Create `compiler/SBPF_SOLANA_TARGET.md` (parallel to `compiler/SB0_ABI_TARGET.md`),
documenting: the target triple, the version decision (§2), the required flags, the
syscall contract, the ELF layout (as pinned by PC3), and the deploy steps. This is the
authoritative toolchain doc.

### 8.2 Compiler invocation (the gating recipe)

Mirroring the android flow (`build-lib -dynamic -target … -femit-bin=…so`), the sBPF
build is:

```
sig build-lib -dynamic ^
    -target sbf-solana-solana ^
    -mcpu sbpfv3 ^
    -O ReleaseSmall ^
    -fnew-linker ^           # forced anyway for solana, stated for clarity
    -femit-bin=program.so ^
    --dep sol_syscalls --dep sol_entrypoint ^
    -Mroot=.build\sbpf-test\entry.sig ^
    -Msol_syscalls=<zpm>\src\platform\solana\syscalls.sig ^
    -Msol_entrypoint=<zpm>\src\platform\solana\entrypoint.sig
```

Notes:
- `-fno-compiler-rt` is **not** required (default for solana per §5), but may be passed
  explicitly for clarity.
- No `-lc`, no `--libc`, no `-L`: on-chain code is freestanding.
- The module wiring (`--dep`/`-M`) follows the exact pattern from `build-android.ps1`;
  the actual zpm modules are out of scope (zpm's job).

### 8.3 PowerShell driver

Ship a `tools/build-sbpf.ps1` driver in the worktree analogous to `build-android.ps1`,
but with no Android SDK dependency — just the `sig` invocation above plus optional
post-steps. It runs on Windows (primary host) and, being a pure `sig` invocation, on all
Sig hosts (mirror it with a trivial shell script; the `sig` command line is identical
cross-platform).

### 8.4 Post-link / deploy

The linked `program.so` is deployed with the Solana CLI
(`solana program deploy program.so`) against `solana-test-validator`. **The Solana CLI /
toolchain is a runtime/validator/measurement dependency for testing, deployment, and the
PC1/PC2/PC3/PC-SYS reference captures — NOT a compiler dependency.** It never
participates in producing the `.so` and is not part of the Sig release pipeline, so it
does not violate the bootstrap "no external compiler" rule.

**A10 (verified in §9):** no post-link transformation (e.g. the strip/relocate pass
`cargo build-sbf` performs) is required beyond what `Elf2.sig` emits. If PC3/integration
shows the loader needs a post-processing step, it is added as a documented post-link
step implemented in-house as a tiny Sig tool, not an external dependency.

---

## 9. Testability and verification

Unit-testable in isolation (no validator):
- Target parsing: `-target sbf-solana-solana` / `sbf-solana-solana` resolves to
  `{ .bpfel, .solana, .solana }`, default `-mcpu` is `sbpfv3`, `sig targets` lists it.
- `canDynamicLink` true for the solana target, false for `bpfel-freestanding`.
- `want_compiler_rt` default resolves to `false` for solana.
- `EhdrMachine.fromElf(.BPF)` returns `.BPF` (no panic); a crafted EM_BPF object loads
  through `Elf2.sig` past line 3752.
- Relocation apply: unit tests over `Elf2.sig`'s `R_BPF_*` apply with crafted
  symbol/addend inputs, asserting the `lddw` split and the `.rela.dyn`
  `R_BPF_64_RELATIVE` emission byte-for-byte (values from PC2).
- murmur3-32 of known syscall names against the reference immediates captured in PC-SYS.

Integration (requires `solana-test-validator`; the acceptance gate):
- Trivial `entrypoint` that logs and returns 0: `build-lib -dynamic -target
  sbf-solana-solana` → `program.so`; `solana program deploy` + invoke succeeds.
- Larger program exercising `sol_log_` + `sol_sha256` + account read + a
  `sol_invoke_signed_c` CPI: deploys, runs, syscalls resolve.

Test module placement: throwaway `entry.sig` (+ the larger one) under
`.build/sbpf-test/` in the worktree — **not** in zpm.

Pre-coding reference captures PC1/PC2/PC3/PC-SYS (§1.1, §2.1, §4.3, §4.4, §7) are run
first and their results recorded in this doc; they pin A1/A5/A6/A9 before any source is
changed. The remaining verification items (A2/A4/A7/A8/A10) are confirmed at the
integration gate. The step is not "done" until a Sig-linked `.so` loads and runs on
`solana-test-validator`, matching the task's acceptance criteria.

---

## 10. Files to touch (summary)

Compiler/toolchain only:

- `lib/std/Target.sig`: add `Os.Tag.solana`, `Abi.solana`; add a `.solana` arm at every
  `.sb0` site (verified lines 24, 162, 403, 844, 1091[override→ELF], 2335, 2501, 2942,
  3251) plus the `.sb0` ABI arms; triple parsing for `sbf`/`solana`; default-CPU branch
  `os == .solana => &bpf.cpu.sbpfv3`; add `isSolana` next to `isSb0` (~2252).
- `lib/std/Target/bpf.sig`: add `sbpfv1/sbpfv2/sbpfv3` CPU models (and, only if §7's
  PC-SYS forces a codegen feature toggle, a synthetic `static_syscalls` `Feature`).
- `lib/std/elf.sig`: add `R_BPF` relocation enum (values from PC2; `+ R_BPF_SYSCALL`
  only if §7 fallback is selected).
- `src/target.sig`: `canDynamicLink` → BPF arches dynamic iff `os == .solana`; audit the
  `.bpfel/.bpfeb` PIE/stack-protector/red-zone arms (keep BPF-wide).
- `src/Compilation/Config.sig`: force `use_lld = false` (~409–443) and
  `use_new_linker = true` (~461) for `os == .solana`.
- `src/Compilation.sig`: `want_compiler_rt` default `false` for `os == .solana` (~1807).
- `src/link/Elf2.sig`: **add `BPF` to the `EhdrMachine` enum (5603)** and handle the
  `fromElf … orelse panic` seam (3752); add a `.BPF` arm to all `MachineRelocType`
  switches enumerated in §4.3 (`none/copy/relative/jumpSlot/globDat/dtpMod/dtpOff/tpOff/
  abs32/abs64/rel32/rel64/size32/size64/wrap/unwrap` + `Format.format`) with the
  mappings/`unreachable` markings given there; `targetPageAlign` `.BPF => 0x1000`
  (5657); `R_BPF_*` apply + `R_BPF_64_RELATIVE` dynamic emission; DSO layout per PC3;
  suppress TLS/GOT/PLT synthetics (natural, since those arms are `unreachable`).
  (`+ R_BPF_SYSCALL` apply only if §7 fallback.)
- `src/codegen/llvm.sig` and/or `src/codegen.sig`: committed static-syscall `call imm`
  lowering for solana externs + murmur3-32 helper (or the linker-side `R_BPF_SYSCALL`
  fallback per §7/PC-SYS).
- `compiler/SBPF_SOLANA_TARGET.md`: recipe + contract doc (incl. the pinned PC2/PC3
  tables).
- `tools/build-sbpf.ps1`: the build driver.
- `.build/sbpf-test/`: throwaway test modules (not committed to zpm).

Explicitly **not** touched: `src/link/Lld.sig` (LLD stays as-is; sBPF bypasses it);
`src/link/Elf/*` (the LLD-era object path is not on the Solana route); the vendored LLVM
libraries; zpm (on-chain library is a separate task).

---

## 11. Consolidated open assumptions and how each is resolved

Every assumption now has a concrete resolution step and the structural ones are pinned
*before* coding (not deferred to integration):

- **A1** sBPFv3 opcode set ⊇ LLVM `bpfel -mcpu v3` output. → **PC1 before coding**
  (§2.1); non-empty-delta fallback ladder incl. an explicit stop-and-escalate.
- **A2** Loader accepts static-syscall `call imm` with no residual relocations. →
  integration gate; `sbpfv1/sbpfv2` legacy-reloc mode available (§7).
- **A3** `Os.Tag`/`Abi` switch inventory. → **RESOLVED** to a bounded checklist: mirror
  every `.sb0` arm (enumerated lines, §3.2) plus three overrides.
- **A4** Segment page alignment the loader tolerates. → pinned by **PC3** (§4.4); single
  `targetPageAlign` arm if different.
- **A5** Exact `R_BPF_*` values + `lddw` split. → pinned by **PC2 before coding** (§4.3
  table).
- **A6** Loader reads by section vs requires specific `PT_LOAD`s. → pinned by **PC3
  before coding** (§4.4); "emit both" hedge removed.
- **A7** No `legalize_compiler_rt_call` for float-free programs (incl. 128-bit int ops).
  → integration verification (§5); mitigation (no-compiler_rt default + doc) already in.
- **A8** `bpf_std`/`.c` matches the Solana entrypoint ABI (ptr r1, ret r0). →
  integration gate (§6).
- **A9** LLVM BPF backend can emit fixed-immediate `call`. → **RESOLVED to a committed
  codegen path**, with PC-SYS deciding before coding whether the linker-side fallback is
  needed (§7).
- **A10** No mandatory post-link transformation. → integration gate (§8.4); in-house Sig
  tool if required.

The structural decisions in §2–§5 and §7 stand; the previously-deferred structural risks
(opcode-set reuse, reloc values, ELF layout, syscall mechanism) are now pinned by the
PC1/PC2/PC3/PC-SYS captures that run before implementation.

---

## 12. Responses to the design review (revision 2)

- **Finding 1 (HIGH) — "acceptance comes for free" is wrong; `Elf2.sig` panics on
  EM_BPF.** ADDRESSED. §4.2 rewritten: the false claim is removed and explicitly
  corrected; it now specifies adding `BPF = @backingInt(std.elf.EM.BPF)` to the
  `EhdrMachine` enum (5603) and handling the `fromElf(...) orelse panic` seam (3752).
  §4.1 states `Elf2.sig` is the authoritative Solana linker and that `src/link/Elf/*`
  (the cited LLD-era file) is not on the Solana route and is not modified. The
  conflation is called out.
- **Finding 2 (HIGH) — ~18 exhaustive `MachineRelocType` switches each need a `.BPF`
  arm; only two were named.** ADDRESSED. §4.3 now enumerates every switch function
  (`none/copy/relative/jumpSlot/globDat/dtpMod/dtpOff/tpOff/abs32/abs64/rel32/rel64/
  size32/size64/wrap/unwrap` + `Format.format` + `targetPageAlign`) in a table with the
  exact BPF reloc each maps to, marks TLS (`dtpMod/dtpOff/tpOff`) and PLT/GOT
  (`jumpSlot/globDat/copy`) arms `unreachable` with justification (single-threaded, no
  PLT/GOT), flags the hot-path ones (`none`, `wrap`/`unwrap`), and adds the full list to
  §10. The `R_BPF_*` numeric table is included (finding 7 folded in), flagged for PC2
  confirmation.
- **Finding 3 (MEDIUM) — A1 is load-bearing and unverified; treated as localized.**
  ADDRESSED. New §2.1 makes A1 a mandatory pre-coding reference capture (PC1:
  disassemble a `cargo build-sbf` program, diff opcodes), records the delta here, and
  defines a concrete fallback ladder including an explicit stop-and-escalate if an
  sBPFv3-only opcode is unreachable without a backend fork. §3.1 is made contingent on
  this.
- **Finding 4 (MEDIUM) — syscall lowering forks on unresolved A9.** ADDRESSED. §7 now
  **commits to the codegen `call imm` path** as primary and defines PC-SYS, a
  before-coding check (inspect LLVM BPF extern lowering / objdump a test) that decides
  whether the linker-side `R_BPF_SYSCALL` fallback is physically necessary. The fallback
  reloc is wired into §4.3's table and §10 conditionally. The primary mechanism is no
  longer "whichever works."
- **Finding 5 (MEDIUM) — `Os.Tag`/`Abi` switch inventory deferred.** ADDRESSED. §3.2
  replaces the open deferral with the concrete rule "add a `.solana` arm everywhere
  `.sb0` has one," lists the verified `.sb0` line sites (24/162/403/844/1091/2335/2501/
  2942/3251), the three overrides (ELF object format, default CPU, compiler_rt), and the
  `isSolana` predicate. Added to §10.
- **Finding 6 (MEDIUM) — ELF layout unverified, self-contradicting PT_LOAD hedge.**
  ADDRESSED. §4.4 replaces the "emit both" hedge with PC3, a before-coding `readelf -a`
  capture of a known-good Solana `.so` that records `e_type`, the program-header vs
  section contract, `DT_REL`/`DT_RELA`, and the entrypoint symbol attributes; the linker
  is then configured to the observed contract. The expected shape is stated but marked
  "PC3 wins."
- **Finding 7 (NIT) — `R_BPF` values / `lddw` split unverified.** ADDRESSED. Folded into
  §4.3's numeric table, flagged for PC2 confirmation.
- **Finding 8 (NIT) — development-hierarchy boundary respected.** Acknowledged; no change
  (all changes remain compiler/toolchain; on-chain library stays in zpm; murmur3 stays
  in the compiler; Solana CLI is a runtime/measurement-only dependency).
