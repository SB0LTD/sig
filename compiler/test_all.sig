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

/// The full fixed-capacity compiler state is caller-owned rather than hidden in
/// a function frame. This is the property the cross-platform bootstrap must
/// enforce: deterministic storage below the 64 MiB design bound and a small
/// orchestration object that remains safe on constrained native stacks.
pub const PIPELINE_FIXED_STATE_BYTES: usize = @sizeOf(streaming.Pipeline_Workspace);
pub const PIPELINE_MEMORY_BUDGET_BYTES: usize = 64 * 1024 * 1024;
pub const MAX_CONTROLLER_STACK_BYTES: usize = 1024 * 1024;

comptime {
    if (PIPELINE_FIXED_STATE_BYTES > PIPELINE_MEMORY_BUDGET_BYTES)
        @compileError("canonical pipeline workspace exceeds its fixed memory budget");
    if (@sizeOf(streaming.Streaming_Controller) > MAX_CONTROLLER_STACK_BYTES)
        @compileError("streaming controller is too large for a bounded native stack");
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

test "canonical pipeline storage is explicit and remains within budget" {
    const testing = @import("std").testing;
    try testing.expect(PIPELINE_FIXED_STATE_BYTES <= PIPELINE_MEMORY_BUDGET_BYTES);
    try testing.expect(@sizeOf(streaming.Streaming_Controller) <= MAX_CONTROLLER_STACK_BYTES);
}
