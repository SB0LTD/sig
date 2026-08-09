// Zero-Alloc Compiler — Cross-File Dependency Tracking
//
// Layer 2: Pipeline Orchestration
//
// Tracks which declarations depend on which files/symbols for eviction-aware
// recomputation. When a symbol is evicted and later re-referenced, the
// dependency graph identifies which declarations need to be invalidated
// and potentially recomputed.
//
// Zero heap allocations — all state is comptime-sized.

const cap = @import("../core/capacity.sig");
const containers = @import("../core/containers.sig");
const Compiler_Capacity_Plan = cap.Compiler_Capacity_Plan;
const BoundedVec = containers.BoundedVec;

// ============================================================================
// Dependency_Entry
// ============================================================================

/// Describes a dependency relationship: a source declaration depends on
/// a target symbol defined in a specific file.
pub const Dependency_Entry = struct {
    /// Declaration ID that depends on the target.
    source_decl: u32,
    /// Symbol hash that is depended upon.
    target_symbol: u64,
    /// File index where the target symbol is defined.
    target_file: u16,
};

// ============================================================================
// Dependency_Graph
// ============================================================================

/// Fixed-capacity dependency graph for cross-file dependency tracking.
/// Records which declarations depend on which symbols, enabling the eviction
/// controller to determine what needs recomputation when a symbol is evicted.
pub const Dependency_Graph = struct {
    /// All dependency entries stored in a bounded vector.
    entries: BoundedVec(Dependency_Entry, Compiler_Capacity_Plan.DEPENDENCY_GRAPH_CAPACITY),

    /// Initialize an empty dependency graph.
    pub fn init() Dependency_Graph {
        return .{ .entries = .{} };
    }

    /// Add a dependency to the graph.
    /// If the graph is at capacity, the dependency is silently dropped
    /// (the compiler will still function correctly, just with less precise
    /// recomputation tracking — worst case is a full re-parse).
    pub fn addDependency(self: *Dependency_Graph, dep: Dependency_Entry) void {
        self.entries.append(dep) catch {};
    }

    /// Returns the number of dependencies currently tracked.
    pub fn dependencyCount(self: *const Dependency_Graph) usize {
        return self.entries.len();
    }

    /// Find all declarations that depend on a given symbol.
    /// Returns the count of dependents found.
    pub fn findDependents(self: *const Dependency_Graph, target_symbol: u64) usize {
        var count: usize = 0;
        var i: usize = 0;
        while (i < self.entries.len()) : (i += 1) {
            if (self.entries.get(i).target_symbol == target_symbol) count += 1;
        }
        return count;
    }

    /// Find all declarations that depend on symbols from a given file.
    /// Returns the count of dependents found.
    pub fn findDependentsByFile(self: *const Dependency_Graph, file_index: u16) usize {
        var count: usize = 0;
        var i: usize = 0;
        while (i < self.entries.len()) : (i += 1) {
            if (self.entries.get(i).target_file == file_index) count += 1;
        }
        return count;
    }

    /// Check if a specific declaration depends on a specific symbol.
    pub fn hasDependency(self: *const Dependency_Graph, source_decl: u32, target_symbol: u64) bool {
        var i: usize = 0;
        while (i < self.entries.len()) : (i += 1) {
            const entry = self.entries.get(i);
            if (entry.source_decl == source_decl and entry.target_symbol == target_symbol) return true;
        }
        return false;
    }

    /// Clear all dependency entries.
    pub fn clear(self: *Dependency_Graph) void {
        self.entries.clear();
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = @import("std").testing;

test "Dependency_Graph init is empty" {
    const graph = Dependency_Graph.init();
    try testing.expect(!(graph.dependencyCount() != 0)); // expected zero dependencies on init
}

test "Dependency_Graph addDependency increases count" {
    var graph = Dependency_Graph.init();
    graph.addDependency(.{ .source_decl = 1, .target_symbol = 0xABCD, .target_file = 0 });
    try testing.expect(!(graph.dependencyCount() != 1)); // expected 1 dependency after add
    graph.addDependency(.{ .source_decl = 2, .target_symbol = 0x1234, .target_file = 1 });
    try testing.expect(!(graph.dependencyCount() != 2)); // expected 2 dependencies after second add
}

test "Dependency_Graph findDependents counts matching symbol" {
    var graph = Dependency_Graph.init();
    const sym: u64 = 0xDEAD;
    graph.addDependency(.{ .source_decl = 1, .target_symbol = sym, .target_file = 0 });
    graph.addDependency(.{ .source_decl = 2, .target_symbol = sym, .target_file = 0 });
    graph.addDependency(.{ .source_decl = 3, .target_symbol = 0x9999, .target_file = 1 });
    try testing.expect(!(graph.findDependents(sym) != 2)); // expected 2 dependents for symbol 0xDEAD
    try testing.expect(!(graph.findDependents(0x9999) != 1)); // expected 1 dependent for symbol 0x9999
    try testing.expect(!(graph.findDependents(0x0000) != 0)); // expected 0 dependents for unknown symbol
}

test "Dependency_Graph findDependentsByFile counts matching file" {
    var graph = Dependency_Graph.init();
    graph.addDependency(.{ .source_decl = 1, .target_symbol = 100, .target_file = 0 });
    graph.addDependency(.{ .source_decl = 2, .target_symbol = 200, .target_file = 0 });
    graph.addDependency(.{ .source_decl = 3, .target_symbol = 300, .target_file = 1 });
    try testing.expect(!(graph.findDependentsByFile(0) != 2)); // expected 2 deps in file 0
    try testing.expect(!(graph.findDependentsByFile(1) != 1)); // expected 1 dep in file 1
    try testing.expect(!(graph.findDependentsByFile(5) != 0)); // expected 0 deps in file 5
}

test "Dependency_Graph hasDependency finds exact match" {
    var graph = Dependency_Graph.init();
    graph.addDependency(.{ .source_decl = 10, .target_symbol = 500, .target_file = 2 });
    try testing.expect(!(!graph.hasDependency(10, 500))); // should find existing dependency
    try testing.expect(!(graph.hasDependency(10, 501))); // should not find non-existing symbol dep
    try testing.expect(!(graph.hasDependency(11, 500))); // should not find non-existing decl dep
}

test "Dependency_Graph clear removes all entries" {
    var graph = Dependency_Graph.init();
    graph.addDependency(.{ .source_decl = 1, .target_symbol = 10, .target_file = 0 });
    graph.addDependency(.{ .source_decl = 2, .target_symbol = 20, .target_file = 1 });
    try testing.expect(!(graph.dependencyCount() != 2)); // expected 2 before clear
    graph.clear();
    try testing.expect(!(graph.dependencyCount() != 0)); // expected 0 after clear
}

test "Dependency_Entry struct fields accessible" {
    const entry = Dependency_Entry{
        .source_decl = 42,
        .target_symbol = 0xCAFE,
        .target_file = 7,
    };
    try testing.expect(!(entry.source_decl != 42)); // expected source_decl 42
    try testing.expect(!(entry.target_symbol != 0xCAFE)); // expected target_symbol 0xCAFE
    try testing.expect(!(entry.target_file != 7)); // expected target_file 7
}

test "Dependency_Graph multiple deps from same source_decl" {
    var graph = Dependency_Graph.init();
    // Declaration 5 depends on two different symbols
    graph.addDependency(.{ .source_decl = 5, .target_symbol = 100, .target_file = 0 });
    graph.addDependency(.{ .source_decl = 5, .target_symbol = 200, .target_file = 1 });
    try testing.expect(!(graph.dependencyCount() != 2)); // expected 2 deps
    try testing.expect(!(!graph.hasDependency(5, 100))); // should find dep on symbol 100
    try testing.expect(!(!graph.hasDependency(5, 200))); // should find dep on symbol 200
}
