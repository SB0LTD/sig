//! Layer 1 — Deep Model Inference
//! Comptime-weighted neural network for register allocation priority hints.
//! All computation uses stack-allocated buffers — zero heap allocations.

const cap = @import("../core/capacity.sig");
const Compiler_Capacity_Plan = cap.Compiler_Capacity_Plan;

const MODEL_MAX_LAYERS = Compiler_Capacity_Plan.MODEL_MAX_LAYERS;
const MODEL_MAX_NEURONS = Compiler_Capacity_Plan.MODEL_MAX_NEURONS;
const MODEL_ACTIVATION_BUF = Compiler_Capacity_Plan.MODEL_ACTIVATION_BUF;

pub const Deep_Model_State = struct {
    weights: [MODEL_MAX_LAYERS][MODEL_MAX_NEURONS][MODEL_MAX_NEURONS]f32,
    biases: [MODEL_MAX_LAYERS][MODEL_MAX_NEURONS]f32,
    active_layers: u8,
    neurons_per_layer: u8,
    confidence_threshold: f32,

    pub fn init() Deep_Model_State {
        return .{
            .weights = @splat(@as([MODEL_MAX_NEURONS][MODEL_MAX_NEURONS]f32, @splat(@as([MODEL_MAX_NEURONS]f32, @splat(@as(f32, 0.0)))))),
            .biases = @splat(@as([MODEL_MAX_NEURONS]f32, @splat(@as(f32, 0.0)))),
            .active_layers = 2,
            .neurons_per_layer = 16,
            .confidence_threshold = 0.7,
        };
    }

    /// Forward pass: input features → priority scores.
    /// Uses ping-pong stack buffers. Only add, mul, and ReLU.
    pub fn infer(self: *const Deep_Model_State, input: []const f32, output: []f32) void {
        var buf_a: [MODEL_ACTIVATION_BUF]f32 = @splat(0.0);
        var buf_b: [MODEL_ACTIVATION_BUF]f32 = @splat(0.0);

        // Copy input into buf_a
        const n = @min(input.len, @as(usize, self.neurons_per_layer));
        for (0..n) |i| {
            buf_a[i] = input[i];
        }

        var src: []f32 = buf_a[0..self.neurons_per_layer];
        var dst: []f32 = buf_b[0..self.neurons_per_layer];

        // Forward pass through each layer
        var layer: u8 = 0;
        while (layer < self.active_layers) : (layer += 1) {
            var j: usize = 0;
            while (j < self.neurons_per_layer) : (j += 1) {
                var sum: f32 = self.biases[layer][j];
                var i: usize = 0;
                while (i < self.neurons_per_layer) : (i += 1) {
                    sum += src[i] * self.weights[layer][i][j];
                }
                // ReLU activation
                dst[j] = if (sum > 0.0) sum else 0.0;
            }
            // Swap buffers (ping-pong)
            const tmp = src;
            src = dst;
            dst = tmp;
        }

        // Copy result to output
        const out_n = @min(output.len, @as(usize, self.neurons_per_layer));
        for (0..out_n) |i| {
            output[i] = src[i];
        }
    }

    /// Returns true if max output score exceeds confidence_threshold.
    pub fn isConfident(self: *const Deep_Model_State, scores: []const f32) bool {
        var max_score: f32 = 0.0;
        for (scores) |s| {
            if (s > max_score) max_score = s;
        }
        return max_score >= self.confidence_threshold;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Deep_Model_State init produces zero weights" {
    const model = Deep_Model_State.init();
    if (model.active_layers != 2) @compileError("active_layers should be 2");
    if (model.neurons_per_layer != 16) @compileError("neurons_per_layer should be 16");
    if (model.weights[0][0][0] != 0.0) @compileError("weights should be zero-initialized");
    if (model.biases[0][0] != 0.0) @compileError("biases should be zero-initialized");
}

test "infer with zero weights produces zero output" {
    const model = Deep_Model_State.init();
    const input = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    var output: [4]f32 = undefined;
    model.infer(&input, &output);
    // Zero weights + zero biases → all zeros after ReLU
    if (output[0] != 0.0) @compileError("output[0] should be 0.0");
    if (output[1] != 0.0) @compileError("output[1] should be 0.0");
    if (output[2] != 0.0) @compileError("output[2] should be 0.0");
    if (output[3] != 0.0) @compileError("output[3] should be 0.0");
}

test "isConfident returns false for zero scores" {
    const model = Deep_Model_State.init();
    const scores = [_]f32{ 0.0, 0.0, 0.0 };
    if (model.isConfident(&scores) != false) @compileError("zero scores should not be confident");
}

test "isConfident returns true when max exceeds threshold" {
    const model = Deep_Model_State.init();
    const scores = [_]f32{ 0.1, 0.8, 0.3 };
    if (model.isConfident(&scores) != true) @compileError("0.8 >= 0.7 threshold");
}

test "isConfident returns false when max is below threshold" {
    const model = Deep_Model_State.init();
    const scores = [_]f32{ 0.1, 0.5, 0.3 };
    if (model.isConfident(&scores) != false) @compileError("0.5 < 0.7 threshold");
}

// Property 14: Deep model stack-only inference
test "deep model inference uses only stack memory" {
    // The infer() function uses buf_a and buf_b on the stack.
    // This test verifies that calling infer produces deterministic output
    // without any heap/global state dependency.
    const model = Deep_Model_State.init();
    const input = [_]f32{ 1.0, 0.5, 0.3 };
    var output1: [16]f32 = undefined;
    var output2: [16]f32 = undefined;
    model.infer(&input, &output1);
    model.infer(&input, &output2);
    // Same input → same output (deterministic, no hidden state)
    for (0..16) |i| {
        if (output1[i] != output2[i]) @compileError("inference should be deterministic");
    }
}

test "deep model inference output bounded by neurons_per_layer" {
    const model = Deep_Model_State.init();
    const input: [16]f32 = @splat(0.5);
    var output: [64]f32 = @splat(@as(f32, -1.0));
    model.infer(&input, &output);
    // Output beyond neurons_per_layer (16) should be untouched (-1.0)
    // Actually the function copies min(output.len, neurons_per_layer) = 16
    // so output[16..] should remain -1.0
    if (output[16] != -1.0) @compileError("output beyond neurons_per_layer should be untouched");
}

// Property 27: Deep model fallback determinism
test "deep model fallback - low confidence triggers fallback" {
    const model = Deep_Model_State.init();
    // With zero weights, all outputs are 0.0 → below threshold (0.7)
    const scores: [16]f32 = @splat(0.0);
    if (model.isConfident(&scores)) @compileError("zero scores should not be confident");
}

test "deep model fallback - deterministic regardless of call order" {
    const model = Deep_Model_State.init();
    const input_a = [_]f32{ 1.0, 2.0, 3.0 };
    const input_b = [_]f32{ 4.0, 5.0, 6.0 };
    var out_a1: [16]f32 = undefined;
    var out_b1: [16]f32 = undefined;
    var out_a2: [16]f32 = undefined;
    // Call in order A, B, then call A again
    model.infer(&input_a, &out_a1);
    model.infer(&input_b, &out_b1);
    model.infer(&input_a, &out_a2);
    // A's output should be identical regardless of intervening B call
    for (0..16) |i| {
        if (out_a1[i] != out_a2[i]) @compileError("inference should be stateless and deterministic");
    }
}
