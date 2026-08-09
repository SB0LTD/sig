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

const testing = @import("std").testing;

test "Eviction_Controller init has zero counts" {
    const ctrl = Eviction_Controller.init();
    try testing.expect(!(ctrl.total_recomputations != 0)); // expected zero total recomputations on init
    try testing.expect(!(ctrl.recomp_counts[0] != 0)); // expected zero count for decl 0
    try testing.expect(!(ctrl.recomp_counts[100] != 0)); // expected zero count for decl 100
}

test "Eviction_Controller triggerRecomputation increments count" {
    var ctrl = Eviction_Controller.init();
    const allowed = ctrl.triggerRecomputation(5);
    try testing.expect(!(!allowed)); // first recomputation should be allowed
    try testing.expect(!(ctrl.getRecompCount(5) != 1)); // expected count 1 after one trigger
    try testing.expect(!(ctrl.total_recomputations != 1)); // expected total 1
}

test "Eviction_Controller respects MAX_RECOMPUTATION_LIMIT" {
    var ctrl = Eviction_Controller.init();
    // Trigger recomputation MAX_RECOMPUTATION_LIMIT times (should all succeed)
    var i: u32 = 0;
    while (i < Compiler_Capacity_Plan.MAX_RECOMPUTATION_LIMIT) : (i += 1) {
        const allowed = ctrl.triggerRecomputation(7);
        try testing.expect(!(!allowed)); // recomputation within limit should be allowed
    }
    // The next attempt should be denied (at limit)
    const denied = ctrl.triggerRecomputation(7);
    try testing.expect(!(denied)); // recomputation beyond limit should be denied
    if (ctrl.getRecompCount(7) != Compiler_Capacity_Plan.MAX_RECOMPUTATION_LIMIT)
        return error.TestUnexpectedResult; // count should equal MAX_RECOMPUTATION_LIMIT
}

test "Eviction_Controller isRecomputationBounded reflects state" {
    var ctrl = Eviction_Controller.init();
    try testing.expect(!(!ctrl.isRecomputationBounded(0))); // fresh decl should be bounded

    // Fill to limit
    var i: u32 = 0;
    while (i < Compiler_Capacity_Plan.MAX_RECOMPUTATION_LIMIT) : (i += 1) {
        _ = ctrl.triggerRecomputation(0);
    }
    try testing.expect(!(ctrl.isRecomputationBounded(0))); // at-limit decl should NOT be bounded
}

test "Eviction_Controller out-of-bounds returns safe defaults" {
    var ctrl = Eviction_Controller.init();
    const oob_id: u32 = @intCast(Compiler_Capacity_Plan.DEPENDENCY_GRAPH_CAPACITY);
    // Out-of-bounds triggerRecomputation returns false
    const allowed = ctrl.triggerRecomputation(oob_id);
    try testing.expect(!(allowed)); // out-of-bounds should return false
    // Out-of-bounds isRecomputationBounded returns false
    try testing.expect(!(ctrl.isRecomputationBounded(oob_id))); // out-of-bounds should not be bounded
    // Out-of-bounds getRecompCount returns 0
    try testing.expect(!(ctrl.getRecompCount(oob_id) != 0)); // out-of-bounds count should be 0
}

test "Eviction_Controller resetCount clears a declaration's count" {
    var ctrl = Eviction_Controller.init();
    _ = ctrl.triggerRecomputation(3);
    _ = ctrl.triggerRecomputation(3);
    try testing.expect(!(ctrl.getRecompCount(3) != 2)); // expected count 2
    ctrl.resetCount(3);
    try testing.expect(!(ctrl.getRecompCount(3) != 0)); // expected count 0 after reset
    // total_recomputations is not decremented (it's a historical counter)
    try testing.expect(!(ctrl.total_recomputations != 2)); // total should remain 2
}

test "Eviction_Controller independent declarations tracked separately" {
    var ctrl = Eviction_Controller.init();
    _ = ctrl.triggerRecomputation(10);
    _ = ctrl.triggerRecomputation(10);
    _ = ctrl.triggerRecomputation(20);
    try testing.expect(!(ctrl.getRecompCount(10) != 2)); // decl 10 should have count 2
    try testing.expect(!(ctrl.getRecompCount(20) != 1)); // decl 20 should have count 1
    try testing.expect(!(ctrl.total_recomputations != 3)); // total should be 3
}

test "Eviction_Controller totalRecomputations accessor" {
    var ctrl = Eviction_Controller.init();
    try testing.expect(!(ctrl.totalRecomputations() != 0)); // expected 0 initially
    _ = ctrl.triggerRecomputation(1);
    _ = ctrl.triggerRecomputation(2);
    try testing.expect(!(ctrl.totalRecomputations() != 2)); // expected 2 after two triggers
}


// Property 24: Recomputation bound
test "recomputation bound - exactly MAX_RECOMPUTATION_LIMIT allowed then denied" {
    var ctrl = Eviction_Controller.init();
    const limit = Compiler_Capacity_Plan.MAX_RECOMPUTATION_LIMIT;
    var i: u32 = 0;
    while (i < limit) : (i += 1) {
        try testing.expect(!(!ctrl.triggerRecomputation(0))); // within-limit recomputation should succeed
    }
    try testing.expect(!(ctrl.triggerRecomputation(0))); // at-limit recomputation should be denied
    try testing.expect(!(ctrl.getRecompCount(0) != limit)); // count should equal limit
}
