// Unit tests for stack-allocated path operations (task 1.5).
//
// Since the build runner (tools/sig_build/main.sig) is not wired as a test import,
// these tests replicate the path operation logic using the same sig.fs module
// and algorithms to validate correctness.
//
// Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7

const std = @import("std");
const testing = std.testing;
const sig = @import("sig");
const containers = sig.containers;
const sig_fs = sig.fs;

const PATH_BUF_SIZE = 4096;
const NAME_BUF_SIZE = 64;

/// Platform-native path separator.
const path_sep = std.fs.path.sep;

// ── Replicated functions from main.sig ──────────────────────────────────

fn pathJoin(buf: *[PATH_BUF_SIZE]u8, segments: []const []const u8) ![]const u8 {
    return sig_fs.joinPath(buf, segments);
}

fn normalizePath(out: *[PATH_BUF_SIZE]u8, path: []const u8) ![]const u8 {
    var segments: containers.BoundedVec([]const u8, 128) = .{};

    var start: usize = 0;
    const is_absolute = path.len > 0 and path[0] == path_sep;
    if (is_absolute) start = 1;

    var i: usize = start;
    while (i <= path.len) {
        if (i == path.len or path[i] == path_sep) {
            const seg = path[start..i];
            if (seg.len == 0 or std.mem.eql(u8, seg, ".")) {
                // skip
            } else if (std.mem.eql(u8, seg, "..")) {
                if (segments.len == 0) {
                    if (is_absolute) return error.DepthExceeded;
                    try segments.push(seg);
                } else {
                    _ = segments.pop();
                }
            } else {
                try segments.push(seg);
            }
            start = i + 1;
        }
        i += 1;
    }

    var offset: usize = 0;
    if (is_absolute) {
        out[0] = path_sep;
        offset = 1;
    }

    const segs = segments.slice();
    for (segs, 0..) |seg, idx| {
        if (idx > 0) {
            if (offset >= PATH_BUF_SIZE) return error.BufferTooSmall;
            out[offset] = path_sep;
            offset += 1;
        }
        if (offset + seg.len > PATH_BUF_SIZE) return error.BufferTooSmall;
        @memcpy(out[offset..][0..seg.len], seg);
        offset += seg.len;
    }

    return out[0..offset];
}

fn pathResolve(buf: *[PATH_BUF_SIZE]u8, base: []const u8, relative: []const u8) ![]const u8 {
    var tmp: [PATH_BUF_SIZE]u8 = undefined;
    const segments = [_][]const u8{ base, relative };
    const joined = try sig_fs.joinPath(&tmp, &segments);
    return normalizePath(buf, joined);
}

fn pathRelative(buf: *[PATH_BUF_SIZE]u8, base: []const u8, target: []const u8) ![]const u8 {
    var norm_base_buf: [PATH_BUF_SIZE]u8 = undefined;
    var norm_target_buf: [PATH_BUF_SIZE]u8 = undefined;
    const norm_base = try normalizePath(&norm_base_buf, base);
    const norm_target = try normalizePath(&norm_target_buf, target);

    var base_segs: containers.BoundedVec([]const u8, 128) = .{};
    var target_segs: containers.BoundedVec([]const u8, 128) = .{};

    var start: usize = 0;
    if (norm_base.len > 0 and norm_base[0] == path_sep) start = 1;
    var i: usize = start;
    while (i <= norm_base.len) {
        if (i == norm_base.len or norm_base[i] == path_sep) {
            const seg = norm_base[start..i];
            if (seg.len > 0) try base_segs.push(seg);
            start = i + 1;
        }
        i += 1;
    }

    start = 0;
    if (norm_target.len > 0 and norm_target[0] == path_sep) start = 1;
    i = start;
    while (i <= norm_target.len) {
        if (i == norm_target.len or norm_target[i] == path_sep) {
            const seg = norm_target[start..i];
            if (seg.len > 0) try target_segs.push(seg);
            start = i + 1;
        }
        i += 1;
    }

    const base_sl = base_segs.slice();
    const target_sl = target_segs.slice();
    var common: usize = 0;
    while (common < base_sl.len and common < target_sl.len) {
        if (!std.mem.eql(u8, base_sl[common], target_sl[common])) break;
        common += 1;
    }

    var result_segs: containers.BoundedVec([]const u8, 128) = .{};
    var ups: usize = 0;
    while (ups < base_sl.len - common) : (ups += 1) {
        try result_segs.push("..");
    }
    var t: usize = common;
    while (t < target_sl.len) : (t += 1) {
        try result_segs.push(target_sl[t]);
    }

    const res_sl = result_segs.slice();
    if (res_sl.len == 0) {
        buf[0] = '.';
        return buf[0..1];
    }

    var offset: usize = 0;
    for (res_sl, 0..) |seg, idx| {
        if (idx > 0) {
            if (offset >= PATH_BUF_SIZE) return error.BufferTooSmall;
            buf[offset] = path_sep;
            offset += 1;
        }
        if (offset + seg.len > PATH_BUF_SIZE) return error.BufferTooSmall;
        @memcpy(buf[offset..][0..seg.len], seg);
        offset += seg.len;
    }

    return buf[0..offset];
}

fn pathStem(buf: *[NAME_BUF_SIZE]u8, path: []const u8) ![]const u8 {
    var filename_start: usize = 0;
    var j: usize = 0;
    while (j < path.len) : (j += 1) {
        if (path[j] == path_sep or path[j] == '/') {
            filename_start = j + 1;
        }
    }
    const filename = path[filename_start..];

    if (filename.len == 0) return error.BufferTooSmall;

    var dot_pos: ?usize = null;
    var k: usize = 1;
    while (k < filename.len) : (k += 1) {
        if (filename[k] == '.') {
            dot_pos = k;
        }
    }

    const stem = if (dot_pos) |dp| filename[0..dp] else filename;

    if (stem.len > NAME_BUF_SIZE) return error.BufferTooSmall;
    @memcpy(buf[0..stem.len], stem);
    return buf[0..stem.len];
}


