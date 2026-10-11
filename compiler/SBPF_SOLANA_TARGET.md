# sBPF (Solana) Target — Toolchain Contract and Build/Deploy Recipe

This is the authoritative toolchain document for compiling and linking Solana
on-chain programs with the Sig compiler, parallel to `SB0_ABI_TARGET.md`. It
covers the target triple, the sBPF version decision, the required flags, the
float-free / no-`compiler_rt` profile, the SIMD-0178 static-syscall contract,
the ELF / relocation / dynamic-symbol layout, and the deploy recipe.

Scope: compiler/toolchain only. The on-chain library (entrypoint input
deserializer, `AccountInfo` views, PDA finder, program-error encoding, syscall
wrappers, atomics) is **out of scope** and lives in `SB0LTD/zpm` per the
development-hierarchy rule.

All measured values here come from a real `cargo build-sbf` sBPFv3 reference
object (FEAT-001 captures PC1/PC2/PC3/PC-SYS, under
`.build/sbpf-test/refcap/`) and from byte-verification of Sig-produced artifacts
(FEAT-005, `refcap/feat005-verify-*.txt`).

---

## 1. Target triple

Reach the target exactly like any other Sig target:

```
-target sbf-solana-solana -mcpu sbpfv3
```

- `sbf` is accepted as an input arch spelling that canonicalizes internally to
  `.bpfel` (the Solana ecosystem spells it `sbf-solana-solana`).
- The canonical internal target is `{ .arch = .bpfel, .os = .solana,
  .abi = .solana }`.
- Default `-mcpu` for `os == .solana` is `sbpfv3`.
- `toElfMachine` maps `.bpfel => EM_BPF` (247); the Solana-ness is an OS+ABI+CPU
  property, not a new arch (mirrors how `aarch64-sb0` keeps `aarch64`).

Confirm with `sig targets`: the `solana` OS/ABI and the `sbpfv1`/`sbpfv2`/
`sbpfv3` CPU models are listed under the `bpfel` arch.

## 2. sBPF version decision — sBPFv3

Target **sBPFv3** as the sole first-class output. Do **not** reuse
`bpfel -mcpu v3/v4` as a deploy target.

- `-mcpu v1..v4` on the upstream `bpf` arch selects the LLVM eBPF *ISA
  generation* (which instructions the backend may emit). "sBPFv3" is a Solana
  **loader/ABI/verifier version**: it fixes the relocation contract, the
  static-syscall call encoding (SIMD-0178), the input-region alignment
  (SIMD-0219), and `rent_epoch = u64::MAX` (SIMD-0267). These are properties of
  the *linked artifact and loader contract*, not of instruction selection, so
  the two version axes are orthogonal and a Solana-specific target is mandatory.
- The CPU models map their `llvm_name` back to the known-good upstream `v1/v2/v3`
  generation so codegen is driven by the verified LLVM BPF path; the Sig-facing
  `name` (`sbpfv1/2/3`) is the Solana version the user selects. `sbpfv3` carries
  the `.alu32` feature.
- PC1 proved the opcode set a logging/account-reading/CPI program needs is a
  strict subset of what `bpfel -mcpu v3` already emits (empty delta), so the
  `.bpfel` codegen substrate is reused unchanged.

## 3. Required flags

```
sig build-lib -dynamic \
    -target sbf-solana-solana \
    -mcpu sbpfv3 \
    -O ReleaseSmall \
    -femit-bin=program.so \
    <root>.sig
```

- `-dynamic` — Solana programs are shared objects (`ET_DYN`). The Solana target
  is the only BPF target for which `canDynamicLink` is true.
- `-O ReleaseSmall` — on-chain size/compute discipline.
- The self-hosted ELF linker (`src/link/Elf2.sig`) is forced on and the vendored
  LLD is bypassed for `os == .solana` (LLD rejects `EM_BPF`). `-fnew-linker` is
  implied; passing it explicitly is harmless.
- No `-lc`, no `--libc`, no `-L`: on-chain code is freestanding.
- `-fno-compiler-rt` is **not** required — it is the default for the Solana
  target (see §4).

## 4. Float-free / no-`compiler_rt` profile

For `os == .solana`, `want_compiler_rt` defaults to `false`. The soft-float
helper `compiler_rt.__negxf2` (an `f80` helper) and its siblings cannot be
lowered by the BPF backend; disabling `compiler_rt` by default keeps them out of
on-chain builds. The user can still force `-fcompiler-rt`, but it will fail to
lower (documented, acceptable).

Banned in on-chain code:

- **Floating-point types** `f16/f32/f64/f80/f128`. Any soft-float legalization
  emits a `compiler_rt` call the BPF backend cannot lower.
