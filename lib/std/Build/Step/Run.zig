const Run = @This();
const builtin = @import("builtin");

const std = @import("std");
const Io = std.Io;
const Build = std.Build;
const Step = std.Build.Step;
const Dir = std.Io.Dir;
const mem = std.mem;
const process = std.process;
const EnvMap = std.process.Environ.Map;
const assert = std.debug.assert;
const Path = std.Build.Cache.Path;

pub const base_tag: Step.Tag = .run;

step: Step,

/// See also addArg and addArgs to modifying this directly
argv: std.ArrayList(Arg),

/// Use `setCwd` to set the initial current working directory
cwd: ?Build.LazyPath,

/// Override this field to modify the environment, or use setEnvironmentVariable
environ_map: ?*EnvMap,

/// Controls the `NO_COLOR` and `CLICOLOR_FORCE` environment variables.
color: Color = .auto,

/// When `true` prevents `ZIG_PROGRESS` environment variable from being passed
/// to the child process, which otherwise would be used for the child to send
/// progress updates to the parent.
disable_zig_progress: bool,

/// Configures whether the Run step is considered to have side-effects, and also
/// whether the Run step will inherit stdio streams, forwarding them to the
/// parent process, in which case will require a global lock to prevent other
/// steps from interfering with stdio while the subprocess associated with this
/// Run step is running.
/// If the Run step is determined to not have side-effects, then execution will
/// be skipped if all output files are up-to-date and input files are
/// unchanged.
stdio: StdIo,

/// This field must be `.none` if stdio is `inherit`.
/// It should be only set using `setStdIn`.
stdin: StdIn,

/// Additional input files that, when modified, indicate that the Run step
/// should be re-executed.
/// If the Run step is determined to have side-effects, the Run step is always
/// executed when it appears in the build graph, regardless of whether these
/// files have been modified.
file_inputs: std.ArrayList(std.Build.LazyPath),

/// After adding an output argument, this step will by default rename itself
/// for a better display name in the build summary.
/// This can be disabled by setting this to false.
rename_step_with_output_arg: bool,

/// If this is true, a Run step which is configured to check the output of the
/// executed binary will not fail the build if the binary cannot be executed
/// due to being for a foreign binary to the host system which is running the
/// build graph.
/// Command-line arguments such as -fqemu and -fwasmtime may affect whether a
/// binary is detected as foreign, as well as system configuration such as
/// Rosetta (macOS) and binfmt_misc (Linux).
/// If this Run step is considered to have side-effects, then this flag does
/// nothing.
skip_foreign_checks: bool,

/// If this is true, failing to execute a foreign binary will be considered an
/// error. However if this is false, the step will be skipped on failure instead.
///
/// This allows for a Run step to attempt to execute a foreign binary using an
/// external executor (such as qemu) but not fail if the executor is unavailable.
failing_to_execute_foreign_is_an_error: bool,

/// If stderr or stdout exceeds this amount, the child process is killed and
/// the step fails.
stdio_limit: std.Io.Limit,

captured_stdout: ?*CapturedStdIo,
captured_stderr: ?*CapturedStdIo,

dep_output_file: ?*Output,

has_side_effects: bool,
test_runner_mode: bool = false,

/// If this Run step was produced by a Compile step, it is tracked here.
producer: ?*Step.Compile,

pub const Color = std.Build.Configuration.Step.Run.Color;

pub const StdIn = union(enum) {
    none,
    bytes: []const u8,
    lazy_path: std.Build.LazyPath,
};

pub const StdIo = union(enum) {
    /// Whether the Run step has side-effects will be determined by whether or not one
    /// of the args is an output file (added with `addOutputFileArg`).
    /// If the Run step is determined to have side-effects, this is the same as `inherit`.
    /// The step will fail if the subprocess crashes or returns a non-zero exit code.
    infer_from_args,
    /// Causes the Run step to be considered to have side-effects, and therefore
    /// always execute when it appears in the build graph.
    /// It also means that this step will obtain a global lock to prevent other
    /// steps from running in the meantime.
    /// The step will fail if the subprocess crashes or returns a non-zero exit code.
    inherit,
    /// Causes the Run step to be considered to *not* have side-effects. The
    /// process will be re-executed if any of the input dependencies are
    /// modified. The exit code and standard I/O streams will be checked for
    /// certain conditions, and the step will succeed or fail based on these
    /// conditions.
    /// Note that an explicit check for exit code 0 needs to be added to this
    /// list if such a check is desirable.
    check: std.ArrayList(Check),
    /// This Run step is running a zig unit test binary and will communicate
    /// extra metadata over the IPC protocol.
    zig_test,

    pub const Check = union(enum) {
        expect_stderr_exact: []const u8,
        expect_stderr_match: []const u8,
        expect_stdout_exact: []const u8,
        expect_stdout_match: []const u8,
        expect_term: process.Child.Term,
    };
};

