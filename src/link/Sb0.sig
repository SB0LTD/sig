//! Self-hosted SB0 native linker backend.
//!
//! Emits a flat SB0X userspace image directly from ZCU machine code, with no
//! ELF/PE intermediate and no dependence on LLD. This is the self-hosted
//! counterpart to the LLD-based raw path: when compiling Sig code for
//! `aarch64-sb0` with `-ofmt=raw` on a self-hosted backend, `link.File` routes
//! here instead of hitting the old "TODO implement raw object format" panic.
//!
//! Model: this backend mirrors the incremental structure of `Elf2.sig` but
//! specialised to SB0's bounded, static, flat-load-image contract:
//!   * A single read+execute text region holds all code and read-only data.
//!   * Symbols are placed monotonically; there is no PLT/GOT/dynamic section.
//!   * AArch64 relocations are applied in-place against intra-image vaddrs.
//!   * The final container is a 64-byte SB0X header + one 40-byte RX segment
//!     descriptor + the packed payload (see `Sb0Format`).
//!
//! The on-disk byte layout is produced exclusively through `Sb0Format`, the
//! bootstrap-safe mirror of the canonical zpm module
//! `zpm/src/platform/sb0x/format.sig`, so the compiler and the zero-alloc
//! compiler cannot drift.
//!
//! Incremental parity with `Elf2` (hot-swap re-link, multi-object `loadInput`,
//! UAV/lazy dedup graphs, GOT-style indirection for very large images) is built
//! up in layers on top of this foundation.

const Sb0 = @This();

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const log = std.log.scoped(.link);
const Allocator = std.mem.Allocator;

const codegen = @import("../codegen.sig");
const Compilation = @import("../Compilation.sig");
const InternPool = @import("../InternPool.sig");
const link = @import("../link.sig");
const MappedFile = @import("MappedFile.sig");
const aarch64 = @import("aarch64.sig");
const target_util = @import("../target.sig");
const Type = @import("../Type.sig");
const Zcu = @import("../Zcu.sig");
const Sb0Format = @import("Sb0Format.sig");
const Alignment = MappedFile.Alignment;

const Error = link.Error || error{MappedFileIo};

// ── Backend state ──

base: link.File,
options: link.File.OpenOptions,
mf: MappedFile,
/// The root text region node; every symbol node is a floating child of this.
text_ni: MappedFile.Node.Index,
/// Symbol table. Index 0 is the null symbol.
syms: std.ArrayList(Symbol),
/// Maps a ZCU NAV to its symbol index.
navs: std.array_hash_map.Auto(InternPool.Nav.Index, SymIndex),
/// Maps an interned UAV value to its symbol index.
uavs: std.array_hash_map.Auto(InternPool.Index, SymIndex),
/// Maps a global/extern symbol name (owned) to its symbol index. Used for
/// references to named runtime symbols (`memcpy`, compiler-rt, panic handlers).
globals: std.StringArrayHashMapUnmanaged(SymIndex),
/// Maps a lazy symbol (compiler-generated code/data for a type) to its symbol
/// index. Lazy bodies are generated during `flush` via `genPending`.
lazy: std.array_hash_map.Auto(LazyKey, SymIndex),
/// Lazy symbols awaiting body generation in `flush`.
pending_lazy: std.ArrayList(SymIndex),
/// Pending relocations to apply during `flush`.
relocs: std.ArrayList(Reloc),
/// Symbol index of the program entry point (`_start`/root), or `.none`.
entry_sym: SymIndex.Optional,
/// Base virtual address of the text region. SB0X images are position-relative,
/// but codegen requires a concrete base for absolute references.
base_vaddr: u64,
/// When true, emit a privileged SB0K kernel image (fixed 64-byte header
/// immediately followed by the reset/entry code at offset 64) instead of an
/// SB0X userspace image (header + segment descriptor + payload). The SB0
/// artifact kind is selected by the presence of a linker script, which is how
/// a bootable/kernel image (`test/sb0_runner.ld`, defining the `.sb0k` layout)
/// is distinguished from a plain userspace image.
kernel: bool,
/// Preferred physical load base recorded in the SB0K header (0 = loader
/// chooses). Taken from the requested image base, defaulting to the SB0 boot
/// address when a kernel image is emitted without an explicit base.
preferred_physical_base: u64,

/// Stable identifier for a symbol; bitcast to/from `link.File.SymbolId`.
pub const SymIndex = enum(u32) {
    null = 0,
    _,

    pub const Optional = enum(u32) {
        none = std.math.maxInt(u32),
        _,
        pub fn unwrap(o: Optional) ?SymIndex {
            return if (o == .none) null else @enumFromInt(@intFromEnum(o));
        }
        pub fn wrap(si: SymIndex) Optional {
            return @enumFromInt(@intFromEnum(si));
        }
    };

    fn toTypeErased(si: SymIndex) link.File.SymbolId {
        return @enumFromInt(@intFromEnum(si));
    }
    fn fromTypeErased(s: link.File.SymbolId) SymIndex {
        return @enumFromInt(@intFromEnum(s));
    }
    fn ptr(si: SymIndex, sb0: *Sb0) *Symbol {
        return &sb0.syms.items[@intFromEnum(si)];
    }
    fn ptrConst(si: SymIndex, sb0: *const Sb0) *const Symbol {
        return &sb0.syms.items[@intFromEnum(si)];
    }
};

