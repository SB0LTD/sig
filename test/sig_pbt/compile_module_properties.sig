// Feature: sig-compilation-engine, Property 8: Module graph construction and dependency wiring
//
// For any valid set of Module_Decl entries (no circular dependencies, all dependency
// names reference registered modules), the Compilation_Context SHALL store all modules
// with their dependency names preserved, and each module's deps should reference names
// of other registered modules.
//
// **Validates: Requirements 6.1, 6.2**

const std = @import("std");
const harness = @import("harness");
const compile_context = @import("compile_context");
const compile_types = @import("compile_types");

const Compilation_Context = compile_context.Compilation_Context;
const Module_Decl = compile_types.Module_Decl;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const MAX_TEST_MODULES = 8;
const NAME_ALPHABET = "abcdefghijklmnopqrstuvwxyz";

/// Generate a unique module name based on index, with random suffix for variety.
fn generateModuleName(random: std.Random, index: usize, buf: *[compile_types.NAME_BUF_SIZE]u8) usize {
    // Base: "mod_" + index char + random suffix (1-4 chars)
    const prefix = "mod_";
    @memcpy(buf[0..prefix.len], prefix);
    var pos: usize = prefix.len;

    // Index digit (0-9 maps to 'a'-'j' to avoid collisions)
    buf[pos] = 'a' + @as(u8, @intCast(index % 26));
    pos += 1;

    // Random suffix (1-4 alpha chars)
    const suffix_len = 1 + random.uintAtMost(usize, 3);
    var s: usize = 0;
    while (s < suffix_len) : (s += 1) {
        buf[pos] = NAME_ALPHABET[random.uintAtMost(usize, NAME_ALPHABET.len - 1)];
        pos += 1;
    }

    return pos;
}

/// Generate a random source path for a module.
fn generateSourcePath(random: std.Random, index: usize, buf: *[compile_types.PATH_BUF_SIZE]u8) usize {
    const prefix = "src/modules/module_";
    @memcpy(buf[0..prefix.len], prefix);
    var pos: usize = prefix.len;

    buf[pos] = '0' + @as(u8, @intCast(index % 10));
    pos += 1;

    // Random suffix
    const suffix_len = 1 + random.uintAtMost(usize, 3);
    var s: usize = 0;
    while (s < suffix_len) : (s += 1) {
        buf[pos] = NAME_ALPHABET[random.uintAtMost(usize, NAME_ALPHABET.len - 1)];
        pos += 1;
    }

    const ext = ".sig";
    @memcpy(buf[pos .. pos + ext.len], ext);
    pos += ext.len;

    return pos;
}

/// Compare two fixed-size name buffers by their content up to len.
fn namesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    return std.mem.eql(u8, a, b);
}

// ---------------------------------------------------------------------------
// Property 8: Module graph construction and dependency wiring
// ---------------------------------------------------------------------------

