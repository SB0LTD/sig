# SB0 ABI Target Plan

The zero-alloc compiler must treat SB0 as the native target, not as an ELF/PE
compatibility side path. Classic `sb0s` and `nexus` are source material for a
single consolidated ABI. The goal is not to support both variants forever; the
goal is to extract the best contract from both and make that the compiler's SB0
target.

## Source Of Truth

Classic SB0S ABI:

- `../sb0s/.kiro/specs/sb0-abi-v0/requirements.md`
- `../sb0s/.kiro/specs/sb0-abi-v0/design.md`
- `../sb0s/src/common/types.sig`
- `../sb0s/src/kernel/sb0x_loader.sig`
- `../sb0s/src/kernel/trap.sig`
- `../sb0s/tests/abi/`

Nexus ABI:

- `../nexus/src/abi/abi.sig`
- `../nexus/src/abi/trap.sig`
- `../nexus/src/abi/wire_format.sig`
- `../nexus/src/common/types.sig`
- `../nexus/src/kernel/universal_loader.sig`

When these disagree, preserve the disagreement explicitly in a decision matrix,
then resolve it into the new consolidated ABI. Do not silently pick one branch's
constant or layout and call it SB0.

## Unified Target

Model SB0 as one native target:

- `aarch64-sb0`: consolidated native SB0 userspace ABI.

Classic SB0S v0 and Nexus v1 names may be useful as test fixtures or migration
inputs, but they should not become permanent compiler output targets unless the
user explicitly asks for compatibility modes.

The target parser should keep OS/ABI identity separate from output container.
For SB0, the output container is the consolidated SB0 native image format,
derived from SB0X rather than ELF or PE.

Native artifact kind is also separate from target identity:

- `SB0X` is the bounded native userspace image.
- `SB0K` is the privileged kernel image.

Both are `aarch64-sb0`. Kernel versus application is an artifact-kind choice,
not a second OS, ABI, or compiler target. The fixed-capacity emitter writes
either image directly into caller-provided storage; an SB0 build must never
route through a foreign executable or object container.

## Native Kernel Container

`SB0K` version 1 begins with one fixed 64-byte header followed immediately by
reset code. All integers are little-endian.

| Offset | Bytes | Field |
|---:|---:|---|
| 0x00 | 4 | `SB0K` magic |
| 0x04 | 2 | format version |
| 0x06 | 2 | header bytes |
| 0x08 | 2 | boot ABI version |
| 0x0a | 2 | ABI revision |
| 0x0c | 4 | flags; bit 0 is fixed layout |
| 0x10 | 8 | entry offset |
| 0x18 | 8 | total image bytes |
| 0x20 | 8 | relocation offset; zero when absent |
| 0x28 | 4 | relocation count |
| 0x2c | 4 | relocation entry bytes |
| 0x30 | 8 | build identity |
| 0x38 | 8 | preferred physical base; zero is loader-selected |

The initial direct-emission gate accepts only already-relocated AArch64 reset
code and records no relocation table. Later section and relocation work must
remain internal to the bounded SB0 emitter rather than materializing a foreign
intermediate file.

## Classic SB0S Evidence

These are compiler-visible requirements from classic SB0S that should be carried
forward unless the consolidated ABI deliberately improves them:

- Base calling convention: AAPCS64.
- Trap gate: `svc #0`.
- Trap opcode: `x8`.
- Trap arguments: `x0` through `x5`.
- Trap result: `x0`.
- Trap status: `x1`, containing `SB0Error`.
- Preserved across traps: `x9` through `x15`, `x19` through `x28`, `x29`, `x30`,
  and `SP`.
- Clobbered by traps: `x0` through `x8`, `x16`, and `x17`.
- Reserved: `x18`; userspace must not allocate or depend on it.
- Process entry: `x0 = *BootHandoffBlock`, `x1 = *HandleTable`,
  `x2` through `x30 = 0`, 16-byte-aligned `SP`, and `PC = SB0X entry`.
- Boot Handoff Block: exactly 256 bytes, magic `SB0H` (`0x53423048`), read-only.
- SB0X header: exactly 64 bytes, magic `SB0X`, version `0`.
- SB0X segment descriptor: exactly 40 bytes.
- Classic loader maximum: 8 segments.
- Classic kernel ABI version currently accepted by `sb0x_loader`: `0`.

The compiler must reserve `x18` in register allocation for every SB0 target,
even before trap codegen exists.

## Nexus Evidence

Nexus currently exposes an ABI layer with:

- `ABI_VERSION = 1` in `nexus/src/abi/abi.sig`.
- `TrapFrame` of exactly 272 bytes:
  `x0-x30`, `SP_EL0`, `ELR_EL1`, `SPSR_EL1`.
- `SyscallResult` written back as `x0 = value`, `x1 = err`.
- ABI-stable wire formats in `nexus/src/abi/wire_format.sig`.
- Explicit marshaling/unmarshaling for capability, message, I/O, resource,
  task, and action result payloads.

Nexus shares the SB0 philosophy and much of the data model, and its stronger
wire-format layer is valuable input for the consolidated ABI. Do not preserve
byte differences for their own sake; resolve them into the new contract.

## Consolidation Principles

- Prefer the simpler kernel/user register contract when it already satisfies
  both branches.
- Keep SB0X's fixed-size, bounded-loader shape unless Nexus proves a cleaner
  replacement.
- Keep Nexus-style explicit wire formats where cross-boundary structured data is
  involved.
- Keep classic SB0S's trap totality, x18 reservation, BHB determinism, and
  property-test coverage.
- Version the consolidated ABI intentionally. Do not inherit `0` or `1` merely
  because a branch used it.
- Once a consolidation decision is made, update compiler tests to target the new
  contract directly.

## Compiler Milestone Gates

SB0 support should have its own gates, parallel to ELF/PE:

1. Target parsing recognizes `aarch64-sb0`.
2. Register allocator reserves `x18` for SB0 targets.
3. Codegen can emit an AArch64 function using AAPCS64 with 16-byte stack
   alignment.
4. Codegen can emit a trap wrapper that places opcode in `x8`, arguments in
   `x0-x5`, issues `svc #0`, and reads `x0/x1`.
5. Linker emits a valid consolidated SB0 native image:
   fixed header, bounded segment descriptors, entry in executable segment.
   For a kernel artifact it emits `SB0K` directly with a fixed 64-byte header
   and reset entry, without a foreign intermediate container.
6. The generated image passes loader validation tests derived from both
   `sb0s/tests/abi/test_sb0x_validation.sig` and Nexus loader expectations.
7. Process-entry tests validate BHB/handle-table register assumptions:
   `x0`, `x1`, zeroed remaining registers, stack alignment, and entry address.
8. Wire-format tests validate the consolidated ABI structs used for capability,
   message, I/O, resource, task, and action payloads.

Do not mark "compiler can emit SB0" complete until the generated artifact is
accepted by the relevant loader and the trap/register contracts are tested.

## Design Rule

ELF and PE are compatibility targets. SB0X is the native target. If an
implementation shortcut makes ELF/PE easier but makes SB0X harder, choose the
structure that keeps SB0X clean.