/// Identifies a compiler-generated lazy symbol by kind + type.
const LazyKey = struct {
    kind: link.File.LazySymbol.Kind,
    ty: InternPool.Index,
};

const Symbol = struct {
    /// The MappedFile node holding this symbol's bytes, or `.none` if undefined
    /// / not yet emitted.
    node: MappedFile.Node.Index.Optional = .none,
    /// Resolved virtual address (valid after layout in `flush`).
    value: u64 = 0,
    /// Size in bytes of the symbol's content.
    size: u64 = 0,
    /// Whether the symbol has a defined body (node emitted).
    defined: bool = false,
    /// Alignment requirement.
    alignment: Alignment = .@"4",
    /// For an extern/global symbol, its name (borrowed from `globals` key);
    /// `null` for local/nav/uav/lazy symbols.
    extern_name: ?[]const u8 = null,
};

/// AArch64 relocation kinds this backend resolves in-place. These map 1:1 to
/// the relocation forms aarch64 codegen requests via `addReloc`.
pub const RelocKind = enum {
    /// 26-bit PC-relative branch (BL/B), 4-byte aligned.
    branch26,
    /// ADRP page-relative high 21 bits.
    adr_prel_pg_hi21,
    /// ADD immediate low 12 bits (unscaled).
    add_abs_lo12,
    /// LDST unsigned immediate low 12 bits (scaled by access size).
    ldst_abs_lo12,
    /// 64-bit absolute address.
    abs64,
};

const Reloc = struct {
    /// The node whose bytes contain the relocation site.
    node: MappedFile.Node.Index,
    /// Offset of the relocation within `node`.
    offset: u64,
    /// Target symbol.
    target: SymIndex,
    /// Addend applied to the target address.
    addend: i64,
    kind: RelocKind,
    /// Access-size log2 for `ldst_abs_lo12` scaling (0=byte..3=dword).
    ldst_size_log2: u3 = 0,
};

// ── Lifecycle ──

pub fn open(
    arena: Allocator,
    comp: *Compilation,
    path: std.Build.Cache.Path,
    options: link.File.OpenOptions,
) !*Sb0 {
    return create(arena, comp, path, options);
}

pub fn createEmpty(
    arena: Allocator,
    comp: *Compilation,
    path: std.Build.Cache.Path,
    options: link.File.OpenOptions,
) !*Sb0 {
    return create(arena, comp, path, options);
}

fn create(
    arena: Allocator,
    comp: *Compilation,
    path: std.Build.Cache.Path,
    options: link.File.OpenOptions,
) !*Sb0 {
    const io = comp.io;
    const gpa = comp.gpa;
    const target = &comp.root_mod.resolved_target.result;
    assert(target.ofmt == .raw);
    assert(target.os.tag == .sb0);
    assert(target.cpu.arch == .aarch64);

    const sb0 = try arena.create(Sb0);
    const file = try path.root_dir.handle.createFile(io, path.sub_path, .{
        .read = true,
        .permissions = link.File.determinePermissions(comp.config.output_mode, comp.config.link_mode),
    });
    errdefer file.close(io);

    var mf: MappedFile = try .init(file, gpa, io);
    errdefer mf.deinit(gpa);

    // A single RX text region under the root. All symbol nodes are floating
    // children so the allocator packs them and reports moves for relocation.
    const text_ni = try MappedFile.Node.Index.root.addFloatingChild(&mf, gpa, .{
        .size = 0,
        .alignment = .@"16",
        .bubbles_moved = true,
    });

    sb0.* = .{
        .base = .{
            .tag = .sb0,
            .comp = comp,
            .emit = path,
            .file = file,
            .gc_sections = false,
            .print_gc_sections = false,
            .build_id = options.build_id,
            .allow_shlib_undefined = false,
            .stack_size = options.stack_size orelse Sb0Format.SB0X_DEFAULT_STACK_SIZE,
            .post_prelink = false,
            .child_pid = null,
        },
        .options = options,
        .mf = mf,
        .text_ni = text_ni,
        .syms = .empty,
        .navs = .empty,
        .uavs = .empty,
        .globals = .empty,
        .lazy = .empty,
        .pending_lazy = .empty,
        .relocs = .empty,
        .entry_sym = .none,
        .base_vaddr = 0,
        // A linker script signals a bootable/kernel artifact (see field docs);
        // its presence selects the SB0K container.
        .kernel = options.linker_script != null,
        .preferred_physical_base = options.image_base orelse
            if (options.linker_script != null) Sb0Format.SB0K_DEFAULT_PHYSICAL_BASE else 0,
    };

    // Reserve the null symbol at index 0.
    try sb0.syms.append(gpa, .{});

    return sb0;
}

pub fn deinit(sb0: *Sb0) void {
    const gpa = sb0.base.comp.gpa;
    sb0.mf.deinit(gpa);
    sb0.syms.deinit(gpa);
    sb0.navs.deinit(gpa);
    sb0.uavs.deinit(gpa);
    for (sb0.globals.keys()) |name| gpa.free(name);
    sb0.globals.deinit(gpa);
    sb0.lazy.deinit(gpa);
    sb0.pending_lazy.deinit(gpa);
    sb0.relocs.deinit(gpa);
    sb0.* = undefined;
}

// ── Symbol / node management ──