test "Property 8: random valid module DAGs are stored correctly in Compilation_Context" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate a random number of modules (1..MAX_TEST_MODULES)
            const module_count = 1 + random.uintAtMost(usize, MAX_TEST_MODULES - 1);

            // Generate module declarations (DAG: each module can only depend on earlier modules)
            var decls: [MAX_TEST_MODULES]Module_Decl = undefined;
            var names: [MAX_TEST_MODULES][compile_types.NAME_BUF_SIZE]u8 = undefined;
            var name_lens: [MAX_TEST_MODULES]usize = undefined;
            var source_paths: [MAX_TEST_MODULES][compile_types.PATH_BUF_SIZE]u8 = undefined;
            var source_path_lens: [MAX_TEST_MODULES]usize = undefined;

            var i: usize = 0;
            while (i < module_count) : (i += 1) {
                var decl: Module_Decl = .{};

                // Generate unique name
                const n_len = generateModuleName(random, i, &names[i]);
                name_lens[i] = n_len;
                @memcpy(decl.name[0..n_len], names[i][0..n_len]);
                decl.name_len = n_len;

                // Generate source path
                const sp_len = generateSourcePath(random, i, &source_paths[i]);
                source_path_lens[i] = sp_len;
                @memcpy(decl.source_path[0..sp_len], source_paths[i][0..sp_len]);
                decl.source_path_len = sp_len;

                // Generate dependencies (only reference earlier modules — ensures no cycles)
                if (i > 0) {
                    const max_deps = @min(i, compile_types.MAX_IMPORTS_PER_MODULE);
                    const dep_count = random.uintAtMost(usize, max_deps);
                    var d: usize = 0;
                    while (d < dep_count) : (d += 1) {
                        // Pick a random earlier module as dependency
                        const dep_idx = random.uintAtMost(usize, i - 1);
                        var dep_entry: Module_Decl.Dep_Entry = .{};
                        @memcpy(dep_entry.name[0..name_lens[dep_idx]], names[dep_idx][0..name_lens[dep_idx]]);
                        dep_entry.name_len = name_lens[dep_idx];
                        decl.deps[d] = dep_entry;
                    }
                    decl.dep_count = dep_count;
                }

                decls[i] = decl;
            }

            // Add all modules to a fresh Compilation_Context
            var ctx = Compilation_Context{};
            i = 0;
            while (i < module_count) : (i += 1) {
                try ctx.addModule(decls[i]);
            }

            // Verify: module_count matches
            try std.testing.expectEqual(module_count, ctx.module_count);

            // Verify: each module's name and source_path are preserved
            i = 0;
            while (i < module_count) : (i += 1) {
                const stored = ctx.modules[i];

                // Name preserved
                try std.testing.expectEqual(name_lens[i], stored.name_len);
                try std.testing.expect(
                    namesEqual(stored.name[0..stored.name_len], names[i][0..name_lens[i]]),
                );

                // Source path preserved
                try std.testing.expectEqual(source_path_lens[i], stored.source_path_len);
                try std.testing.expect(
                    namesEqual(stored.source_path[0..stored.source_path_len], source_paths[i][0..source_path_lens[i]]),
                );

                // Dep count preserved
                try std.testing.expectEqual(decls[i].dep_count, stored.dep_count);

                // Each dep name references a registered module
                var d: usize = 0;
                while (d < stored.dep_count) : (d += 1) {
                    const dep_name = stored.deps[d].name[0..stored.deps[d].name_len];

                    // Verify dep name matches what we generated
                    const orig_dep_name = decls[i].deps[d].name[0..decls[i].deps[d].name_len];
                    try std.testing.expect(namesEqual(dep_name, orig_dep_name));

                    // Verify the dep name exists among registered modules
                    var found = false;
                    var m: usize = 0;
                    while (m < module_count) : (m += 1) {
                        const mod_name = ctx.modules[m].name[0..ctx.modules[m].name_len];
                        if (namesEqual(dep_name, mod_name)) {
                            found = true;
                            break;
                        }
                    }
                    try std.testing.expect(found);
                }
            }
        }
    };
    harness.property("random valid module DAGs stored correctly", S.run);
}

