# Design: `sig objdump -d` sBPF disassembly via PT_LOAD segment fallback

Status: proposed (0.6.2 follow-up bug-fix). Worktree:
`c:\Just-Things\Projects\sb0\sig\.worktrees\objdump-sbpf-disasm`.
Branch: `feat/objdump-sbpf-segment-disasm`.
Primary file: `lib/compiler/objdump.sig` (the `disasm` namespace).
Investigated file (issue 1): `src/link/Elf2.sig` (`finalizeBpfSolanaObject`).
Governing contract: `compiler/SBPF_SOLANA_TARGET.md` (§6.2, SIMD-0189) — read.

> All paths below are **absolute inside the worktree**. The step cwd is the user's
> main workspace, NOT the worktree, so every file op must use
> `c:\Just-Things\Projects\sb0\sig\.worktrees\objdump-sbpf-disasm\...` and every
> git op must use `git -C c:\Just-Things\Projects\sb0\sig\.worktrees\objdump-sbpf-disasm`.

---

## 0. CRITICAL PRECONDITION — the worktree base is stale (reconcile first)

The brief assumes the from-scratch sBPF disassembler internals already live in
`lib/compiler/objdump.sig` on this branch (`decodeOne`, `murmur3_32`, the
comptime SIMD-0178 syscall table, the `Annotator`, and `disasm.run`). **On this
worktree branch they do not exist.** Verified against the actual tree:

- `lib/compiler/objdump.sig` on the worktree is 1784 lines; the ELF/Mach-O/Wasm
  handlers are still the pre-feature stubs:
  `const elf = struct { fn dump(r, w) { _ = r; try w.writeAll("TODO dump elf file\n"); } };`
  (same for `macho`/`wasm`). There is **no** `disasm` namespace, **no**
  `decodeOne`, **no** `murmur3_32`, **no** `Annotator`, and the arg loop's final
  branch is `fatal("unrecognized argument: {s}", …)` — `-d`/`--disassemble` are
  NOT recognized.
- The worktree HEAD is `3200c2f87b` ("Merge pull request #27 …resinator…"),
  which predates the objdump feature work.

All of that work was merged to `origin/master` as **PR #28**
(`cd9c274ede`, branch `feat/objdump-elf-disasm`, commits FEAT-001…FEAT-005):
full ELF inspection, the `-d`/`--disassemble`/`--disassemble-all`/`--disassemble=<sym>`
flags, `--summary`/`--program-headers`/`--segments`/`--dynamic`/`--dynamic-symbols`/
`--dynamic-relocs`, the from-scratch sBPF decoder, `murmur3_32` (verbatim from
`src/codegen/llvm.sig`), the comptime SIMD-0178 syscall-hash reverse-map table,
and the `Annotator`. Verified on `origin/master:lib/compiler/objdump.sig`:
`disasm.run` at ~L1366, `decodeOne` at ~L1221, `Annotator` at ~L999,
`murmur3_32` at ~L1035, `MM_PROGRAM_START = 0x1_0000_0000` at ~L991, in-file unit
tests `test "murmur3_32 reference immediates"` and `test "sBPF decodeOne"`.

**Git relationship (verified):** the worktree branch (`3200c2f87b`) is a strict
ancestor of `origin/master` (`860768b690`): `git merge-base --is-ancestor
feat/objdump-sbpf-segment-disasm origin/master` → exit 0; the merge-base equals
the worktree HEAD. `git diff --stat` shows only `lib/compiler/objdump.sig`
differs (+1598 lines; `src/link/Elf2.sig` is byte-identical between the two).
Therefore **merging `origin/master` into the worktree branch is a clean
fast-forward with zero conflicts** and brings in both PR #28 (objdump feature)
and PR #29 (a second resinator fix).

**Step 1 of implementation is therefore a reconcile**, not a code change:

```
git -C c:\Just-Things\Projects\sb0\sig\.worktrees\objdump-sbpf-disasm fetch origin
git -C c:\Just-Things\Projects\sb0\sig\.worktrees\objdump-sbpf-disasm merge --no-ff origin/master
```

After this, `disasm.run` / `decodeOne` / `murmur3_32` / `Annotator` / the full
ELF handler / `-d` all exist exactly as the brief describes, and the segment
fallback (issue 2) is a small additive change on top. Every subsequent section of
this document is written against the **post-merge** `lib/compiler/objdump.sig`
(i.e. the `origin/master` content), and every line reference is to that content.

> If `--no-ff` is undesirable, a plain `git merge origin/master` fast-forwards the
> branch to `860768b690`. Either is acceptable; `--no-ff` keeps a visible merge
> commit documenting the reconcile. Do NOT rebase the public feature branch.

---

## 1. The problem (restated against the real code)

`sig objdump -d <sbpf.so>` prints the `Disassembly (sbpfv3):` banner and then
nothing, because `disasm.run` (post-merge `lib/compiler/objdump.sig` ~L1366)
locates code ONLY by walking section headers and filtering `shf.EXECINSTR`:

```sig
for (sections.items) |shdr| {
    if (!shdr.flags.shf.EXECINSTR) continue;   // <-- nothing to iterate when shnum==0
    if (shdr.size == 0) continue;
    ...
    try fr.seekTo(shdr.offset);
    const codebytes = try r.readAlloc(d.gpa, shdr.size);
    defer d.gpa.free(codebytes);
    ... decodeOne cursor loop over codebytes, base = shdr.addr ...
}
```

sBPF `.so` files emitted by sig carry `e_shoff = e_shnum = 0` (no section table),
so `sections.items` is empty and the loop body never runs. The code is present and
reachable only through the two `PT_LOAD` program segments (`phnum == 2`), which
`disasm.run` never consults. There is no segment-walk fallback today.

Everything else works and must not be touched: the ELF inspection views
(`--summary`/`--file-headers`/`--section-headers`/`--program-headers`/`--segments`/
`--symbols`/`--dynamic-symbols`/`--relocs`/`--dynamic-relocs`/`--dynamic`/
`--strings`/`--tls`, snapshot tooling `--elements`/`--redact`/`-s`), the COFF arm,
`decodeOne`, `murmur3_32`, the comptime syscall table, and the `Annotator`.

---

## 2. Issue 1 (linker/codegen): the shnum=0 finalizer — DECISION: keep stripped

### 2.1 Exact location of the shnum=0 sBPF finalizer

The sBPF `.so` is NOT produced by the generic finalizer. The generic path in
`src/link/Elf2.sig` DOES build a full section table — the `shnum:` comptime block
(~L4064) counts a reserved null shdr, `.symtab`, `.shstrtab`, `.strtab`, optional
`.interp`, `.rodata`, **`.text`** (with EXECINSTR), `.data`, etc. If sBPF went
through that path, `-d`'s section walk would already find `.text`.

Instead, after the generic flush, a BPF-only pass rewrites the entire output
file. Verified call site (`src/link/Elf2.sig` ~L9482):

```sig
if (bpf_solana) {
    elf.finalizeBpfSolanaObject(bpf_entry_vaddr) catch |err|
        return diags.fail("sBPF SIMD-0189 program-header finalization failed: {t}", .{err});
}
```

`finalizeBpfSolanaObject` (defined ~L9507) allocates a fresh `buf`, writes a
hand-built `Elf64.Ehdr` with **`.shoff = 0, .shnum = 0, .shentsize = 0,
.shstrndx = 0`** (~L9644-9653) and `.flags = .{ .int = 0x3 }` (sBPFv3), followed by
exactly two `PT_LOAD` program headers (phdr[0] = `PF_R` ro-data @ vaddr 0;
phdr[1] = `PF_X` bytecode @ vaddr `0x1_0000_0000`), then the rodata and trimmed
`.text` bytes, then `writePositionalAll` + `setLength(total_len)`. No section
header table is ever written. This is the exact origin of `shnum=0`/`shoff=0`.

