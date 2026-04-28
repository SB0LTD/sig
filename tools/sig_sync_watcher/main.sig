const std = @import("std");
const c = std.c;
const mem = std.mem;
const fmt = std.fmt;
const fd_t = std.posix.fd_t;

// libc functions not exposed by std.c
const FILE = opaque {};
extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn pclose(stream: *FILE) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *FILE) usize;

/// Sig Sync Watcher — Cloud Run service (pure Sig)
///
/// Listens on $PORT. Cloud Scheduler hits every ~30s.
/// On each request:
///   1. Fetches Codeberg RSS for ziglang/zig master → latest upstream commit
///   2. Fetches tools/sig_sync/manifest.json from sig repo → last integrated commit
///   3. If upstream is ahead → fires repository_dispatch to GitHub
///   4. Returns 200
///
/// Stateless — no in-memory state needed. Survives cold starts perfectly
/// because the source of truth is always the manifest in the repo.

// ── Helpers ──────────────────────────────────────────────────────────────

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const ptr = std.c.getenv(name) orelse return null;
    return mem.sliceTo(ptr, 0);
}

fn log(comptime f: []const u8, args: anytype) void {
    std.debug.print("[sig-sync-watcher] " ++ f ++ "\n", args);
}

// ── Main ─────────────────────────────────────────────────────────────────

pub fn main() !void {
    const port_str = getenv("PORT") orelse "8080";
    const port = fmt.parseInt(u16, port_str, 10) catch 8080;

    // Listen
    const AF_INET: c_uint = 2;
    const SOCK_STREAM: c_uint = 1;
    const SOL_SOCKET: i32 = 1;
    const SO_REUSEADDR: u32 = 2;

    const sock = c.socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return error.SocketFailed;

    var one: c_int = 1;
    _ = c.setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, @ptrCast(&one), @sizeOf(c_int));

    var addr: c.sockaddr.in = .{
        .port = mem.nativeToBig(u16, port),
        .addr = 0,
    };
    if (c.bind(sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) < 0) return error.BindFailed;
    if (c.listen(sock, 8) < 0) return error.ListenFailed;

    log("listening on port {d}", .{port});

    while (true) {
        const conn = c.accept(sock, null, null);
        if (conn < 0) continue;
        handleConnection(conn);
        _ = c.close(conn);
    }
}

// ── Connection Handler ───────────────────────────────────────────────────

fn handleConnection(conn: fd_t) void {
    var req_buf: [4096]u8 = undefined;
    _ = c.read(conn, &req_buf, req_buf.len);

    const github_token = getenv("GITHUB_TOKEN") orelse "";
    const github_repo = getenv("GITHUB_REPO") orelse "SB0LTD/sig";

    // 1. Fetch Codeberg RSS → latest upstream commit
    var rss_buf: [65536]u8 = undefined;
    const rss_len = curlGet("https://codeberg.org/ziglang/zig/rss/branch/master", null, &rss_buf) catch |err| {
        log("RSS fetch failed: {s}", .{@errorName(err)});
        sendResponse(conn, "502 Bad Gateway", "RSS fetch failed");
        return;
    };

    var upstream_hash: [40]u8 = undefined;
    const upstream = extractCommitHash(rss_buf[0..rss_len], &upstream_hash) orelse {
        sendResponse(conn, "502 Bad Gateway", "No commit hash in RSS");
        return;
    };

    // 2. Fetch manifest from sig repo → last integrated commit
    var manifest_url_buf: [256]u8 = undefined;
    const manifest_url = fmt.bufPrint(&manifest_url_buf, "https://raw.githubusercontent.com/{s}/master/tools/sig_sync/manifest.json", .{github_repo}) catch {
        sendResponse(conn, "500 Internal Server Error", "URL overflow");
        return;
    };

    var manifest_buf: [4096]u8 = undefined;
    const manifest_len = curlGet(manifest_url, null, &manifest_buf) catch |err| {
        log("manifest fetch failed: {s}", .{@errorName(err)});
        // If we can't read the manifest, trigger sync anyway — it'll sort itself out
        if (github_token.len > 0) {
            fireDispatch(github_token, github_repo) catch {};
            sendResponse(conn, "200 OK", "Triggered sync (manifest unavailable)");
        } else {
            sendResponse(conn, "200 OK", "Manifest unavailable, no token");
        }
        return;
    };

    var integrated_hash: [40]u8 = undefined;
    const integrated = extractManifestCommit(manifest_buf[0..manifest_len], &integrated_hash);

    // 3. Compare
    if (integrated) |synced| {
        // Check if upstream commit starts with the synced prefix or matches fully.
        // Manifest stores full 40-char hash; RSS also gives 40-char.
        if (mem.eql(u8, upstream, synced)) {
            sendResponse(conn, "200 OK", "Up to date");
            return;
        }
    }
    // else: no manifest or parse failure → trigger sync to be safe

    log("upstream={s} synced={s}", .{ upstream, if (integrated) |s| s else "unknown" });

    if (github_token.len == 0) {
        sendResponse(conn, "200 OK", "Upstream ahead but no GITHUB_TOKEN");
        return;
    }

    // 4. Check if a sync workflow is already running (avoid duplicate dispatches)
    if (isSyncRunning(github_token, github_repo)) {
        log("sync already in progress, skipping dispatch", .{});
        sendResponse(conn, "200 OK", "Sync already running");
        return;
    }

    // 5. Fire dispatch
    fireDispatch(github_token, github_repo) catch |err| {
        log("dispatch failed: {s}", .{@errorName(err)});
        sendResponse(conn, "502 Bad Gateway", "Dispatch failed");
        return;
    };

    sendResponse(conn, "200 OK", "Triggered sync");
}

