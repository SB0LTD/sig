// Canonical test root for the allocator-free native compiler.
//
// Keeping the root at compiler/ makes every cross-layer relative import resolve
// exactly as it does in the production compiler graph. Importing each module
// here also guarantees that `sig test compiler/test_all.sig` discovers the full
// transitive test suite instead of silently testing only a leaf module.

const main = @import("main.sig");
const bootstrap = @import("bootstrap.sig");
const verification = @import("verification.sig");

const capacity = @import("core/capacity.sig");
const containers = @import("core/containers.sig");
const target = @import("core/target.sig");
const types = @import("core/types.sig");

const tokenizer = @import("frontend/tokenizer.sig");
const parser = @import("frontend/parser.sig");
const sema = @import("frontend/sema.sig");

const codegen = @import("backend/codegen.sig");
const deep_model = @import("backend/deep_model.sig");
const linker = @import("backend/linker.sig");

const compat = @import("pipeline/compat.sig");
const deps = @import("pipeline/deps.sig");
const diagnostics = @import("pipeline/diagnostics.sig");
const eviction = @import("pipeline/eviction.sig");
const streaming = @import("pipeline/streaming.sig");

/// Cross-platform reserve used by the canonical test jobs. The pipeline frame
/// owns all fixed-capacity phases simultaneously in Debug test builds, plus a
/// code buffer and final image. Requiring 2x that exact type-size sum leaves a
/// deterministic margin for the test runner, call frames, and ABI alignment.
pub const CANONICAL_TEST_STACK_BYTES: usize = 32 * 1024 * 1024;
pub const PIPELINE_FIXED_STATE_BYTES: usize =
    @sizeOf(tokenizer.Tokenizer) +
    @sizeOf(parser.Parser) +
    @sizeOf(sema.Sema) +
    @sizeOf(codegen.Codegen) +
    @sizeOf(linker.Linker) +
    capacity.Compiler_Capacity_Plan.CODEGEN_RING_CAPACITY +
    streaming.MAX_EXECUTABLE_IMAGE_BYTES;

comptime {
    if (CANONICAL_TEST_STACK_BYTES < PIPELINE_FIXED_STATE_BYTES * 2)
        @compileError("canonical compiler test stack has less than 2x fixed-state headroom");
}

test "all native compiler modules are reachable from the canonical root" {
    _ = main;
    _ = bootstrap;
    _ = verification;
    _ = capacity;
    _ = containers;
    _ = target;
    _ = types;
    _ = tokenizer;
    _ = parser;
    _ = sema;
    _ = codegen;
    _ = deep_model;
    _ = linker;
    _ = compat;
    _ = deps;
    _ = diagnostics;
    _ = eviction;
    _ = streaming;
}

test "canonical stack reserve has at least 2x pipeline headroom" {
    const testing = @import("std").testing;
    try testing.expect(CANONICAL_TEST_STACK_BYTES >= PIPELINE_FIXED_STATE_BYTES * 2);
}
