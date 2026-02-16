const Configuration = @This();

const std = @import("../std.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const maxInt = std.math.maxInt;

string_bytes: []u8,
steps: []Step,
path_deps_base: []Path.Base,
path_deps_sub: []String,
unlazy_deps: []String,
extra: []u32,

/// The field order here matches `Configuration` which documents the order in
/// the serialized format.
pub const Header = extern struct {
    string_bytes_len: u32,
    steps_len: u32,
    path_deps_len: u32,
    unlazy_deps_len: u32,
    extra_len: u32,

    default_step: Step.Index,
};

pub const Wip = struct {
    gpa: Allocator,
    string_table: StringTable = .empty,
    deps_table: DepsTable = .empty,

    string_bytes: std.ArrayList(u8) = .empty,
    unlazy_deps: std.ArrayList(String) = .empty,
    steps: std.ArrayList(Step) = .empty,
    path_deps: std.MultiArrayList(Path) = .empty,
    extra: std.ArrayList(u32) = .empty,

    const DepsTable = std.HashMapUnmanaged(Deps, void, DepsTableContext, std.hash_map.default_max_load_percentage);

    const DepsTableContext = struct {
        extra: []const u32,

        pub fn eql(ctx: @This(), a: Deps, b: Deps) bool {
            const len_a = ctx.extra[@intFromEnum(a)];
            const len_b = ctx.extra[@intFromEnum(b)];
            const slice_a = ctx.extra[@intFromEnum(a) + 1 ..][0..len_a];
            const slice_b = ctx.extra[@intFromEnum(b) + 1 ..][0..len_b];
            return std.mem.eql(u32, slice_a, slice_b);
        }

        pub fn hash(ctx: @This(), key: Deps) u64 {
            const len = ctx.extra[@intFromEnum(key)];
            const slice = ctx.extra[@intFromEnum(key) + 1 ..][0..len];
            return std.hash_map.hashString(@ptrCast(slice));
        }
    };

    const StringTable = std.HashMapUnmanaged(String, void, StringTableContext, std.hash_map.default_max_load_percentage);
    const StringTableContext = struct {
        bytes: []const u8,

        pub fn eql(_: @This(), a: String, b: String) bool {
            return a == b;
        }

        pub fn hash(ctx: @This(), key: String) u64 {
            return std.hash_map.hashString(std.mem.sliceTo(ctx.bytes[@intFromEnum(key)..], 0));
        }
    };

    const StringTableIndexAdapter = struct {
        bytes: []const u8,

        pub fn eql(ctx: @This(), a: []const u8, b: String) bool {
            return std.mem.eql(u8, a, std.mem.sliceTo(ctx.bytes[@intFromEnum(b)..], 0));
        }

        pub fn hash(_: @This(), adapted_key: []const u8) u64 {
            assert(std.mem.indexOfScalar(u8, adapted_key, 0) == null);
            return std.hash_map.hashString(adapted_key);
        }
    };

    pub fn init(gpa: Allocator) Wip {
        return .{ .gpa = gpa };
    }

    pub fn deinit(wip: *Wip) void {
        const gpa = wip.gpa;
        wip.string_bytes.deinit(gpa);
        wip.unlazy_deps.deinit(gpa);
        wip.steps.deinit(gpa);
        wip.path_deps.deinit(gpa);
        wip.extra.deinit(gpa);
        wip.* = undefined;
    }

    pub const Static = struct {
        default_step: Step.Index,
    };

    pub fn write(wip: *Wip, w: *Io.Writer, static: Static) Io.Writer.Error!void {
        const header: Header = .{
            .string_bytes_len = @intCast(wip.string_bytes.items.len),
            .steps_len = @intCast(wip.steps.items.len),
            .path_deps_len = @intCast(wip.path_deps.len),
            .unlazy_deps_len = @intCast(wip.unlazy_deps.items.len),
            .extra_len = @intCast(wip.extra.items.len),

            .default_step = static.default_step,
        };
        var buffers = [_][]const u8{
            @ptrCast(&header),
            wip.string_bytes.items,
            @ptrCast(wip.steps.items),
            @ptrCast(wip.path_deps.items(.base)),
            @ptrCast(wip.path_deps.items(.sub)),
            @ptrCast(wip.unlazy_deps.items),
            @ptrCast(wip.extra.items),
        };
        try w.writeVecAll(&buffers);
    }

    pub fn addString(wip: *Wip, bytes: []const u8) Allocator.Error!String {
        const gpa = wip.gpa;
        assert(std.mem.indexOfScalar(u8, bytes, 0) == null);
        const gop = try wip.string_table.getOrPutContextAdapted(
            gpa,
            @as([]const u8, bytes),
            @as(StringTableIndexAdapter, .{ .bytes = wip.string_bytes.items }),
            @as(StringTableContext, .{ .bytes = wip.string_bytes.items }),
        );
        if (gop.found_existing) return gop.key_ptr.*;

        try wip.string_bytes.ensureUnusedCapacity(gpa, bytes.len + 1);
        const new_off: String = @enumFromInt(wip.string_bytes.items.len);

        wip.string_bytes.appendSliceAssumeCapacity(bytes);
        wip.string_bytes.appendAssumeCapacity(0);

        gop.key_ptr.* = new_off;

        return new_off;
    }

    pub fn prepareDeps(wip: *Wip, n: usize) Allocator.Error![]u32 {
        const slice = try wip.extra.addManyAsSlice(wip.gpa, n + 1);
        slice[0] = @intCast(n);
        return slice[1..];
    }

    pub fn dedupeDeps(wip: *Wip, deps: Deps) Allocator.Error!Deps {
        const gpa = wip.gpa;
        const gop = try wip.deps_table.getOrPutContext(gpa, deps, @as(DepsTableContext, .{
            .extra = wip.extra.items,
        }));
        if (gop.found_existing) {
            wip.extra.items.len = @intFromEnum(deps);
            return gop.key_ptr.*;
        } else {
            return deps;
        }
    }

    pub fn addExtra(wip: *Wip, extra: anytype) Allocator.Error!u32 {
        const gpa = wip.gpa;
        const fields = @typeInfo(@TypeOf(extra)).@"struct".fields;
        try wip.extra.ensureUnusedCapacity(gpa, fields.len);
        return addExtraAssumeCapacity(wip, extra);
    }

    pub fn addExtraAssumeCapacity(wip: *Wip, extra: anytype) u32 {
        const fields = @typeInfo(@TypeOf(extra)).@"struct".fields;
        const result: u32 = @intCast(wip.extra.items.len);
        wip.extra.items.len += fields.len;
        setExtra(wip, result, extra);
        return result;
    }

    fn setExtra(wip: *Wip, index: usize, extra: anytype) void {
        const fields = @typeInfo(@TypeOf(extra)).@"struct".fields;
        var i = index;
        inline for (fields) |field| {
            comptime assert(@sizeOf(field.type) == @sizeOf(u32));
            wip.extra.items[i] = switch (@typeInfo(field.type)) {
                .int => @field(extra, field.name),
                .@"enum" => @intFromEnum(@field(extra, field.name)),
                .@"struct" => @bitCast(@field(extra, field.name)),
                else => @compileError("bad field type: " ++ @typeName(field.type)),
            };
            i += 1;
        }
    }
};

pub const Step = extern struct {
    name: String,
    deps: Deps,
    max_rss: MaxRss,
    /// Points into `extra` for step-specific data. First element has flags
    /// with `Tag`.
    extra_index: u32,

    pub const Index = enum(u32) {
        _,
    };

    pub const Tag = enum(u8) {
        top_level,
        compile,
        install_artifact,
        install_file,
        install_dir,
        remove_dir,
        fail,
        fmt,
        translate_c,
        write_file,
        update_source_files,
        run,
        check_file,
        check_object,
        config_header,
        objcopy,
        options,
    };

    pub const TopLevel = struct {
        flags: Flags = .{},
        description: String,

        pub const Flags = packed struct(u32) {
            tag: Tag = .top_level,
            _: u24 = 0,
        };
    };

    pub const InstallArtifact = struct {
        flags: Flags,

        dest_dir: InstallDir,
        dest_sub_path: String,
        emitted_bin: OptionalLazyPath,

        implib_dir: InstallDir,
        emitted_implib: OptionalLazyPath,

        pdb_dir: InstallDir,
        emitted_pdb: OptionalLazyPath,

        h_dir: InstallDir,
        emitted_h: OptionalLazyPath,

        /// Always a compile step.
        artifact: Step.Index,

        pub const Flags = packed struct(u32) {
            tag: Tag = .install_artifact,
            dylib_symlinks: bool,
            _: u23 = 0,
        };
    };

    /// Trailing:
    /// * LazyPath for each file_inputs_len
    /// * Arg for each args_len
    /// * environ_map if corresponding flag is set
    /// * stdin: Bytes, // if StdIn.bytes is chosen
    /// * stdin: LazyPath, // if StdIn.lazy_path is chosen
    /// * checks: Checks, // if StdIo.check is chosen
    /// * stdio_limit: u64, // if stdio_limit is set
    /// * producer: Step.Index, // if producer is set. always compile step
    pub const Run = struct {
        flags: Flags,
        file_inputs_len: u32,
        args_len: u32,
        cwd: OptionalLazyPath,
        captured_stdout: OptionalString, // basename
        captured_stderr: OptionalString, // basename

        /// Trailing:
        /// * String if prefix set
        /// * String if suffix set
        /// * String if basename set
        /// * Step.Index which is always a compile step if tag is artifact
        /// * LazyPath if tag is path_file, path_directory, or file_content
        pub const Arg = struct {
            flags: Arg.Flags,

            pub const Flags = packed struct(u32) {
                tag: Arg.Tag,
                prefix: bool,
                suffix: bool,
                basename: bool,
                /// Implies Tag is output_file
                dep_file: bool,
                _: u20 = 0,
            };

            pub const Tag = enum(u8) {
                artifact,
                path_file,
                path_directory,
                file_content,
                bytes,
                output_file,
                output_directory,
            };
        };

        pub const Color = enum(u4) {
            /// `CLICOLOR_FORCE` is set, and `NO_COLOR` is unset.
            enable,
            /// `NO_COLOR` is set, and `CLICOLOR_FORCE` is unset.
            disable,
            /// If the build runner is using color, equivalent to `.enable`. Otherwise, equivalent to `.disable`.
            inherit,
            /// If stderr is captured or checked, equivalent to `.disable`. Otherwise, equivalent to `.inherit`.
            auto,
            /// The build runner does not modify the `CLICOLOR_FORCE` or `NO_COLOR` environment variables.
            /// They are treated like normal variables, so can be controlled through `setEnvironmentVariable`.
            manual,
        };

        pub const StdIn = enum(u2) { none, bytes, lazy_path };
        pub const TrimWhitespace = enum(u2) { none, all, leading, trailing };
        pub const StdIo = enum(u2) { infer_from_args, inherit, check, zig_test };

        pub const Flags = packed struct(u32) {
            tag: Tag = .run,

            disable_zig_progress: bool,
            skip_foreign_checks: bool,
            failing_to_execute_foreign_is_an_error: bool,
            has_side_effects: bool,
            test_runner_mode: bool,
            color: Color,
            stdin: StdIn,
            stdio: StdIo,
            stdout_trim_whitespace: TrimWhitespace,
            stderr_trim_whitespace: TrimWhitespace,
            stdio_limit: bool,
            producer: bool,
            _: u5 = 0,
        };
    };
};

pub const MaxRss = enum(u32) {
    none = 0,
    _,

    pub fn toBytes(mr: MaxRss) usize {
        const x: usize = @intFromEnum(mr);
        return x << 8;
    }

    pub fn fromBytes(bytes: usize) MaxRss {
        return @enumFromInt(bytes >> 8);
    }
};

/// An index into `extra`, or `null`.
pub const OptionalLazyPath = enum(u32) {
    none = maxInt(u32),
    _,
};

/// An index into `extra`.
pub const LazyPath = enum(u32) {
    _,

    pub const Tag = enum(u8) {
        /// A source file path relative to build root.
        source_path,
        generated,
        relative,
    };

    pub const SourcePath = struct {
        flags: Flags,
        owner: Package,
        sub_path: String,

        pub const Flags = packed struct(u32) {
            tag: Tag = .source_path,
            _: u24 = 0,
        };
    };

    pub const Generated = struct {
        flags: Flags,
        /// Applied after `up`.
        sub_path: String,

        pub const Flags = packed struct(u32) {
            tag: Tag = .generated,
            /// The number of parent directories to go up.
            /// 0 means the generated file itself.
            /// 1 means the directory of the generated file.
            /// 2 means the parent of that directory, and so on.
            up: u24,
        };
    };

    pub const Relative = struct {
        flags: Flags,
        sub_path: String,

        pub const Flags = packed struct(u32) {
            tag: Tag = .relative,
            base: Path.Base,
            _: u16 = 0,
        };
    };
};

pub const Package = enum(u32) {
    _,
};

/// Points into `extra`, where the first element is number of deps,
/// following elements is `Step.Index` per dep.
pub const Deps = enum(u32) {
    _,
};

pub const Path = extern struct {
    base: Base,
    sub: String,

    pub const Base = enum(u8) {
        cwd,
        local_cache,
        global_cache,
        build_root,
    };

    pub fn toCachePath(path: Path, c: *const Configuration, arena: Allocator) std.Build.Cache.Path {
        _ = c;
        _ = arena;
        _ = path;
        @panic("TODO");
    }
};

pub const InstallDir = enum(u32) {
    none = maxInt(u32) - 4,
    prefix = maxInt(u32) - 3,
    lib = maxInt(u32) - 2,
    bin = maxInt(u32) - 1,
    header = maxInt(u32),
    /// A `String` path relative to the prefix.
    _,

    pub fn initCustom(sub_path: String) InstallDir {
        assert(@intFromEnum(sub_path) < @intFromEnum(InstallDir.none));
        return @enumFromInt(@intFromEnum(sub_path));
    }
};

/// Points into `string_bytes`, null-terminated.
pub const OptionalString = enum(u32) {
    empty = 0,
    none = maxInt(u32),
    _,

    pub fn init(s: String) OptionalString {
        const result: OptionalString = @enumFromInt(@intFromEnum(s));
        assert(result != .none);
        return result;
    }
};

/// Points into `string_bytes`, null-terminated.
pub const String = enum(u32) {
    empty = 0,
    _,

    pub fn slice(index: String, c: *const Configuration) [:0]const u8 {
        const start_slice = c.string_bytes[@intFromEnum(index)..];
        return start_slice[0..std.mem.indexOfScalar(u8, start_slice, 0).? :0];
    }
};

pub const LoadFileError = Io.File.Reader.Error || Allocator.Error || error{EndOfStream};

pub fn loadFile(arena: Allocator, io: Io, file: Io.File) LoadFileError!Configuration {
    var buffer: [2000]u8 = undefined;
    var fr = file.reader(io, &buffer);
    return load(arena, &fr.interface) catch |err| switch (err) {
        error.ReadFailed => return fr.err.?,
        else => |e| return e,
    };
}

pub const LoadError = Io.Reader.Error || Allocator.Error;

pub fn load(arena: Allocator, reader: *Io.Reader) LoadError!Configuration {
    const header = try reader.takeStruct(Header, .little);
    var result: Configuration = .{
        .string_bytes = try arena.alloc(u8, header.string_bytes_len),
        .steps = try arena.alloc(Step, header.steps_len),
        .path_deps_sub = try arena.alloc(String, header.path_deps_len),
        .path_deps_base = try arena.alloc(Path.Base, header.path_deps_len),
        .unlazy_deps = try arena.alloc(String, header.unlazy_deps_len),
        .extra = try arena.alloc(u32, header.extra_len),
    };
    var vecs = [_][]u8{
        result.string_bytes,
        @ptrCast(result.steps),
        @ptrCast(result.path_deps_base),
        @ptrCast(result.path_deps_sub),
        @ptrCast(result.unlazy_deps),
    };
    try reader.readVecAll(&vecs);
    return result;
}