pub const Arg = union(enum) {
    artifact: PrefixedArtifact,
    lazy_path: PrefixedLazyPath,
    decorated_directory: DecoratedLazyPath,
    file_content: PrefixedLazyPath,
    bytes: []u8,
    output_file: *Output,
    output_directory: *Output,
};

pub const PrefixedArtifact = struct {
    prefix: []const u8,
    artifact: *Step.Compile,
};

pub const PrefixedLazyPath = struct {
    prefix: []const u8,
    lazy_path: std.Build.LazyPath,
};

pub const DecoratedLazyPath = struct {
    prefix: []const u8,
    lazy_path: std.Build.LazyPath,
    suffix: []const u8,
};

pub const Output = struct {
    generated_file: std.Build.GeneratedFile,
    prefix: []const u8,
    basename: []const u8,
};

pub const CapturedStdIo = struct {
    output: Output,
    trim_whitespace: TrimWhitespace,

    pub const Options = struct {
        /// `null` means `stdout`/`stderr`.
        basename: ?[]const u8 = null,
        /// Does not affect `expectStdOutEqual`/`expectStdErrEqual`.
        trim_whitespace: TrimWhitespace = .none,
    };

    pub const TrimWhitespace = std.Build.Configuration.Step.Run.TrimWhitespace;
};

pub fn create(owner: *std.Build, name: []const u8) *Run {
    const run = owner.allocator.create(Run) catch @panic("OOM");
    run.* = .{
        .step = .init(.{
            .tag = base_tag,
            .name = name,
            .owner = owner,
        }),
        .argv = .empty,
        .cwd = null,
        .environ_map = null,
        .disable_zig_progress = false,
        .stdio = .infer_from_args,
        .stdin = .none,
        .file_inputs = .empty,
        .rename_step_with_output_arg = true,
        .skip_foreign_checks = false,
        .failing_to_execute_foreign_is_an_error = true,
        .stdio_limit = .unlimited,
        .captured_stdout = null,
        .captured_stderr = null,
        .dep_output_file = null,
        .has_side_effects = false,
        .producer = null,
    };
    return run;
}

pub fn setName(run: *Run, name: []const u8) void {
    run.step.name = name;
    run.rename_step_with_output_arg = false;
}

pub fn enableTestRunnerMode(run: *Run) void {
    if (run.test_runner_mode) return;
    const b = run.step.owner;
    run.stdio = .zig_test;
    run.addPrefixedDirectoryArg("--cache-dir=", .{ .cwd_relative = b.cache_root.path orelse "." });
    run.test_runner_mode = true;
}

pub fn addArtifactArg(run: *Run, artifact: *Step.Compile) void {
    run.addPrefixedArtifactArg("", artifact);
}

pub fn addPrefixedArtifactArg(run: *Run, prefix: []const u8, artifact: *Step.Compile) void {
    const b = run.step.owner;

    const prefixed_artifact: PrefixedArtifact = .{
        .prefix = b.dupe(prefix),
        .artifact = artifact,
    };
    run.argv.append(b.allocator, .{ .artifact = prefixed_artifact }) catch @panic("OOM");

    const bin_file = artifact.getEmittedBin();
    bin_file.addStepDependencies(&run.step);
}

/// Provides a file path as a command line argument to the command being run.
///
/// Returns a `std.Build.LazyPath` which can be used as inputs to other APIs
/// throughout the build system.
///
/// Related:
/// * `addPrefixedOutputFileArg` - same thing but prepends a string to the argument
/// * `addFileArg` - for input files given to the child process
pub fn addOutputFileArg(run: *Run, basename: []const u8) std.Build.LazyPath {
    return run.addPrefixedOutputFileArg("", basename);
}