### 2.2 Is it deliberate? — Yes, and it is validator-verified

Both the finalizer's own doc comment and `compiler/SBPF_SOLANA_TARGET.md` §6.2
state this is mandated by **SIMD-0189** (stricter sBPF ELF headers): the Solana
loader's header parser rejects a multi-segment, page-aligned layout and **ignores
section headers**, so the emitter writes `e_shoff = e_shnum = 0` and a minimal
two-segment file. §8 of that doc records the acceptance gate as **PASSING**: the
Sig-produced `program.so` and `syscalls_demo.so` deploy and execute on a real
`solana-test-validator 4.3.0` (Agave) under WSL, with the bytecode verifier
accepting the SIMD-0178 static-syscall `call imm` encoding. The reference
`cargo build-sbf` output retains a `.text` section, which is how `llvm-objdump -d`
disassembles it — but Solana's loader does not require it, and SIMD-0189 explicitly
permits (and sig chooses) the section-less form.

### 2.3 Decision: KEEP the sBPF artifact stripped; do NOT restore a section table

Rationale, grounded in the contract and loader compatibility:

1. **Loadability is proven for the current byte layout.** The two-segment,
   section-less image is the exact shape that passed the validator deploy+execute
   gate (§8). The finalizer rebuilds the file byte-for-byte and `setLength`s it to
   `total_len = ehdr | 2·phdr | rodata(pad8) | text(pad8)`. Appending a section
   header table (even a minimal `.text`/`.shstrtab`) would grow the file past
   `total_len` and set `e_shoff` to a non-zero value — a change to a
   loader-verified binary whose SIMD-0189 header constraints (`e_shoff = e_shnum = 0`
   among them) are part of what the validator accepted. The brief is explicit:
   if restoring a section table risks changing the loadable artifact's loader
   behavior, do NOT change the emitted artifact — prefer issue 2 and document
   issue 1 as a deliberate strip. That condition holds here.

2. **The fix does not need it.** Issue 2 (segment fallback) makes `-d` work on
   exactly the section-less shape sBPF emits, with the code reachable via the
   `PF_X` `PT_LOAD` segment. Restoring sections would be redundant for tooling and
   would reintroduce loader-contract risk for zero functional gain.

3. **SIMD-0189 says sections are ignored, not required.** Tooling parity with
   `llvm-objdump` is achieved by making *our* objdump segment-aware, which also
   benefits any third-party section-less sBPF `.so`, not only sig's own output.

**Documented outcome:** issue 1 is a *deliberate strip* dictated by SIMD-0189 and
confirmed by a passing validator gate; `finalizeBpfSolanaObject` is left
unchanged; tooling reaches the code through the issue-2 segment fallback. **No
change is made to `src/link/Elf2.sig` in this task.** (If a future task wants
`llvm-objdump`-style section parity, the safe route is an opt-in, off-by-default
emitter flag that appends a non-loaded `.text`/`.shstrtab` after the segments
while keeping `e_shoff`/`e_shnum` semantics the loader tolerates — explicitly out
of scope here and gated behind its own validator re-test.)

---

## 3. Issue 2 (objdump): section-aware-or-segment-fallback in `disasm.run` — THE FIX

This is the primary change and lands regardless of issue 1. It is confined to the
`disasm` namespace in `lib/compiler/objdump.sig`; the COFF arm and every `coff.*`
helper stay byte-identical.

### 3.1 Which function, and the selection logic

Modify **`disasm.run`** (`lib/compiler/objdump.sig` ~L1366). Keep its signature
unchanged — it already receives everything needed:
`run(d, hdr, sections, shstrtab, syms, e_flags)`, and `d.fr` provides
`hdr.iterateProgramHeaders(d.fr)` and `fr.seekTo`/`readAlloc`.

