const api = @import("sig_build");
fn noop(_: *api.Step_Context) api.SigError!void {}
pub fn build(ctx: *api.Build_Context) !void {
    const library=ctx.sig_lib_dir[0..ctx.sig_lib_dir_len];
    var path:[api.PATH_BUF_SIZE]u8=undefined;
    const suffix="/sig/sig.sig";
    if(library.len+suffix.len>path.len) return error.BufferTooSmall;
    @memcpy(path[0..library.len],library);
    @memcpy(path[library.len..][0..suffix.len],suffix);
    var module:api.Import_Entry=.{};
    @memcpy(module.name[0..3],"sig");module.name_len=3;
    @memcpy(module.path[0..library.len+suffix.len],path[0..library.len+suffix.len]);
    module.path_len=library.len+suffix.len;
    const executable=try ctx.addCompileStep(.{.source_path="main.sig",.output_name="native-io-contract",
        .cache_dir=ctx.cache_dir[0..ctx.cache_dir_len],.optimize=ctx.optimize,.target=&ctx.target,
        .imports=&.{module},.compiler_path=""});
    const install=try ctx.addStep("install","Compile native I/O integration contract",&noop);
    try ctx.addDependency(install,executable);
}