fn newSymbol(sb0: *Sb0) Allocator.Error!SymIndex {
    const gpa = sb0.base.comp.gpa;
    const idx: SymIndex = @enumFromInt(@as(u32, @intCast(sb0.syms.items.len)));
    try sb0.syms.append(gpa, .{});
    return idx;
}

fn navSymbol(sb0: *Sb0, nav_index: InternPool.Nav.Index) Allocator.Error!SymIndex {
    const gpa = sb0.base.comp.gpa;
    const gop = try sb0.navs.getOrPut(gpa, nav_index);
    if (!gop.found_existing) gop.value_ptr.* = try sb0.newSymbol();
    return gop.value_ptr.*;
}

/// Codegen-facing NAV reference resolver (parity with `Elf2.navSymbol`).
/// Returns a stable, type-erased symbol id for the given NAV, allocating one on
/// first reference.
pub fn navSymbolId(sb0: *Sb0, nav_index: InternPool.Nav.Index) link.Error!link.File.SymbolId {
    const si = try sb0.navSymbol(nav_index);
    return si.toTypeErased();
}

fn uavSymbolIndex(sb0: *Sb0, uav_val: InternPool.Index) Allocator.Error!SymIndex {
    const gpa = sb0.base.comp.gpa;
    const gop = try sb0.uavs.getOrPut(gpa, uav_val);
    if (!gop.found_existing) gop.value_ptr.* = try sb0.newSymbol();
    return gop.value_ptr.*;
}

/// Codegen-facing named global/extern symbol resolver (parity with
/// `Elf2.getGlobalSymbol`). Allocates an extern symbol on first reference; it is
/// resolved to an in-image definition during `flush` if one exists, otherwise
/// reported as an undefined symbol.
pub fn getGlobalSymbol(sb0: *Sb0, name: []const u8, lib_name: ?[]const u8) link.Error!link.File.SymbolId {
    _ = lib_name;
    const gpa = sb0.base.comp.gpa;
    const gop = try sb0.globals.getOrPut(gpa, name);
    if (!gop.found_existing) {
        const owned = try gpa.dupe(u8, name);
        gop.key_ptr.* = owned;
        const si = try sb0.newSymbol();
        si.ptr(sb0).extern_name = owned;
        gop.value_ptr.* = si;
    }
    return gop.value_ptr.*.toTypeErased();
}

/// Codegen-facing lazy-symbol resolver (parity with
/// `Elf2.getOrCreateMetadataForLazySymbol`). Allocates a symbol for the
/// compiler-generated code/data on first reference and queues body generation
/// for `flush`.
pub fn getOrCreateLazySymbol(
    sb0: *Sb0,
    lazy_sym: link.File.LazySymbol,
) link.Error!link.File.SymbolId {
    const gpa = sb0.base.comp.gpa;
    const gop = try sb0.lazy.getOrPut(gpa, .{ .kind = lazy_sym.kind, .ty = lazy_sym.ty });
    if (!gop.found_existing) {
        const si = try sb0.newSymbol();
        gop.value_ptr.* = si;
        try sb0.pending_lazy.append(gpa, si);
    }
    return gop.value_ptr.*.toTypeErased();
}

/// Ensure the given symbol has a MappedFile node to write its bytes into.
fn ensureSymbolNode(sb0: *Sb0, si: SymIndex, alignment: Alignment) Error!MappedFile.Node.Index {
    const gpa = sb0.base.comp.gpa;
    const sym = si.ptr(sb0);
    if (sym.node.unwrap()) |ni| return ni;
    const ni = try sb0.text_ni.addFloatingChild(&sb0.mf, gpa, .{
        .size = 0,
        .alignment = alignment,
        .bubbles_moved = true,
    });
    sym.node = ni.toOptional();
    sym.alignment = alignment;
    return ni;
}

fn atomForSymbol(si: SymIndex, sb0: *Sb0) link.File.AtomId {
    const ni = si.ptrConst(sb0).node.unwrap().?;
    return @enumFromInt(@intFromEnum(ni));
}

fn symbolForAtom(atom: link.File.AtomId) MappedFile.Node.Index {
    return @enumFromInt(@intFromEnum(atom));
}

// ── ZCU update entry points ──

pub fn updateFunc(
    sb0: *Sb0,
    pt: Zcu.PerThread,
    func_index: InternPool.Index,
    mir: *const codegen.AnyMir,
) link.Error!void {
    const diags = &sb0.base.comp.link_diags;
    sb0.updateFuncInner(pt, func_index, mir) catch |err| switch (err) {
        error.MappedFileIo => return diags.fail("failed to write output file: {t}", .{sb0.mf.io_err.?}),
        else => |e| return e,
    };
}

