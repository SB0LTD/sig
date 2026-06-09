/// build_api.zig — Public API surface for the in-process build runner.
///
/// Re-exports Compilation and Package types needed by the build runner
/// (tools/sig_build/main.sig) to call Compilation.create() + update() directly.
/// This file is the root_src_path of the "compiler" module wired by compileSigBuildRunner.
pub const Compilation = @import("Compilation.zig");
pub const Package = @import("Package.zig");
pub const Config = Compilation.Config;
pub const CreateDiagnostic = Compilation.CreateDiagnostic;
pub const CreateOptions = Compilation.CreateOptions;
pub const Directories = Compilation.Directories;
pub const Path = Compilation.Path;
pub const Cache = @import("std").Build.Cache;
pub const introspect = @import("introspect.zig");

pub const create = Compilation.create;
pub const UpdateError = Compilation.UpdateError;
