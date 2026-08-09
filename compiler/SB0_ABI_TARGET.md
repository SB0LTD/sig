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