fn updateFuncInner(
    sb0: *Sb0,
    pt: Zcu.PerThread,
    func_index: InternPool.Index,
    mir: *const codegen.AnyMir,
) Error!void {
    const zcu = pt.zcu;
    const ip = &zcu.intern_pool;
    const func = zcu.funcInfo(func_index);

    const si = try sb0.navSymbol(func.owner_nav);
    const ni = try sb0.ensureSymbolNode(si, .@"16");
    sb0.resetNodeRelocs(ni);
    try ni.moved(sb0.base.comp.gpa, &sb0.mf);

    {
        var nw: MappedFile.Node.Writer = undefined;
        ni.writer(&sb0.mf, sb0.base.comp.gpa, &nw);
        defer nw.deinit();
        codegen.emitFunction(
            &sb0.base,
            pt,
            func_index,
            @enumFromInt(@intFromEnum(ni)),
            mir,
            &nw.interface,
            .none,
        ) catch |err| switch (err) {
            error.WriteFailed => return nw.err.?,
            else => |e| return e,
        };
        si.ptr(sb0).size = nw.interface.end;
        si.ptr(sb0).defined = true;
    }

    // Track the entry point: the first defined function becomes the entry
    // unless a more specific root is chosen later.
    if (sb0.entry_sym == .none) sb0.entry_sym = SymIndex.Optional.wrap(si);
    _ = ip;
}

pub fn updateNav(
    sb0: *Sb0,
    pt: Zcu.PerThread,
    nav_index: InternPool.Nav.Index,
) link.Error!void {
    const diags = &sb0.base.comp.link_diags;
    sb0.updateNavInner(pt, nav_index) catch |err| switch (err) {
        error.MappedFileIo => return diags.fail("failed to write output file: {t}", .{sb0.mf.io_err.?}),
        else => |e| return e,
    };
}

fn updateNavInner(
    sb0: *Sb0,
    pt: Zcu.PerThread,
    nav_index: InternPool.Nav.Index,
) Error!void {
    const zcu = pt.zcu;
    const ip = &zcu.intern_pool;
    const nav = ip.getNav(nav_index);
    if (ip.indexToKey(nav.resolved.?.value) == .@"extern") return;
    if (!Type.fromInterned(nav.resolved.?.type).hasRuntimeBits(zcu)) return;

    const si = try sb0.navSymbol(nav_index);
    const align_ip = nav.resolved.?.@"align";
    const alignment: Alignment = if (align_ip == .none) .@"8" else .fromIp(align_ip);
    const ni = try sb0.ensureSymbolNode(si, alignment);
    sb0.resetNodeRelocs(ni);
    try ni.moved(sb0.base.comp.gpa, &sb0.mf);

    var nw: MappedFile.Node.Writer = undefined;
    ni.writer(&sb0.mf, sb0.base.comp.gpa, &nw);
    defer nw.deinit();
    codegen.generateSymbol(
        &sb0.base,
        pt,
        .fromInterned(nav.resolved.?.value),
        &nw.interface,
        .{ .atom_index = @enumFromInt(@intFromEnum(ni)) },
    ) catch |err| switch (err) {
        error.WriteFailed => return nw.err.?,
        else => |e| return e,
    };
    si.ptr(sb0).size = nw.interface.end;
    si.ptr(sb0).defined = true;
}

pub fn updateExports(
    sb0: *Sb0,
    pt: Zcu.PerThread,
    export_indices: []const Zcu.Export.Index,
) link.Error!void {
    const zcu = pt.zcu;
    const ip = &zcu.intern_pool;
    const gpa = sb0.base.comp.gpa;

    // Register each export's name so intra-image references to that name (e.g.
    // `memcpy`, `memset`, or a program-provided runtime symbol) bind to this
    // definition. A single unified symbol index is shared between the export
    // and any global reference of the same name.
    for (export_indices) |export_index| {
        const exp = export_index.ptr(zcu);
        const target_si: SymIndex = switch (exp.exported) {
            .nav => |nav| try sb0.navSymbol(nav),
            .uav => |uav| try sb0.uavSymbolIndex(uav),
        };
        const name = exp.opts.name.toSlice(ip);

        const gop = try sb0.globals.getOrPut(gpa, name);
        if (gop.found_existing) {
            // A reference to this name already allocated a distinct extern
            // symbol; unify by pointing the global entry at the definition and
            // copying its name onto the defining symbol so `findDefinedByName`
            // resolves it.
            const ref_si = gop.value_ptr.*;
            if (ref_si != target_si) {
                target_si.ptr(sb0).extern_name = gop.key_ptr.*;
            }
        } else {
            const owned = try gpa.dupe(u8, name);
            gop.key_ptr.* = owned;
            gop.value_ptr.* = target_si;
            target_si.ptr(sb0).extern_name = owned;
        }

        // If the program exports a conventional entry symbol, use it as the
        // image entry point.
        if (std.mem.eql(u8, name, "_start") or std.mem.eql(u8, name, "sb0_entry")) {
            sb0.entry_sym = SymIndex.Optional.wrap(target_si);
        }
    }
}

// ── Relocations (called back from codegen via link.File) ──

pub fn getNavVAddr(
    sb0: *Sb0,
    pt: Zcu.PerThread,
    nav_index: InternPool.Nav.Index,
    reloc_info: link.File.RelocInfo,
) link.Error!u64 {
    _ = pt;
    const si = try sb0.navSymbol(nav_index);
    try sb0.recordReloc(reloc_info, si);
    return si.ptr(sb0).value;
}

pub fn getUavVAddr(
    sb0: *Sb0,
    uav_val: InternPool.Index,
    reloc_info: link.File.RelocInfo,
) link.Error!u64 {
    const si = try sb0.uavSymbolIndex(uav_val);
    try sb0.recordReloc(reloc_info, si);
    return si.ptr(sb0).value;
}

