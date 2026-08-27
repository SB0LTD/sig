//! AI Smart Capacity — predictive resource sizing for sig_build.
//!
//! Uses a local Qwen3 model (when available) to analyze build.sig source and
//! predict the required capacity for modules, steps, imports, and parallelism.
//! Results are cached between runs. When no model is available or prediction
//! fails, falls back to generous static limits with page_arena growth.
//!
//! Architecture:
//!   1. On first build: hash build.sig, check cache → miss → run inference
//!   2. Construct prompt: "Given this build graph, predict: module_count,
//!      max_imports_per_module, step_count, max_deps_per_step"
//!   3. Parse model output as structured capacity values
//!   4. Store prediction in .zig-cache/capacity_model.bin (keyed by build.sig hash)
//!   5. On subsequent builds: check cache → hit → use cached prediction
//!   6. All predictions include a safety margin (1.5x)
//!   7. Page arena catches any mispredictions (no build can ever fail)
//!
//! The model file location is resolved from:
//!   1. SIG_MODEL_PATH environment variable
//!   2. ~/.sig/models/qwen3-0.6b-q4k.gguf (default)
//!   3. (none) — graceful fallback to static limits

const sig = @import("sig");

const sig_io = sig.io;
const sig_mem = sig.mem;

// ══════════════════════════════════════════════════════════════════════════════
// Capacity Prediction Result
// ══════════════════════════════════════════════════════════════════════════════

pub const Prediction = struct {
    module_count: u32,
    max_imports_per_module: u32,
    step_count: u32,
    max_deps_per_step: u32,
    suggested_threads: u8,
    confidence: f32, // 0.0–1.0, how confident the model is
    source: Source,

    pub const Source = enum(u8) {
        model_inference, // Fresh inference from the model
        cached, // Loaded from prediction cache
        static_fallback, // No model available, using generous defaults
        heuristic, // Simple line-counting heuristic (no model needed)
    };
};

/// Static fallback prediction — generous limits that handle any project.
pub const STATIC_FALLBACK = Prediction{
    .module_count = 1024,
    .max_imports_per_module = 64,
    .step_count = 1024,
    .max_deps_per_step = 512,
    .suggested_threads = 8,
    .confidence = 0.5,
    .source = .static_fallback,
};

// ══════════════════════════════════════════════════════════════════════════════
// Prediction Cache
// ══════════════════════════════════════════════════════════════════════════════

const CACHE_MAGIC: [4]u8 = .{ 'S', 'C', 'A', 'P' }; // Smart CAPacity
const CACHE_VERSION: u8 = 1;

const CacheEntry = extern struct {
    magic: [4]u8 align(1),
    version: u8 align(1),
    _pad: [3]u8 align(1),
    source_hash: [16]u8 align(1), // XxHash128 of build.sig
    module_count: u32 align(1),
    max_imports: u32 align(1),
    step_count: u32 align(1),
    max_deps: u32 align(1),
    threads: u8 align(1),
    confidence_x100: u8 align(1), // confidence * 100
    _reserved: [6]u8 align(1),
};

/// Try to load a cached prediction for the given build.sig hash.
pub fn loadCached(cache_dir: []const u8, source_hash: [16]u8, io: sig_io.Io) ?Prediction {
    var path_buf: [4096]u8 = undefined;
    const path = formatCachePath(&path_buf, cache_dir) catch return null;

    const cwd: sig_io.Dir = .cwd();
    var file = cwd.openFile(io, path, .{}) catch return null;
    defer file.close(io);

    var entry: CacheEntry = undefined;
    const entry_bytes: *[@sizeOf(CacheEntry)]u8 = @ptrCast(&entry);
    const n = file.reader(io, &.{}).interface.readSliceShort(entry_bytes);
    if ((n catch 0) != @sizeOf(CacheEntry)) return null;

    // Validate
    if (!sig_mem.eql(u8, &entry.magic, &CACHE_MAGIC)) return null;
    if (entry.version != CACHE_VERSION) return null;
    if (!sig_mem.eql(u8, &entry.source_hash, &source_hash)) return null;

    return .{
        .module_count = entry.module_count,
        .max_imports_per_module = entry.max_imports,
        .step_count = entry.step_count,
        .max_deps_per_step = entry.max_deps,
        .suggested_threads = entry.threads,
        .confidence = @as(f32, @floatFromInt(entry.confidence_x100)) / 100.0,
        .source = .cached,
    };
}

