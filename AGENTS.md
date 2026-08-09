# Sig Agent Guide

Sig is the compiler/toolchain repo. It is a Zig compiler fork where `.sig`
strict mode makes allocator usage a compile-time error. Be especially cautious
around bootstrap, LLVM, release, and CI files.

## Bootstrap Rules

Sig builds Sig. Do not use upstream Zig to compile Sig releases. The intended
bootstrap chain is:

```text
zig1.wasm -> zig1.c -> zig1.exe -> zig2.c -> zig2.exe/bootstrap -> sig release
```

- The bootstrap binary (`zig2.exe` / `sig`) must produce the release binary.
- If the bootstrap cannot produce a working binary for a target, fix the
  bootstrap instead of falling back to upstream Zig.
- Do not add `setup-zig` to release workflows.
- The only acceptable upstream Zig usage is in bootstrap/toolchain construction
  workflows such as `build-bootstrap.yaml` and `build-llvm.yaml`.

## Windows Strategy

The C-backend bootstrap has had Windows UB/runtime issues. Until that path is
fixed:

- Linux and macOS bootstrap builds compile Sig natively.
- Windows releases should be cross-compiled from the Linux bootstrap with LLVM
  linked, using `-fllvm -flld -target x86_64-windows`.
- Do not rely on the native Windows bootstrap for `build-exe` release output.

## CI/CD Rules

- Never cancel running GitHub Actions workflows. Push fixes and trigger a new
  run; let older runs finish.
- Jobs that download or build LLVM must free disk space first on GitHub-hosted
  runners.
- Prefer zstd level 19 for large LLVM/toolchain artifacts that need fast
  decompression. Avoid xz for Windows/macOS LLVM packages when speed matters.

Suggested disk cleanup block:

```yaml
- name: Free disk space
  run: |
    sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /usr/local/share/boost
    sudo rm -rf /usr/local/graalvm /usr/local/.ghcup /usr/local/share/powershell
    sudo rm -rf /opt/hostedtoolcache/CodeQL /opt/hostedtoolcache/go
    sudo apt-get clean
```

## Kiro Specs To Preserve

- `../.kiro/specs/zero-alloc-compiler-functional/`: current functional compiler
  implementation plan for `sig/compiler/`; read this before compiler work.
- `../.kiro/specs/windows-bootstrap-fix/`: Windows bootstrap crash fix history.
- `.kiro/specs/sig-llvm-integration/`: LLVM integration history.
- `.kiro/specs/eradicate-zig-from-build/`: Sig-native build migration history.

## SB0 Native Target

The zero-alloc compiler must support SB0 as its native target, not only ELF and
PE. Before changing target parsing, AArch64 codegen, register allocation,
linking, trap wrappers, or binary emission, read `compiler/SB0_ABI_TARGET.md`.

Key non-negotiables:

- Classic SB0S uses SB0X, not ELF/PE, for native userspace binaries.
- Nexus has a related but not byte-identical ABI surface; use it as design input
  for the consolidated SB0 ABI, not as a permanent separate compiler target.
- SB0 targets reserve `x18` for kernel/platform use.
- SB0 trap wrappers use `svc #0`, `x8` for opcode, `x0-x5` for args, `x0` for
  value, and `x1` for status.
- Generated SB0 artifacts must pass loader/ABI tests, not just header magic
  checks.