pub fn lowerUav(
    sb0: *Sb0,
    pt: Zcu.PerThread,
    uav_val: InternPool.Index,
    uav_align: InternPool.Alignment,
) link.Error!link.File.SymbolId {
    const si = try sb0.uavSymbolIndex(uav_val);
    if (uav_align != .none) {
        const a: Alignment = .fromIp(uav_align);
        if (a.compare(.gt, si.ptr(sb0).alignment)) si.ptr(sb0).alignment = a;
    }

    // Emit the UAV's constant bytes into the image (parity with `updateNav`).
    // Without a body the referenced rodata (string/array literals, other
    // anonymous constants) would read as zero at run time. Only generate once.
    if (si.ptr(sb0).node == .none) {
        sb0.lowerUavBody(pt, uav_val, si) catch |err| switch (err) {
            error.MappedFileIo => return sb0.base.comp.link_diags.fail(
                "failed to write output file: {t}",
                .{sb0.mf.io_err.?},
            ),
            else => |e| return e,
        };
    }
    return si.toTypeErased();
}

fn lowerUavBody(sb0: *Sb0, pt: Zcu.PerThread, uav_val: InternPool.Index, si: SymIndex) Error!void {
    const ni = try sb0.ensureSymbolNode(si, si.ptr(sb0).alignment);
    sb0.resetNodeRelocs(ni);
    try ni.moved(sb0.base.comp.gpa, &sb0.mf);

    var nw: MappedFile.Node.Writer = undefined;
    ni.writer(&sb0.mf, sb0.base.comp.gpa, &nw);
    defer nw.deinit();
    codegen.generateSymbol(
        &sb0.base,
        pt,
        .fromInterned(uav_val),
        &nw.interface,
        .{ .atom_index = @enumFromInt(@intFromEnum(ni)) },
    ) catch |err| switch (err) {
        error.WriteFailed => return nw.err.?,
        else => |e| return e,
    };
    si.ptr(sb0).size = nw.interface.end;
    si.ptr(sb0).defined = true;
}

/// Codegen-facing relocation hook (parity with `Elf2.addReloc`). The concrete
/// relocation kind is derived from the machine reloc type by the caller.
pub fn addReloc(
    sb0: *Sb0,
    atom: link.File.AtomId,
    offset: u64,
    target: link.File.SymbolId,
    addend: i64,
    kind: RelocKind,
) link.Error!void {
    const gpa = sb0.base.comp.gpa;
    try sb0.relocs.append(gpa, .{
        .node = symbolForAtom(atom),
        .offset = offset,
        .target = SymIndex.fromTypeErased(target),
        .addend = addend,
        .kind = kind,
    });
}

/// Record an LDST low-12 relocation, carrying the access-size log2 needed to
/// unscale the resolved immediate.
pub fn addLdstReloc(
    sb0: *Sb0,
    atom: link.File.AtomId,
    offset: u64,
    target: link.File.SymbolId,
    addend: i64,
    size_log2: u3,
) link.Error!void {
    const gpa = sb0.base.comp.gpa;
    try sb0.relocs.append(gpa, .{
        .node = symbolForAtom(atom),
        .offset = offset,
        .target = SymIndex.fromTypeErased(target),
        .addend = addend,
        .kind = .ldst_abs_lo12,
        .ldst_size_log2 = size_log2,
    });
}

fn recordReloc(sb0: *Sb0, reloc_info: link.File.RelocInfo, target: SymIndex) link.Error!void {
    const gpa = sb0.base.comp.gpa;
    const node = switch (reloc_info.parent) {
        .atom_index => |atom| symbolForAtom(atom),
        .none, .debug_output => return, // no in-image site to patch
    };
    try sb0.relocs.append(gpa, .{
        .node = node,
        .offset = reloc_info.offset,
        .target = target,
        .addend = @intCast(reloc_info.addend),
        .kind = .abs64,
    });
}

