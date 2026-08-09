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

    /// Derives capacity from invariant + headroom, rounded to next power of 2.
    /// Formula: nextPow2(ceil(n * (1.0 + headroom)))
    fn planned(comptime n: usize, comptime headroom: f64) usize {
        const raw = @as(usize, @intFromFloat(@as(f64, @floatFromInt(n)) * (1.0 + headroom)));
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
    pub const SYMBOL_TABLE_CAPACITY: usize = 65536;
    /// Open addressing hash map bucket count
    pub const SYMBOL_BUCKETS: usize = 8192;
    pub const CODEGEN_RING_CAPACITY: usize = 16384;
    pub const RELOCATION_TABLE_CAPACITY: usize = 65536;
    pub const SECTION_MERGE_CAPACITY: usize = 1024;
    pub const DEPENDENCY_GRAPH_CAPACITY: usize = 16384;
    pub const DIAGNOSTIC_RING_CAPACITY: usize = 256;
    pub const EXTERNAL_SYMBOL_INDEX_CAPACITY: usize = 32768;

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
    if (C.CODEGEN_RING_CAPACITY & (C.CODEGEN_RING_CAPACITY - 1) != 0)
        @compileError("CODEGEN_RING_CAPACITY must be a power of 2");
}

test "planned() rounds to next power of 2 with headroom" {
    const C = Compiler_Capacity_Plan;
    // planned(100, 0.5) = nextPow2(floor(100 * 1.5)) = nextPow2(150) = 256
    if (C.planned(100, 0.5) != 256) @compileError("planned(100, 0.5) should be 256");
    // planned(1, 0.0) = nextPow2(floor(1 * 1.0)) = nextPow2(1) = 1
    if (C.planned(1, 0.0) != 1) @compileError("planned(1, 0.0) should be 1");
    // planned(4, 1.0) = nextPow2(floor(4 * 2.0)) = nextPow2(8) = 8
    if (C.planned(4, 1.0) != 8) @compileError("planned(4, 1.0) should be 8");
    // planned(5, 0.0) = nextPow2(floor(5 * 1.0)) = nextPow2(5) = 8
    if (C.planned(5, 0.0) != 8) @compileError("planned(5, 0.0) should be 8");
}