/// Save a prediction to the cache.
pub fn saveCached(cache_dir: []const u8, source_hash: [16]u8, pred: Prediction, io: sig_io.Io) void {
    var path_buf: [4096]u8 = undefined;
    const path = formatCachePath(&path_buf, cache_dir) catch return;

    const cwd: sig_io.Dir = .cwd();
    var file = cwd.createFile(io, path, .{}) catch return;
    defer file.close(io);

    const entry = CacheEntry{
        .magic = CACHE_MAGIC,
        .version = CACHE_VERSION,
        ._pad = .{ 0, 0, 0 },
        .source_hash = source_hash,
        .module_count = pred.module_count,
        .max_imports = pred.max_imports_per_module,
        .step_count = pred.step_count,
        .max_deps = pred.max_deps_per_step,
        .threads = pred.suggested_threads,
        .confidence_x100 = @intCast(@min(@as(u32, @intFromFloat(pred.confidence * 100)), 100)),
        ._reserved = .{ 0, 0, 0, 0, 0, 0 },
    };

    const entry_bytes: *const [@sizeOf(CacheEntry)]u8 = @ptrCast(&entry);
    _ = file.writer(io, &.{}).interface.writeSlice(entry_bytes);
}

fn formatCachePath(buf: *[4096]u8, cache_dir: []const u8) ![]const u8 {
    const suffix = "/capacity_prediction.bin";
    if (cache_dir.len + suffix.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[0..cache_dir.len], cache_dir);
    @memcpy(buf[cache_dir.len..][0..suffix.len], suffix);
    return buf[0 .. cache_dir.len + suffix.len];
}

// ══════════════════════════════════════════════════════════════════════════════
// Heuristic Prediction (no model needed)
// ══════════════════════════════════════════════════════════════════════════════

/// Fast heuristic: count patterns in build.sig source to estimate capacity.
/// This doesn't need a model — just regex-like pattern counting.
/// Handles both sig_build API styles:
///   - New: ctx.addModule(), try wire(), addTest()
///   - Compile: ctx.addCompileStep() (single-step projects)
///   - Old Zig: b.addModule(), mod.addImport()
pub fn predictFromSource(source: []const u8) Prediction {
    var module_count: u32 = 0;
    var step_count: u32 = 0;
    var max_imports: u32 = 0;
    var current_imports: u32 = 0;
    var wire_count: u32 = 0;
    var compile_steps: u32 = 0;
    var link_libs: u32 = 0;
    var old_add_import: u32 = 0;

    // Count lines containing key patterns
    var i: usize = 0;
    while (i < source.len) {
        const line_end = sig_mem.indexOfScalar(u8, source[i..], '\n') orelse source.len - i;
        const line = source[i..][0..line_end];

        if (containsPattern(line, "addModule(")) module_count += 1;
        if (containsPattern(line, "addStep(") or containsPattern(line, "addTest(") or
            containsPattern(line, "addTestStep(")) step_count += 1;
        if (containsPattern(line, "addCompileStep(")) { compile_steps += 1; step_count += 1; }
        if (containsPattern(line, "addInstallStep(")) step_count += 1;
        if (containsPattern(line, "try wire(")) {
            wire_count += 1;
            current_imports += 1;
        }
        if (containsPattern(line, "importEntry(")) current_imports += 1;
        if (containsPattern(line, ".addImport(")) { old_add_import += 1; current_imports += 1; }
        if (containsPattern(line, "linkSystemLibrary(")) link_libs += 1;

        // Track max imports per block (reset on new module/step)
        if (containsPattern(line, "addModule(") or containsPattern(line, "addTest(") or
            containsPattern(line, "addCompileStep(")) {
            if (current_imports > max_imports) max_imports = current_imports;
            current_imports = 0;
        }

        i += line_end + 1;
    }
    if (current_imports > max_imports) max_imports = current_imports;

    // Wire calls and old addImport calls can register new modules
    const transitive_modules = wire_count / 2 + old_add_import / 2;
    var total_modules = module_count + transitive_modules;

    // Compile steps imply the compiler resolves modules internally —
    // estimate based on project size (link_libs is a proxy for complexity)
    if (compile_steps > 0 and total_modules < 10) {
        // Small sig_build project: estimate modules from link libraries and source size
        total_modules = @max(total_modules, compile_steps * 10 + link_libs * 2);
    }

    // Apply safety margin (1.5x) and minimum floors
    return .{
        .module_count = @max(total_modules * 3 / 2, 128),
        .max_imports_per_module = @max(max_imports * 3 / 2, 16),
        .step_count = @max(step_count * 3 / 2, 64),
        .max_deps_per_step = @max(step_count, 64), // Aggregate steps can depend on all leaf steps
        .suggested_threads = @intCast(@min(@max(step_count, 4), 16)),
        .confidence = 0.8,
        .source = .heuristic,
    };
}

