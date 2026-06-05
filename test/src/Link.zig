b: *Build,
step: *Step,
optimize: std.builtin.OptimizeMode,
target: std.Build.ResolvedTarget,
use_llvm: bool,
use_lld: bool,
link_libc: bool,
suffix: []const u8,
test_filters: []const []const u8,
max_rss: usize,

pub fn addTestStep(self: *const Link, prefix: []const u8) ?[]const u8 {
    if (for (self.test_filters) |filter| {
        if (std.mem.containsAtLeast(u8, prefix, 1, filter)) break false;
    } else self.test_filters.len > 0) return null;

    return std.fmt.allocPrint(self.b.allocator, "test-{s}", .{prefix}) catch @panic("OOM");
}

pub fn addStaticLibrary(self: *const Link, overlay: OverlayOptions) *Step.Compile {
    return self.b.addLibrary(.{
        .linkage = .static,
        .name = overlay.name,
        .root_module = self.createModule(overlay),
        .use_llvm = self.use_llvm,
        .use_lld = self.use_lld,
    });
}

// TODO: Use std.meta.FieldEnum on TargetQuery?
const SnapshotScope = packed struct {
    arch: bool = false,
    os: bool = false,
    abi: bool = false,
    optimize: bool = false,
    use_llvm: bool = false,
    use_lld: bool = false,
    link_libc: bool = false,
};

pub fn verifyObjdump(
    self: *const Link,
    name: []const u8,
    compile: *Step.Compile,
    args: []const []const u8,
    scope: SnapshotScope,
) void {
    const snapshot_name = self.snapshotName(name, compile.name, scope) catch @panic("OOM");
    const run_step = Step.Run.create(self.b, self.b.fmt("objdump {s}", .{snapshot_name}));
    run_step.addArgs(&.{ self.b.graph.zig_exe, "objdump" });
    run_step.addArtifactArg(compile);
    run_step.addArgs(args);
    run_step.addCheck(.{ .expect_term = .{ .exited = 0 } });

    const actual_path = run_step.captureStdOut(.{ .trim_whitespace = .none });
    const expected_path = self.b.path(self.b.pathJoin(&.{ "test/link/snapshots/", snapshot_name }));

    const check_step = self.b.addCheckFile(actual_path, .{
        .expected_file = .{
            .file = expected_path,
            .if_missing = .fail,
            // TODO: Option to do UpdateSourceFiles if not matching / missing?
            // TODO: Option to output to <name>-<self.suffix>.actual.dmp file?
        },
    });

    self.step.dependOn(&check_step.step);
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
    if (scope.use_llvm and self.use_llvm) try w.writeAll("-llvm");
    if (scope.use_lld and self.use_lld) try w.writeAll("-lld");
    if (scope.link_libc and self.link_libc) try w.writeAll("-libc");
    try w.writeAll(".dmp");

    return try snapshot_name.toOwnedSlice();
}

fn createModule(self: *const Link, overlay: OverlayOptions) *Build.Module {
    const write_files = self.b.addWriteFiles();

    const mod = self.b.createModule(.{
        .target = self.target,
        .optimize = self.optimize,
        .root_source_file = rsf: {
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
    pic: ?bool = null,
    strip: ?bool = null,
};

const std = @import("std");
const Build = std.Build;
const Step = Build.Step;

const Link = @This();