/// Drop all relocations whose site is `ni` (called before re-emitting a node).
fn resetNodeRelocs(sb0: *Sb0, ni: MappedFile.Node.Index) void {
    var i: usize = 0;
    while (i < sb0.relocs.items.len) {
        if (sb0.relocs.items[i].node == ni) {
            _ = sb0.relocs.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

// ── Layout + flush ──

pub fn flush(
    sb0: *Sb0,
    arena: Allocator,
    tid: Zcu.PerThread.Id,
    prog_node: std.Progress.Node,
) link.Error!void {
    const sub = prog_node.start("SB0 Flush", 0);
    defer sub.end();
    sb0.flushInner(arena, tid) catch |err| switch (err) {
        error.MappedFileIo => return sb0.base.comp.link_diags.fail(
            "failed to write output file: {t}",
            .{sb0.mf.io_err.?},
        ),
        else => |e| return e,
    };
}

/// Generate the bodies of any lazy symbols queued during codegen. Lazy symbols
/// are compiler-generated code/data (e.g. per-type helpers) whose bytes are
/// produced here via `codegen.generateLazySymbol`, mirroring `Elf2.genLazy`.
fn genPendingLazy(sb0: *Sb0, tid: Zcu.PerThread.Id) Error!void {
    if (sb0.pending_lazy.items.len == 0) return;
    const comp = sb0.base.comp;
    const gpa = comp.gpa;
    const zcu = comp.zcu.?;
    const active = zcu.activate(tid);
    defer active.deactivate();
    const pt = active.pt;

    // Draining loop: generating one lazy body may enqueue more.
    while (sb0.pending_lazy.pop()) |si| {
        const lazy_sym = lazyForSymbol(sb0, si) orelse continue;
        const ni = try sb0.ensureSymbolNode(si, .@"16");
        sb0.resetNodeRelocs(ni);
        try ni.moved(gpa, &sb0.mf);
        var alignment: InternPool.Alignment = .none;
        var nw: MappedFile.Node.Writer = undefined;
        ni.writer(&sb0.mf, gpa, &nw);
        defer nw.deinit();
        codegen.generateLazySymbol(
            &sb0.base,
            pt,
            lazy_sym,
            &alignment,
            &nw.interface,
            .none,
            .{ .atom_index = @enumFromInt(@intFromEnum(ni)) },
        ) catch |err| switch (err) {
            error.WriteFailed => return nw.err.?,
            else => |e| return e,
        };
        si.ptr(sb0).size = nw.interface.end;
        si.ptr(sb0).defined = true;
    }
}

/// Find a defined symbol whose extern name matches `name`, returning its vaddr.
/// Used to bind a referenced global to an in-image definition of the same name.
fn findDefinedByName(sb0: *Sb0, name: []const u8) ?u64 {
    for (sb0.syms.items, 0..) |*sym, i| {
        if (i == 0) continue;
        if (sym.node == .none) continue; // must be a real, body-bearing definition
        const en = sym.extern_name orelse continue;
        if (std.mem.eql(u8, en, name)) return sym.value;
    }
    return null;
}

/// Reverse-lookup the LazySymbol for a symbol index (small maps; flat images).
fn lazyForSymbol(sb0: *Sb0, si: SymIndex) ?link.File.LazySymbol {
    var it = sb0.lazy.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == si) return .{ .kind = entry.key_ptr.kind, .ty = entry.key_ptr.ty };
    }
    return null;
}

fn flushInner(sb0: *Sb0, arena: Allocator, tid: Zcu.PerThread.Id) Error!void {
    const comp = sb0.base.comp;
    const diags = &comp.link_diags;

    // 0. Generate any pending lazy-symbol bodies before layout. Extern/global
    //    symbol resolution happens after layout (step 0c) so that referenced
    //    definitions already have their final in-image addresses.
    try sb0.genPendingLazy(tid);

    // A fixed-layout SB0K kernel image is loaded at a known physical base with
    // the reset code immediately after the 64-byte header, so its symbols have
    // concrete run-time addresses: `preferred_physical_base + header + offset`.
    // Anchoring `base_vaddr` there makes in-place absolute relocations (adrp /
    // add_abs_lo12 / abs64) resolve to the correct load-time addresses. An SB0X
    // userspace image is position-relative (loader-relocated), so it keeps
    // `base_vaddr == 0`.
    if (sb0.kernel) {
        sb0.base_vaddr = sb0.preferred_physical_base + Sb0Format.SB0K_HEADER_SIZE;
    }

    // 1. Assign monotonic vaddrs to every body-bearing symbol (one with an
    //    emitted node), within the text region starting at base_vaddr. The
    //    entry symbol is placed FIRST so it sits at segment offset 0 (file
    //    offset payloadOffset(1)); the SB0X loader and the SB0 ABI expect the
    //    reset/entry vector at the start of the RX segment, and tooling reads
    //    the entry bytes at that fixed offset.
    var cursor: u64 = sb0.base_vaddr;
    var total_code: usize = 0;
    const entry_si = sb0.entry_sym.unwrap();
    if (entry_si) |esi| {
        const sym = esi.ptr(sb0);
        if (sym.node != .none) {
            cursor = sym.alignment.forward(cursor);
            sym.value = cursor;
            sym.defined = true;
            cursor += sym.size;
            total_code = @intCast(cursor - sb0.base_vaddr);
        }
    }
    for (sb0.syms.items, 0..) |*sym, i| {
        if (i == 0) continue; // null symbol
        if (sym.node == .none) continue; // extern/unresolved: no body to place
        if (entry_si) |esi| if (@intFromEnum(esi) == i) continue; // already placed first
        cursor = sym.alignment.forward(cursor);
        sym.value = cursor;
        sym.defined = true;
        cursor += sym.size;
        total_code = @intCast(cursor - sb0.base_vaddr);
    }

    // 0c. Now that definitions have final addresses, bind each referenced
    //     global/extern symbol (which has no body node of its own) to an
    //     in-image definition of the same name. A global left unresolved is a
    //     hard error: a self-contained SB0 image cannot reference it.
    for (sb0.globals.keys(), sb0.globals.values()) |name, gsi| {
        const gsym = gsi.ptr(sb0);
        if (gsym.node != .none) continue; // this global is itself a definition
        if (sb0.findDefinedByName(name)) |def_val| {
            gsym.value = def_val;
            gsym.defined = true;
        } else {
            diags.addError("undefined SB0 symbol: {s}", .{name});
        }
    }

    if (total_code == 0) {
        // Nothing to emit: produce an empty output rather than an invalid image.
        return sb0.writeImage(arena, &.{}, 0);
    }

    // 2. Gather the linearised code image from the body-bearing nodes.
    const image = try arena.alloc(u8, total_code);
    @memset(image, 0);
    for (sb0.syms.items, 0..) |*sym, i| {
        if (i == 0 or sym.node == .none) continue;
        const ni = sym.node.unwrap().?;
        const bytes = ni.sliceConst(&sb0.mf);
        const off: usize = @intCast(sym.value - sb0.base_vaddr);
        const n: usize = @intCast(sym.size);
        @memcpy(image[off..][0..n], bytes[0..n]);
    }

    // 3. Apply relocations in-place against the linearised image.
    for (sb0.relocs.items) |reloc| {
        try sb0.applyReloc(image, reloc, diags);
    }

    // 4. Resolve the entry offset within the segment.
    const entry_offset: u64 = if (sb0.entry_sym.unwrap()) |esi|
        esi.ptr(sb0).value - sb0.base_vaddr
    else
        0;

    try sb0.writeImage(arena, image, entry_offset);

    // Optional: emit a textual assembly listing (`-femit-asm`). The listing is
    // rendered from the fully-relocated linearised image so it reflects the exact
    // bytes that will execute, with one label per defined symbol.
    if (comp.emit_asm) |raw| {
        sb0.emitAsmListing(arena, tid, raw, image) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return diags.fail("failed to write asm listing: {t}", .{err}),
        };
    }
}