Refactor the per-section decode body into a single private helper so the section
path and the new segment path share identical cursor/annotation/output logic:

```sig
/// Decode one contiguous code blob: print the per-pc banner/entry note, then run
/// the decodeOne cursor loop. `base` is the vaddr of codebytes[0]. Shared by the
/// section path and the segment fallback so both annotate and format identically.
fn decodeBlob(
    d: *const DumpContext,
    ann: *const Annotator,
    syms: []const SymName,
    name: []const u8,          // section name, or a synthesized "segmentN" label
    base: u64,
    codebytes: []const u8,
) !void { ... existing banner + MM_PROGRAM_START note + decodeOne while-loop ... }
```

Then `run` becomes:

1. Machine gate (unchanged): `switch (hdr.machine) { .BPF, .SBF => {}, else =>
   d.failParse("disassembly not implemented for {s}", …) }`.
2. Build the single `Annotator` (unchanged) and print the
   `Disassembly ({sbpfVersionName})` banner (unchanged).
3. **Decide the source of code:**
   - Count executable sections: iterate `sections.items`, note any with
     `shdr.flags.shf.EXECINSTR and shdr.size != 0`.
   - **If at least one exists → section path (unchanged behavior):** for each such
     section, apply the existing `--only-section` filter and `--disassemble=<sym>`
     scoping, do the existing EOF/bounds guard, `fr.seekTo(shdr.offset)` +
     `readAlloc(d.gpa, shdr.size)` (defer free), and call
     `decodeBlob(d, &ann, syms, name, shdr.addr, codebytes)`.
   - **Else (no executable section — `shnum == 0` or none has EXECINSTR) → segment
     fallback.** This is the new arm.

"Sections when present, segments otherwise" is preserved exactly; the section path
is not removed and runs byte-identically whenever an EXECINSTR section exists.

### 3.2 Segment fallback — selection, byte materialization, pc base, guards

```sig
const file_size = try fr.getSize();
var it = hdr.iterateProgramHeaders(d.fr);   // yields std.elf.Elf64.Phdr
var seg_index: usize = 0;
var decoded_any = false;
while (try it.next()) |ph| : (seg_index += 1) {
    if (ph.type != .LOAD) continue;         // PT_LOAD only
    if (!ph.flags.X) continue;              // executable segments only
    if (ph.filesz == 0) continue;           // nothing on disk to decode

    // Bounds guard: offset in-range AND filesz within the remaining file.
    // Compare against (file_size - offset) so a crafted filesz cannot wrap.
    if (ph.offset > file_size or ph.filesz > file_size - ph.offset)
        d.failParse("segment {d} bytes out of bounds", .{seg_index});

    try fr.seekTo(ph.offset);
    const codebytes = try r.readAlloc(d.gpa, @intCast(ph.filesz));
    defer d.gpa.free(codebytes);

    // Synthesize a stable label (there is no section name without a shstrtab).
    var namebuf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&namebuf, "segment{d}", .{seg_index}) catch "segment";

    // --disassemble=<sym> scoping: only decode the segment whose vaddr range
    // contains the requested symbol's value (mirrors the section path's intent).
    if (d.opts.disassemble_symbol) |want| {
        var hit = false;
        for (syms) |s| {
            if (std.mem.eql(u8, s.name, want) and
                s.value >= ph.vaddr and s.value < ph.vaddr + ph.memsz) { hit = true; break; }
        }
        if (!hit) continue;
    }

    try decodeBlob(d, &ann, syms, name, ph.vaddr, codebytes);   // pc base = segment vaddr
    decoded_any = true;
}
if (!decoded_any and d.element(.@"header-name"))
    try w.writeAll("  <no instructions>\n");   // keep the existing empty-output banner shape
```

Key points:

- **PT selection** uses the typed `Elf64.Phdr` the existing `--program-headers`
  view already consumes: `ph.type` is the `PT` enum (compare `.LOAD`), and
  `ph.flags` is the `PF` packed struct with `bool` members (`ph.flags.X`). This is
  the same field access `--program-headers` uses at ~L648 — no new parsing.
- **Byte materialization** mirrors the section path exactly: `fr.seekTo(ph.offset)`
  then `r.readAlloc(d.gpa, ph.filesz)` with a matching `defer d.gpa.free(...)`.
  Use `ph.filesz` (bytes actually present on disk), never `memsz` (which may
  include zero-fill not backed by file bytes).
- **pc base = `ph.vaddr`.** For sBPF, phdr[1] has `vaddr == 0x1_0000_0000 ==
  MM_PROGRAM_START`, so the first instruction's pc equals `e_entry`, which drives
  the entry note (see §4). phdr[0] (ro-data) is `PF_R` only and is skipped by the
  `ph.flags.X` filter, so rodata is never mis-decoded as code.
- **Bounds guards** match the section path's wrap-safe comparison; a segment whose
  `offset`/`filesz` is inconsistent with the file size → `d.failParse` (the §9
  error channel, never a stub, never an OOB read). `decodeOne` already guards a
  short/odd tail (`code.len < 8`, and `< 16` for `lddw`) by emitting `<truncated>`
  and returning `error.ParseFailure`, which `decodeBlob` catches to stop the blob
  cleanly — identical to the section path.
- **Allocator discipline (strict mode):** every read uses the single `d.gpa` with
  a matching `defer free`; `namebuf` is a fixed stack buffer (no alloc). No global
  allocator, no hidden allocation. This matches the section path and `dumpObject`.

### 3.3 Why this is safe and minimal

- The section path is literally unchanged when an EXECINSTR section exists, so all
  existing ELF snapshots (x86_64/aarch64 objects that DO have `.text`) are
  byte-identical.
- `decodeOne` is pc-independent (`_ = pc;`) and `Annotator.resolve`/`.region`
  operate purely on immediates/addresses, so moving the byte source from section
  to segment changes nothing about how any instruction renders.
- The COFF arm is in a different namespace and is not touched.

---

## 4. Annotation reachability via the segment path

The `Annotator` is constructed once in `run` and passed into `decodeBlob` for both
the section and segment paths, so annotation is automatically reachable via the
fallback. Specifics the fix must preserve (all already satisfied by reusing
`decodeBlob` + the existing `Annotator`):

- **Entry note.** `decodeBlob`'s per-pc loop already prints `; entrypoint` when
  `pc == MM_PROGRAM_START (0x1_0000_0000)` and `d.element(.@"header-name")`. In the
  segment path the `PF_X` segment's `vaddr` is `0x1_0000_0000`, so the first
  decoded pc equals `e_entry` and the entry note fires. (`src/link/Elf2.sig` places
  `.text`/`e_entry` at `0x1_0000_0000`; `finalizeBpfSolanaObject` sets
  `e_entry = text_vaddr_base + (entry_vaddr - text_vaddr)`, inside phdr[1].)
- **Symbol banners.** `decodeBlob` prints `<name>:` when a symbol's `value == pc`.
  Note sBPF `.so` files are typically symbol-stripped (no `.symtab` section once
  section headers are gone), so `syms` may be empty and no `<name>:` banner
  appears — that is correct and expected; the entry note and raw addresses still
  render.
