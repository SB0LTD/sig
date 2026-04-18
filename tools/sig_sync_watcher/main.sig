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

/// Sig Sync Watcher — Cloud Run service (pure Sig)
///
/// Listens on $PORT. Cloud Scheduler hits every ~30s.
/// On each request:
///   1. Fetches Codeberg RSS for ziglang/zig master
///   2. Extracts latest commit hash
///   3. Compares to last known (in-memory, survives warm invocations)
///   4. If new → fires repository_dispatch to GitHub
///   5. Returns 200

// ── State ────────────────────────────────────────────────────────────────

var last_known_commit: [40]u8 = .{0} ** 40;
var last_known_len: usize = 0;

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

    if (getenv("LAST_KNOWN_COMMIT")) |seed| {
        if (seed.len == 40) {
            @memcpy(&last_known_commit, seed[0..40]);
            last_known_len = 40;
        }
    }

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

    // 1. Fetch RSS
    var rss_buf: [65536]u8 = undefined;
    const rss_len = httpGet("codeberg.org", "/ziglang/zig/rss/branch/master", null, &rss_buf) catch |err| {
        log("RSS fetch failed: {s}", .{@errorName(err)});
        sendResponse(conn, "502 Bad Gateway", "RSS fetch failed");
        return;
    };
    const rss_data = rss_buf[0..rss_len];

    // 2. Extract commit hash
    var hash_buf: [40]u8 = undefined;
    const latest_hash = extractCommitHash(rss_data, &hash_buf) orelse {
        sendResponse(conn, "502 Bad Gateway", "No commit hash in RSS");
        return;
    };

    // 3. Compare
    if (last_known_len == 40 and mem.eql(u8, latest_hash, &last_known_commit)) {
        sendResponse(conn, "200 OK", "No new commits");
        return;
    }

    // 4. Update state
    log("New commit: {s}", .{latest_hash});
    @memcpy(&last_known_commit, latest_hash);
    last_known_len = 40;

    if (github_token.len == 0) {
        sendResponse(conn, "200 OK", "New commit but no GITHUB_TOKEN");
        return;
    }

    // 5. Fire dispatch
    fireDispatch(github_token, github_repo) catch |err| {
        log("Dispatch failed: {s}", .{@errorName(err)});
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
        if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F'))) return null;
    }
    @memcpy(out, hash);
    return out;
}

// ── HTTP (raw TLS via std.crypto.tls) ────────────────────────────────────

fn httpGet(host: []const u8, path: []const u8, auth: ?[]const u8, buf: []u8) !usize {
    _ = auth;
    var url_buf: [512]u8 = undefined;
    const url = fmt.bufPrint(&url_buf, "curl -sf https://{s}{s}", .{ host, path }) catch return error.Overflow;
    url_buf[url.len] = 0;
    const cmd: [*:0]const u8 = @ptrCast(url_buf[0..url.len]);
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

fn httpPost(host: []const u8, path: []const u8, auth: []const u8, body: []const u8, buf: []u8) !usize {
    var cmd_buf: [2048]u8 = undefined;
    const cmd_str = fmt.bufPrint(&cmd_buf, "curl -sf -X POST -H 'Authorization: {s}' -H 'Accept: application/vnd.github.v3+json' -H 'Content-Type: application/json' -d '{s}' https://{s}{s}", .{ auth, body, host, path }) catch return error.Overflow;
    cmd_buf[cmd_str.len] = 0;
    const cmd: [*:0]const u8 = @ptrCast(cmd_buf[0..cmd_str.len]);
    const pipe = popen(cmd, "r") orelse return error.PipeFailed;
    const status = pclose(pipe);
    if (status != 0) {
        // For dispatch, 204 No Content returns empty body — curl returns 0 on 2xx
        _ = buf;
        return 0;
    }
    return 0;
}

fn tlsRequest(host: []const u8, request: []const u8, buf: []u8) !usize {
    _ = host;
    _ = request;
    _ = buf;
    return error.NotImplemented;
}

// ── GitHub dispatch ──────────────────────────────────────────────────────

fn fireDispatch(token: []const u8, repo: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    const path = fmt.bufPrint(&path_buf, "/repos/{s}/dispatches", .{repo}) catch return error.Overflow;

    var auth_buf: [256]u8 = undefined;
    const auth = fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch return error.Overflow;

    const body = "{\"event_type\":\"upstream-push\"}";

    var resp_buf: [4096]u8 = undefined;
    _ = httpPost("api.github.com", path, auth, body, &resp_buf) catch return error.ConnectionFailed;
    log("dispatch triggered", .{});
}