/// Render `-femit-asm` output: for each defined symbol, a label line followed by
/// its instructions disassembled from the relocated image (4 bytes each).
fn emitAsmListing(
    sb0: *Sb0,
    arena: Allocator,
    tid: Zcu.PerThread.Id,
    raw_path: []const u8,
    image: []const u8,
) !void {
    const comp = sb0.base.comp;
    const io = comp.io;
    const gpa = comp.gpa;

    // Resolve NAV symbol names for readable labels.
    const zcu = comp.zcu.?;
    const active = zcu.activate(tid);
    defer active.deactivate();
    const ip = &active.pt.zcu.intern_pool;

    // Reverse map: symbol index -> NAV.
    var sym_nav = std.AutoHashMap(u32, InternPool.Nav.Index).init(gpa);
    defer sym_nav.deinit();
    {
        var it = sb0.navs.iterator();
        while (it.next()) |entry| {
            try sym_nav.put(@intFromEnum(entry.value_ptr.*), entry.key_ptr.*);
        }
    }

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    try w.print("// aarch64-sb0 assembly listing (base_vaddr=0x{x})\n", .{sb0.base_vaddr});

    // Emit symbols in address order for a readable listing.
    const Entry = struct { si: usize, value: u64 };
    var order = std.ArrayList(Entry).empty;
    defer order.deinit(gpa);
    for (sb0.syms.items, 0..) |*sym, i| {
        if (i == 0 or sym.node == .none or !sym.defined) continue;
        try order.append(gpa, .{ .si = i, .value = sym.value });
    }
    std.mem.sort(Entry, order.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.value < b.value;
        }
    }.lt);

    for (order.items) |e| {
        const sym = &sb0.syms.items[e.si];
        const off: usize = @intCast(sym.value - sb0.base_vaddr);
        const n: usize = @intCast(sym.size);
        if (off + n > image.len) continue;

        // Label: extern name, else NAV fqn, else a synthesized local name.
        if (sym.extern_name) |name| {
            try w.print("\n{s}: // 0x{x}, {d} bytes\n", .{ name, sym.value, n });
        } else if (sym_nav.get(@intCast(e.si))) |nav_index| {
            try w.print("\n{f}: // 0x{x}, {d} bytes\n", .{ ip.getNav(nav_index).fqn.fmt(ip), sym.value, n });
        } else {
            try w.print("\nsym{d}: // 0x{x}, {d} bytes\n", .{ e.si, sym.value, n });
        }

        var p: usize = 0;
        while (p + 4 <= n) : (p += 4) {
            const chunk = image[off + p ..][0..4];
            const inst = aarch64.encoding.Instruction.read(chunk);
            const word = std.mem.readInt(u32, chunk, .little);
            try w.print("    0x{x:0>8}:  {x:0>8}  {f}\n", .{ sym.value + p, word, inst });
        }
    }

    const path = try comp.resolveEmitPathFlush(arena, .artifact, raw_path);
    const text = aw.written();
    const file = try path.root_dir.handle.createFile(io, path.sub_path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, text, 0);
}

fn applyReloc(sb0: *Sb0, image: []u8, reloc: Reloc, diags: anytype) Error!void {
    const target_sym = reloc.target.ptrConst(sb0);
    // Site vaddr: the node's assigned value plus the in-node offset. We locate
    // the node's owning symbol by scanning (flat images are small); this keeps
    // the reloc record independent of symbol identity for the site.
    const site_vaddr = sb0.nodeVAddr(reloc.node) + reloc.offset;
    const site_off: usize = @intCast(site_vaddr - sb0.base_vaddr);
    if (site_off + 4 > image.len and reloc.kind != .abs64) return;
    const target_vaddr: i64 = @as(i64, @intCast(target_sym.value)) + reloc.addend;

    switch (reloc.kind) {
        .branch26 => {
            const disp = target_vaddr - @as(i64, @intCast(site_vaddr));
            const disp28 = std.math.cast(i28, disp) orelse {
                sb0.overflow(diags);
                return;
            };
            aarch64.writeBranchImm(disp28, image[site_off..][0..4]);
        },
        .adr_prel_pg_hi21 => {
            const pages = aarch64.calcNumberOfPages(@intCast(site_vaddr), target_vaddr) catch {
                sb0.overflow(diags);
                return;
            };
            aarch64.writeAdrInst(pages, image[site_off..][0..4]);
        },
        .add_abs_lo12 => {
            aarch64.writeAddImmInst(@truncate(@as(u64, @bitCast(target_vaddr))), image[site_off..][0..4]);
        },
        .ldst_abs_lo12 => {
            const lo12: u12 = @truncate(@as(u64, @bitCast(target_vaddr)));
            const scaled: u12 = @intCast(lo12 >> reloc.ldst_size_log2);
            aarch64.writeLoadStoreRegInst(scaled, image[site_off..][0..4]);
        },
        .abs64 => {
            if (site_off + 8 > image.len) return;
            Sb0Format.writeU64LE(image[site_off..][0..8], @bitCast(target_vaddr));
        },
    }
}