- **SIMD-0178 static syscalls.** `decodeOne`'s `call <imm>` arm (opcode 0x85,
  src==0) calls `ann.resolve(@as(u64, @as(u32, @bitCast(in.imm))))`, which
  reverse-maps the murmur3_32 hash against the comptime `syscalls` table
  (`sol_log_=0x207559bd`, `sol_memcpy_=0x717cc4a3`, `sol_sha256=0x11f49d86`,
  `abort=0xb6fc1a11`, `sol_get_clock_sysvar=0xd56b5fe9`,
  `sol_try_find_program_address=0x48504a38`, …, plus `sol_invoke_signed_c`). The
  raw immediate is ALWAYS printed (`call 0x<imm>`) and the resolved name is
  appended only on a hit (`<sol_log_>`) — never guessed. This arm is inside
  `decodeOne`, so it is reached identically whether bytes came from a section or a
  segment. **Verify** the comptime table includes `sol_sha256`,
  `sol_invoke_signed_c`, `sol_get_clock_sysvar` (and the rest already present); add
  any missing name to the comptime name list (the hash is computed at comptime via
  `murmur3_32`, so only the name string is needed).

No annotation code changes are required beyond the §3 refactor; the task must only
**confirm** (by the §6 end-to-end run / unit test) that `call` immediates reached
via the segment path resolve.

---

## 5. Files touched

| File (absolute, in worktree) | Change |
|---|---|
| (git) merge `origin/master` | Step 0: bring in PR #28/#29 so the disassembler exists. No file authored by hand. |
| `lib/compiler/objdump.sig` | Refactor `disasm.run` body into `decodeBlob`; add the `PT_LOAD`+`PF_X` segment fallback; `<no instructions>` only when neither path decoded anything. Add a `test "sBPF segment fallback"` unit test (§6). |
| `src/link/Elf2.sig` | **No change** (issue-1 decision: deliberate strip). |
| `CHANGELOG.md` | One line under `## [0.6.2]` → `### Fixed`: `sig objdump -d` now disassembles section-less sBPF `.so` files via executable PT_LOAD segment fallback. |

The COFF arm, all `coff.*` helpers, the ELF inspection views, `decodeOne`,
`murmur3_32`, the syscall table, and the `Annotator` are not modified (beyond the
mechanical extraction of the shared loop into `decodeBlob`, which keeps their call
shapes identical).

---

## 6. Verification plan

Use the installed self-hosted compiler at
`C:\Just-Things\Projects\Lib\sig-latest\bin\sig.exe` (confirmed `sig 0.6.2
(zig 0.17.0)`). Run from the worktree root.

