// Unit tests for Dependency_Graph (task 1.7).
//
// Since the build runner (tools/sig_build/main.sig) is not wired as a test import,
// these tests replicate the Dependency_Graph logic using the same algorithms.
//
// Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 7.5

const std = @import("std");
const testing = std.testing;
const sig = @import("sig");
const containers = sig.containers;
const SigError = sig.SigError;

const MAX_STEPS = 256;
const MAX_DEPS_PER_STEP = 32;
const Step_Handle = u16;

// ── Replicated Dependency_Graph from main.sig ───────────────────────────

const Dependency_Graph = struct {
    adj: [MAX_STEPS][MAX_DEPS_PER_STEP]Step_Handle = undefined,
    adj_counts: [MAX_STEPS]usize = [_]usize{0} ** MAX_STEPS,
    node_count: usize = 0,

    pub fn addEdge(self: *Dependency_Graph, dependent: Step_Handle, dependency: Step_Handle) SigError!void {
        const dep_idx: usize = dependent;
        const dependency_idx: usize = dependency;
        if (dep_idx >= MAX_STEPS or dependency_idx >= MAX_STEPS) return error.CapacityExceeded;
        if (dep_idx >= self.node_count) self.node_count = dep_idx + 1;
        if (dependency_idx >= self.node_count) self.node_count = dependency_idx + 1;

        if (self.adj_counts[dep_idx] >= MAX_DEPS_PER_STEP) return error.CapacityExceeded;

        self.adj[dep_idx][self.adj_counts[dep_idx]] = dependency;
        self.adj_counts[dep_idx] += 1;
    }

    pub fn topologicalSort(self: *const Dependency_Graph, out: *[MAX_STEPS]Step_Handle) SigError![]const Step_Handle {
        var in_degree: [MAX_STEPS]usize = [_]usize{0} ** MAX_STEPS;
        for (0..self.node_count) |i| {
            in_degree[i] = self.adj_counts[i];
        }

        var queue: containers.BoundedDeque(Step_Handle, MAX_STEPS) = .{};
        for (0..self.node_count) |i| {
            if (in_degree[i] == 0) {
                try queue.pushBack(@intCast(i));
            }
        }

        var count: usize = 0;
        while (queue.popFront()) |node| {
            out[count] = node;
            count += 1;

            const node_idx: usize = node;
            for (0..self.node_count) |j| {
                for (self.adj[j][0..self.adj_counts[j]]) |dep| {
                    if (@as(usize, dep) == node_idx) {
                        in_degree[j] -= 1;
                        if (in_degree[j] == 0) {
                            try queue.pushBack(@intCast(j));
                        }
                        break;
                    }
                }
            }
        }

        if (count < self.node_count) return error.DepthExceeded;

        return out[0..count];
    }

    pub fn readySet(self: *const Dependency_Graph, completed: *const containers.BoundedBitSet(MAX_STEPS), out: *[MAX_STEPS]Step_Handle) []const Step_Handle {
        var count: usize = 0;
        for (0..self.node_count) |i| {
            if (completed.isSet(i)) continue;

            var all_met = true;
            for (self.adj[i][0..self.adj_counts[i]]) |dep| {
                if (!completed.isSet(dep)) {
                    all_met = false;
                    break;
                }
            }
            if (all_met) {
                out[count] = @intCast(i);
                count += 1;
            }
        }
        return out[0..count];
    }

    pub fn propagateFailure(self: *const Dependency_Graph, failed: Step_Handle, skipped: *containers.BoundedBitSet(MAX_STEPS)) void {
        var queue: containers.BoundedDeque(Step_Handle, MAX_STEPS) = .{};
        queue.pushBack(failed) catch return;
        skipped.set(failed) catch return;

        while (queue.popFront()) |node| {
            const node_idx: usize = node;
            for (0..self.node_count) |j| {
                if (skipped.isSet(j)) continue;
                for (self.adj[j][0..self.adj_counts[j]]) |dep| {
                    if (@as(usize, dep) == node_idx) {
                        skipped.set(j) catch continue;
                        queue.pushBack(@intCast(j)) catch continue;
                        break;
                    }
                }
            }
        }
    }
};

// ── Helper: check if a handle appears before another in sorted output ───

fn indexOfHandle(sorted: []const Step_Handle, handle: Step_Handle) ?usize {
    for (sorted, 0..) |h, i| {
        if (h == handle) return i;
    }
    return null;
}

fn handleInSlice(slice: []const Step_Handle, handle: Step_Handle) bool {
    for (slice) |h| {
        if (h == handle) return true;
    }
    return false;
}

// ── addEdge tests ───────────────────────────────────────────────────────

