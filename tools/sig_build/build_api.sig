/// build_api.sig — Lazy compiler API access for the in-process build runner.
///
/// Module root: project directory. Path: src/build_api.sig.
/// ALL imports are inside functions to prevent transitive analysis at module-wire time.
/// When the build runner compiles, this file is parsed but functions are NOT evaluated.
/// Only when inProcessCompileBackend calls these functions at runtime do the imports trigger.
pub fn getCompilation() type {
    return @import("Compilation.sig");
}

pub fn getPackage() type {
    return @import("Package.sig");
}

pub fn getIntrospect() type {
    return @import("introspect.sig");
}
