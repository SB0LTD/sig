# Verification — `sig objdump -d` sBPF segment fallback

Worktree: `c:\Just-Things\Projects\sb0\sig\.worktrees\objdump-sbpf-disasm`
Branch: `feat/objdump-sbpf-segment-disasm`
`sig` on PATH: `sig 0.6.2 (zig 0.17.0)` (the released binary — does NOT contain
this fix; used as the "before" oracle and to compile the worktree sources).

## 0. Reconcile (design §0 — mandatory first step)

The worktree branch HEAD was `3200c2f87b` (PR #27 merge), which predates the
objdump feature. Confirmed the branch is a strict ancestor of `origin/master`
(`git merge-base --is-ancestor HEAD origin/master` → exit 0) and that only
`lib/compiler/objdump.sig`, `CHANGELOG.md`, `test/link.sig`, and
`.agents/tasks/objdump-elf-disasm/*` differed.

Ran `git fetch origin` then `git merge --no-ff origin/master`. Result: clean
merge via the ORT strategy, no conflicts. After the merge the disassembler
(`disasm.run`, `decodeOne`, `murmur3_32`, `Annotator`, the comptime syscall
table, `-d`/`--disassemble` flags) exists exactly as the design describes.

## 1. Issue 1 (linker) — decision applied: KEEP STRIPPED, no code change

`compiler/SBPF_SOLANA_TARGET.md` §6.2 confirms SIMD-0189 mandates
`e_shoff = e_shnum = 0` (no section-header table); section headers are **ignored**
by the Solana loader, and the two-segment section-less image is validator-verified
(deploy+execute on `solana-test-validator 4.3.0`). Per the design's issue-1
decision, **`src/link/Elf2.sig` is unchanged** (`git diff` touches only
`lib/compiler/objdump.sig` and `CHANGELOG.md`). The loadable artifact's byte
layout and loadability are untouched. Tooling reaches the code via the issue-2
segment fallback instead.

## 2. Issue 2 (objdump) — the fix

`disasm.run` in `lib/compiler/objdump.sig` is now section-aware-or-segment-fallback:

- The per-blob decode/annotate/output loop was extracted into a shared private
  helper `decodeBlob(d, ann, syms, name, base, codebytes)` that both paths call,
  so section and segment paths render identically.
- `run` counts executable sections (`shf.EXECINSTR and size != 0`). If ≥1 exists,
  the **section path runs unchanged** (and returns). Otherwise it falls back to
  iterating `hdr.iterateProgramHeaders(fr)`, selecting `PT_LOAD` segments with
  `flags.X`, materializing each segment's bytes via `seekTo(ph.offset)` +
  `readAlloc(d.gpa, ph.filesz)` (matching `defer free`), decode base pc =
  `ph.vaddr`.
- Bounds guard mirrors the section path: `ph.offset > file_size or ph.filesz >
  file_size - ph.offset` → `d.failParse` (wrap-safe). Uses `filesz` (on-disk),
  never `memsz`.
- `--disassemble=<sym>` scoping mirrors the section path (segment whose vaddr
  range contains the symbol).
- `<no instructions>` is printed only when neither a section nor a segment
  decoded anything.
- COFF arm and all `coff.*` helpers are byte-identical (untouched).

Syscall table already covers the required names (`sol_log_`, `sol_sha256`,
`sol_invoke_signed_c`, `sol_get_clock_sysvar`) plus the full SIMD-0178 set — no
additions needed. The raw `call` immediate is always printed; the resolved name
is appended only on a hash hit (never guessed).

## 3. Compiler-graph type-check — PASS

Command (cwd = worktree):

```
sig build-exe -fno-emit-bin --dep std --dep aro --dep build_options \
  "-Mroot=src/main.sig" "-Mstd=lib/std/std.sig" \
  "-Maro=lib/compiler/aro/aro.sig" \
  "-Mbuild_options=c:/Just-Things/Projects/sb0/sig/.build-gen/build_options.sig"
```

Result: exit 0, no diagnostics (empty output). The whole compiler graph including
the modified `lib/compiler/objdump.sig` type-checks.

## 4. objdump unit tests — PASS (3/3)

Command: `sig test lib/compiler/objdump.sig`

```
1/3 objdump.test.murmur3_32 reference immediates...OK
2/3 objdump.test.sBPF decodeOne...OK
3/3 objdump.test.sBPF segment fallback decodeBlob...OK
All 3 tests passed.
```

The pre-existing `murmur3_32` and `sBPF decodeOne` tests stay green. The new
`sBPF segment fallback decodeBlob` test drives the shared `decodeBlob` helper
(the unit both paths funnel through) with `base = MM_PROGRAM_START` and an EMPTY
symbol table, asserting:
- the synthesized `segment1:` label banner,
- the `; entrypoint` note fires at `pc == 0x100000000`,
- `call 0x207559bd <sol_log_>` — raw immediate shown AND resolved via the
  Annotator syscall hash even with no symbols,
- `exit` renders.

## 5. End-to-end on a REAL sBPF `.so` — PASS (the whole point)

`log.sig` (from the brief) built for the Solana sBPF target. The brief's
`-femit-bin=log.so` form is rejected by the **released** 0.6.2 arg parser
(`error: .so: file not found` / `unrecognized file extension`), so the plain
`build-lib` default output name was used instead (`liblog.so`). The emission
itself succeeds:

```
sig build-lib log.sig -dynamic -target bpfel-solana -mcpu sbpfv3 \
    -OReleaseSmall -fno-compiler-rt
→ exit 0, produces liblog.so (65760 bytes)
```

Because `sig` on PATH is the released binary without this fix, the modified
objdump was compiled from the worktree sources into a standalone tool and run
against the real `.so`:

```
sig build-exe --dep std "-Mroot=lib/compiler/objdump.sig" \
    "-Mstd=lib/std/std.sig" --name objdump_wt      → exit 0 (objdump_wt.exe)
```

### Header state (before == after; artifact unchanged)

`objdump_wt.exe --summary liblog.so`:

```
liblog.so: ELF 64 shared object

type=DYN machine=BPF(247) entry=       100000000 class=ELF64 data=little flags=0x3(sbpfv3) phnum=2 shnum=0
```

`objdump_wt.exe --section-headers liblog.so` — header row only, zero entries:

```
Section Headers:
  [Nr] Name                 Type            Flg      Addr   Offset     Size Lk Inf Algn Entsz
```

So the emitted artifact is still `shnum=0` / `phnum=2` — unchanged, as the
issue-1 decision requires.

### `-d` BEFORE (released sig on PATH, no fix) — the reported bug

`sig objdump -d liblog.so`:

```
liblog.so: ELF 64 shared object

Disassembly (sbpfv3):
```

(banner then nothing — exactly the user's `<no instructions>` symptom.)

### `-d` AFTER (worktree objdump with the fix) — EMITS INSTRUCTIONS

`objdump_wt.exe -d liblog.so`:

```
liblog.so: ELF 64 shared object

Disassembly (sbpfv3):
segment1:
; entrypoint
         100000000:  lddw r1, 0x0
         100000010:  mov r2, 0x13
         100000018:  call 0x207559bd <sol_log_>
         100000020:  mov r0, 0x0
         100000028:  exit
```

This confirms every requested behavior on a real section-less sBPF object:
- the entry banner at `e_entry == 0x100000000` (`; entrypoint`),
- the segment covering `e_entry` anchors the decode (base = segment vaddr),
- the decoded sBPF instruction stream,
- the `call <imm>` to `sol_log_` with the raw immediate shown AND the resolved
  syscall name (`0x207559bd <sol_log_>`). `0x13 == 19 == len("hello from sig sbpf")`.

The hand-constructed-fixture fallback described in the brief/design §6.4 was
**not needed** — the real `build-lib` emission worked on this host.

## 6. Cleanup

Temp verification artifacts (`log.sig`, `liblog.so`, `objdump_wt.exe`,
`objdump_wt.pdb`, and the `.agents/tasks/objdump-sbpf-disasm/_*.txt` scratch
capture files) were produced only for verification and removed before commit.
The committed change set is `lib/compiler/objdump.sig` + `CHANGELOG.md` (plus this
task folder's design/verification docs).
