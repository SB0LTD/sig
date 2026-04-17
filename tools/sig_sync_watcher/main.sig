const std = @import("std");

/// Sig Sync Watcher — Cloud Run service (pure Sig, zero allocators where possible)
///
/// Listens on $PORT. On each request (Cloud Scheduler hits every ~30s):
///   1. Fetches the Codeberg RSS feed for ziglang/zig master branch
///   2. Extracts the latest commit hash from the first <link> element
///   3. Compares to the last known hash (in-memory, survives warm invocations)
///   4. If new commit detected → fires repository_dispatch to GitHub
///   5. Returns 200 with status text
///
/// Environment variables:
///   PORT              — HTTP listen port (set by Cloud Run, default 8080)
///   GITHUB_TOKEN      — Personal access token with repo scope
///   GITHUB_REPO       — e.g. "SB0LTD/sig"

// ── Configuration ────────────────────────────────────────────────────────

const rss_host = "codeberg.org";
const rss_path = "/ziglang/zig/rss/branch/master";
const github_api_host = "api.github.com";

// ── State (persists across warm invocations on Cloud Run) ────────────────

var last_known_commit: [40]u8 = .{0} ** 40;
var last_known_len: usize = 0;

// ── Helpers ──────────────────────────────────────────────────────────────

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const ptr = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(ptr, 0);
}

fn log(comptime fmt_str: []const u8, args: anytype) void {
    std.debug.print("[sig-sync-watcher] " ++ fmt_str ++ "\n", args);
}

// ── Main ─────────────────────────────────────────────────────────────────

pub fn main() !void {
    const port_str = getenv("PORT") orelse "8080";
    const port = std.fmt.parseInt(u16, port_str, 10) catch 8080;

    if (getenv("LAST_KNOWN_COMMIT")) |seed| {
        if (seed.len == 40) {
            @memcpy(&last_known_commit, seed[0..40]);
            last_known_len = 40;
        }
    }

    const address = std.net.Address.parseIp4("0.0.0.0", port) catch unreachable;
    var server = try std.net.StreamServer.init(.{
        .reuse_address = true,
    });
    defer server.deinit();

    server.listen(address) catch |err| {
        log("Failed to listen on port {d}: {s}", .{ port, @errorName(err) });
        return;
    };

    log("listening on port {d}", .{port});

    while (true) {
        const conn = server.accept() catch continue;
        defer conn.stream.close();
        handleConnection(conn.stream);
    }
}

// ── Connection Handler ───────────────────────────────────────────────────

fn handleConnection(stream: std.net.Stream) void {
    // Read the HTTP request (we don't really need to parse it)
    var req_buf: [4096]u8 = undefined;
    _ = stream.read(&req_buf) catch return;

    const github_token = getenv("GITHUB_TOKEN") orelse "";
    const github_repo = getenv("GITHUB_REPO") orelse "SB0LTD/sig";

    // 1. Fetch RSS feed
    var rss_buf: [65536]u8 = undefined;
    const rss_data = fetchRss(&rss_buf) catch |err| {
        log("RSS fetch failed: {s}", .{@errorName(err)});
        sendResponse(stream, "502 Bad Gateway", "Failed to fetch RSS feed");
        return;
    };

    // 2. Extract latest commit hash
    var hash_buf: [40]u8 = undefined;
    const latest_hash = extractLatestCommitHash(rss_data, &hash_buf) orelse {
        sendResponse(stream, "502 Bad Gateway", "Failed to parse commit hash from RSS");
        return;
    };

    // 3. Compare to last known
    if (last_known_len == 40 and std.mem.eql(u8, latest_hash, &last_known_commit)) {
        sendResponse(stream, "200 OK", "No new commits");
        return;
    }

    // 4. New commit — update state
    log("New commit: {s}", .{latest_hash});
    @memcpy(&last_known_commit, latest_hash);
    last_known_len = 40;

    // 5. Fire repository_dispatch
    if (github_token.len == 0) {
        sendResponse(stream, "200 OK", "New commit detected but no GITHUB_TOKEN set");
        return;
    }

    fireRepositoryDispatch(github_token, github_repo) catch |err| {
        log("Dispatch failed: {s}", .{@errorName(err)});
        sendResponse(stream, "502 Bad Gateway", "Failed to trigger dispatch");
        return;
    };

    sendResponse(stream, "200 OK", "Triggered sync for new commit");
}