1. **Type-check / build the objdump JIT tool.** The in-file unit tests compile the
   whole module, so:
   ```
   & "C:\Just-Things\Projects\Lib\sig-latest\bin\sig.exe" test lib\compiler\objdump.sig
   ```
   Expected: `All N tests passed` with the pre-existing `murmur3_32 reference
   immediates` and `sBPF decodeOne` tests plus the new segment-fallback test.
   (This is the authoritative gate FEAT-005 used; it also exercises the comptime
   syscall table's `@setEvalBranchQuota`.)

2. **New unit test — `test "sBPF segment fallback"` (pure, no I/O to disk).**
   Because `disasm.run` needs a `DumpContext`/file reader, add a focused test at
   the `decodeBlob` level (the unit that both paths funnel through) OR a small
   in-memory ELF test:
   - *Decoder-level (preferred, no file):* hand-encode a tiny instruction stream
     (`mov r0, 0` `0xb7…`, `call 0x207559bd` `0x85…`, `exit` `0x95…`), construct a
     throwaway `Annotator{ .syms = &.{}, .syscalls = disasm.syscalls, .machine =
     .BPF }`, run the `decodeOne` cursor loop with `base = MM_PROGRAM_START` into a
     `std.Io.Writer.fixed` buffer, and assert the rendered text contains the entry
     note, `call 0x207559bd <sol_log_>`, and `exit`. This proves annotation +
     entry note are reachable with a segment-style base and empty symbol table.
   - This mirrors the existing `test "sBPF decodeOne"` style (fixed buffer,
     `w.buffered()`), so no new harness is needed.

3. **End-to-end reproduction (the user's `log.sig`).** If the Solana target is
   available on this host:
   ```
   & "...\sig.exe" build-lib log.sig -dynamic -target sbf-solana-solana -mcpu sbpfv3 ^
       -O ReleaseSmall -fno-compiler-rt -femit-bin=log.so
   & "...\sig.exe" objdump --summary log.so          # expect shnum=0 phnum=2 (unchanged)
   & "...\sig.exe" objdump --section-headers log.so   # expect header row only (unchanged)
   & "...\sig.exe" objdump -d log.so                   # EXPECT instructions now, not <no instructions>
   ```
   `log.sig` (from the brief): an `extern fn sol_log_(...)` static syscall plus an
   `export fn entrypoint(...)`. Expected `-d` output: the `Disassembly (sbpfv3):`
   banner, a `; entrypoint` note at `0x100000000`, the instruction stream, and the
   `sol_log_` call rendered as `call 0x207559bd <sol_log_>`.

4. **Fallback fixture if `build-lib` cannot target Solana on this host.** FEAT-002…
   005 findings record that the Solana target is unavailable in this Windows dev
   env. In that case, construct a **hand-built section-less sBPF ELF fixture** at
   test time (a byte array: a valid `Elf64.Ehdr` with `machine = .BPF`,
   `flags.int = 0x3`, `shoff = shnum = 0`, `phoff = 64`, `phnum = 2`; phdr[0]
   `PT_LOAD PF_R` @ vaddr 0; phdr[1] `PT_LOAD PF_X` @ vaddr `0x1_0000_0000` whose
   `offset`/`filesz` cover a short hand-encoded instruction stream ending in
   `exit`). Write it to a temp file, run `objdump -d` against it, and assert the
   instructions appear and `<no instructions>` does NOT. This exercises the full
   `run` → segment-fallback → `decodeBlob` path without needing the Solana
   codegen/linker. Clean up the temp file afterward.

5. **Regression — section path unchanged.** Build any ELF object that DOES have an
   EXECINSTR `.text` (e.g. `build-obj -target x86_64-linux`) and confirm `-d` emits
   the clear `disassembly not implemented for X86_64` message (non-sBPF machine
   gate, unchanged) and that `--summary`/`--section-headers` are byte-identical to
   pre-change output. For sBPF-with-sections (hypothetical), the section path still
   wins. The `test/link.sig` `elf-objdump` snapshot cases (added by FEAT-005,
   guarded by `ofmt == .elf`) remain the CI gate for ELF inspection parity; this
   change adds no new section-path output, so existing `.dmp` snapshots are
   unchanged. If an sBPF `-d` snapshot can be produced in CI (Solana target
   available), add one `verifyObjdump(... &.{ "-s", "-d" } ...)` case following the
   existing pattern.

6. **Formatting.** `lib/compiler/objdump.sig` pre-dates clean `sig fmt`
   (FEAT-005 noted the file fails `sig fmt --check` at HEAD). Format only the new
   lines to match surrounding style; do NOT reformat the whole file.

7. **Cleanup.** Remove any `log.so`/`log.o`/temp fixtures built under the worktree
   during verification.

---

## 7. Scope boundaries & assumptions

- **In scope:** the git reconcile (§0), the `disasm.run` segment fallback (§3), its
  unit test, and a one-line CHANGELOG `### Fixed` note.
- **Out of scope:** any change to `finalizeBpfSolanaObject` or the emitted sBPF
  artifact (§2 decision); Mach-O/Wasm disassembly; x86_64/aarch64/riscv decoders.
- **Assumption (documented, low-risk):** the merge of `origin/master` is a clean
  fast-forward (verified: worktree branch is a strict ancestor of `origin/master`,
  only `objdump.sig` differs, `Elf2.sig` identical). If the merge somehow conflicts
  (it should not), resolve in favor of `origin/master`'s objdump feature content,
  then apply §3 on top.
- **Assumption:** on this Windows host the Solana target may be unavailable for a
  live `build-lib`; the §6.4 hand-built fixture is the mandated fallback so the fix
  is verified regardless.
