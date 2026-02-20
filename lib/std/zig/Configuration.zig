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
system_integrations: []SystemIntegration,
available_options: []AvailableOption,
extra: []u32,
default_step: Step.Index,

/// The field order here matches `Configuration` which documents the order in
/// the serialized format.
pub const Header = extern struct {
    string_bytes_len: u32,
    steps_len: u32,
    path_deps_len: u32,
    unlazy_deps_len: u32,
    system_integrations_len: u32,
    available_options_len: u32,
    extra_len: u32,

    default_step: Step.Index,
};

pub const Wip = struct {
    gpa: Allocator,
    string_table: StringTable = .empty,
    deps_table: DepsTable = .empty,
    targets_table: TargetsTable = .empty,

    string_bytes: std.ArrayList(u8) = .empty,
    unlazy_deps: std.ArrayList(String) = .empty,
    system_integrations: std.ArrayList(SystemIntegration) = .empty,
    available_options: std.ArrayList(AvailableOption) = .empty,
    steps: std.ArrayList(Step) = .empty,
    path_deps: std.MultiArrayList(Path) = .empty,
    extra: std.ArrayList(u32) = .empty,

    const DepsTable = std.HashMapUnmanaged(Deps, void, DepsTableContext, std.hash_map.default_max_load_percentage);
    const TargetsTable = std.HashMapUnmanaged(TargetQuery.Index, void, TargetsTableContext, std.hash_map.default_max_load_percentage);

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

    const TargetsTableContext = struct {
        extra: []const u32,

        pub fn eql(ctx: @This(), a: TargetQuery.Index, b: TargetQuery.Index) bool {
            const slice_a = a.extraSlice(ctx.extra);
            const slice_b = b.extraSlice(ctx.extra);
            return std.mem.eql(u32, slice_a, slice_b);
        }

        pub fn hash(ctx: @This(), key: TargetQuery.Index) u64 {
            const slice = key.extraSlice(ctx.extra);
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
        wip.system_integrations.deinit(gpa);
        wip.available_options.deinit(gpa);
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
            .system_integrations_len = @intCast(wip.system_integrations.items.len),
            .available_options_len = @intCast(wip.available_options.items.len),
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
            @ptrCast(wip.system_integrations.items),
            @ptrCast(wip.available_options.items),
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

    pub fn addSemVer(wip: *Wip, sv: std.SemanticVersion) Allocator.Error!String {
        var buffer: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        sv.format(&writer) catch return error.OutOfMemory;
        return addString(wip, writer.buffered());
    }

    pub fn addTargetQuery(wip: *Wip, q: std.Target.Query) !TargetQuery.OptionalIndex {
        if (q.isNative()) return .none;
        const gpa = wip.gpa;
        const cpu_name: ?String = switch (q.cpu_model) {
            .native, .baseline, .determined_by_arch_os => null,
            .explicit => |model| try wip.addString(model.name),
        };
        const os_version_min: ?u32 = if (q.os_version_min) |ver| switch (ver) {
            .none => null,
            .semver => |sem_ver| @intFromEnum(try wip.addSemVer(sem_ver)),
            .windows => |win_ver| @intFromEnum(win_ver),
        } else null;
        const os_version_max: ?u32 = if (q.os_version_max) |ver| switch (ver) {
            .none => null,
            .semver => |sem_ver| @intFromEnum(try wip.addSemVer(sem_ver)),
            .windows => |win_ver| @intFromEnum(win_ver),
        } else null;
        const glibc_version: ?String = if (q.glibc_version) |sem_ver| try wip.addSemVer(sem_ver) else null;
        const dynamic_linker: ?String = if (q.dynamic_linker) |*dl|
            if (dl.get()) |s| try wip.addString(s) else .empty
        else
            null;
        const cpu_features_add_empty = q.cpu_features_add.isEmpty();
        const cpu_features_sub_empty = q.cpu_features_sub.isEmpty();
        const result_index: TargetQuery.Index = @enumFromInt(try wip.addExtra(@as(TargetQuery, .{
            .flags = .{
                .cpu_arch = .init(q.cpu_arch),
                .cpu_model = .init(q.cpu_model),
                .cpu_features_add = !cpu_features_add_empty,
                .cpu_features_sub = !cpu_features_sub_empty,
                .os_tag = .init(q.os_tag),
                .abi = .init(q.abi),
                .object_format = .init(q.ofmt),
                .os_version_min = .init(q.os_version_min),
                .os_version_max = .init(q.os_version_max),
                .glibc_version = glibc_version != null,
                .android_api_level = q.android_api_level != null,
                .dynamic_linker = dynamic_linker != null,
            },
            .cpu_features_add = .{ .value = if (cpu_features_add_empty) null else q.cpu_features_add },
            .cpu_features_sub = .{ .value = if (cpu_features_sub_empty) null else q.cpu_features_sub },
            .glibc_version = .{ .value = glibc_version },
            .android_api_level = .{ .value = q.android_api_level },
            .dynamic_linker = .{ .value = dynamic_linker },
        })));
        std.log.err("TODO serialize more target query stuff", .{});
        _ = os_version_min;
        _ = os_version_max;
        _ = cpu_name;

        // Deduplicate.
        const gop = try wip.targets_table.getOrPutContext(gpa, result_index, @as(TargetsTableContext, .{
            .extra = wip.extra.items,
        }));
        if (gop.found_existing) {
            wip.extra.items.len = @intFromEnum(result_index);
            return .init(gop.key_ptr.*);
        } else {
            return .init(result_index);
        }
    }

    pub fn addTarget(wip: *Wip, t: std.Target) !TargetQuery.Index {
        const gpa = wip.gpa;
        const cpu_name: String = try wip.addString(t.cpu.model.name);

        const os_version_min: ?u32, const os_version_max: ?u32, const glibc_version: ?String, const android_api_level: ?u32 = switch (t.os.versionRange()) {
            .none => .{
                null,
                null,
                null,
                null,
            },
            .semver => |range| .{
                @intFromEnum(try wip.addSemVer(range.min)),
                @intFromEnum(try wip.addSemVer(range.max)),
                null,
                null,
            },
            .hurd => |hurd| .{
                @intFromEnum(try wip.addSemVer(hurd.range.min)),
                @intFromEnum(try wip.addSemVer(hurd.range.max)),
                try wip.addSemVer(hurd.glibc),
                null,
            },
            .linux => |linux| .{
                @intFromEnum(try wip.addSemVer(linux.range.min)),
                @intFromEnum(try wip.addSemVer(linux.range.max)),
                try wip.addSemVer(linux.glibc),
                linux.android,
            },
            .windows => |range| .{
                @intFromEnum(range.min),
                @intFromEnum(range.max),
                null,
                null,
            },
        };
        const dynamic_linker: ?String = if (t.dynamic_linker.get()) |dl| try wip.addString(dl) else null;
        const cpu_features_add_empty = t.cpu.features.isEmpty();
        const os_version: TargetQuery.OsVersion = switch (t.os.versionRange()) {
            .none => .none,
            .semver, .linux, .hurd => .semver,
            .windows => .windows,
        };
        const result_index: TargetQuery.Index = @enumFromInt(try wip.addExtra(@as(TargetQuery, .{
            .flags = .{
                .cpu_arch = .init(t.cpu.arch),
                .cpu_model = .explicit,
                .cpu_features_add = !cpu_features_add_empty,
                .cpu_features_sub = false,
                .os_tag = .init(t.os.tag),
                .abi = .init(t.abi),
                .object_format = .init(t.ofmt),
                .os_version_min = os_version,
                .os_version_max = os_version,
                .glibc_version = glibc_version != null,
                .android_api_level = android_api_level != null,
                .dynamic_linker = dynamic_linker != null,
            },
            .cpu_features_add = .{ .value = if (cpu_features_add_empty) null else t.cpu.features },
            .cpu_features_sub = .{ .value = null },
            .glibc_version = .{ .value = glibc_version },
            .android_api_level = .{ .value = android_api_level },
            .dynamic_linker = .{ .value = dynamic_linker },
        })));
        std.log.err("TODO serialize more target stuff", .{});
        _ = cpu_name;
        _ = os_version_min;
        _ = os_version_max;

        // Deduplicate.
        const gop = try wip.targets_table.getOrPutContext(gpa, result_index, @as(TargetsTableContext, .{
            .extra = wip.extra.items,
        }));
        if (gop.found_existing) {
            wip.extra.items.len = @intFromEnum(result_index);
            return gop.key_ptr.*;
        } else {
            return result_index;
        }
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
        const extra_len = Storage.calculateExtraLenUpperBound(@TypeOf(extra));
        try wip.extra.ensureUnusedCapacity(wip.gpa, extra_len);
        return addExtraAssumeCapacity(wip, extra);
    }

    pub fn addExtraAssumeCapacity(wip: *Wip, extra: anytype) u32 {
        const result: u32 = @intCast(wip.extra.items.len);
        wip.extra.items.len = Storage.setExtra(wip.extra.allocatedSlice(), result, extra);
        return result;
    }

    fn addExtraOptionalStringAssumeCapacity(wip: *Wip, optional_string: ?String) void {
        const string = optional_string orelse return;
        wip.extra.appendAssumeCapacity(@intFromEnum(string));
    }
};

pub const SystemIntegration = extern struct {
    name: String,
    status: Status,

    pub const Status = enum(u32) {
        disabled = 0,
        enabled = 1,
    };
};

pub const AvailableOption = extern struct {
    name: String,
    description: String,
    type: Type,
    /// If the `type_id` is `enum` or `enum_list` this provides the list of enum options
    enum_options: OptionalStringList,

    pub const Type = enum(u8) {
        bool,
        int,
        float,
        @"enum",
        enum_list,
        string,
        list,
        build_id,
        lazy_path,
        lazy_path_list,
    };
};

pub const Step = extern struct {
    name: String,
    owner: Package.Index,
    deps: Deps,
    max_rss: MaxRss,
    /// Points into `extra` for step-specific data. First element has flags
    /// with `Tag`.
    extra_index: u32,

    /// Points into `steps`.
    pub const Index = enum(u32) {
        _,

        pub fn ptr(i: Index, c: *const Configuration) *const Step {
            return &c.steps[@intFromEnum(i)];
        }
    };

    /// Shared by all steps.
    pub const Flags = packed struct(u32) {
        tag: Tag,
        _: u27 = 0,
    };

    pub const Tag = enum(u5) {
        check_file,
        check_object,
        compile,
        config_header,
        fail,
        fmt,
        install_artifact,
        install_dir,
        install_file,
        objcopy,
        options,
        remove_dir,
        run,
        top_level,
        translate_c,
        update_source_files,
        write_file,
    };

    pub const TopLevel = struct {
        flags: @This().Flags = .{},
        description: String,

        pub const Flags = packed struct(u32) {
            tag: Tag = .top_level,
            _: u27 = 0,
        };
    };

    pub const InstallArtifact = struct {
        flags: @This().Flags,

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
            _: u26 = 0,
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
        flags: @This().Flags,
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
                cli_rest_positionals,
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
            _: u8 = 0,
        };
    };

    /// Trailing:
    /// * exact_match: String, // if expect_errors is contains, starts_with, or stderr_contains
    /// * test_runner: LazyPath, // if test_runner_mode is not default
    pub const Compile = struct {
        flags: @This().Flags,
        flags2: Flags2,
        flags3: Flags3,
        flags4: Flags4,

        root_module: Module.Index,
        root_name: String,

        //filters: FlagLengthPrefixedList(.flags, .filters_len, String),
        //exec_cmd_args: FlagLengthPrefixedList(.flags, .exec_cmd_args_len, u32),
        //installed_headers: FlagLengthPrefixedList(.flags, .installed_headers_len, InstalledHeader),
        //force_undefined_symbols: FlagLengthPrefixedList(.flags, .force_undefined_symbols_len, String),
        //exacts: EnumConditionalPrefixedList(.flags4, .expect_errors, .exact, String),
        linker_script: Storage.FlagOptional(.flags4, .linker_script, LazyPath),
        version_script: Storage.FlagOptional(.flags4, .version_script, LazyPath),
        zig_lib_dir: Storage.FlagOptional(.flags3, .zig_lib_dir, LazyPath),
        libc_file: Storage.FlagOptional(.flags4, .libc_file, LazyPath),
        win32_manifest: Storage.FlagOptional(.flags3, .win32_manifest, LazyPath),
        win32_module_definition: Storage.FlagOptional(.flags3, .win32_module_definition, LazyPath),
        entitlements: Storage.FlagOptional(.flags4, .entitlements, LazyPath),
        version: Storage.FlagOptional(.flags3, .version, String), // semantic version string
        //entry: EnumOptional(.flags3, .entry, .symbol, String),
        install_name: Storage.FlagOptional(.flags4, .install_name, String),
        initial_memory: Storage.FlagOptional(.flags3, .initial_memory, u64),
        max_memory: Storage.FlagOptional(.flags3, .max_memory, u64),
        global_base: Storage.FlagOptional(.flags3, .global_base, u64),
        image_base: Storage.FlagOptional(.flags3, .image_base, u64),
        link_z_common_page_size: Storage.FlagOptional(.flags4, .link_z_common_page_size, u64),
        link_z_max_page_size: Storage.FlagOptional(.flags4, .link_z_max_page_size, u64),
        pagezero_size: Storage.FlagOptional(.flags4, .pagezero_size, u64),
        stack_size: Storage.FlagOptional(.flags4, .stack_size, u64),
        headerpad_size: Storage.FlagOptional(.flags4, .headerpad_size, u32),
        error_limit: Storage.FlagOptional(.flags4, .error_limit, u32),
        //build_id: EnumOptional(.flags3, .build_id, .hexstring, Hexstring),

        pub const ExpectErrors = enum(u3) { contains, exact, starts_with, stderr_contains, none };
        pub const TestRunnerMode = enum(u2) { default, simple, server };
        pub const Entry = enum(u2) { default, disabled, enabled, symbol_name };

        pub const Lto = enum(u2) {
            none,
            full,
            thin,
            default,

            pub fn init(lto: ?std.zig.LtoMode) Lto {
                return switch (lto orelse return .default) {
                    .none => .none,
                    .full => .full,
                    .thin => .thin,
                };
            }
        };

        pub const BuildId = enum(u3) {
            none,
            fast,
            uuid,
            sha1,
            md5,
            hexstring,
            default,

            pub fn init(build_id: ?std.zig.BuildId) BuildId {
                return switch (build_id orelse return .default) {
                    .none => .none,
                    .fast => .fast,
                    .uuid => .uuid,
                    .sha1 => .sha1,
                    .md5 => .md5,
                    .hexstring => .hexstring,
                };
            }
        };
        pub const WasiExecModel = enum(u2) {
            default,
            command,
            reactor,

            pub fn init(wasi_exec_model: ?std.builtin.WasiExecModel) WasiExecModel {
                return switch (wasi_exec_model orelse return .default) {
                    .command => .command,
                    .reactor => .reactor,
                };
            }
        };
        pub const Linkage = enum(u2) {
            static,
            dynamic,
            default,

            pub fn init(link_mode: ?std.builtin.LinkMode) Linkage {
                return switch (link_mode orelse return .default) {
                    .static => .static,
                    .dynamic => .dynamic,
                };
            }
        };
        pub const Kind = enum(u3) {
            exe,
            lib,
            obj,
            @"test",
            test_obj,

            pub fn isTest(kind: Kind) bool {
                return switch (kind) {
                    .exe, .lib, .obj => false,
                    .@"test", .test_obj => true,
                };
            }
        };
        pub const Subsystem = enum(u4) {
            console,
            windows,
            posix,
            native,
            efi_application,
            efi_boot_service_driver,
            efi_rom,
            efi_runtime_driver,
            default,

            pub fn init(subsystem: ?std.zig.Subsystem) Subsystem {
                return switch (subsystem orelse return .default) {
                    .console => .console,
                    .windows => .windows,
                    .posix => .posix,
                    .native => .native,
                    .efi_application => .efi_application,
                    .efi_boot_service_driver => .efi_boot_service_driver,
                    .efi_rom => .efi_rom,
                    .efi_runtime_driver => .efi_runtime_driver,
                };
            }
        };

        pub const Flags = packed struct(u32) {
            tag: Tag = .compile,

            filters_len: bool,
            exec_cmd_args_len: bool,
            installed_headers_len: bool,
            force_undefined_symbols_len: bool,

            verbose_link: bool,
            verbose_cc: bool,
            rdynamic: bool,
            import_memory: bool,
            export_memory: bool,
            import_symbols: bool,
            import_table: bool,
            export_table: bool,
            shared_memory: bool,
            link_eh_frame_hdr: bool,
            link_emit_relocs: bool,
            link_function_sections: bool,
            link_data_sections: bool,
            linker_dynamicbase: bool,
            link_z_notext: bool,
            link_z_relro: bool,
            link_z_lazy: bool,
            link_z_defs: bool,
            headerpad_max_install_names: bool,
            dead_strip_dylibs: bool,
            force_load_objc: bool,
            discard_local_symbols: bool,
            mingw_unicode_entry_point: bool,
        };

        pub const Flags2 = packed struct(u32) {
            pie: DefaultingBool,
            formatted_panics: DefaultingBool,
            bundle_compiler_rt: DefaultingBool,
            bundle_ubsan_rt: DefaultingBool,
            each_lib_rpath: DefaultingBool,
            link_gc_sections: DefaultingBool,
            linker_allow_shlib_undefined: DefaultingBool,
            linker_allow_undefined_version: DefaultingBool,
            linker_enable_new_dtags: DefaultingBool,
            dll_export_fns: DefaultingBool,
            use_llvm: DefaultingBool,
            use_lld: DefaultingBool,
            use_new_linker: DefaultingBool,
            allow_so_scripts: DefaultingBool,
            sanitize_coverage_trace_pc_guard: DefaultingBool,
            linkage: Linkage,
        };

        pub const Flags3 = packed struct(u32) {
            is_linking_libc: bool,
            is_linking_libcpp: bool,
            version: bool,
            initial_memory: bool,
            max_memory: bool,
            kind: Kind,
            compress_debug_sections: std.zig.CompressDebugSections,
            global_base: bool,
            test_runner_mode: TestRunnerMode,
            wasi_exec_model: WasiExecModel,
            win32_manifest: bool,
            win32_module_definition: bool,
            zig_lib_dir: bool,
            rc_includes: std.zig.RcIncludes,
            image_base: bool,
            build_id: BuildId,
            entry: Entry,
            lto: Lto,
            subsystem: Subsystem,
        };

        pub const Flags4 = packed struct(u32) {
            libc_file: bool,
            link_z_common_page_size: bool,
            link_z_max_page_size: bool,
            pagezero_size: bool,
            stack_size: bool,
            headerpad_size: bool,
            error_limit: bool,
            install_name: bool,
            entitlements: bool,
            expect_errors: ExpectErrors,
            linker_script: bool,
            version_script: bool,
            _: u18 = 0,
        };
    };

    pub fn flags(s: *const Step, c: *const Configuration) Flags {
        return @bitCast(c.extra[s.extra_index]);
    }
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

    pub fn unwrap(this: @This()) ?LazyPath {
        return switch (this) {
            .none => null,
            else => @enumFromInt(@intFromEnum(this)),
        };
    }
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
        owner: Package.Index,
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

pub const Package = struct {
    dep_prefix: String,
    hash: String,

    pub const Index = enum(u32) {
        root = maxInt(u32),
        _,

        pub fn depPrefixSlice(i: Index, c: *const Configuration) [:0]const u8 {
            if (i == .root) return "";
            return extraData(c, Package, @intFromEnum(i)).dep_prefix.slice(c);
        }
    };
};

/// Trailing:
/// * c_macros: LengthPrefixedList(String), // if flag is set
/// * lib_paths: LengthPrefixedList(LazyPath), // if flag is set
/// * export_symbol_names: LengthPrefixedList(String), // if flag is set
/// * frameworks: FlagsPrefixedList(FrameworkFlags), // if flag is set
/// * include_dirs: UnionList(IncludeDir), // if flag is set
/// * rpaths: UnionList(RPath), // if flag is set
/// * link_objects: UnionList(LinkObject), // if flag is set
pub const Module = struct {
    flags: Flags,
    owner: Package.Index,
    root_source_file: OptionalLazyPath,
    import_table: ImportTable,
    resolved_target: ResolvedTarget.OptionalIndex,

    pub const Optimize = enum(u3) {
        debug,
        safe,
        fast,
        small,
        default,

        pub fn init(o: ?std.builtin.OptimizeMode) Optimize {
            return switch (o orelse return .default) {
                .Debug => .debug,
                .ReleaseSafe => .safe,
                .ReleaseFast => .fast,
                .ReleaseSmall => .small,
            };
        }
    };

    pub const UnwindTables = enum(u2) {
        none,
        sync,
        async,
        default,

        pub fn init(ut: ?std.builtin.UnwindTables) UnwindTables {
            return switch (ut orelse return .default) {
                .none => .none,
                .sync => .sync,
                .async => .async,
            };
        }
    };

    pub const SanitizeC = enum(u2) {
        off,
        trap,
        full,
        default,

        pub fn init(sc: ?std.zig.SanitizeC) SanitizeC {
            return switch (sc orelse return .default) {
                .off => .off,
                .trap => .trap,
                .full => .full,
            };
        }
    };

    pub const DwarfFormat = enum(u2) {
        @"32",
        @"64",
        default,

        pub fn init(df: ?std.dwarf.Format) DwarfFormat {
            return switch (df orelse return .default) {
                .@"32" => .@"32",
                .@"64" => .@"64",
            };
        }
    };

    pub const Index = enum(u32) {
        _,
    };

    pub const Flags = packed struct(u64) {
        optimize: Optimize,
        strip: DefaultingBool,
        unwind_tables: UnwindTables,
        dwarf_format: DwarfFormat,
        single_threaded: DefaultingBool,
        stack_protector: DefaultingBool,
        stack_check: DefaultingBool,
        sanitize_c: SanitizeC,
        sanitize_thread: DefaultingBool,
        fuzz: DefaultingBool,
        code_model: std.builtin.CodeModel,
        c_macros: bool,
        include_dirs: bool,
        lib_paths: bool,
        rpaths: bool,
        frameworks: bool,
        link_objects: bool,
        export_symbol_names: bool,

        valgrind: DefaultingBool,
        pic: DefaultingBool,
        red_zone: DefaultingBool,
        omit_frame_pointer: DefaultingBool,
        error_tracing: DefaultingBool,
        link_libc: DefaultingBool,
        link_libcpp: DefaultingBool,
        no_builtin: DefaultingBool,
        _: u16 = 0,
    };

    pub const IncludeDir = union(enum(u3)) {
        path: LazyPath,
        path_system: LazyPath,
        path_after: LazyPath,
        framework_path: LazyPath,
        framework_path_system: LazyPath,
        /// Always `Step.Tag.compile`.
        other_step: Step.Index,
        /// Always `Step.Tag.config_header`.
        config_header_step: Step.Index,
        embed_path: LazyPath,
    };

    pub const RPath = union(enum(u1)) {
        lazy_path: LazyPath,
        special: String,
    };

    pub const LinkObject = union(enum(u3)) {
        static_path: LazyPath,
        /// Always `Step.Tag.compile`.
        other_step: Step.Index,
        system_lib: SystemLib,
        assembly_file: LazyPath,
        c_source_file: CSourceFile.Index,
        c_source_files: CSourceFiles.Index,
        win32_resource_file: RcSourceFile.Index,
    };

    pub const FrameworkFlags = packed struct(u2) {
        needed: bool,
        weak: bool,
    };
};

/// Points into `extra`, first element is len, then:
/// * import_name: String, // for each len
/// * Module.Index, // for each len
pub const ImportTable = enum(u32) {
    _,
};

/// Points into `extra`, where the first element is count of deps, following
/// elements is `Step.Index` per count.
pub const Deps = enum(u32) {
    _,

    pub fn slice(deps: Deps, c: *const Configuration) []Step.Index {
        const len = c.extra[@intFromEnum(deps)];
        return @ptrCast(c.extra[@intFromEnum(deps) + 1 ..][0..len]);
    }
};

/// Points into `extra`, where the first element is count of strings, following
/// elements is `String` per count.
///
/// Stored identically to `Deps`.
pub const OptionalStringList = enum(u32) {
    none = maxInt(u32),
    _,

    pub fn slice(osl: OptionalStringList, c: *const Configuration) ?[]const String {
        const len = c.extra[@intFromEnum(osl)];
        return @ptrCast(c.extra[@intFromEnum(osl) + 1 ..][0..len]);
    }
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

pub const DefaultingBool = enum(u2) {
    false,
    true,
    default,

    pub fn init(b: ?bool) DefaultingBool {
        return switch (b orelse return .default) {
            false => .false,
            true => .true,
        };
    }
};

pub const SystemLib = struct {
    name: String,
    flags: Flags,

    pub const Index = enum(u32) {
        _,
    };

    pub const UsePkgConfig = enum(u2) { no, yes, force };
    pub const LinkMode = enum { static, dynamic };

    pub const Flags = packed struct(u32) {
        needed: bool,
        weak: bool,
        use_pkg_config: UsePkgConfig,
        preferred_link_mode: LinkMode,
        search_strategy: SearchStrategy,
    };

    pub const SearchStrategy = enum(u2) { paths_first, mode_first, no_fallback };
};

/// Trailing:
/// * flag: String, // for each flags_len
/// * sub_path: String, // for each files_len
pub const CSourceFiles = struct {
    root: LazyPath,
    files_len: u32,
    flags: Flags,

    pub const Index = enum(u32) {
        _,
    };

    pub const Flags = packed struct(u32) {
        /// C compiler CLI flags.
        flags_len: u29,
        lang: OptionalCSourceLanguage,
    };
};

/// Trailing:
/// * flag: String, // for each flags_len
pub const CSourceFile = struct {
    file: LazyPath,
    flags: Flags,

    pub const Index = enum(u32) {
        _,
    };

    pub const Flags = packed struct(u32) {
        /// C compiler CLI flags.
        flags_len: u29,
        lang: OptionalCSourceLanguage,
    };
};

pub const OptionalCSourceLanguage = enum(u3) {
    c,
    cpp,
    objective_c,
    objective_cpp,
    assembly,
    assembly_with_preprocessor,
    default,
};

pub const RcSourceFile = struct {
    file: LazyPath,
    /// Any option that rc.exe accepts will work here, with the exception of:
    /// - `/fo`: The output filename is set by the build system
    /// - `/p`: Only running the preprocessor is not supported in this context
    /// - `/:no-preprocess` (non-standard option): Not supported in this context
    /// - Any MUI-related option
    /// https://learn.microsoft.com/en-us/windows/win32/menurc/using-rc-the-rc-command-line-
    ///
    /// Implicitly defined options:
    ///  /x (ignore the INCLUDE environment variable)
    ///  /D_DEBUG or /DNDEBUG depending on the optimization mode
    flags: []const []const u8 = &.{},
    /// Include paths that may or may not exist yet and therefore need to be
    /// specified as a LazyPath. Each path will be appended to the flags
    /// as `/I <resolved path>`.
    include_paths: []const LazyPath = &.{},

    pub const Index = enum(u32) {
        _,
    };
};

pub const ResolvedTarget = struct {
    /// none indicates host.
    query: TargetQuery.OptionalIndex,
    /// defaults will be resolved.
    result: TargetQuery.Index,

    pub const Index = enum(u32) {
        _,
    };

    pub const OptionalIndex = enum(u32) {
        none = maxInt(u32),
        _,
    };
};

pub const TargetQuery = struct {
    flags: Flags,

    cpu_features_add: Storage.FlagOptional(.flags, .cpu_features_add, std.Target.Cpu.Feature.Set),
    cpu_features_sub: Storage.FlagOptional(.flags, .cpu_features_sub, std.Target.Cpu.Feature.Set),
    //cpu_name: Storage.EnumOptional(.flags, .cpu_name, .explicit, String),
    //os_version_min: Storage.EnumOptional(.flags, .os_version_min, .windows, WindowsVersion),
    //os_version_min: Storage.EnumOptional(.flags, .os_version_min, .semver, String),
    //os_version_max: Storage.EnumOptional(.flags, .os_version_max, .windows, WindowsVersion),
    //os_version_max: Storage.EnumOptional(.flags, .os_version_max, .semver, String),
    glibc_version: Storage.FlagOptional(.flags, .glibc_version, String),
    android_api_level: Storage.FlagOptional(.flags, .android_api_level, u32),
    dynamic_linker: Storage.FlagOptional(.flags, .dynamic_linker, String),

    pub const Index = enum(u32) {
        _,

        pub fn extraSlice(i: Index, extra: []const u32) []const u32 {
            return extra[@intFromEnum(i)..][0..length(i, extra)];
        }

        pub fn length(i: Index, extra: []const u32) usize {
            return Storage.dataLength(extra, @intFromEnum(i), TargetQuery);
        }
    };

    pub const OptionalIndex = enum(u32) {
        none = maxInt(u32),
        _,

        pub fn init(i: Index) OptionalIndex {
            const result: OptionalIndex = @enumFromInt(@intFromEnum(i));
            assert(result != .none);
            return result;
        }
    };

    pub const CpuModel = enum(u2) {
        native,
        baseline,
        determined_by_arch_os,
        explicit,

        pub fn init(x: std.Target.Query.CpuModel) @This() {
            return switch (x) {
                .native => .native,
                .baseline => .baseline,
                .determined_by_arch_os => .determined_by_arch_os,
                .explicit => .explicit,
            };
        }
    };
    pub const OsVersion = enum(u2) {
        none,
        semver,
        windows,
        default,

        pub fn init(x: ?std.Target.Query.OsVersion) @This() {
            return switch (x orelse return .default) {
                .none => .none,
                .semver => .semver,
                .windows => .windows,
            };
        }
    };
    pub const Abi = enum(u5) {
        none,
        gnu,
        gnuabin32,
        gnuabi64,
        gnueabi,
        gnueabihf,
        gnuf32,
        gnusf,
        gnux32,
        eabi,
        eabihf,
        ilp32,
        android,
        androideabi,
        musl,
        muslabin32,
        muslabi64,
        musleabi,
        musleabihf,
        muslf32,
        muslsf,
        muslx32,
        msvc,
        itanium,
        simulator,
        ohos,
        ohoseabi,

        default,

        pub fn init(x: ?std.Target.Abi) @This() {
            // TODO comptime assert the enums match
            return @enumFromInt(@intFromEnum(x orelse return .default));
        }
    };
    pub const CpuArch = enum(u6) {
        aarch64,
        aarch64_be,
        alpha,
        amdgcn,
        arc,
        arceb,
        arm,
        armeb,
        avr,
        bpfeb,
        bpfel,
        csky,
        hexagon,
        hppa,
        hppa64,
        kalimba,
        kvx,
        lanai,
        loongarch32,
        loongarch64,
        m68k,
        microblaze,
        microblazeel,
        mips,
        mipsel,
        mips64,
        mips64el,
        msp430,
        nvptx,
        nvptx64,
        or1k,
        powerpc,
        powerpcle,
        powerpc64,
        powerpc64le,
        propeller,
        riscv32,
        riscv32be,
        riscv64,
        riscv64be,
        s390x,
        sh,
        sheb,
        sparc,
        sparc64,
        spirv32,
        spirv64,
        thumb,
        thumbeb,
        ve,
        wasm32,
        wasm64,
        x86_16,
        x86,
        x86_64,
        xcore,
        xtensa,
        xtensaeb,

        default,

        pub fn init(x: ?std.Target.Cpu.Arch) @This() {
            // TODO comptime assert the enums match
            return @enumFromInt(@intFromEnum(x orelse return .default));
        }
    };
    pub const OsTag = enum(u6) {
        freestanding,
        other,
        contiki,
        fuchsia,
        hermit,
        managarm,
        haiku,
        hurd,
        illumos,
        linux,
        plan9,
        rtems,
        serenity,
        dragonfly,
        freebsd,
        netbsd,
        openbsd,
        driverkit,
        ios,
        maccatalyst,
        macos,
        tvos,
        visionos,
        watchos,
        windows,
        uefi,
        @"3ds",
        ps3,
        ps4,
        ps5,
        vita,
        emscripten,
        wasi,
        amdhsa,
        amdpal,
        cuda,
        mesa3d,
        nvcl,
        opencl,
        opengl,
        vulkan,

        default,

        pub fn init(x: ?std.Target.Os.Tag) @This() {
            // TODO comptime assert the enums match
            return @enumFromInt(@intFromEnum(x orelse return .default));
        }
    };
    pub const ObjectFormat = enum(u4) {
        c,
        coff,
        elf,
        hex,
        macho,
        plan9,
        raw,
        spirv,
        wasm,

        default,

        pub fn init(x: ?std.Target.ObjectFormat) @This() {
            // TODO comptime assert the enums match
            return @enumFromInt(@intFromEnum(x orelse return .default));
        }
    };

    pub const Flags = packed struct(u32) {
        cpu_arch: CpuArch,
        cpu_model: CpuModel,
        cpu_features_add: bool,
        cpu_features_sub: bool,
        os_tag: OsTag,
        abi: Abi,
        object_format: ObjectFormat,
        os_version_min: OsVersion,
        os_version_max: OsVersion,
        glibc_version: bool,
        android_api_level: bool,
        dynamic_linker: bool,
    };
};

pub const Storage = enum {
    flag_optional,

    pub fn FlagOptional(
        comptime flags_arg: @EnumLiteral(),
        comptime flag_arg: @EnumLiteral(),
        comptime ValueArg: type,
    ) type {
        return struct {
            value: ?Value,

            pub const flags = flags_arg;
            pub const flag = flag_arg;
            pub const storage: Storage = .flag_optional;
            pub const Value = ValueArg;
        };
    }

    pub fn dataLength(buffer: []const u32, i: usize, comptime S: type) usize {
        var end = i;
        _ = data(buffer, &end, S);
        return end - i;
    }

    pub fn data(buffer: []const u32, i: *usize, comptime S: type) S {
        var result: S = undefined;
        const fields = @typeInfo(S).@"struct".fields;
        inline for (fields) |field| {
            @field(result, field.name) = dataField(buffer, i, &result, field.type);
        }
        return result;
    }

    fn dataField(buffer: []const u32, i: *usize, container: anytype, comptime Field: type) Field {
        switch (@typeInfo(Field)) {
            .int => |info| switch (info.bits) {
                32 => {
                    defer i.* += 1;
                    return buffer[i.*];
                },
                64 => {
                    defer i.* += 2;
                    return buffer[i.*..][0..2].*;
                },
                else => comptime unreachable,
            },
            .@"enum" => {
                defer i.* += 1;
                return @enumFromInt(buffer[i.*]);
            },
            .@"struct" => |info| switch (info.layout) {
                .@"packed" => switch (info.backing_integer.?) {
                    u32 => {
                        defer i.* += 1;
                        return @bitCast(buffer[i.*]);
                    },
                    u64 => {
                        defer i.* += 2;
                        return @bitCast(buffer[i.*..][0..2].*);
                    },
                    else => comptime unreachable,
                },
                .auto => switch (Field) {
                    std.Target.Cpu.Feature.Set => {
                        const u32_count = (Field.usize_count * @sizeOf(usize)) / @sizeOf(u32);
                        defer i.* += u32_count;
                        return .{ .ints = @as(
                            *align(@alignOf(u32)) const [Field.usize_count]usize,
                            @ptrCast(buffer[i.*..][0..u32_count]),
                        ).* };
                    },
                    else => switch (Field.storage) {
                        .flag_optional => {
                            const flags = @field(container, @tagName(Field.flags));
                            const flag = @field(flags, @tagName(Field.flag));
                            return .{
                                .value = if (flag) dataField(buffer, i, container, Field.Value) else null,
                            };
                        },
                    },
                },
                .@"extern" => comptime unreachable,
            },
            else => comptime unreachable,
        }
    }

    /// Returns new end index.
    fn setExtra(buffer: []u32, index: usize, extra: anytype) usize {
        const fields = @typeInfo(@TypeOf(extra)).@"struct".fields;
        var i = index;
        inline for (fields) |field| {
            i += setExtraField(buffer, i, field.type, @field(extra, field.name));
        }
        return i;
    }

    fn calculateExtraLenUpperBound(comptime Extra: type) comptime_int {
        var i = 0;
        const fields = @typeInfo(Extra).@"struct".fields;
        inline for (fields) |field| {
            i += calculateExtraFieldLenUpperBound(field.type);
        }
        return i;
    }

    inline fn setExtraField(buffer: []u32, i: usize, comptime Field: type, value: anytype) usize {
        switch (@typeInfo(Field)) {
            .int => |info| switch (info.bits) {
                32 => {
                    buffer[i] = value;
                    return 1;
                },
                64 => {
                    buffer[i..][0..2].* = @bitCast(value);
                    return 2;
                },
                else => comptime unreachable,
            },
            .@"enum" => {
                buffer[i] = @intFromEnum(value);
                return 1;
            },
            .@"struct" => |info| switch (info.layout) {
                .@"packed" => switch (info.backing_integer.?) {
                    u32 => {
                        buffer[i] = @bitCast(value);
                        return 1;
                    },
                    u64 => {
                        buffer[i..][0..2].* = @bitCast(value);
                        return 2;
                    },
                    else => comptime unreachable,
                },
                .auto => switch (Field) {
                    std.Target.Cpu.Feature.Set => {
                        const casted: []const u32 = @ptrCast(&value.ints);
                        @memcpy(buffer[i..][0..casted.len], casted);
                        return casted.len;
                    },
                    else => switch (Field.storage) {
                        .flag_optional => {
                            return if (value.value) |v| setExtraField(buffer, i, Field.Value, v) else 0;
                        },
                    },
                },
                .@"extern" => comptime unreachable,
            },
            else => @compileError("bad field type: " ++ @typeName(Field)),
        }
    }

    fn calculateExtraFieldLenUpperBound(comptime Field: type) comptime_int {
        return switch (@typeInfo(Field)) {
            .int => |info| switch (info.bits) {
                32 => 1,
                64 => 2,
                else => comptime unreachable,
            },
            .@"enum" => 1,
            .@"struct" => |info| switch (info.layout) {
                .@"packed" => switch (info.backing_integer.?) {
                    u32 => 1,
                    u64 => 2,
                    else => comptime unreachable,
                },
                .auto => switch (Field.storage) {
                    .flag_optional => 1,
                },
                .@"extern" => comptime unreachable,
            },
            else => comptime unreachable,
        };
    }
};

pub fn extraData(c: *const Configuration, comptime T: type, index: usize) T {
    var i: usize = index;
    return Storage.data(c.extra, &i, T);
}

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
        .system_integrations = try arena.alloc(SystemIntegration, header.system_integrations_len),
        .available_options = try arena.alloc(AvailableOption, header.available_options_len),
        .extra = try arena.alloc(u32, header.extra_len),
        .default_step = header.default_step,
    };
    var vecs = [_][]u8{
        result.string_bytes,
        @ptrCast(result.steps),
        @ptrCast(result.path_deps_base),
        @ptrCast(result.path_deps_sub),
        @ptrCast(result.unlazy_deps),
        @ptrCast(result.system_integrations),
        @ptrCast(result.available_options),
        @ptrCast(result.extra),
    };
    try reader.readVecAll(&vecs);
    return result;
}