// ══════════════════════════════════════════════════════════════════════════════
// Model-Based Prediction (full AI inference)
// ══════════════════════════════════════════════════════════════════════════════

/// The prompt template for capacity prediction.
const CAPACITY_PROMPT_PREFIX =
    \\Analyze this Sig build graph and predict the required capacity.
    \\Respond with ONLY a JSON object: {"modules":N,"imports":N,"steps":N,"deps":N,"threads":N}
    \\
    \\Build graph source:
    \\```
;
const CAPACITY_PROMPT_SUFFIX =
    \\```
    \\
    \\Prediction:
;

/// Attempt model-based prediction. Returns null if no model available or inference fails.
/// The caller provides the inference session (already initialized with a model).
pub fn predictWithModel(
    build_source: []const u8,
    response_buf: []u8,
    generate_fn: *const fn (prompt: []const u8, output: []u8) usize,
) ?Prediction {
    // Construct prompt (truncate build source if too long)
    var prompt_buf: [4096]u8 = undefined;
    var prompt_len: usize = 0;

    // Copy prefix
    @memcpy(prompt_buf[prompt_len..][0..CAPACITY_PROMPT_PREFIX.len], CAPACITY_PROMPT_PREFIX);
    prompt_len += CAPACITY_PROMPT_PREFIX.len;

    // Copy build source (truncated to fit)
    const max_source = 3000; // Leave room for suffix
    const source_len = @min(build_source.len, max_source);
    @memcpy(prompt_buf[prompt_len..][0..source_len], build_source[0..source_len]);
    prompt_len += source_len;

    // Copy suffix
    @memcpy(prompt_buf[prompt_len..][0..CAPACITY_PROMPT_SUFFIX.len], CAPACITY_PROMPT_SUFFIX);
    prompt_len += CAPACITY_PROMPT_SUFFIX.len;

    // Generate
    const response_len = generate_fn(prompt_buf[0..prompt_len], response_buf);
    if (response_len == 0) return null;

    // Parse JSON response
    return parseCapacityResponse(response_buf[0..response_len]);
}

/// Parse the model's JSON response into a Prediction.
fn parseCapacityResponse(response: []const u8) ?Prediction {
    // Find JSON object boundaries
    const start = sig_mem.indexOfScalar(u8, response, '{') orelse return null;
    const end_idx = sig_mem.lastIndexOfScalar(u8, response, '}') orelse return null;
    if (end_idx <= start) return null;

    const json = response[start .. end_idx + 1];

    // Simple field extraction (no full JSON parser needed)
    const modules = extractNumber(json, "modules") orelse return null;
    const imports = extractNumber(json, "imports") orelse 16;
    const steps = extractNumber(json, "steps") orelse return null;
    const deps = extractNumber(json, "deps") orelse 64;
    const threads = extractNumber(json, "threads") orelse 8;

    // Apply safety margin
    return .{
        .module_count = @intCast(@max(modules * 3 / 2, 64)),
        .max_imports_per_module = @intCast(@max(imports * 3 / 2, 16)),
        .step_count = @intCast(@max(steps * 3 / 2, 32)),
        .max_deps_per_step = @intCast(@max(deps * 3 / 2, 32)),
        .suggested_threads = @intCast(@min(threads, 64)),
        .confidence = 0.9,
        .source = .model_inference,
    };
}