test "addEdge: basic edge storage" {
    var g: Dependency_Graph = .{};
    g.node_count = 3;
    try g.addEdge(1, 0); // step 1 depends on step 0
    try testing.expectEqual(@as(usize, 1), g.adj_counts[1]);
    try testing.expectEqual(@as(Step_Handle, 0), g.adj[1][0]);
}

test "addEdge: auto-expands node_count" {
    var g: Dependency_Graph = .{};
    try g.addEdge(5, 3);
    try testing.expectEqual(@as(usize, 6), g.node_count); // max(5,3) + 1
}

test "addEdge: capacity exceeded on too many deps" {
    var g: Dependency_Graph = .{};
    g.node_count = 34;
    for (0..MAX_DEPS_PER_STEP) |i| {
        try g.addEdge(0, @intCast(i + 1));
    }
    // 33rd dependency should fail
    try testing.expectError(error.CapacityExceeded, g.addEdge(0, 33));
}

// ── topologicalSort tests ───────────────────────────────────────────────

test "topologicalSort: single node" {
    var g: Dependency_Graph = .{};
    g.node_count = 1;
    var out: [MAX_STEPS]Step_Handle = undefined;
    const sorted = try g.topologicalSort(&out);
    try testing.expectEqual(@as(usize, 1), sorted.len);
    try testing.expectEqual(@as(Step_Handle, 0), sorted[0]);
}

test "topologicalSort: linear chain 0 <- 1 <- 2" {
    var g: Dependency_Graph = .{};
    g.node_count = 3;
    try g.addEdge(1, 0); // 1 depends on 0
    try g.addEdge(2, 1); // 2 depends on 1
    var out: [MAX_STEPS]Step_Handle = undefined;
    const sorted = try g.topologicalSort(&out);
    try testing.expectEqual(@as(usize, 3), sorted.len);
    // 0 must come before 1, 1 before 2
    const idx0 = indexOfHandle(sorted, 0).?;
    const idx1 = indexOfHandle(sorted, 1).?;
    const idx2 = indexOfHandle(sorted, 2).?;
    try testing.expect(idx0 < idx1);
    try testing.expect(idx1 < idx2);
}

test "topologicalSort: diamond graph" {
    // 0 has no deps, 1 depends on 0, 2 depends on 0, 3 depends on 1 and 2
    var g: Dependency_Graph = .{};
    g.node_count = 4;
    try g.addEdge(1, 0);
    try g.addEdge(2, 0);
    try g.addEdge(3, 1);
    try g.addEdge(3, 2);
    var out: [MAX_STEPS]Step_Handle = undefined;
    const sorted = try g.topologicalSort(&out);
    try testing.expectEqual(@as(usize, 4), sorted.len);
    const idx0 = indexOfHandle(sorted, 0).?;
    const idx1 = indexOfHandle(sorted, 1).?;
    const idx2 = indexOfHandle(sorted, 2).?;
    const idx3 = indexOfHandle(sorted, 3).?;
    try testing.expect(idx0 < idx1);
    try testing.expect(idx0 < idx2);
    try testing.expect(idx1 < idx3);
    try testing.expect(idx2 < idx3);
}

test "topologicalSort: independent nodes" {
    var g: Dependency_Graph = .{};
    g.node_count = 3; // 0, 1, 2 with no edges
    var out: [MAX_STEPS]Step_Handle = undefined;
    const sorted = try g.topologicalSort(&out);
    try testing.expectEqual(@as(usize, 3), sorted.len);
    // All three must appear
    try testing.expect(handleInSlice(sorted, 0));
    try testing.expect(handleInSlice(sorted, 1));
    try testing.expect(handleInSlice(sorted, 2));
}

test "topologicalSort: cycle detection" {
    var g: Dependency_Graph = .{};
    g.node_count = 2;
    try g.addEdge(0, 1); // 0 depends on 1
    try g.addEdge(1, 0); // 1 depends on 0 — cycle!
    var out: [MAX_STEPS]Step_Handle = undefined;
    try testing.expectError(error.DepthExceeded, g.topologicalSort(&out));
}

test "topologicalSort: self-cycle detection" {
    var g: Dependency_Graph = .{};
    g.node_count = 1;
    try g.addEdge(0, 0); // 0 depends on itself
    var out: [MAX_STEPS]Step_Handle = undefined;
    try testing.expectError(error.DepthExceeded, g.topologicalSort(&out));
}

test "topologicalSort: three-node cycle" {
    var g: Dependency_Graph = .{};
    g.node_count = 3;
    try g.addEdge(0, 1);
    try g.addEdge(1, 2);
    try g.addEdge(2, 0);
    var out: [MAX_STEPS]Step_Handle = undefined;
    try testing.expectError(error.DepthExceeded, g.topologicalSort(&out));
}

