/// build_api.zig — Public API surface for the in-process build runner.
///
/// Re-exports Compilation and Package types needed by the build runner
/// (tools/sig_build/main.sig) to call Compilation.create() + update() directly.
/// This file is the root_src_path of the "compiler" module wired by compileSigBuildRunner.
///
/// IMPORTANT: All imports are lazy (inside functions) to avoid triggering
/// transitive analysis during the build runner compilation phase.
/// No file-scope imports of compiler internals or std.
pub fn getCompilation() type {
    return @import("Compilation.zig");
}

pub fn getPackage() type {
    return @import("Package.zig");
}

pub fn getIntrospect() type {
    return @import("introspect.zig");
}

pub fn getCache() type {
    return @import("std").Build.Cache;
}