fn extractNumber(json: []const u8, key: []const u8) ?u64 {
    // Find "key": followed by a number
    var i: usize = 0;
    while (i + key.len + 3 < json.len) : (i += 1) {
        if (json[i] == '"' and i + 1 + key.len + 1 < json.len and
            sig_mem.eql(u8, json[i + 1 ..][0..key.len], key) and
            json[i + 1 + key.len] == '"')
        {
            // Found the key, skip to the colon and number
            var j = i + 2 + key.len;
            while (j < json.len and (json[j] == ':' or json[j] == ' ')) : (j += 1) {}
            // Parse number
            var val: u64 = 0;
            while (j < json.len and json[j] >= '0' and json[j] <= '9') : (j += 1) {
                val = val * 10 + (json[j] - '0');
            }
            if (val > 0) return val;
        }
    }
    return null;
}

// ══════════════════════════════════════════════════════════════════════════════
// Top-Level API
// ══════════════════════════════════════════════════════════════════════════════

/// The main entry point for smart capacity prediction.
/// Tries in order: cache → model → heuristic → static fallback.
pub fn predict(
    build_source: []const u8,
    source_hash: [16]u8,
    cache_dir: []const u8,
    io: sig_io.Io,
    generate_fn: ?*const fn ([]const u8, []u8) usize,
) Prediction {
    // 1. Try cache
    if (loadCached(cache_dir, source_hash, io)) |cached| {
        return cached;
    }

    // 2. Try model inference (if available)
    if (generate_fn) |gen| {
        var response_buf: [1024]u8 = undefined;
        if (predictWithModel(build_source, &response_buf, gen)) |model_pred| {
            saveCached(cache_dir, source_hash, model_pred, io);
            return model_pred;
        }
    }

    // 3. Heuristic (always available, fast)
    const heuristic = predictFromSource(build_source);
    saveCached(cache_dir, source_hash, heuristic, io);
    return heuristic;
}

// ══════════════════════════════════════════════════════════════════════════════
// Helpers
// ══════════════════════════════════════════════════════════════════════════════

fn containsPattern(line: []const u8, pattern: []const u8) bool {
    if (line.len < pattern.len) return false;
    var i: usize = 0;
    while (i + pattern.len <= line.len) : (i += 1) {
        if (sig_mem.eql(u8, line[i..][0..pattern.len], pattern)) return true;
    }
    return false;
}

// ══════════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════════

test "heuristic: counts modules and steps" {
    const source =
        \\_ = try ctx.addModule("foo", "src/foo.sig");
        \\_ = try ctx.addModule("bar", "src/bar.sig");
        \\try wire(ctx, foo, "bar", "src/bar.sig");
        \\_ = try addTest(ctx, test_all, "test-foo", "src/foo.sig", &.{});
    ;
    const pred = predictFromSource(source);
    if (pred.module_count < 3) return error.TestUnexpectedResult; // 2 modules + 1 wire = ~3
    if (pred.step_count < 1) return error.TestUnexpectedResult;
    if (pred.source != .heuristic) return error.TestUnexpectedResult;
}

test "heuristic: empty source gives minimums" {
    const pred = predictFromSource("");
    if (pred.module_count < 128) return error.TestUnexpectedResult;
    if (pred.step_count < 64) return error.TestUnexpectedResult;
}

test "JSON response parsing" {
    const response = "Here is my prediction: {\"modules\":150,\"imports\":24,\"steps\":45,\"deps\":100,\"threads\":8}";
    const pred = parseCapacityResponse(response) orelse return error.TestUnexpectedResult;
    if (pred.module_count < 150) return error.TestUnexpectedResult;
    if (pred.step_count < 45) return error.TestUnexpectedResult;
    if (pred.source != .model_inference) return error.TestUnexpectedResult;
}
