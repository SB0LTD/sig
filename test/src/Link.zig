b: *Build,
step: *Step,
optimize: std.builtin.OptimizeMode,
target: std.Build.ResolvedTarget,
use_llvm: bool,
use_lld: bool,
link_libc: bool,
test_filters: []const []const u8,
update_step: ?*Step.UpdateSourceFiles,
updated_snapshots: std.StringArrayHashMapUnmanaged(void),
max_rss: usize,

pub fn includeTest(self: *const Link, prefix: []const u8) ?[]const u8 {
    if (for (self.test_filters) |filter| {
        if (std.mem.containsAtLeast(u8, prefix, 1, filter)) break false;
    } else self.test_filters.len > 0) return null;
    return prefix;
}

pub fn sourcePath(self: *const Link, sub_path: []const u8) std.Build.LazyPath {
    return self.b.path(self.b.pathJoin(&.{ "test/link", sub_path }));
}

pub fn addLibrary(
    self: *const Link,
    linkage: std.builtin.LinkMode,
    overlay: OverlayOptions,
) *Step.Compile {
    return self.b.addLibrary(.{
        .linkage = linkage,
        .name = overlay.name,
        .root_module = self.createModule(overlay),
        .use_llvm = overlay.use_llvm orelse self.use_llvm,
        .use_lld = overlay.use_lld orelse self.use_lld,
    });
}

pub fn addObject(self: *const Link, overlay: OverlayOptions) *Step.Compile {
    return self.b.addObject(.{
        .name = overlay.name,
        .root_module = self.createModule(overlay),
        .use_llvm = overlay.use_llvm orelse self.use_llvm,
        .use_lld = overlay.use_lld orelse self.use_lld,
    });
}

const SnapshotScope = packed struct {
    arch: bool = false,
    os: bool = false,
    abi: bool = false,
    optimize: bool = false,
    use_llvm: bool = false,
    use_lld: bool = false,
    link_libc: bool = false,
};

/// Verify the results of a `zig objdump` call against a snapshot, which
/// contains the expected output. Snapshots alias between all build
/// configurations by default, but by specifying fields in `scope`,
/// unique snapshot names are generated for each value of that field.
pub fn verifyObjdump(
    self: *Link,
    prefix: []const u8,
    compile: *Step.Compile,
    args: []const []const u8,
    scope: SnapshotScope,
) void {
    const snapshot_name = self.snapshotName(prefix, compile.name, scope) catch @panic("OOM");
    const snapshot_sub_path = self.b.pathJoin(&.{ "test/link/snapshots/", snapshot_name });

    // Many tests may read the same snapshot, so only use the first one to update.
    // If there are differences in output, they will show up on the next test run.
    if (self.update_step != null) {
        const gop = self.updated_snapshots.getOrPut(self.b.allocator, snapshot_sub_path) catch @panic("OOM");
        if (gop.found_existing) return;
    }

    const run_step = Step.Run.create(self.b, self.b.fmt("objdump {s}", .{snapshot_name}));
    run_step.addArgs(&.{ self.b.graph.zig_exe, "objdump" });
    run_step.addArtifactArg(compile);
    run_step.addArgs(args);
    run_step.addCheck(.{ .expect_term = .{ .exited = 0 } });

    if (self.update_step) |update_step| {
        // Workaround for the build system not realizing objdump itself has changed
        run_step.has_side_effects = true;

        const snapshot_update_path = run_step.captureStdOut(.{});
        update_step.addCopyFileToSource(snapshot_update_path, snapshot_sub_path);
    } else {
        run_step.addCheck(.{ .snapshot = .{ .file = self.b.path(snapshot_sub_path) } });
    }

    self.step.dependOn(&run_step.step);
}

fn snapshotName(
    self: *const Link,
    test_name: []const u8,
    compile_name: []const u8,
    scope: SnapshotScope,
) ![]const u8 {
    var snapshot_name: std.Io.Writer.Allocating = .init(self.b.allocator);
    const w = &snapshot_name.writer;

    try w.print("{s}.{s}", .{ test_name, compile_name });
    if (scope.arch) try w.print("-{t}", .{self.target.result.cpu.arch});
    if (scope.os) try w.print("-{t}", .{self.target.result.os.tag});
    if (scope.abi) try w.print("-{t}", .{self.target.result.abi});
    if (scope.optimize) try w.print("-{t}", .{self.optimize});
    if (scope.use_llvm) try w.writeAll(if (self.use_llvm) "-llvm" else "-no-llvm");
    if (scope.use_lld) try w.writeAll(if (self.use_lld) "-lld" else "-no-lld");
    if (scope.link_libc) try w.writeAll(if (self.link_libc) "-libc" else "-no-libc");
    try w.writeAll(".dmp");

    return try snapshot_name.toOwnedSlice();
}

fn createModule(self: *const Link, overlay: OverlayOptions) *Build.Module {
    const write_files = self.b.addWriteFiles();

    const mod = self.b.createModule(.{
        .target = self.target,
        .optimize = self.optimize,
        .root_source_file = overlay.zig_source_file orelse rsf: {
            const bytes = overlay.zig_source_bytes orelse break :rsf null;
            const name = self.b.fmt("{s}.zig", .{overlay.name});
            break :rsf write_files.add(name, bytes);
        },
        .link_libc = self.link_libc, // TODO: Should this be in overlay instead?
        .pic = overlay.pic,
        .strip = overlay.strip,
    });

    if (overlay.objcpp_source_bytes) |bytes| {
        mod.addCSourceFile(.{
            .file = write_files.add("a.mm", bytes),
            .flags = overlay.objcpp_source_flags,
        });
    }
    if (overlay.objc_source_bytes) |bytes| {
        mod.addCSourceFile(.{
            .file = write_files.add("a.m", bytes),
            .flags = overlay.objc_source_flags,
        });
    }
    if (overlay.cpp_source_bytes) |bytes| {
        mod.addCSourceFile(.{
            .file = write_files.add("a.cpp", bytes),
            .flags = overlay.cpp_source_flags,
        });
    }
    if (overlay.c_source_bytes) |bytes| {
        mod.addCSourceFile(.{
            .file = write_files.add("a.c", bytes),
            .flags = overlay.c_source_flags,
        });
    }
    if (overlay.asm_source_bytes) |bytes| {
        mod.addAssemblyFile(write_files.add("a.s", bytes));
    }

    return mod;
}

const OverlayOptions = struct {
    name: []const u8,
    asm_source_bytes: ?[]const u8 = null,
    c_source_bytes: ?[]const u8 = null,
    c_source_flags: []const []const u8 = &.{},
    cpp_source_bytes: ?[]const u8 = null,
    cpp_source_flags: []const []const u8 = &.{},
    objc_source_bytes: ?[]const u8 = null,
    objc_source_flags: []const []const u8 = &.{},
    objcpp_source_bytes: ?[]const u8 = null,
    objcpp_source_flags: []const []const u8 = &.{},
    zig_source_bytes: ?[]const u8 = null,
    zig_source_file: ?std.Build.LazyPath = null,
    pic: ?bool = null,
    strip: ?bool = null,
    use_llvm: ?bool = null,
    use_lld: ?bool = null,
};

const std = @import("std");
const Build = std.Build;
const Step = Build.Step;

const Link = @This();