fn sendResponse(conn: fd_t, status: []const u8, body: []const u8) void {
    var buf: [1024]u8 = undefined;
    const resp = fmt.bufPrint(&buf, "HTTP/1.1 {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, body.len, body }) catch return;
    _ = c.write(conn, resp.ptr, resp.len);
}

// ── RSS parsing ──────────────────────────────────────────────────────────

fn extractCommitHash(rss: []const u8, out: *[40]u8) ?[]const u8 {
    const item_pos = mem.indexOf(u8, rss, "<item>") orelse return null;
    const after = rss[item_pos..];
    const link_pos = mem.indexOf(u8, after, "<link>") orelse return null;
    const rest = after[link_pos + 6 ..];
    const end = mem.indexOf(u8, rest, "</link>") orelse return null;
    const url = rest[0..end];
    if (url.len < 40) return null;
    const hash = url[url.len - 40 ..][0..40];
    for (hash) |ch| {
        if (!isHexChar(ch)) return null;
    }
    @memcpy(out, hash);
    return out;
}

// ── Manifest parsing ─────────────────────────────────────────────────────

fn extractManifestCommit(json: []const u8, out: *[40]u8) ?[]const u8 {
    // Find "last_integrated_commit": "<hash>"
    const key = "\"last_integrated_commit\"";
    const key_pos = mem.indexOf(u8, json, key) orelse return null;
    const after_key = json[key_pos + key.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '\n' or after_key[i] == '\r' or after_key[i] == '\t')) : (i += 1) {}

    // Expect opening quote
    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1;

    // Read hash chars
    const start = i;
    while (i < after_key.len and after_key[i] != '"') : (i += 1) {}
    const value = after_key[start..i];

    if (value.len != 40) return null;
    for (value) |ch| {
        if (!isHexChar(ch)) return null;
    }
    @memcpy(out, value[0..40]);
    return out;
}

