// Zero-Alloc Compiler — Capacity Plan
//
// Layer 0: Core Types & Containers
//
// Central comptime constant registry. All buffer sizes in the compiler derive
// from known compiler invariants (zig token count, scope limits, etc.) plus
// a headroom factor, rounded to the next power of 2. This ensures no wasted
// space while guaranteeing sufficient capacity for the streaming pipeline.
//
// Zero heap allocations — every structure is comptime-sized.

pub const Compiler_Capacity_Plan = struct {

    // ── Capacity Derivation ──

    /// Derives capacity from an invariant plus exact rational headroom, rounded
    /// to the next power of two. Integer arithmetic makes the result identical
    /// on every bootstrap host and avoids floating-point truncation at powers.
    /// Formula: nextPow2(ceil(n * (denominator + numerator) / denominator))
    fn planned(
        comptime n: usize,
        comptime headroom_numerator: usize,
        comptime headroom_denominator: usize,
    ) usize {
        if (headroom_denominator == 0) @compileError("headroom denominator must be non-zero");
        const scaled = n * (headroom_denominator + headroom_numerator);
        const quotient = scaled / headroom_denominator;
        const raw = quotient + if (scaled % headroom_denominator == 0) 0 else 1;
        return nextPow2(raw);
    }

    fn nextPow2(comptime v: usize) usize {
        if (v <= 1) return 1;
        var p: usize = 1;
        while (p < v) p *= 2;
        return p;
    }

    // ── Compiler Invariants ──

    /// Zig token enum count
    pub const MAX_TOKEN_TYPES: usize = 256;
    /// Longest legal identifier
    pub const MAX_IDENTIFIER_LEN: usize = 256;
    /// Nested scope limit
    pub const MAX_SCOPE_DEPTH: usize = 64;
    /// Maximum function parameters
    pub const MAX_FUNCTION_PARAMS: usize = 256;
    /// Maximum struct fields
    pub const MAX_STRUCT_FIELDS: usize = 4096;
    /// Maximum enum variants
    pub const MAX_ENUM_FIELDS: usize = 4096;
    /// Comptime recursion limit
    pub const MAX_COMPTIME_EVAL_DEPTH: usize = 128;
    /// Stop after N errors
    pub const MAX_ERROR_LIMIT: usize = 64;
    /// Re-parse ceiling per declaration
    pub const MAX_RECOMPUTATION_LIMIT: usize = 8;

    // ── Derived Phase Capacities ──

    pub const TOKEN_RING_CAPACITY: usize = 4096;
    pub const AST_NODE_POOL_CAPACITY: usize = 65536;
    pub const SOURCE_MAP_CAPACITY: usize = 65536;
    pub const TYPE_INTERN_CAPACITY: usize = 32768;
    /// One maximum-size declaration surface plus 100% scope headroom.
    pub const SYMBOL_TABLE_CAPACITY: usize = planned(MAX_STRUCT_FIELDS, 1, 1);
    /// Open addressing stays at or below a 1/2 load factor, bounding expected
    /// successful lookup probes by 1.5 under uniform hashing.
    pub const SYMBOL_BUCKETS: usize = planned(SYMBOL_TABLE_CAPACITY, 1, 1);
    pub const CODEGEN_RING_CAPACITY: usize = 16384;
    pub const RELOCATION_TABLE_CAPACITY: usize = 65536;
    pub const SECTION_MERGE_CAPACITY: usize = 1024;
    pub const DEPENDENCY_GRAPH_CAPACITY: usize = 16384;
    pub const DIAGNOSTIC_RING_CAPACITY: usize = 256;
    /// Four external references per maximum function parameter, then 100%
    /// headroom; the matching bucket count preserves the 1/2 load bound.
    pub const EXTERNAL_SYMBOL_INDEX_CAPACITY: usize = planned(MAX_FUNCTION_PARAMS * 4, 1, 1);
    pub const EXTERNAL_SYMBOL_BUCKETS: usize = planned(EXTERNAL_SYMBOL_INDEX_CAPACITY, 1, 1);

    // ── Register Sets (per architecture) ──

    pub const X86_64_REGS: usize = 16;
    pub const AARCH64_REGS: usize = 32;
    pub const ARM32_REGS: usize = 16;
    pub const RISCV_REGS: usize = 32;
    pub const WASM_LOCALS: usize = 65536;

    // ── Deep Model ──

    pub const MODEL_MAX_LAYERS: usize = 4;
    pub const MODEL_MAX_NEURONS: usize = 64;
    pub const MODEL_ACTIVATION_BUF: usize = 256;
};

// ── Compile-time validation ──

comptime {
    // Verify derived capacities are powers of 2
    const C = Compiler_Capacity_Plan;
    if (C.TOKEN_RING_CAPACITY & (C.TOKEN_RING_CAPACITY - 1) != 0)
        @compileError("TOKEN_RING_CAPACITY must be a power of 2");
    if (C.AST_NODE_POOL_CAPACITY & (C.AST_NODE_POOL_CAPACITY - 1) != 0)
        @compileError("AST_NODE_POOL_CAPACITY must be a power of 2");
    if (C.SYMBOL_TABLE_CAPACITY & (C.SYMBOL_TABLE_CAPACITY - 1) != 0)
        @compileError("SYMBOL_TABLE_CAPACITY must be a power of 2");
    if (C.SYMBOL_BUCKETS & (C.SYMBOL_BUCKETS - 1) != 0)
        @compileError("SYMBOL_BUCKETS must be a power of 2");
    if (C.SYMBOL_TABLE_CAPACITY * 2 > C.SYMBOL_BUCKETS)
        @compileError("symbol table load factor must not exceed 1/2");
    if (C.EXTERNAL_SYMBOL_INDEX_CAPACITY * 2 > C.EXTERNAL_SYMBOL_BUCKETS)
        @compileError("external symbol load factor must not exceed 1/2");
    if (C.CODEGEN_RING_CAPACITY & (C.CODEGEN_RING_CAPACITY - 1) != 0)
        @compileError("CODEGEN_RING_CAPACITY must be a power of 2");
}

test "planned() rounds to next power of 2 with headroom" {
    const C = Compiler_Capacity_Plan;
    comptime {
        // 100 with 1/2 headroom = 150, then nextPow2(150) = 256.
        if (C.planned(100, 1, 2) != 256) @compileError("planned(100, 1/2) should be 256");
        if (C.planned(1, 0, 1) != 1) @compileError("planned(1, 0/1) should be 1");
        if (C.planned(4, 1, 1) != 8) @compileError("planned(4, 1/1) should be 8");
        if (C.planned(5, 0, 1) != 8) @compileError("planned(5, 0/1) should be 8");
        // 5 with 1/3 headroom is ceil(20/3) = 7, then nextPow2(7) = 8.
        if (C.planned(5, 1, 3) != 8) @compileError("planned(5, 1/3) should be 8");
    }
}