/// Provides a file path as a command line argument to the command being run.
/// Asserts `basename` is not empty.
///
/// For example, a prefix of "-o" and basename of "output.txt" will result in
/// the child process seeing something like this: "-ozig-cache/.../output.txt"
///
/// The child process will see a single argument, regardless of whether the
/// prefix or basename have spaces.
///
/// The returned `std.Build.LazyPath` can be used as inputs to other APIs
/// throughout the build system.
///
/// Related:
/// * `addOutputFileArg` - same thing but without the prefix
/// * `addFileArg` - for input files given to the child process
pub fn addPrefixedOutputFileArg(
    run: *Run,
    prefix: []const u8,
    basename: []const u8,
) std.Build.LazyPath {
    const b = run.step.owner;
    if (basename.len == 0) @panic("basename must not be empty");

    const output = b.allocator.create(Output) catch @panic("OOM");
    output.* = .{
        .prefix = b.dupe(prefix),
        .basename = b.dupe(basename),
        .generated_file = .{ .step = &run.step },
    };
    run.argv.append(b.allocator, .{ .output_file = output }) catch @panic("OOM");

    if (run.rename_step_with_output_arg) {
        run.setName(b.fmt("{s} ({s})", .{ run.step.name, basename }));
    }

    return .{ .generated = .{ .file = &output.generated_file } };
}

/// Appends an input file to the command line arguments.
///
/// The child process will see a file path. Modifications to this file will be
/// detected as a cache miss in subsequent builds, causing the child process to
/// be re-executed.
///
/// Related:
/// * `addPrefixedFileArg` - same thing but prepends a string to the argument
/// * `addOutputFileArg` - for files generated by the child process
pub fn addFileArg(run: *Run, lp: std.Build.LazyPath) void {
    run.addPrefixedFileArg("", lp);
}

/// Appends an input file to the command line arguments prepended with a string.
///
/// For example, a prefix of "-F" will result in the child process seeing something
/// like this: "-Fexample.txt"
///
/// The child process will see a single argument, even if the prefix has
/// spaces. Modifications to this file will be detected as a cache miss in
/// subsequent builds, causing the child process to be re-executed.
///
/// Related:
/// * `addFileArg` - same thing but without the prefix
/// * `addOutputFileArg` - for files generated by the child process
pub fn addPrefixedFileArg(run: *Run, prefix: []const u8, lp: std.Build.LazyPath) void {
    const b = run.step.owner;

    const prefixed_file_source: PrefixedLazyPath = .{
        .prefix = b.dupe(prefix),
        .lazy_path = lp.dupe(b),
    };
    run.argv.append(b.allocator, .{ .lazy_path = prefixed_file_source }) catch @panic("OOM");
    lp.addStepDependencies(&run.step);
}

/// Appends the content of an input file to the command line arguments.
///
/// The child process will see a single argument, even if the file contains whitespace.
/// This means that the entire file content up to EOF is rendered as one contiguous
/// string, including escape sequences. Notably, any (trailing) newlines will show up
/// like this: "hello,\nfile world!\n"
///
/// Modifications to the source file will be detected as a cache miss in subsequent
/// builds, causing the child process to be re-executed.
///
/// This function may not be used to supply the first argument of a `Run` step.
///
/// Related:
/// * `addPrefixedFileContentArg` - same thing but prepends a string to the argument
pub fn addFileContentArg(run: *Run, lp: std.Build.LazyPath) void {
    run.addPrefixedFileContentArg("", lp);
}