fn isHexChar(ch: u8) bool {
    return (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
}

// ── Check if sync is already running ─────────────────────────────────────

fn isSyncRunning(token: []const u8, repo: []const u8) bool {
    // Query GitHub Actions API for in_progress or queued runs of sig-sync
    var url_buf: [512]u8 = undefined;
    const url = fmt.bufPrint(&url_buf, "https://api.github.com/repos/{s}/actions/workflows/sig-sync.yaml/runs?status=in_progress&per_page=1", .{repo}) catch return false;

    var auth_buf: [256]u8 = undefined;
    const auth = fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch return false;

    var resp_buf: [8192]u8 = undefined;
    const resp_len = curlGet(url, auth, &resp_buf) catch return false;
    const resp = resp_buf[0..resp_len];

    // Look for "total_count": N where N > 0
    const key = "\"total_count\"";
    const key_pos = mem.indexOf(u8, resp, key) orelse return false;
    const after = resp[key_pos + key.len ..];
    var i: usize = 0;
    while (i < after.len and (after[i] == ' ' or after[i] == ':')) : (i += 1) {}
    // Parse the number
    const start = i;
    while (i < after.len and after[i] >= '0' and after[i] <= '9') : (i += 1) {}
    if (i == start) return false;
    const count = fmt.parseInt(u32, after[start..i], 10) catch return false;
    if (count > 0) return true;

    // Also check queued
    var url_buf2: [512]u8 = undefined;
    const url2 = fmt.bufPrint(&url_buf2, "https://api.github.com/repos/{s}/actions/workflows/sig-sync.yaml/runs?status=queued&per_page=1", .{repo}) catch return false;

    var resp_buf2: [8192]u8 = undefined;
    const resp_len2 = curlGet(url2, auth, &resp_buf2) catch return false;
    const resp2 = resp_buf2[0..resp_len2];

    const key_pos2 = mem.indexOf(u8, resp2, key) orelse return false;
    const after2 = resp2[key_pos2 + key.len ..];
    var j: usize = 0;
    while (j < after2.len and (after2[j] == ' ' or after2[j] == ':')) : (j += 1) {}
    const start2 = j;
    while (j < after2.len and after2[j] >= '0' and after2[j] <= '9') : (j += 1) {}
    if (j == start2) return false;
    const count2 = fmt.parseInt(u32, after2[start2..j], 10) catch return false;
    return count2 > 0;
}

// ── HTTP via curl ────────────────────────────────────────────────────────

fn curlGet(url: []const u8, auth: ?[]const u8, buf: []u8) !usize {
    var cmd_buf: [1024]u8 = undefined;
    var cmd_len: usize = 0;

    const prefix = "curl -sf";
    @memcpy(cmd_buf[cmd_len..][0..prefix.len], prefix);
    cmd_len += prefix.len;

    if (auth) |a| {
        const h1 = " -H 'Authorization: ";
        @memcpy(cmd_buf[cmd_len..][0..h1.len], h1);
        cmd_len += h1.len;
        @memcpy(cmd_buf[cmd_len..][0..a.len], a);
        cmd_len += a.len;
        cmd_buf[cmd_len] = '\'';
        cmd_len += 1;
    }

    // Always send Accept header for GitHub API compatibility
    const accept = " -H 'Accept: application/vnd.github.v3+json'";
    @memcpy(cmd_buf[cmd_len..][0..accept.len], accept);
    cmd_len += accept.len;

    // User-Agent required by GitHub API
    const ua = " -H 'User-Agent: sig-sync-watcher'";
    @memcpy(cmd_buf[cmd_len..][0..ua.len], ua);
    cmd_len += ua.len;

    cmd_buf[cmd_len] = ' ';
    cmd_len += 1;
    cmd_buf[cmd_len] = '\'';
    cmd_len += 1;
    @memcpy(cmd_buf[cmd_len..][0..url.len], url);
    cmd_len += url.len;
    cmd_buf[cmd_len] = '\'';
    cmd_len += 1;
    cmd_buf[cmd_len] = 0;

    const cmd: [*:0]const u8 = @ptrCast(cmd_buf[0..cmd_len]);
    const pipe = popen(cmd, "r") orelse return error.PipeFailed;
    defer _ = pclose(pipe);

    var total: usize = 0;
    while (total < buf.len) {
        const n = fread(buf[total..].ptr, 1, buf.len - total, pipe);
        if (n == 0) break;
        total += n;
    }
    return total;
}

fn curlPost(url: []const u8, auth: []const u8, body: []const u8) !void {
    // Don't use -f so we can capture the error response body
    var cmd_buf: [2048]u8 = undefined;
    const cmd_str = fmt.bufPrint(&cmd_buf, "curl -s -w '\\n%%{{http_code}}' -X POST -H 'Authorization: {s}' -H 'Accept: application/vnd.github+json' -A 'sig-sync-watcher/1.0' -H 'Content-Type: application/json' -d '{s}' 'https://{s}'", .{ auth, body, url }) catch return error.Overflow;
    cmd_buf[cmd_str.len] = 0;
    const cmd: [*:0]const u8 = @ptrCast(cmd_buf[0..cmd_str.len]);
    const pipe = popen(cmd, "r") orelse return error.PipeFailed;

    // Read response body + status code (last line)
    var out_buf: [4096]u8 = undefined;
    var out_len: usize = 0;
    while (out_len < out_buf.len) {
        const n = fread(out_buf[out_len..].ptr, 1, out_buf.len - out_len, pipe);
        if (n == 0) break;
        out_len += n;
    }
    _ = pclose(pipe);

    // Last 3 chars should be the HTTP status code (from -w '%{http_code}')
    if (out_len >= 3) {
        const status = out_buf[out_len - 3 .. out_len];
        if (status[0] == '2') {
            // 2xx success
            return;
        }
        // Log the error body (everything before the status code)
        const body_end = if (out_len > 4 and out_buf[out_len - 4] == '\n') out_len - 4 else out_len - 3;
        log("curl POST HTTP {s}: {s}", .{ status, out_buf[0..@min(body_end, 300)] });
        return error.HttpError;
    }
    log("curl POST: no response", .{});
    return error.HttpError;
}

// ── GitHub dispatch ──────────────────────────────────────────────────────

fn fireDispatch(token: []const u8, repo: []const u8) !void {
    // Build curl command with inline JSON body using double quotes
    // The JSON uses escaped double quotes which work inside shell double quotes
    var cmd_buf: [1024]u8 = undefined;
    var pos: usize = 0;

    const p1 = "curl -s -X POST -H 'Authorization: token ";
    @memcpy(cmd_buf[pos..][0..p1.len], p1);
    pos += p1.len;
    @memcpy(cmd_buf[pos..][0..token.len], token);
    pos += token.len;
    const p2 = "' -H 'Accept: application/vnd.github+json' -A 'sig-sync-watcher/1.0' -H 'Content-Type: application/json' -d ";
    @memcpy(cmd_buf[pos..][0..p2.len], p2);
    pos += p2.len;
    // JSON body with escaped quotes for shell: "{\"event_type\":\"upstream-push\"}"
    const json = "\"{\\\"event_type\\\":\\\"upstream-push\\\"}\"";
    @memcpy(cmd_buf[pos..][0..json.len], json);
    pos += json.len;
    const p3 = " -o /dev/null -w '%";
    @memcpy(cmd_buf[pos..][0..p3.len], p3);
    pos += p3.len;
    const p3b = "{http_code}' https://api.github.com/repos/";
    @memcpy(cmd_buf[pos..][0..p3b.len], p3b);
    pos += p3b.len;
    @memcpy(cmd_buf[pos..][0..repo.len], repo);
    pos += repo.len;
    const p4 = "/dispatches";
    @memcpy(cmd_buf[pos..][0..p4.len], p4);
    pos += p4.len;
    cmd_buf[pos] = 0;

    log("cmd: {s}", .{cmd_buf[0..pos]});

    const cmd: [*:0]const u8 = @ptrCast(cmd_buf[0..pos]);
    const pipe = popen(cmd, "r") orelse return error.PipeFailed;

    var out_buf: [16]u8 = undefined;
    var out_len: usize = 0;
    while (out_len < out_buf.len) {
        const n = fread(out_buf[out_len..].ptr, 1, out_buf.len - out_len, pipe);
        if (n == 0) break;
        out_len += n;
    }
    _ = pclose(pipe);

    if (out_len >= 3) {
        const status = out_buf[0..3];
        if (status[0] == '2') {
            log("dispatch OK (HTTP {s})", .{status});
            return;
        }
        log("dispatch HTTP {s}", .{status});
        return error.HttpError;
    }
    log("dispatch: no status (len={d})", .{out_len});
    return error.HttpError;
}