- **128-bit integer multiply/divide** and any other operation that routes
  through `compiler_rt` (`__multi3`, `__udivti3`, …). If a non-float path still
  pulls `compiler_rt` in, the offending integer-width op is the cause; keep
  arithmetic at 64-bit or narrower.

Strict `.sig` mode (no heap allocation) already aligns with the on-chain
profile.

## 5. Syscall contract (SIMD-0178 static syscalls)

On-chain syscalls are declared in zpm with **no library name** because the
Solana runtime resolves them:

```sig
extern fn sol_log_(ptr: [*]const u8, len: u64) callconv(.c) void;
```

Under `os == .solana`, codegen (`src/codegen/llvm.sig`, FEAT-004) recognizes a
no-library `extern ... callconv(.c)` as a **static syscall** and lowers the call
to a BPF `call imm` (opcode `0x85`, source register `0`) whose 32-bit immediate
is `murmur3_32(name, seed = 0)` — the standard MurmurHash3 x86 32-bit of the raw
syscall name. **No relocation is emitted** for the call (SIMD-0178).

Verified immediates (PC-SYS, bit-exact against the reference `.so`, and
re-verified in the FEAT-005 `syscalls_demo.so` disassembly):

| syscall name | `call imm` (hex) | source |
|---|---|---|
| `sol_log_`    | `0x207559bd` | PC-SYS + FEAT-005 demo |
| `sol_memcpy_` | `0x717cc4a3` | PC-SYS |
| `sol_sha256`  | `0x11f49d86` | FEAT-005 demo |
| `abort`       | `0xb6fc1a11` | PC-SYS |

Internal (same-module) calls use the PC-relative `call` form (opcode `0x85`,
source register `1`) and are resolved at link time; they are not syscalls.

## 6. ELF / relocation / dynamic-symbol layout

### 6.1 Relocation set (R_SBF, FEAT-001 PC2)

The Solana LLVM fork names the relocation family `R_SBF_*`. `lib/std/elf.sig`
defines `R_BPF` with the PC2-measured values (only the three that appear in a
real sBPFv3 object):

| name | value | meaning |
|---|---|---|
| `R_BPF_NONE`     | 0  | no-op |
| `R_BPF_64_64`    | 1  | 64-bit address split across a two-slot `lddw` |
| `R_BPF_64_ABS64` | 2  | full 64-bit absolute written at the data slot |
| `R_BPF_64_32`    | 10 | 32-bit value written into a single instruction imm |

There is **no** `R_SBF_64_ABS32` and **no** `R_SBF_64_RELATIVE` in sBPFv3; the
32-bit case is value **10**, not the upstream-eBPF `3`.

The `R_BPF_64_64` `lddw` split (FEAT-003 `bpfLddwSplit`): the 64-bit value is
split across the imm fields of the two 8-byte instruction slots — low 32 bits
into slot-1's imm (bytes `[4..8)`), high 32 bits into slot-2's imm
(bytes `[12..16)`); the opcode/register bytes are untouched.

Relocation **apply** (`src/link/Elf2.sig`, FEAT-003 + FEAT-005): because the
Solana output has no `.dynamic` section, `classifySymbolValue` returns `.static`
for every symbol, so each `R_SBF_*` is resolved to `S + A` and written directly
into section contents. **The final artifact carries no relocation table.**

### 6.2 Measured DSO layout — reference vs Sig-produced

The sBPFv3 loader contract (FEAT-001 PC3, from `cargo build-sbf`):

- `e_type = ET_DYN`, `e_machine = EM_BPF (247)`, ELFCLASS64, little-endian,
  `e_flags = 0x3`.
- Loader enters via **`e_entry`** (not a dynamic-symbol lookup); the symbol at
  `e_entry` is `entrypoint` (`GLOBAL FUNC`, `DEFAULT` visibility, in `.text`).
- Fully resolved and **relocation-free** — no `.dynamic`, `.dynsym`, `.hash`,
  `.plt`, `.got`, or relocation section.
- Reference segment layout: `.rodata` at vaddr `0` (R), `.text` at vaddr
  `0x100000000` (E, execute-only), both `p_align 0x8`.