/// Appends the content of an input file to the command line arguments prepended with a string.
///
/// For example, a prefix of "-F" will result in the child process seeing something
/// like this: "-Fmy file content"
///
/// The child process will see a single argument, even if the prefix and/or the file
/// contain whitespace.
/// This means that the entire file content up to EOF is rendered as one contiguous
/// string, including escape sequences. Notably, any (trailing) newlines will show up
/// like this: "hello,\nfile world!\n"
///
/// Modifications to the source file will be detected as a cache miss in subsequent
/// builds, causing the child process to be re-executed.
///
/// This function may not be used to supply the first argument of a `Run` step.
///
/// Related:
/// * `addFileContentArg` - same thing but without the prefix
pub fn addPrefixedFileContentArg(run: *Run, prefix: []const u8, lp: std.Build.LazyPath) void {
    const b = run.step.owner;

    // Some parts of this step's configure phase API rely on the first argument being somewhat
    // transparent/readable, but the content of the file specified by `lp` remains completely
    // opaque until its path can be resolved during the make phase.
    if (run.argv.items.len == 0) {
        @panic("'addFileContentArg'/'addPrefixedFileContentArg' cannot be first argument");
    }

    const prefixed_file_source: PrefixedLazyPath = .{
        .prefix = b.dupe(prefix),
        .lazy_path = lp.dupe(b),
    };
    run.argv.append(b.allocator, .{ .file_content = prefixed_file_source }) catch @panic("OOM");
    lp.addStepDependencies(&run.step);
}

/// Provides a directory path as a command line argument to the command being run.
///
/// Returns a `std.Build.LazyPath` which can be used as inputs to other APIs
/// throughout the build system.
///
/// Related:
/// * `addPrefixedOutputDirectoryArg` - same thing but prepends a string to the argument
/// * `addDirectoryArg` - for input directories given to the child process
pub fn addOutputDirectoryArg(run: *Run, basename: []const u8) std.Build.LazyPath {
    return run.addPrefixedOutputDirectoryArg("", basename);
}

/// Provides a directory path as a command line argument to the command being run.
/// Asserts `basename` is not empty.
///
/// For example, a prefix of "-o" and basename of "output_dir" will result in
/// the child process seeing something like this: "-ozig-cache/.../output_dir"
///
/// The child process will see a single argument, regardless of whether the
/// prefix or basename have spaces.
///
/// The returned `std.Build.LazyPath` can be used as inputs to other APIs
/// throughout the build system.
///
/// Related:
/// * `addOutputDirectoryArg` - same thing but without the prefix
/// * `addDirectoryArg` - for input directories given to the child process
pub fn addPrefixedOutputDirectoryArg(
    run: *Run,
    prefix: []const u8,
    basename: []const u8,
) std.Build.LazyPath {
    if (basename.len == 0) @panic("basename must not be empty");
    const b = run.step.owner;

    const output = b.allocator.create(Output) catch @panic("OOM");
    output.* = .{
        .prefix = b.dupe(prefix),
        .basename = b.dupe(basename),
        .generated_file = .{ .step = &run.step },
    };
    run.argv.append(b.allocator, .{ .output_directory = output }) catch @panic("OOM");

    if (run.rename_step_with_output_arg) {
        run.setName(b.fmt("{s} ({s})", .{ run.step.name, basename }));
    }

    return .{ .generated = .{ .file = &output.generated_file } };
}

pub fn addDirectoryArg(run: *Run, lazy_directory: std.Build.LazyPath) void {
    run.addDecoratedDirectoryArg("", lazy_directory, "");
}

pub fn addPrefixedDirectoryArg(run: *Run, prefix: []const u8, lazy_directory: std.Build.LazyPath) void {
    const b = run.step.owner;
    run.argv.append(b.allocator, .{ .decorated_directory = .{
        .prefix = b.dupe(prefix),
        .lazy_path = lazy_directory.dupe(b),
        .suffix = "",
    } }) catch @panic("OOM");
    lazy_directory.addStepDependencies(&run.step);
}

pub fn addDecoratedDirectoryArg(
    run: *Run,
    prefix: []const u8,
    lazy_directory: std.Build.LazyPath,
    suffix: []const u8,
) void {
    const b = run.step.owner;
    run.argv.append(b.allocator, .{ .decorated_directory = .{
        .prefix = b.dupe(prefix),
        .lazy_path = lazy_directory.dupe(b),
        .suffix = b.dupe(suffix),
    } }) catch @panic("OOM");
    lazy_directory.addStepDependencies(&run.step);
}

/// Add a path argument to a dep file (.d) for the child process to write its
/// discovered additional dependencies.
/// Only one dep file argument is allowed by instance.
pub fn addDepFileOutputArg(run: *Run, basename: []const u8) std.Build.LazyPath {
    return run.addPrefixedDepFileOutputArg("", basename);
}