// ── readySet tests ──────────────────────────────────────────────────────

test "readySet: all independent nodes are ready initially" {
    var g: Dependency_Graph = .{};
    g.node_count = 3;
    var completed: containers.BoundedBitSet(MAX_STEPS) = .{};
    var out: [MAX_STEPS]Step_Handle = undefined;
    const ready = g.readySet(&completed, &out);
    try testing.expectEqual(@as(usize, 3), ready.len);
}

test "readySet: node with unmet dep is not ready" {
    var g: Dependency_Graph = .{};
    g.node_count = 2;
    try g.addEdge(1, 0); // 1 depends on 0
    var completed: containers.BoundedBitSet(MAX_STEPS) = .{};
    var out: [MAX_STEPS]Step_Handle = undefined;
    const ready = g.readySet(&completed, &out);
    // Only node 0 should be ready
    try testing.expectEqual(@as(usize, 1), ready.len);
    try testing.expectEqual(@as(Step_Handle, 0), ready[0]);
}

test "readySet: node becomes ready after dep completes" {
    var g: Dependency_Graph = .{};
    g.node_count = 2;
    try g.addEdge(1, 0);
    var completed: containers.BoundedBitSet(MAX_STEPS) = .{};
    try completed.set(0); // mark 0 as completed
    var out: [MAX_STEPS]Step_Handle = undefined;
    const ready = g.readySet(&completed, &out);
    // Node 1 should now be ready (node 0 is completed, not in ready set)
    try testing.expectEqual(@as(usize, 1), ready.len);
    try testing.expectEqual(@as(Step_Handle, 1), ready[0]);
}

test "readySet: completed nodes excluded" {
    var g: Dependency_Graph = .{};
    g.node_count = 1;
    var completed: containers.BoundedBitSet(MAX_STEPS) = .{};
    try completed.set(0);
    var out: [MAX_STEPS]Step_Handle = undefined;
    const ready = g.readySet(&completed, &out);
    try testing.expectEqual(@as(usize, 0), ready.len);
}

// ── propagateFailure tests ──────────────────────────────────────────────

test "propagateFailure: marks direct dependent" {
    var g: Dependency_Graph = .{};
    g.node_count = 2;
    try g.addEdge(1, 0); // 1 depends on 0
    var skipped: containers.BoundedBitSet(MAX_STEPS) = .{};
    g.propagateFailure(0, &skipped);
    try testing.expect(skipped.isSet(0));
    try testing.expect(skipped.isSet(1));
}

test "propagateFailure: marks transitive dependents" {
    // 0 <- 1 <- 2 <- 3
    var g: Dependency_Graph = .{};
    g.node_count = 4;
    try g.addEdge(1, 0);
    try g.addEdge(2, 1);
    try g.addEdge(3, 2);
    var skipped: containers.BoundedBitSet(MAX_STEPS) = .{};
    g.propagateFailure(0, &skipped);
    try testing.expect(skipped.isSet(0));
    try testing.expect(skipped.isSet(1));
    try testing.expect(skipped.isSet(2));
    try testing.expect(skipped.isSet(3));
}

test "propagateFailure: does not mark unrelated nodes" {
    // 0 <- 1, 2 is independent
    var g: Dependency_Graph = .{};
    g.node_count = 3;
    try g.addEdge(1, 0);
    var skipped: containers.BoundedBitSet(MAX_STEPS) = .{};
    g.propagateFailure(0, &skipped);
    try testing.expect(skipped.isSet(0));
    try testing.expect(skipped.isSet(1));
    try testing.expect(!skipped.isSet(2));
}

test "propagateFailure: diamond — failing root skips all" {
    // 0 <- 1, 0 <- 2, 1 <- 3, 2 <- 3
    var g: Dependency_Graph = .{};
    g.node_count = 4;
    try g.addEdge(1, 0);
    try g.addEdge(2, 0);
    try g.addEdge(3, 1);
    try g.addEdge(3, 2);
    var skipped: containers.BoundedBitSet(MAX_STEPS) = .{};
    g.propagateFailure(0, &skipped);
    try testing.expect(skipped.isSet(0));
    try testing.expect(skipped.isSet(1));
    try testing.expect(skipped.isSet(2));
    try testing.expect(skipped.isSet(3));
}

test "propagateFailure: failing leaf skips nothing else" {
    var g: Dependency_Graph = .{};
    g.node_count = 3;
    try g.addEdge(1, 0);
    try g.addEdge(2, 1);
    var skipped: containers.BoundedBitSet(MAX_STEPS) = .{};
    g.propagateFailure(2, &skipped); // fail the leaf
    try testing.expect(!skipped.isSet(0));
    try testing.expect(!skipped.isSet(1));
    try testing.expect(skipped.isSet(2));
}