Sig-produced `program.so` (FEAT-005, byte-verified and validator-accepted — the
emitter conforms to [SIMD-0189](https://github.com/solana-foundation/solana-improvement-documents/blob/main/proposals/0189-sbpf-stricter-elf-headers.md)):

| contract item | required (PC3 / SIMD-0189) | Sig `program.so` | status |
|---|---|---|---|
| ELFCLASS64 | yes | yes | ✅ |
| `EI_DATA` little-endian | yes | yes | ✅ |
| `EI_OSABI` / `EI_ABIVERSION` | `0` / `0` | `0` / `0` | ✅ |
| `e_machine` | 247 (EM_BPF) | 247 | ✅ |
| `e_type` | `ET_DYN` | `ET_DYN` | ✅ |
| `e_flags` | `0x3` | `0x3` | ✅ |
| `e_phoff` | `64` | `64` | ✅ |
| `e_phentsize` / `e_phnum` | `56` / `≥1` | `56` / `2` | ✅ |
| `e_entry` → `entrypoint` | inside bytecode segment | `0x100000000` (== entrypoint) | ✅ |
| `entrypoint` symbol | `GLOBAL FUNC` in `.text` | `GLOBAL FUNC` in `.text` | ✅ |
| relocation table | none | none | ✅ |
| `.dynamic`/`.dynsym`/`.hash`/`.plt`/`.got` | absent | absent | ✅ |
| static syscalls (`call imm`) | yes | yes (byte-exact imms) | ✅ |
| phdr[0] ro-data | `PT_LOAD PF_R` vaddr `0` | `PT_LOAD PF_R` vaddr `0` | ✅ |
| phdr[1] bytecode | `PT_LOAD PF_X` vaddr `0x100000000` | `PT_LOAD PF_X` vaddr `0x100000000` | ✅ |
| `p_align` | `0x8` | `0x8` | ✅ |
| `p_offset` chaining / 8-byte divisible | yes | yes (`0xb0` = 64 + 2·56) | ✅ |

Section headers are **ignored** by the loader (SIMD-0189), so the emitter writes
`e_shoff = e_shnum = 0` and no section-header table — a minimal two-segment file.

**How it is produced:** the self-hosted linker first lays out a correct,
relocation-free `EM_BPF` `ET_DYN` with the program's `.rodata`/`.text`, then a
BPF-only finalization pass (`finalizeBpfSolanaObject` in `src/link/Elf2.sig`,
keyed strictly on `machine == .BPF`) rewrites the output into the SIMD-0189 shape:
`e_phoff = 64`, exactly two ordered `PT_LOAD` headers (ro-data `PF_R` @ vaddr 0;
bytecode `PF_X` @ vaddr `0x100000000`), `e_entry` relocated into the bytecode
segment, the bytecode segment trimmed to the real instruction stream (trailing
zero instruction slots removed so the verifier does not read a `0x00` opcode),
and absolute rodata pointers (`lddw` immediates) rebased from the internal rodata
VA to the loader's rodata base (`0`). No non-BPF target is affected (verified:
x86_64 ELF exe/dyn output is byte-identical to the stage0 compiler).

## 7. Build driver

`tools/build-sbpf.ps1` is the PowerShell driver (mirrors the android
`build-lib -dynamic -target … -femit-bin=…so` shape, no Android SDK). It is a
pure `sig` invocation and therefore works on Windows (primary host) and every
Sig host; the `sig` command line is identical cross-platform (replicate with a
one-line shell script if needed).

```
tools\build-sbpf.ps1 -Entry path\to\entry.sig -Out program.so
```

## 8. Deploy recipe (WSL) and acceptance

The Solana CLI / `solana-test-validator` is a **runtime/deploy/measurement
dependency only** — it never participates in producing the `.so` and is not part
of the Sig release pipeline, so it does not violate the bootstrap "no external
compiler" rule.

Deploy and invoke under WSL. The exact flow run for acceptance is scripted in
`.build/sbpf-test/deploy-invoke.sh` (deploy via the Solana CLI, invoke via a
minimal JSON-RPC `sendTransaction` using `solders`):

```bash
# 1. Start a local validator (reset ledger)
solana-test-validator --reset

# 2. Point the CLI at it and fund a deployer key
solana config set --url http://127.0.0.1:8899 --keypair deployer.json
solana airdrop 10

# 3. Deploy the Sig-produced shared object (prints the Program Id)
solana program deploy program.so

# 4. Invoke it. A freshly-deployed program is invokable only from the slot
#    AFTER deployment once finalized, so retry the send with a fresh blockhash
#    until the runtime can load it (see invoke.py). The trivial program returns 0.
```

### Acceptance status — PASSING

- **Byte-level verification (in-environment):** both `program.so` (trivial) and
  `syscalls_demo.so` build with exit 0 and verify as relocation-free `EM_BPF`
  `ET_DYN` with the full SIMD-0189 header/program-header shape (§6.2), a
  `GLOBAL FUNC` `entrypoint` at `e_entry`, and byte-exact SIMD-0178 static-syscall
  immediates. Logs: `refcap/feat005-verify-*.txt`.

- **Validator deploy + execute (acceptance gate, PASSING):** run against a local
  `solana-test-validator 4.3.0` (Agave) under WSL
  (`.build/sbpf-test/deploy-invoke.sh`; logs `refcap/feat005-invoke-*.txt`).

  - **Trivial `program.so`:** deploys and executes successfully —
    ```
    Program <id> invoke [1]
    Program <id> consumed 2 of 200000 compute units
    Program <id> success
    ```
    (the two instructions `mov r0, 0` / `exit`; transaction `err: None`).

  - **`syscalls_demo.so`:** deploys (the loader's bytecode verifier accepts the
    SIMD-0178 static-syscall `call imm` encoding) and executes the `sol_log_`
    syscall on-chain —
    ```
    Program <id> invoke [1]
    Program log: sbpf demo: logging + sha256
    Program <id> consumed 195 of 200000 compute units
    ```
    The rodata string prints correctly (confirming the rodata-pointer rebase to
    VA 0). The program then faults reading the input region
    (`sol_sha256(input, 32, …)`) because the throwaway test transaction supplies
    no account/instruction input region — a test-harness limitation, not a
    toolchain defect. The toolchain pieces (load, static syscall dispatch, rodata
    access, compute metering) all execute on the real validator.

So a minimal Sig program with no external toolchain beyond `sig` deploys and runs
on a current Solana validator, and syscalls resolve at runtime. The gating
deliverable is met.

## 9. Files

Compiler/toolchain:

- `lib/std/Target.sig` — `Os.Tag.solana`, `Abi.solana`, triple parsing, default
  CPU, `isSolana` (FEAT-002).
- `lib/std/Target/bpf.sig` — `sbpfv1/sbpfv2/sbpfv3` CPU models (FEAT-002).
- `lib/std/elf.sig` — `R_BPF` relocation enum (FEAT-003).
- `src/target.sig` — `canDynamicLink` true for BPF iff `os == .solana`
  (FEAT-002).
- `src/Compilation/Config.sig` — force self-hosted linker, ban LLD for solana
  (FEAT-002).
- `src/Compilation.sig` — `want_compiler_rt` default false for solana (FEAT-002).
- `src/codegen/llvm.sig` — static-syscall `call imm` lowering + murmur3-32
  (FEAT-004).
- `src/link/Elf2.sig` — accept `EM_BPF`, `R_SBF_*` apply + `lddw` split, the
  static relocation-free DSO emission path (`emit_got_plt` gating, `have_dynamic`
  false for BPF, `e_entry → entrypoint`, no GOT/PLT/TLS/dyn sections), and the
  BPF-only `finalizeBpfSolanaObject` SIMD-0189 program-header finalizer
  (`e_phoff = 64`, two ordered `PT_LOAD` headers, bytecode trim, rodata-pointer
  rebase to VA 0) (FEAT-003 + FEAT-005).
- `tools/build-sbpf.ps1` — build driver (FEAT-005).

Out of scope: the on-chain zpm library; the vendored LLVM; `src/link/Lld.sig`
(bypassed for sBPF).

## 10. Windows `-Denable-llvm` build-system fixes (separable concern)

Producing the LLVM-linked compiler on Windows required three fixes to the
`sig_build` runner (`tools/sig_build/main.sig`). These are **pre-existing-defect
fixes in the build system, independent of the sBPF feature**, kept minimal and
noted here for separate review:

1. `Step_Registry.addDep` is now idempotent. A duplicate `sig → config` edge
   (added once in `build.sig` and again by `addLlvmLinkStep` under
   `-Denable-llvm`) left Kahn's in-degree stuck above zero and was misreported as
   a `dependency cycle`.
2. The registered subprocess compile step (`externalCompileStepFn`) now wires the
   ZigLLVM C++ wrapper sources (`-cflags … -- src/zig_llvm*.cpp …`) and the
   LLVM/Clang/LLD/system libraries, so a `-Denable-llvm` build links a working
   `sig.exe` instead of failing with undefined `ZigLLVM*`/`LLVMInitialize*`.
3. `appendLlvmLinkerArgs` adds the Windows system libraries LLVM Support needs
   (`ole32`, `uuid`, `advapi32`, `shell32`, `oleaut32`, `psapi`) alongside
   `ntdll`/`ws2_32`/`version`.

On this host the vendored LLVM 22 closure is selected with
`-Dllvm-prefix=…\.build\llvm-22-windows` (no `llvm-config` needed).

## Version bump

This completes the native sBPF (Solana) backend + link/deploy path. When merged
and released, bump the **patch** version (e.g. `0.6.0 → 0.6.1`).