/// Add a prefixed path argument to a dep file (.d) for the child process to
/// write its discovered additional dependencies.
/// Only one dep file argument is allowed by instance.
pub fn addPrefixedDepFileOutputArg(run: *Run, prefix: []const u8, basename: []const u8) std.Build.LazyPath {
    const b = run.step.owner;
    assert(run.dep_output_file == null);

    const dep_file = b.allocator.create(Output) catch @panic("OOM");
    dep_file.* = .{
        .prefix = b.dupe(prefix),
        .basename = b.dupe(basename),
        .generated_file = .{ .step = &run.step },
    };

    run.dep_output_file = dep_file;

    run.argv.append(b.allocator, .{ .output_file = dep_file }) catch @panic("OOM");

    return .{ .generated = .{ .file = &dep_file.generated_file } };
}

pub fn addArg(run: *Run, arg: []const u8) void {
    const b = run.step.owner;
    run.argv.append(b.allocator, .{ .bytes = b.dupe(arg) }) catch @panic("OOM");
}

pub fn addArgs(run: *Run, args: []const []const u8) void {
    for (args) |arg| run.addArg(arg);
}

pub fn setStdIn(run: *Run, stdin: StdIn) void {
    switch (stdin) {
        .lazy_path => |lazy_path| lazy_path.addStepDependencies(&run.step),
        .bytes, .none => {},
    }
    run.stdin = stdin;
}

pub fn setCwd(run: *Run, cwd: Build.LazyPath) void {
    cwd.addStepDependencies(&run.step);
    run.cwd = cwd.dupe(run.step.owner);
}

pub fn clearEnvironment(run: *Run) void {
    const b = run.step.owner;
    const new_env_map = b.allocator.create(EnvMap) catch @panic("OOM");
    new_env_map.* = .init(b.allocator);
    run.environ_map = new_env_map;
}

pub fn addPathDir(run: *Run, search_path: []const u8) void {
    const b = run.step.owner;
    const environ_map = getEnvMapInternal(run);

    const use_wine = b.enable_wine and b.graph.host.result.os.tag != .windows and use_wine: switch (run.argv.items[0]) {
        .artifact => |p| p.artifact.rootModuleTarget().os.tag == .windows,
        .lazy_path => |p| {
            switch (p.lazy_path) {
                .generated => |g| if (g.file.step.cast(Step.Compile)) |cs| break :use_wine cs.rootModuleTarget().os.tag == .windows,
                else => {},
            }
            break :use_wine std.mem.endsWith(u8, p.lazy_path.basename(b, &run.step), ".exe");
        },
        .decorated_directory => false,
        .file_content => unreachable, // not allowed as first arg
        .bytes => |bytes| std.mem.endsWith(u8, bytes, ".exe"),
        .output_file, .output_directory => false,
    };
    const key = if (use_wine) "WINEPATH" else "PATH";
    const prev_path = environ_map.get(key);

    if (prev_path) |pp| {
        const new_path = b.fmt("{s}{c}{s}", .{
            pp,
            if (use_wine) Dir.path.delimiter_windows else Dir.path.delimiter,
            search_path,
        });
        environ_map.put(key, new_path) catch @panic("OOM");
    } else {
        environ_map.put(key, b.dupePath(search_path)) catch @panic("OOM");
    }
}

pub fn getEnvMap(run: *Run) *EnvMap {
    return getEnvMapInternal(run);
}

fn getEnvMapInternal(run: *Run) *EnvMap {
    const graph = run.step.owner.graph;
    const arena = graph.arena;
    return run.environ_map orelse {
        const cloned_map = arena.create(EnvMap) catch @panic("OOM");
        cloned_map.* = graph.environ_map.clone(arena) catch @panic("OOM");
        run.environ_map = cloned_map;
        return cloned_map;
    };
}

pub fn setEnvironmentVariable(run: *Run, key: []const u8, value: []const u8) void {
    const environ_map = run.getEnvMap();
    // This data structure already dupes keys and values.
    environ_map.put(key, value) catch @panic("OOM");
}