fn overflow(sb0: *Sb0, diags: anytype) void {
    _ = sb0;
    diags.addError("SB0 relocation overflow", .{});
}

/// Virtual address of a node = base_vaddr + node file offset within the text
/// region. During flush every defined symbol node has an assigned value, so we
/// prefer that; nodes without a symbol fall back to their mapped offset.
fn nodeVAddr(sb0: *Sb0, ni: MappedFile.Node.Index) u64 {
    for (sb0.syms.items, 0..) |*sym, i| {
        if (i == 0 or !sym.defined) continue;
        if (sym.node == ni.toOptional()) return sym.value;
    }
    const off = ni.fileLocation(&sb0.mf, false).offset;
    return sb0.base_vaddr + off;
}

/// Write the final SB0 container to the output file, replacing the incremental
/// mapped-file content.
///
/// Two container kinds share this bounded, self-hosted emitter (never a foreign
/// intermediate), selected by `sb0.kernel`:
///
///   * SB0X (userspace): a 64-byte SB0X header, one 40-byte RX segment
///     descriptor, then the payload. `entry_offset` is relative to the segment.
///   * SB0K (kernel/bootable): a fixed 64-byte SB0K header immediately followed
///     by the reset/entry code (which the linker placed first, so the entry is
///     at image offset `SB0K_HEADER_SIZE`). There is no segment table; the whole
///     file is the load image. `entry_offset`/`total_image_bytes` are absolute.
fn writeImage(sb0: *Sb0, arena: Allocator, code: []const u8, entry_offset: u64) Error!void {
    const comp = sb0.base.comp;
    const io = comp.io;
    const diags = &comp.link_diags;

    const out = if (sb0.kernel) out: {
        const header = Sb0Format.SB0K_HEADER_SIZE;
        const total = header + code.len;
        const out = try arena.alloc(u8, total);
        // The reset/entry code sits immediately after the header. The entry
        // symbol is placed first during flush, so its in-code offset is 0 and
        // the absolute entry offset is exactly the header size.
        _ = Sb0Format.encodeKernelHeader(out, .{
            .entry_offset = header + entry_offset,
            .total_image_bytes = @intCast(total),
            .preferred_physical_base = sb0.preferred_physical_base,
        });
        if (code.len != 0) @memcpy(out[header..][0..code.len], code);
        break :out out;
    } else out: {
        const total = Sb0Format.payloadOffset(1) + code.len;
        const out = try arena.alloc(u8, total);
        _ = Sb0Format.encodeHeader(out, .{
            .entry_offset = entry_offset,
            .segment_count = 1,
            .image_size = Sb0Format.alignForward(@intCast(total), Sb0Format.SB0X_PAGE_SIZE),
            .stack_size = sb0.base.stack_size,
        });
        const meta = Sb0Format.payloadOffset(1);
        _ = Sb0Format.encodeSegment(out[Sb0Format.SB0X_HEADER_SIZE..], .{
            .file_offset = @intCast(meta),
            .vaddr_offset = 0,
            .file_size = @intCast(code.len),
            .mem_size = Sb0Format.alignForward(@intCast(code.len), Sb0Format.SB0X_PAGE_SIZE),
            .flags = Sb0Format.SEG_RX,
        });
        if (code.len != 0) @memcpy(out[meta..][0..code.len], code);
        break :out out;
    };

    // The MappedFile keeps the output memory-mapped for incremental writes.
    // Release the mapping before rewriting the file as the final flat SB0
    // container, otherwise resizing the still-mapped file fails (e.g. Windows
    // returns AccessDenied when truncating a mapped file).
    sb0.mf.unmap();

    const file = sb0.base.file.?;
    file.setLength(io, out.len) catch |err|
        return diags.fail("failed to set SB0 image length: {t}", .{err});
    file.writePositionalAll(io, out, 0) catch |err|
        return diags.fail("failed to write SB0 image: {t}", .{err});
}

// ── No-op / trivial hooks required by link.File ──

pub fn prelink(sb0: *Sb0, prog_node: std.Progress.Node) link.Error!void {
    _ = sb0;
    _ = prog_node;
}

pub fn updateLineNumber(sb0: *Sb0, pt: Zcu.PerThread, ti_id: InternPool.TrackedInst.Index) link.Error!void {
    _ = sb0;
    _ = pt;
    _ = ti_id;
}

pub fn loadInput(sb0: *Sb0, input: link.File.Input) anyerror!void {
    _ = sb0;
    _ = input;
}
