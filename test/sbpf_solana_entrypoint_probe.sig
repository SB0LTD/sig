//! Solana sBPF on-chain entrypoint probe.
//!
//! Compiled for `-target sbf-solana-solana`, this is the minimal shape of a
//! deployable Solana program: a single exported `entrypoint` taking the raw
//! input region pointer and returning a u64 status, plus a no-library syscall
//! extern. It exercises the three toolchain pieces the Solana support work
//! added to the compiler:
//!
//!   - FEAT-002/003: the `sbf-solana-solana` target routes through the
//!     self-hosted ELF linker (the vendored LLD rejects EM_BPF) and emits the
//!     static, relocation-free ET_DYN `.so` layout the Solana loader expects
//!     (ELFCLASS64, little-endian, e_machine=EM_BPF/247, `.text` at the fixed
//!     VA 0x100000000, 8-byte segment alignment).
//!   - FEAT-004: a no-library `extern fn sol_log_(...) callconv(.c)` lowers to
//!     the SIMD-0178 static-syscall encoding — a BPF `call imm` whose 32-bit
//!     immediate is murmur3_32("sol_log_") == 0x207559bd, with no residual
//!     syscall relocation.
//!
//! `ci/test-sbpf-solana-target.sh` compiles this probe and byte-verifies both
//! the ELF layout and the static-syscall immediate.

// No library name: resolved by the Solana runtime as a static syscall.
extern fn sol_log_(msg: [*]const u8, len: u64) callconv(.c) void;

const greeting = "sig-sbpf";

/// Solana program entry. The loader passes a pointer to the serialized input
/// region (accounts + instruction data); a real program would deserialize it.
/// This probe logs a fixed message and returns success (0).
export fn entrypoint(input: [*]u8) callconv(.c) u64 {
    _ = input;
    sol_log_(greeting, greeting.len);
    return 0;
}
