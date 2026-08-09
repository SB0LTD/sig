//! Layer 2 — Sig/Zig Compatibility
//! File extension detection and sig-specific syntax extensions.

const types = @import("../core/types.sig");
const Token = types.Token;

/// File language mode based on extension.
pub const Language_Mode = enum(u8) {
    sig, // .sig files — zig + sig extensions
    zig, // .zig files — standard zig semantics only
};

/// Detect the language mode from a file path.
/// Returns .sig for .sig files, .zig for .zig files.
pub fn detectLanguageMode(path: []const u8) Language_Mode {
    if (path.len >= 4) {
        const ext = path[path.len - 4 ..];
        if (ext[0] == '.' and ext[1] == 's' and ext[2] == 'i' and ext[3] == 'g')
            return .sig;
    }
    if (path.len >= 4) {
        const ext = path[path.len - 4 ..];
        if (ext[0] == '.' and ext[1] == 'z' and ext[2] == 'i' and ext[3] == 'g')
            return .zig;
    }
    // Default to sig
    return .sig;
}

/// Check if a token represents a sig-specific extension keyword
/// that is NOT valid in standard zig mode.
pub fn isSigExtension(tag: Token.Tag) bool {
    return tag == .sig_keyword_extended;
}

/// Validate that a token is acceptable in the given language mode.
/// Returns false if the token is a sig extension used in .zig mode.
pub fn isValidInMode(tag: Token.Tag, mode: Language_Mode) bool {
    if (mode == .zig and isSigExtension(tag)) return false;
    return true;
}

/// File extension constants.
pub const SIG_EXTENSION = ".sig";
pub const ZIG_EXTENSION = ".zig";

/// Check if a path ends with the sig extension.
pub fn isSigFile(path: []const u8) bool {
    return detectLanguageMode(path) == .sig;
}

/// Check if a path ends with the zig extension.
pub fn isZigFile(path: []const u8) bool {
    return detectLanguageMode(path) == .zig;
}

// ============================================================================
// Allocator Detection
// ============================================================================

/// Known allocator-dependent standard library types.
/// If source references any of these, it's flagged as using heap allocation.
const FORBIDDEN_ALLOCATOR_TYPES = [_][]const u8{
    "ArrayList",
    "HashMap",
    "GeneralPurposeAllocator",
    "c_allocator",
    "page_allocator",
    "smp_allocator",
    "ArenaAllocator",
};

/// Check if a source slice contains references to allocator-dependent types.
/// Returns true if any forbidden allocator usage is detected.
pub fn detectAllocatorUsage(source: []const u8) bool {
    for (FORBIDDEN_ALLOCATOR_TYPES) |forbidden| {
        if (containsSubstring(source, forbidden)) return true;
    }
    return false;
}

/// Simple substring search (no heap allocation).
fn containsSubstring(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, j| {
            if (haystack[i + j] != c) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

// ============================================================================
// Mixed Compilation
// ============================================================================

/// Validate that a .zig file can be linked with .sig compiled objects.
/// Cross-linking is permitted as long as the .zig file doesn't use allocator types.
pub fn validateMixedCompilation(source: []const u8, mode: Language_Mode) bool {
    if (mode == .zig) {
        // .zig files that use allocators cannot be part of a zero-alloc compilation
        return !detectAllocatorUsage(source);
    }
    // .sig files never have allocators (enforced by the language)
    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "detectLanguageMode .sig" {
    if (detectLanguageMode("main.sig") != .sig) @compileError("should detect .sig");
}

test "detectLanguageMode .zig" {
    if (detectLanguageMode("main.zig") != .zig) @compileError("should detect .zig");
}

test "detectLanguageMode unknown defaults to sig" {
    if (detectLanguageMode("main.txt") != .sig) @compileError("unknown should default to sig");
}

test "sig extension invalid in zig mode" {
    if (isValidInMode(.sig_keyword_extended, .zig)) @compileError("sig extension should be invalid in zig mode");
}

test "sig extension valid in sig mode" {
    if (!isValidInMode(.sig_keyword_extended, .sig)) @compileError("sig extension should be valid in sig mode");
}

test "normal tokens valid in both modes" {
    if (!isValidInMode(.keyword_const, .zig)) @compileError("const should be valid in zig mode");
    if (!isValidInMode(.keyword_const, .sig)) @compileError("const should be valid in sig mode");
}

test "detectAllocatorUsage finds ArrayList" {
    const src = "var list = std.ArrayList(u8).init(allocator);";
    if (!detectAllocatorUsage(src)) @compileError("should detect ArrayList");
}

test "detectAllocatorUsage clean source" {
    const src = "const x: u32 = 42;";
    if (detectAllocatorUsage(src)) @compileError("should not detect allocator in clean source");
}

test "detectAllocatorUsage finds page_allocator" {
    const src = "const alloc = std.heap.page_allocator;";
    if (!detectAllocatorUsage(src)) @compileError("should detect page_allocator");
}

test "validateMixedCompilation .sig always passes" {
    const src = "var x = std.ArrayList(u8).init(alloc);"; // even with allocator text
    if (!validateMixedCompilation(src, .sig)) @compileError(".sig should always pass");
}

test "validateMixedCompilation .zig with allocator fails" {
    const src = "var list = ArrayList(u8).init(alloc);";
    if (validateMixedCompilation(src, .zig)) @compileError(".zig with allocator should fail");
}

test "validateMixedCompilation .zig without allocator passes" {
    const src = "pub fn add(a: u32, b: u32) u32 { return a + b; }";
    if (!validateMixedCompilation(src, .zig)) @compileError(".zig without allocator should pass");
}

test "containsSubstring basic" {
    if (!containsSubstring("hello world", "world")) @compileError("should find 'world'");
    if (containsSubstring("hello world", "xyz")) @compileError("should not find 'xyz'");
}


// Property 22: Mixed sig/zig linking
test "mixed linking - .sig and .zig without allocators both valid" {
    const sig_src = "pub fn compute() u32 { return 42; }";
    const zig_src = "pub fn helper() u32 { return 1; }";
    if (!validateMixedCompilation(sig_src, .sig)) @compileError(".sig should pass");
    if (!validateMixedCompilation(zig_src, .zig)) @compileError(".zig without alloc should pass");
}

test "mixed linking - .zig with allocator rejected from mixed compilation" {
    const zig_src = "var buf = std.ArrayList(u8).init(gpa.allocator());";
    if (validateMixedCompilation(zig_src, .zig)) @compileError(".zig with ArrayList should be rejected");
}

// Property 23: Allocator usage detection
test "allocator detection - all forbidden types detected" {
    const types_to_check = [_][]const u8{
        "ArrayList", "HashMap", "GeneralPurposeAllocator",
        "c_allocator", "page_allocator", "smp_allocator", "ArenaAllocator",
    };
    for (types_to_check) |t| {
        if (!detectAllocatorUsage(t)) @compileError("should detect forbidden allocator type");
    }
}

test "allocator detection - safe identifiers not flagged" {
    const safe_sources = [_][]const u8{
        "const x = 42;",
        "pub fn main() void {}",
        "var arr: [10]u8 = undefined;",
    };
    for (safe_sources) |src| {
        if (detectAllocatorUsage(src)) @compileError("safe source should not trigger detection");
    }
}
