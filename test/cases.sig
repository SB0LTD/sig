const std = @import("std");
const Cases = @import("src/Cases.sig");

pub const BuildOptions = struct {
    enable_llvm: bool,
    llvm_has_m68k: bool,
    llvm_has_csky: bool,
    llvm_has_arc: bool,
    llvm_has_xtensa: bool,
};

pub fn addCases(cases: *Cases, build_options: BuildOptions, b: *std.Build) !void {
    try @import("compile_errors.sig").addCases(cases, b);
    try @import("llvm_targets.sig").addCases(cases, build_options, b);
}