test "Property 8: module data is not corrupted between slots" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Add a random number of modules and verify no cross-contamination
            const module_count = 2 + random.uintAtMost(usize, MAX_TEST_MODULES - 2);

            var ctx = Compilation_Context{};
            var expected_names: [MAX_TEST_MODULES][compile_types.NAME_BUF_SIZE]u8 = undefined;
            var expected_name_lens: [MAX_TEST_MODULES]usize = undefined;
            var expected_src: [MAX_TEST_MODULES][compile_types.PATH_BUF_SIZE]u8 = undefined;
            var expected_src_lens: [MAX_TEST_MODULES]usize = undefined;

            var i: usize = 0;
            while (i < module_count) : (i += 1) {
                var decl: Module_Decl = .{};

                // Generate distinct names
                const n_len = generateModuleName(random, i, &expected_names[i]);
                expected_name_lens[i] = n_len;
                @memcpy(decl.name[0..n_len], expected_names[i][0..n_len]);
                decl.name_len = n_len;

                // Generate distinct source paths
                const sp_len = generateSourcePath(random, i, &expected_src[i]);
                expected_src_lens[i] = sp_len;
                @memcpy(decl.source_path[0..sp_len], expected_src[i][0..sp_len]);
                decl.source_path_len = sp_len;

                try ctx.addModule(decl);
            }

            // After all modules are added, verify each slot independently
            i = 0;
            while (i < module_count) : (i += 1) {
                const stored = ctx.modules[i];

                // Verify name hasn't been overwritten by subsequent additions
                try std.testing.expectEqual(expected_name_lens[i], stored.name_len);
                try std.testing.expect(
                    namesEqual(stored.name[0..stored.name_len], expected_names[i][0..expected_name_lens[i]]),
                );

                // Verify source path hasn't been corrupted
                try std.testing.expectEqual(expected_src_lens[i], stored.source_path_len);
                try std.testing.expect(
                    namesEqual(stored.source_path[0..stored.source_path_len], expected_src[i][0..expected_src_lens[i]]),
                );
            }
        }
    };
    harness.property("module data not corrupted between slots", S.run);
}

test "Property 8: dependency names always reference registered modules in DAG" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Build a DAG where every dep is guaranteed valid (references earlier module)
            const module_count = 3 + random.uintAtMost(usize, MAX_TEST_MODULES - 3);

            var ctx = Compilation_Context{};
            var mod_names: [MAX_TEST_MODULES][compile_types.NAME_BUF_SIZE]u8 = undefined;
            var mod_name_lens: [MAX_TEST_MODULES]usize = undefined;

            var i: usize = 0;
            while (i < module_count) : (i += 1) {
                var decl: Module_Decl = .{};

                const n_len = generateModuleName(random, i, &mod_names[i]);
                mod_name_lens[i] = n_len;
                @memcpy(decl.name[0..n_len], mod_names[i][0..n_len]);
                decl.name_len = n_len;

                // Minimal source path
                const src = "src/m.sig";
                @memcpy(decl.source_path[0..src.len], src);
                decl.source_path_len = src.len;

                // Wire deps to earlier modules (ensuring valid DAG)
                if (i > 0) {
                    const max_deps = @min(i, compile_types.MAX_IMPORTS_PER_MODULE);
                    const dep_count = 1 + random.uintAtMost(usize, max_deps - 1);
                    var d: usize = 0;
                    while (d < dep_count) : (d += 1) {
                        const dep_idx = random.uintAtMost(usize, i - 1);
                        var dep_entry: Module_Decl.Dep_Entry = .{};
                        @memcpy(dep_entry.name[0..mod_name_lens[dep_idx]], mod_names[dep_idx][0..mod_name_lens[dep_idx]]);
                        dep_entry.name_len = mod_name_lens[dep_idx];
                        decl.deps[d] = dep_entry;
                    }
                    decl.dep_count = dep_count;
                }

                try ctx.addModule(decl);
            }

            // Verify every stored dependency name exists in the registered module set
            i = 0;
            while (i < ctx.module_count) : (i += 1) {
                const stored = ctx.modules[i];
                var d: usize = 0;
                while (d < stored.dep_count) : (d += 1) {
                    const dep_name = stored.deps[d].name[0..stored.deps[d].name_len];

                    // Must find this name among registered modules
                    var found = false;
                    var m: usize = 0;
                    while (m < ctx.module_count) : (m += 1) {
                        if (namesEqual(ctx.modules[m].name[0..ctx.modules[m].name_len], dep_name)) {
                            found = true;
                            break;
                        }
                    }
                    try std.testing.expect(found);

                    // Dep must reference an earlier module (DAG property: no forward refs)
                    var is_earlier = false;
                    var e: usize = 0;
                    while (e < i) : (e += 1) {
                        if (namesEqual(ctx.modules[e].name[0..ctx.modules[e].name_len], dep_name)) {
                            is_earlier = true;
                            break;
                        }
                    }
                    try std.testing.expect(is_earlier);
                }
            }
        }
    };
    harness.property("dependency names always reference registered modules", S.run);
}