pub fn removeEnvironmentVariable(run: *Run, key: []const u8) void {
    _ = run.getEnvMap().swapRemove(key);
}

/// Adds a check for exact stderr match. Does not add any other checks.
pub fn expectStdErrEqual(run: *Run, bytes: []const u8) void {
    run.addCheck(.{ .expect_stderr_exact = run.step.owner.dupe(bytes) });
}

pub fn expectStdErrMatch(run: *Run, bytes: []const u8) void {
    run.addCheck(.{ .expect_stderr_match = run.step.owner.dupe(bytes) });
}

/// Adds a check for exact stdout match as well as a check for exit code 0, if
/// there is not already an expected termination check.
pub fn expectStdOutEqual(run: *Run, bytes: []const u8) void {
    run.addCheck(.{ .expect_stdout_exact = run.step.owner.dupe(bytes) });
    if (!run.hasTermCheck()) run.expectExitCode(0);
}

/// Adds a check for stdout match as well as a check for exit code 0, if there
/// is not already an expected termination check.
pub fn expectStdOutMatch(run: *Run, bytes: []const u8) void {
    run.addCheck(.{ .expect_stdout_match = run.step.owner.dupe(bytes) });
    if (!run.hasTermCheck()) run.expectExitCode(0);
}

pub fn expectExitCode(run: *Run, code: u8) void {
    const new_check: StdIo.Check = .{ .expect_term = .{ .exited = code } };
    run.addCheck(new_check);
}

pub fn hasTermCheck(run: Run) bool {
    for (run.stdio.check.items) |check| switch (check) {
        .expect_term => return true,
        else => continue,
    };
    return false;
}

pub fn addCheck(run: *Run, new_check: StdIo.Check) void {
    const b = run.step.owner;

    switch (run.stdio) {
        .infer_from_args => {
            run.stdio = .{ .check = .empty };
            run.stdio.check.append(b.allocator, new_check) catch @panic("OOM");
        },
        .check => |*checks| checks.append(b.allocator, new_check) catch @panic("OOM"),
        else => @panic("illegal call to addCheck: conflicting helper method calls. Suggest to directly set stdio field of Run instead"),
    }
}

pub fn captureStdErr(run: *Run, options: CapturedStdIo.Options) std.Build.LazyPath {
    assert(run.stdio != .inherit);
    assert(run.stdio != .zig_test);

    const b = run.step.owner;

    if (run.captured_stderr) |captured| return .{ .generated = .{ .file = &captured.output.generated_file } };

    const captured = b.allocator.create(CapturedStdIo) catch @panic("OOM");
    captured.* = .{
        .output = .{
            .prefix = "",
            .basename = if (options.basename) |basename| b.dupe(basename) else "stderr",
            .generated_file = .{ .step = &run.step },
        },
        .trim_whitespace = options.trim_whitespace,
    };
    run.captured_stderr = captured;
    return .{ .generated = .{ .file = &captured.output.generated_file } };
}

pub fn captureStdOut(run: *Run, options: CapturedStdIo.Options) std.Build.LazyPath {
    assert(run.stdio != .inherit);
    assert(run.stdio != .zig_test);

    const b = run.step.owner;

    if (run.captured_stdout) |captured| return .{ .generated = .{ .file = &captured.output.generated_file } };

    const captured = b.allocator.create(CapturedStdIo) catch @panic("OOM");
    captured.* = .{
        .output = .{
            .prefix = "",
            .basename = if (options.basename) |basename| b.dupe(basename) else "stdout",
            .generated_file = .{ .step = &run.step },
        },
        .trim_whitespace = options.trim_whitespace,
    };
    run.captured_stdout = captured;
    return .{ .generated = .{ .file = &captured.output.generated_file } };
}

/// Adds an additional input files that, when modified, indicates that this Run
/// step should be re-executed.
/// If the Run step is determined to have side-effects, the Run step is always
/// executed when it appears in the build graph, regardless of whether this
/// file has been modified.
pub fn addFileInput(self: *Run, file_input: std.Build.LazyPath) void {
    file_input.addStepDependencies(&self.step);
    self.file_inputs.append(self.step.owner.allocator, file_input.dupe(self.step.owner)) catch @panic("OOM");
}