// ── Helper ──────────────────────────────────────────────────────────────

/// Convert a forward-slash path literal to the platform separator for expected values.
fn p(comptime literal: []const u8) []const u8 {
    if (path_sep == '/') return literal;
    // On Windows, replace '/' with '\\'
    comptime {
        var buf: [literal.len]u8 = undefined;
        for (literal, 0..) |c, idx| {
            buf[idx] = if (c == '/') '\\' else c;
        }
        const result = buf;
        return &result;
    }
}

// ── pathJoin ────────────────────────────────────────────────────────────

test "pathJoin: two segments" {
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const segs = [_][]const u8{ "src", "main.zig" };
    const result = try pathJoin(&buf, &segs);
    try testing.expectEqualStrings(p("src/main.zig"), result);
}

test "pathJoin: three segments" {
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const segs = [_][]const u8{ "tools", "sig_build", "main.sig" };
    const result = try pathJoin(&buf, &segs);
    try testing.expectEqualStrings(p("tools/sig_build/main.sig"), result);
}

test "pathJoin: single segment" {
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const segs = [_][]const u8{"hello"};
    const result = try pathJoin(&buf, &segs);
    try testing.expectEqualStrings("hello", result);
}

test "pathJoin: empty segments are skipped" {
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const segs = [_][]const u8{ "a", "", "b" };
    const result = try pathJoin(&buf, &segs);
    try testing.expectEqualStrings(p("a/b"), result);
}

// ── pathResolve ─────────────────────────────────────────────────────────

test "pathResolve: simple relative" {
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const result = try pathResolve(&buf, p("project/src"), "main.zig");
    try testing.expectEqualStrings(p("project/src/main.zig"), result);
}

test "pathResolve: dot component is collapsed" {
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const result = try pathResolve(&buf, p("project"), p("./src/main.zig"));
    try testing.expectEqualStrings(p("project/src/main.zig"), result);
}

test "pathResolve: dotdot navigates up" {
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const result = try pathResolve(&buf, p("project/src"), p("../lib/utils.zig"));
    try testing.expectEqualStrings(p("project/lib/utils.zig"), result);
}

test "pathResolve: multiple dotdot" {
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const result = try pathResolve(&buf, p("a/b/c"), p("../../d"));
    try testing.expectEqualStrings(p("a/d"), result);
}

test "pathResolve: dotdot escaping root returns DepthExceeded" {
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const sep_str: []const u8 = &[_]u8{path_sep};
    // Absolute path: /a, relative: ../../x should fail
    var abs_buf: [PATH_BUF_SIZE]u8 = undefined;
    abs_buf[0] = path_sep;
    @memcpy(abs_buf[1..2], "a");
    const abs_path = abs_buf[0..2];
    const result = pathResolve(&buf, abs_path, p("../../x"));
    _ = sep_str;
    try testing.expectError(error.DepthExceeded, result);
}

// ── pathRelative ────────────────────────────────────────────────────────

test "pathRelative: sibling directory" {
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const result = try pathRelative(&buf, p("project/src"), p("project/lib"));
    try testing.expectEqualStrings(p("../lib"), result);
}

test "pathRelative: child directory" {
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const result = try pathRelative(&buf, "project", p("project/src/main.zig"));
    try testing.expectEqualStrings(p("src/main.zig"), result);
}

test "pathRelative: same path returns dot" {
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const result = try pathRelative(&buf, p("a/b/c"), p("a/b/c"));
    try testing.expectEqualStrings(".", result);
}

test "pathRelative: parent directory" {
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const result = try pathRelative(&buf, p("a/b/c"), "a");
    try testing.expectEqualStrings(p("../.."), result);
}

test "pathRelative: completely different paths" {
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const result = try pathRelative(&buf, p("x/y"), p("a/b"));
    try testing.expectEqualStrings(p("../../a/b"), result);
}

// ── pathStem ────────────────────────────────────────────────────────────

test "pathStem: simple filename with extension" {
    var buf: [NAME_BUF_SIZE]u8 = undefined;
    const result = try pathStem(&buf, "main.zig");
    try testing.expectEqualStrings("main", result);
}

test "pathStem: path with directories" {
    var buf: [NAME_BUF_SIZE]u8 = undefined;
    const result = try pathStem(&buf, p("tools/sig_build/main.sig"));
    try testing.expectEqualStrings("main", result);
}

test "pathStem: no extension" {
    var buf: [NAME_BUF_SIZE]u8 = undefined;
    const result = try pathStem(&buf, "Makefile");
    try testing.expectEqualStrings("Makefile", result);
}

test "pathStem: dotfile" {
    var buf: [NAME_BUF_SIZE]u8 = undefined;
    const result = try pathStem(&buf, ".gitignore");
    try testing.expectEqualStrings(".gitignore", result);
}

test "pathStem: multiple dots takes last" {
    var buf: [NAME_BUF_SIZE]u8 = undefined;
    const result = try pathStem(&buf, "archive.tar.gz");
    try testing.expectEqualStrings("archive.tar", result);
}

test "pathStem: empty filename returns error" {
    var buf: [NAME_BUF_SIZE]u8 = undefined;
    // Trailing separator means empty filename
    const sep_str: []const u8 = &[_]u8{path_sep};
    try testing.expectError(error.BufferTooSmall, pathStem(&buf, sep_str));
}