fn sendResponse(stream: std.net.Stream, status: []const u8, body: []const u8) void {
    var buf: [1024]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, "HTTP/1.1 {s}\r\nContent-Length: {d}\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n", .{ status, body.len }) catch return;
    _ = stream.write(header) catch return;
    _ = stream.write(body) catch return;
}

// ── RSS Fetch ────────────────────────────────────────────────────────────

fn fetchRss(buf: []u8) ![]const u8 {
    return httpGet(rss_host, rss_path, null, buf);
}

// ── Commit Hash Extraction ───────────────────────────────────────────────

fn extractLatestCommitHash(rss: []const u8, out: *[40]u8) ?[]const u8 {
    // Find first <item>, then its <link>...</link>
    const item_start = std.mem.indexOf(u8, rss, "<item>") orelse return null;
    const after_item = rss[item_start..];

    const link_open = std.mem.indexOf(u8, after_item, "<link>") orelse return null;
    const content_start = link_open + 6; // len("<link>")
    const remaining = after_item[content_start..];

    const link_close = std.mem.indexOf(u8, remaining, "</link>") orelse return null;
    const link_url = remaining[0..link_close];

    // The URL ends with the 40-char commit hash
    if (link_url.len < 40) return null;
    const hash = link_url[link_url.len - 40 ..][0..40];

    for (hash) |c| {
        if (!isHex(c)) return null;
    }

    @memcpy(out, hash);
    return out;
}

fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

// ── GitHub Dispatch ──────────────────────────────────────────────────────

fn fireRepositoryDispatch(token: []const u8, repo: []const u8) !void {
    // Build path: /repos/{repo}/dispatches
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/dispatches", .{repo}) catch return error.Overflow;

    // Build auth header value
    var auth_buf: [256]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch return error.Overflow;

    const body = "{\"event_type\":\"upstream-push\"}";

    var resp_buf: [4096]u8 = undefined;
    const resp = httpPost(github_api_host, path, auth, body, &resp_buf) catch return error.ConnectionFailed;

    // Check for 2xx status in the raw response
    if (std.mem.startsWith(u8, resp, "HTTP/1.1 2") or std.mem.startsWith(u8, resp, "HTTP/1.0 2")) {
        log("repository_dispatch triggered successfully", .{});
    } else {
        const status_end = std.mem.indexOf(u8, resp, "\r\n") orelse resp.len;
        log("GitHub API unexpected response: {s}", .{resp[0..@min(status_end, 80)]});
        return error.Unexpected;
    }
}

// ── Raw HTTPS transport (TLS over TCP) ───────────────────────────────────

fn httpGet(host: []const u8, path: []const u8, auth: ?[]const u8, buf: []u8) ![]const u8 {
    var req_buf: [2048]u8 = undefined;
    var pos: usize = 0;

    pos += (std.fmt.bufPrint(req_buf[pos..], "GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: sig-sync-watcher/1.0\r\nConnection: close\r\n", .{ path, host }) catch return error.Overflow).len;
    if (auth) |a| {
        pos += (std.fmt.bufPrint(req_buf[pos..], "Authorization: {s}\r\n", .{a}) catch return error.Overflow).len;
    }
    pos += (std.fmt.bufPrint(req_buf[pos..], "\r\n", .{}) catch return error.Overflow).len;

    return tcpTlsRequest(host, req_buf[0..pos], buf);
}

fn httpPost(host: []const u8, path: []const u8, auth: []const u8, body: []const u8, buf: []u8) ![]const u8 {
    var req_buf: [4096]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "POST {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: sig-sync-watcher/1.0\r\nAuthorization: {s}\r\nAccept: application/vnd.github.v3+json\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ path, host, auth, body.len, body }) catch return error.Overflow;

    return tcpTlsRequest(host, req, buf);
}

fn tcpTlsRequest(host: []const u8, request: []const u8, buf: []u8) ![]const u8 {
    // Resolve hostname
    const list = try std.net.Address.resolveIp(host, 443);
    const addr = list;

    const sock = try std.posix.socket(addr.any.family, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);

    try std.posix.connect(sock, &addr.any, addr.getOsSockLen());

    // TLS handshake
    var tls = try std.crypto.tls.client(sock, .{
        .host = host,
    });
    defer tls.close() catch {};

    // Send request
    try tls.writeAll(request);

    // Read response
    var total: usize = 0;
    while (total < buf.len) {
        const n = tls.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    return buf[0..total];
}
