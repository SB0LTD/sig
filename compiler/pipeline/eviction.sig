// Zero-Alloc Compiler — Eviction Controller
//
// Layer 2: Pipeline Orchestration
//
// Coordinates eviction policy across compiler phases.
// Enforces bounded recomputation (MAX_RECOMPUTATION_LIMIT per declaration).
// When a declaration is evicted from the symbol table or type pool and later
// re-referenced, the eviction controller decides whether recomputation is
// allowed or whether the limit has been reached.
//
// Zero heap allocations — all state is comptime-sized.

const cap = @import("../core/capacity.sig");
const containers = @import("../core/containers.sig");
const Compiler_Capacity_Plan = cap.Compiler_Capacity_Plan;
const BoundedVec = containers.BoundedVec;

// ============================================================================
// Eviction_Controller
// ============================================================================

/// Coordinates eviction policy across compiler phases.
/// Tracks how many times each declaration has been recomputed after eviction,
/// enforcing MAX_RECOMPUTATION_LIMIT to prevent unbounded re-parsing of
/// adversarial inputs.
pub const Eviction_Controller = struct {
    /// Recomputation count per declaration (indexed by declaration ID).
    /// Each entry tracks how many times that declaration has been evicted
    /// and subsequently recomputed from source.
    recomp_counts: [Compiler_Capacity_Plan.DEPENDENCY_GRAPH_CAPACITY]u8 = @splat(0),

    /// Total recomputations triggered across all declarations.
    total_recomputations: u32 = 0,

    /// Initialize an eviction controller with all counts at zero.
    pub fn init() Eviction_Controller {
        return .{};
    }

    /// Trigger recomputation for a given declaration.
    /// Returns true if recomputation is allowed (within limit), false if capped.
    /// When false is returned, the compiler should emit a diagnostic error
    /// rather than attempting to recompute again.
    pub fn triggerRecomputation(self: *Eviction_Controller, decl_id: u32) bool {
        if (decl_id >= Compiler_Capacity_Plan.DEPENDENCY_GRAPH_CAPACITY) return false;
        if (self.recomp_counts[decl_id] >= Compiler_Capacity_Plan.MAX_RECOMPUTATION_LIMIT) return false;
        self.recomp_counts[decl_id] += 1;
        self.total_recomputations += 1;
        return true;
    }

    /// Check if recomputation for a declaration is still within bounds.
    /// Returns true if the declaration can still be recomputed (count < limit).
    pub fn isRecomputationBounded(self: *const Eviction_Controller, decl_id: u32) bool {
        if (decl_id >= Compiler_Capacity_Plan.DEPENDENCY_GRAPH_CAPACITY) return false;
        return self.recomp_counts[decl_id] < Compiler_Capacity_Plan.MAX_RECOMPUTATION_LIMIT;
    }

    /// Get the recomputation count for a declaration.
    /// Returns 0 for out-of-bounds declaration IDs.
    pub fn getRecompCount(self: *const Eviction_Controller, decl_id: u32) u8 {
        if (decl_id >= Compiler_Capacity_Plan.DEPENDENCY_GRAPH_CAPACITY) return 0;
        return self.recomp_counts[decl_id];
    }

    /// Reset the recomputation count for a declaration.
    /// Used when a declaration is definitively resolved (no longer subject to eviction).
    pub fn resetCount(self: *Eviction_Controller, decl_id: u32) void {
        if (decl_id >= Compiler_Capacity_Plan.DEPENDENCY_GRAPH_CAPACITY) return;
        self.recomp_counts[decl_id] = 0;
    }

    /// Get the total number of recomputations triggered across all declarations.
    pub fn totalRecomputations(self: *const Eviction_Controller) u32 {
        return self.total_recomputations;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Eviction_Controller init has zero counts" {
    const ctrl = Eviction_Controller.init();
    if (ctrl.total_recomputations != 0) @compileError("expected zero total recomputations on init");
    if (ctrl.recomp_counts[0] != 0) @compileError("expected zero count for decl 0");
    if (ctrl.recomp_counts[100] != 0) @compileError("expected zero count for decl 100");
}

test "Eviction_Controller triggerRecomputation increments count" {
    var ctrl = Eviction_Controller.init();
    const allowed = ctrl.triggerRecomputation(5);
    if (!allowed) @compileError("first recomputation should be allowed");
    if (ctrl.getRecompCount(5) != 1) @compileError("expected count 1 after one trigger");
    if (ctrl.total_recomputations != 1) @compileError("expected total 1");
}

test "Eviction_Controller respects MAX_RECOMPUTATION_LIMIT" {
    var ctrl = Eviction_Controller.init();
    // Trigger recomputation MAX_RECOMPUTATION_LIMIT times (should all succeed)
    var i: u32 = 0;
    while (i < Compiler_Capacity_Plan.MAX_RECOMPUTATION_LIMIT) : (i += 1) {
        const allowed = ctrl.triggerRecomputation(7);
        if (!allowed) @compileError("recomputation within limit should be allowed");
    }
    // The next attempt should be denied (at limit)
    const denied = ctrl.triggerRecomputation(7);
    if (denied) @compileError("recomputation beyond limit should be denied");
    if (ctrl.getRecompCount(7) != Compiler_Capacity_Plan.MAX_RECOMPUTATION_LIMIT)
        @compileError("count should equal MAX_RECOMPUTATION_LIMIT");
}

test "Eviction_Controller isRecomputationBounded reflects state" {
    var ctrl = Eviction_Controller.init();
    if (!ctrl.isRecomputationBounded(0)) @compileError("fresh decl should be bounded");

    // Fill to limit
    var i: u32 = 0;
    while (i < Compiler_Capacity_Plan.MAX_RECOMPUTATION_LIMIT) : (i += 1) {
        _ = ctrl.triggerRecomputation(0);
    }
    if (ctrl.isRecomputationBounded(0)) @compileError("at-limit decl should NOT be bounded");
}

test "Eviction_Controller out-of-bounds returns safe defaults" {
    var ctrl = Eviction_Controller.init();
    const oob_id: u32 = @intCast(Compiler_Capacity_Plan.DEPENDENCY_GRAPH_CAPACITY);
    // Out-of-bounds triggerRecomputation returns false
    const allowed = ctrl.triggerRecomputation(oob_id);
    if (allowed) @compileError("out-of-bounds should return false");
    // Out-of-bounds isRecomputationBounded returns false
    if (ctrl.isRecomputationBounded(oob_id)) @compileError("out-of-bounds should not be bounded");
    // Out-of-bounds getRecompCount returns 0
    if (ctrl.getRecompCount(oob_id) != 0) @compileError("out-of-bounds count should be 0");
}

test "Eviction_Controller resetCount clears a declaration's count" {
    var ctrl = Eviction_Controller.init();
    _ = ctrl.triggerRecomputation(3);
    _ = ctrl.triggerRecomputation(3);
    if (ctrl.getRecompCount(3) != 2) @compileError("expected count 2");
    ctrl.resetCount(3);
    if (ctrl.getRecompCount(3) != 0) @compileError("expected count 0 after reset");
    // total_recomputations is not decremented (it's a historical counter)
    if (ctrl.total_recomputations != 2) @compileError("total should remain 2");
}

test "Eviction_Controller independent declarations tracked separately" {
    var ctrl = Eviction_Controller.init();
    _ = ctrl.triggerRecomputation(10);
    _ = ctrl.triggerRecomputation(10);
    _ = ctrl.triggerRecomputation(20);
    if (ctrl.getRecompCount(10) != 2) @compileError("decl 10 should have count 2");
    if (ctrl.getRecompCount(20) != 1) @compileError("decl 20 should have count 1");
    if (ctrl.total_recomputations != 3) @compileError("total should be 3");
}

test "Eviction_Controller totalRecomputations accessor" {
    var ctrl = Eviction_Controller.init();
    if (ctrl.totalRecomputations() != 0) @compileError("expected 0 initially");
    _ = ctrl.triggerRecomputation(1);
    _ = ctrl.triggerRecomputation(2);
    if (ctrl.totalRecomputations() != 2) @compileError("expected 2 after two triggers");
}


// Property 24: Recomputation bound
test "recomputation bound - exactly MAX_RECOMPUTATION_LIMIT allowed then denied" {
    var ctrl = Eviction_Controller.init();
    const limit = Compiler_Capacity_Plan.MAX_RECOMPUTATION_LIMIT;
    var i: u32 = 0;
    while (i < limit) : (i += 1) {
        if (!ctrl.triggerRecomputation(0)) @compileError("within-limit recomputation should succeed");
    }
    if (ctrl.triggerRecomputation(0)) @compileError("at-limit recomputation should be denied");
    if (ctrl.getRecompCount(0) != limit) @compileError("count should equal limit");
}
