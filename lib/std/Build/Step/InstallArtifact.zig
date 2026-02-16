const InstallArtifact = @This();

const std = @import("std");
const Step = std.Build.Step;
const InstallDir = std.Build.InstallDir;
const LazyPath = std.Build.LazyPath;

step: Step,

dest_dir: ?InstallDir,
dest_sub_path: []const u8,
emitted_bin: ?LazyPath,

implib_dir: ?InstallDir,
emitted_implib: ?LazyPath,

pdb_dir: ?InstallDir,
emitted_pdb: ?LazyPath,

// hack for stage2_x86_64 + coff
compiler_rt_dyn_lib_dir: ?InstallDir,
emitted_compiler_rt_dyn_lib: ?LazyPath,

h_dir: ?InstallDir,
emitted_h: ?LazyPath,

dylib_symlinks: ?DylibSymlinkInfo,

artifact: *Step.Compile,

const DylibSymlinkInfo = struct {
    major_only_filename: []const u8,
    name_only_filename: []const u8,
};

pub const base_tag: Step.Tag = .install_artifact;

pub const Options = struct {
    /// Which installation directory to put the main output file into.
    dest_dir: Dir = .default,
    pdb_dir: Dir = .default,
    compiler_rt_dyn_lib_dir: Dir = .default,
    h_dir: Dir = .default,
    implib_dir: Dir = .default,

    /// Whether to install symlinks along with dynamic libraries.
    dylib_symlinks: ?bool = null,
    /// If non-null, adds additional path components relative to bin dir, and
    /// overrides the basename of the Compile step for installation purposes.
    dest_sub_path: ?[]const u8 = null,

    pub const Dir = union(enum) {
        disabled,
        default,
        override: InstallDir,
    };
};

pub fn create(owner: *std.Build, artifact: *Step.Compile, options: Options) *InstallArtifact {
    const install_artifact = owner.allocator.create(InstallArtifact) catch @panic("OOM");
    const dest_dir: ?InstallDir = switch (options.dest_dir) {
        .disabled => null,
        .default => switch (artifact.kind) {
            .obj, .test_obj => @panic("object files have no standard installation procedure"),
            .exe, .@"test" => .bin,
            .lib => if (artifact.isDll()) .bin else .lib,
        },
        .override => |o| o,
    };
    install_artifact.* = .{
        .step = Step.init(.{
            .tag = base_tag,
            .name = owner.fmt("install {s}", .{artifact.name}),
            .owner = owner,
        }),
        .dest_dir = dest_dir,
        .pdb_dir = switch (options.pdb_dir) {
            .disabled => null,
            .default => if (artifact.producesPdbFile()) dest_dir else null,
            .override => |o| o,
        },
        .compiler_rt_dyn_lib_dir = switch (options.compiler_rt_dyn_lib_dir) {
            .disabled => null,
            .default => if (artifact.producesCompilerRtDynLib()) dest_dir else null,
            .override => |o| o,
        },
        .h_dir = switch (options.h_dir) {
            .disabled => null,
            .default => if (artifact.kind == .lib) .header else null,
            .override => |o| o,
        },
        .implib_dir = switch (options.implib_dir) {
            .disabled => null,
            .default => if (artifact.producesImplib()) .lib else null,
            .override => |o| o,
        },

        .dylib_symlinks = if (options.dylib_symlinks orelse (dest_dir != null and
            artifact.isDynamicLibrary() and
            artifact.version != null and
            std.Build.wantSharedLibSymLinks(artifact.rootModuleTarget()))) .{
            .major_only_filename = artifact.major_only_filename.?,
            .name_only_filename = artifact.name_only_filename.?,
        } else null,

        .dest_sub_path = options.dest_sub_path orelse artifact.out_filename,

        .emitted_bin = null,
        .emitted_pdb = null,
        .emitted_compiler_rt_dyn_lib = null,
        .emitted_h = null,
        .emitted_implib = null,

        .artifact = artifact,
    };

    install_artifact.step.dependOn(&artifact.step);

    if (install_artifact.dest_dir != null) install_artifact.emitted_bin = artifact.getEmittedBin();
    if (install_artifact.compiler_rt_dyn_lib_dir != null) install_artifact.emitted_compiler_rt_dyn_lib = artifact.getEmittedCompilerRtDynLib();
    if (install_artifact.pdb_dir != null) install_artifact.emitted_pdb = artifact.getEmittedPdb();
    // https://github.com/ziglang/zig/issues/9698
    //if (install_artifact.h_dir != null) install_artifact.emitted_h = artifact.getEmittedH();
    if (install_artifact.implib_dir != null) install_artifact.emitted_implib = artifact.getEmittedImplib();

    return install_artifact;
}
