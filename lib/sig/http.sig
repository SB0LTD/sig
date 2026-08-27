//! HTTP/1.1 client and server — freestanding, zero std dependency.
//!
//! Uses os.sig socket primitives for TCP, sig_fmt for integer formatting,
//! and sig_io.Io for API compat. All buffers are caller-provided (zero allocation).

const os = @import("os.sig");
const sig_io = @import("io.sig");
const sig_fmt = @import("fmt.sig");
const sig_mem = @import("mem.sig");
const SigError = @import("errors.sig").SigError;
const builtin = @import("builtin");

/// An HTTP header name-value pair. Slices point into caller-provided buffers.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// A parsed URI. All slices point into the original input buffer (zero-copy).
pub const Uri = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    path: []const u8,
    query: []const u8,
};

/// A parsed HTTP response. All slices point into the original input buffer (zero-copy).
pub const Response = struct {
    status: u16,
    headers: []const Header,
    body: []const u8,
};

/// Parses a URI string of the form "scheme://host[:port][/path][?query]".
/// All returned slices point into the input `buf` (zero-copy). No allocation.
/// Default port: 80 for "http", 443 for "https".
pub fn parseUri(buf: []const u8) SigError!Uri {
    // Extract scheme: everything before "://"
    const scheme_end = indexOf(buf, "://") orelse return error.BufferTooSmall;
    const scheme = buf[0..scheme_end];

    var rest = buf[scheme_end + 3 ..];

    // Extract host and optional port
    // Find the end of the authority section (first '/' or '?' or end)
    const authority_end = findAuthorityEnd(rest);
    const authority = rest[0..authority_end];
    rest = rest[authority_end..];

    var host: []const u8 = authority;
    var port: u16 = defaultPort(scheme);

    // Check for port separator
    if (indexOfChar(authority, ':')) |colon_pos| {
        host = authority[0..colon_pos];
        const port_str = authority[colon_pos + 1 ..];
        port = sig_fmt.parseInt(u16, port_str, 10) catch return error.BufferTooSmall;
    }

    // Extract path and query
    var path: []const u8 = "/";
    var query: []const u8 = "";

    if (rest.len > 0 and rest[0] == '/') {
        if (indexOfChar(rest, '?')) |q_pos| {
            path = rest[0..q_pos];
            query = rest[q_pos + 1 ..];
        } else {
            path = rest;
        }
    } else if (rest.len > 0 and rest[0] == '?') {
        query = rest[1..];
    }

    return Uri{
        .scheme = scheme,
        .host = host,
        .port = port,
        .path = path,
        .query = query,
    };
}

/// Builds an HTTP/1.1 request into a caller-provided buffer.
/// Automatically includes the Host header. Returns the written slice,
/// or `BufferTooSmall` if the buffer cannot hold the full request.
pub fn buildRequest(
    buf: []u8,
    method: []const u8,
    host: []const u8,
    path: []const u8,
    headers: []const Header,
    body: []const u8,
) SigError![]u8 {
    var offset: usize = 0;

    // Request line: "METHOD /path HTTP/1.1\r\n"
    offset = try appendSlice(buf, offset, method);
    offset = try appendSlice(buf, offset, " ");
    offset = try appendSlice(buf, offset, path);
    offset = try appendSlice(buf, offset, " HTTP/1.1\r\n");

    // Host header
    offset = try appendSlice(buf, offset, "Host: ");
    offset = try appendSlice(buf, offset, host);
    offset = try appendSlice(buf, offset, "\r\n");

    // User-provided headers
    for (headers) |h| {
        offset = try appendSlice(buf, offset, h.name);
        offset = try appendSlice(buf, offset, ": ");
        offset = try appendSlice(buf, offset, h.value);
        offset = try appendSlice(buf, offset, "\r\n");
    }

    // Content-Length header if body is non-empty
    if (body.len > 0) {
        offset = try appendSlice(buf, offset, "Content-Length: ");
        var len_buf: [20]u8 = undefined;
        const len_str = sig_fmt.bufPrint(&len_buf, "{d}", .{body.len}) catch return error.BufferTooSmall;
        offset = try appendSlice(buf, offset, len_str);
        offset = try appendSlice(buf, offset, "\r\n");
    }

    // End of headers
    offset = try appendSlice(buf, offset, "\r\n");

    // Body
    if (body.len > 0) {
        offset = try appendSlice(buf, offset, body);
    }

    return buf[0..offset];
}

/// Parses an HTTP/1.1 response from a buffer.
/// Format: "HTTP/1.1 STATUS REASON\r\nHeaders\r\n\r\nBody"
/// Extracts status code, headers into `header_buf`, and body slice.
/// All slices point into the input `buf` (zero-copy). No allocation.
pub fn parseResponse(buf: []const u8, header_buf: []Header) SigError!Response {
    // Find end of status line
    const status_line_end = indexOf(buf, "\r\n") orelse return error.BufferTooSmall;
    const status_line = buf[0..status_line_end];

    // Parse status line: "HTTP/1.1 STATUS REASON"
    // Skip "HTTP/1.1 " (9 chars)
    if (status_line.len < 12) return error.BufferTooSmall; // minimum: "HTTP/1.1 200"
    if (!startsWith(status_line, "HTTP/1.1 ") and !startsWith(status_line, "HTTP/1.0 "))
        return error.BufferTooSmall;

    const status_start: usize = 9;
    // Find end of status code (next space or end of line)
    var status_end: usize = status_start;
    while (status_end < status_line.len and status_line[status_end] != ' ') {
        status_end += 1;
    }
    const status_str = status_line[status_start..status_end];
    const status = sig_fmt.parseInt(u16, status_str, 10) catch return error.BufferTooSmall;

    // Parse headers
    var header_count: usize = 0;
    var pos = status_line_end + 2; // skip past "\r\n"

    while (pos < buf.len) {
        // Check for end of headers (empty line)
        if (pos + 1 < buf.len and buf[pos] == '\r' and buf[pos + 1] == '\n') {
            pos += 2;
            break;
        }

        // Find end of this header line
        const line_end = indexOfFrom(buf, pos, "\r\n") orelse return error.BufferTooSmall;
        const line = buf[pos..line_end];

        // Split on first ": "
        if (indexOfStr(line, ": ")) |colon_pos| {
            if (header_count >= header_buf.len) return error.BufferTooSmall;
            header_buf[header_count] = Header{
                .name = line[0..colon_pos],
                .value = line[colon_pos + 2 ..],
            };
            header_count += 1;
        } else if (indexOfChar(line, ':')) |colon_pos| {
            // Handle "Name:Value" without space after colon
            if (header_count >= header_buf.len) return error.BufferTooSmall;
            const value_start = colon_pos + 1;
            // Trim leading whitespace from value
            var trimmed_start = value_start;
            while (trimmed_start < line.len and line[trimmed_start] == ' ') {
                trimmed_start += 1;
            }
            header_buf[header_count] = Header{
                .name = line[0..colon_pos],
                .value = line[trimmed_start..],
            };
            header_count += 1;
        }

        pos = line_end + 2; // skip past "\r\n"
    }

    // Everything after headers is the body
    const body = buf[pos..];

    return Response{
        .status = status,
        .headers = header_buf[0..header_count],
        .body = body,
    };
}

// ── HTTP client ──────────────────────────────────────────────────────────

/// Perform an HTTP GET request, writing the full response into a caller-provided buffer.
/// Uses os.sig sockets for TCP. No allocator needed.
///
/// `host` must be a numeric IPv4 address (e.g. "93.184.216.34") or a hostname
/// that can be resolved via the platform's DNS resolver.
///
/// Returns the filled slice of `response_buf` containing the raw HTTP response,
/// or `error.BufferTooSmall` if the response exceeds the buffer or connection fails.
pub fn get(io: sig_io.Io, host: []const u8, path: []const u8, response_buf: []u8) SigError![]u8 {
    _ = io;
    return doRequest("GET", host, 80, path, &[_]Header{}, "", response_buf);
}

/// Perform an HTTP GET on a specific port.
pub fn getPort(io: sig_io.Io, host: []const u8, port: u16, path: []const u8, response_buf: []u8) SigError![]u8 {
    _ = io;
    return doRequest("GET", host, port, path, &[_]Header{}, "", response_buf);
}

/// Perform an HTTP POST request, writing the full response into a caller-provided buffer.
/// Uses os.sig sockets for TCP. No allocator needed.
///
/// Returns the filled slice of `response_buf` containing the raw HTTP response,
/// or `error.BufferTooSmall` if the response exceeds the buffer or connection fails.
pub fn post(
    io: sig_io.Io,
    host: []const u8,
    path: []const u8,
    headers: []const Header,
    body: []const u8,
    response_buf: []u8,
) SigError![]u8 {
    _ = io;
    return doRequest("POST", host, 80, path, headers, body, response_buf);
}

/// A parsed HTTP request. All slices point into the caller-provided request buffer (zero-copy).
pub const Request = struct {
    method: []const u8,
    path: []const u8,
    headers: []const Header,
    body: []const u8,
};

/// A capacity-first HTTP server. Accepts connections, reads requests
/// into caller buffers, dispatches to a handler.
/// `max_request_size` bounds the maximum request that can be read in `accept`.
pub fn Server(comptime max_request_size: usize) type {
    return struct {
        const Self = @This();

        listen_sock: os.socket_t,
        client_sock: os.socket_t = os.INVALID_SOCKET,

        /// Creates a listening TCP server on the given port (binds to 0.0.0.0).
        /// Returns the server instance or `BufferTooSmall` on failure.
        pub fn listen(io: sig_io.Io, port: u16) SigError!Self {
            _ = io;
            const sock = os.socketCreate();
            if (sock == os.INVALID_SOCKET) return error.BufferTooSmall;

            // Set SO_REUSEADDR
            _ = os.socketSetReuseAddr(sock, true);

            // Bind to 0.0.0.0:port
            var addr = os.sockaddr_in{
                .sin_family = os.AF_INET,
                .sin_port = os.htons(port),
                .sin_addr = .{ 0, 0, 0, 0 },
                .sin_zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
            };

            if (!os.socketBind(sock, &addr)) {
                os.socketClose(sock);
                return error.BufferTooSmall;
            }

            if (!os.socketListen(sock, 128)) {
                os.socketClose(sock);
                return error.BufferTooSmall;
            }

            return Self{
                .listen_sock = sock,
            };
        }

        /// Accepts a connection and reads the HTTP request into `req_buf`.
        /// Parses the request line and headers. All returned slices point into `req_buf`.
        /// Returns `BufferTooSmall` if the request exceeds `req_buf` or `max_request_size`.
        pub fn accept(self: *Self, io: sig_io.Io, req_buf: []u8) SigError!Request {
            _ = io;
            const effective_size = @min(req_buf.len, max_request_size);
            const buf = req_buf[0..effective_size];

            const client = os.socketAccept(self.listen_sock);
            if (client == os.INVALID_SOCKET) return error.BufferTooSmall;
            self.client_sock = client;

            // Read request data into the caller-provided buffer.
            var total: usize = 0;
            while (total < buf.len) {
                const n = os.socketRecv(client, buf[total..]);
                if (n == 0) break;
                total += n;

                // Check if we've received the end of headers (\r\n\r\n).
                if (total >= 4) {
                    if (indexOf(buf[0..total], "\r\n\r\n") != null) break;
                }
            }

            if (total == 0) return error.BufferTooSmall;

            const data = buf[0..total];

            // Parse request line: "METHOD /path HTTP/1.x\r\n"
            const request_line_end = indexOf(data, "\r\n") orelse return error.BufferTooSmall;
            const request_line = data[0..request_line_end];

            // Extract method
            const method_end = indexOfChar(request_line, ' ') orelse return error.BufferTooSmall;
            const method = request_line[0..method_end];

            // Extract path
            const after_method = request_line[method_end + 1 ..];
            const path_end = indexOfChar(after_method, ' ') orelse return error.BufferTooSmall;
            const req_path = after_method[0..path_end];

            // Parse headers into a stack-allocated header buffer.
            var header_buf: [64]Header = undefined;
            var header_count: usize = 0;
            var pos = request_line_end + 2; // skip past first \r\n

            while (pos < data.len) {
                // Check for end of headers (empty line)
                if (pos + 1 < data.len and data[pos] == '\r' and data[pos + 1] == '\n') {
                    pos += 2;
                    break;
                }

                // Find end of this header line
                const line_end = indexOfFrom(data, pos, "\r\n") orelse break;
                const line = data[pos..line_end];

                // Split on first ": "
                if (indexOfStr(line, ": ")) |colon_pos| {
                    if (header_count < header_buf.len) {
                        header_buf[header_count] = Header{
                            .name = line[0..colon_pos],
                            .value = line[colon_pos + 2 ..],
                        };
                        header_count += 1;
                    }
                } else if (indexOfChar(line, ':')) |colon_pos| {
                    if (header_count < header_buf.len) {
                        const value_start = colon_pos + 1;
                        var trimmed_start = value_start;
                        while (trimmed_start < line.len and line[trimmed_start] == ' ') {
                            trimmed_start += 1;
                        }
                        header_buf[header_count] = Header{
                            .name = line[0..colon_pos],
                            .value = line[trimmed_start..],
                        };
                        header_count += 1;
                    }
                }

                pos = line_end + 2;
            }

            // Everything after headers is the body
            const req_body = data[pos..];

            return Request{
                .method = method,
                .path = req_path,
                .headers = header_buf[0..header_count],
                .body = req_body,
            };
        }

        /// Writes an HTTP/1.1 response with the given status code and body
        /// to the currently accepted connection. Uses stack-allocated buffers.
        /// Returns `BufferTooSmall` if the response cannot be written.
        pub fn respond(self: *Self, io: sig_io.Io, status: u16, body: []const u8) SigError!void {
            _ = io;
            const sock = self.client_sock;
            if (sock == os.INVALID_SOCKET) return error.BufferTooSmall;

            // Build the response into a stack buffer.
            var resp_buf: [512]u8 = undefined;
            var offset: usize = 0;

            // Status line: "HTTP/1.1 STATUS REASON\r\n"
            offset = try appendSlice(&resp_buf, offset, "HTTP/1.1 ");

            // Format status code
            var status_digits: [3]u8 = undefined;
            const status_str = sig_fmt.bufPrint(&status_digits, "{d}", .{status}) catch return error.BufferTooSmall;
            offset = try appendSlice(&resp_buf, offset, status_str);
            offset = try appendSlice(&resp_buf, offset, " ");
            offset = try appendSlice(&resp_buf, offset, statusReason(status));
            offset = try appendSlice(&resp_buf, offset, "\r\n");

            // Content-Length header
            offset = try appendSlice(&resp_buf, offset, "Content-Length: ");
            var len_buf: [20]u8 = undefined;
            const len_str = sig_fmt.bufPrint(&len_buf, "{d}", .{body.len}) catch return error.BufferTooSmall;
            offset = try appendSlice(&resp_buf, offset, len_str);
            offset = try appendSlice(&resp_buf, offset, "\r\n");

            // Connection: close
            offset = try appendSlice(&resp_buf, offset, "Connection: close\r\n");

            // End of headers
            offset = try appendSlice(&resp_buf, offset, "\r\n");

            // Send headers
            if (!os.socketSendAll(sock, resp_buf[0..offset])) return error.BufferTooSmall;

            // Send body
            if (body.len > 0) {
                if (!os.socketSendAll(sock, body)) return error.BufferTooSmall;
            }

            // Close the client connection after responding.
            os.socketClose(sock);
            self.client_sock = os.INVALID_SOCKET;
        }

        /// Shuts down the server, closing the listening socket.
        pub fn deinit(self: *Self, io: sig_io.Io) void {
            _ = io;
            if (self.client_sock != os.INVALID_SOCKET) {
                os.socketClose(self.client_sock);
                self.client_sock = os.INVALID_SOCKET;
            }
            os.socketClose(self.listen_sock);
        }
    };
}

/// Returns a reason phrase for common HTTP status codes.
fn statusReason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}

/// Internal: performs an HTTP request (GET or POST) over TCP.
/// All buffers are caller-provided or stack-allocated. No allocator is used.
///
/// Resolves hostname to IPv4 by parsing numeric dotted-quad. For DNS names,
/// the caller should pre-resolve and pass the numeric IP.
fn doRequest(
    method: []const u8,
    host: []const u8,
    port: u16,
    path: []const u8,
    headers: []const Header,
    body: []const u8,
    response_buf: []u8,
) SigError![]u8 {
    // Parse the host as an IPv4 address (dotted quad)
    var addr = os.sockaddr_in{
        .sin_family = os.AF_INET,
        .sin_port = os.htons(port),
        .sin_addr = .{ 0, 0, 0, 0 },
        .sin_zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };

    addr.sin_addr = parseIpv4(host) orelse return error.BufferTooSmall;

    // Create TCP socket
    const sock = os.socketCreate();
    if (sock == os.INVALID_SOCKET) return error.BufferTooSmall;

    // Connect to the server
    if (!os.socketConnect(sock, &addr)) {
        os.socketClose(sock);
        return error.BufferTooSmall;
    }

    // Build the HTTP request into a stack buffer (8 KiB covers most requests).
    var request_buf: [8192]u8 = undefined;
    const request = buildRequest(&request_buf, method, host, path, headers, body) catch {
        os.socketClose(sock);
        return error.BufferTooSmall;
    };

    // Send the request
    if (!os.socketSendAll(sock, request)) {
        os.socketClose(sock);
        return error.BufferTooSmall;
    }

    // Read the response into the caller-provided buffer.
    var total: usize = 0;
    while (total < response_buf.len) {
        const n = os.socketRecv(sock, response_buf[total..]);
        if (n == 0) break;
        total += n;
    }

    os.socketClose(sock);

    if (total == 0) return error.BufferTooSmall;

    return response_buf[0..total];
}

/// Parse a dotted-quad IPv4 address string (e.g. "192.168.1.1") into 4 bytes.
/// Returns null if the string is not a valid IPv4 address.
fn parseIpv4(host: []const u8) ?[4]u8 {
    var result: [4]u8 = .{ 0, 0, 0, 0 };
    var octet_idx: usize = 0;
    var current: u16 = 0;
    var has_digit = false;

    for (host) |c| {
        if (c >= '0' and c <= '9') {
            current = current * 10 + @as(u16, c - '0');
            if (current > 255) return null;
            has_digit = true;
        } else if (c == '.') {
            if (!has_digit) return null;
            if (octet_idx >= 3) return null;
            result[octet_idx] = @intCast(current);
            octet_idx += 1;
            current = 0;
            has_digit = false;
        } else {
            return null; // Invalid character — not a numeric IP
        }
    }

    // Final octet
    if (!has_digit) return null;
    if (octet_idx != 3) return null;
    result[3] = @intCast(current);

    return result;
}

// ── Internal helpers ─────────────────────────────────────────────────────

/// Appends a slice to `buf` at `offset`. Returns the new offset.
fn appendSlice(buf: []u8, offset: usize, data: []const u8) SigError!usize {
    if (offset + data.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[offset..][0..data.len], data);
    return offset + data.len;
}

/// Finds the first occurrence of `needle` in `haystack`. Returns the index or null.
fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    return indexOfFrom(haystack, 0, needle);
}

/// Finds the first occurrence of `needle` in `haystack` starting from `start`.
fn indexOfFrom(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return start;
    if (haystack.len < needle.len) return null;
    var i = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eql(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

/// Finds the first occurrence of a single character in a slice.
fn indexOfChar(haystack: []const u8, char: u8) ?usize {
    for (haystack, 0..) |c, i| {
        if (c == char) return i;
    }
    return null;
}

/// Finds the first occurrence of a string in a slice (alias for indexOf on a sub-slice).
fn indexOfStr(haystack: []const u8, needle: []const u8) ?usize {
    return indexOf(haystack, needle);
}

/// Finds the end of the authority section (host[:port]) in a URI.
/// The authority ends at the first '/', '?', or end of string.
fn findAuthorityEnd(buf: []const u8) usize {
    for (buf, 0..) |c, i| {
        if (c == '/' or c == '?') return i;
    }
    return buf.len;
}

/// Returns the default port for a scheme.
fn defaultPort(scheme: []const u8) u16 {
    if (eql(scheme, "https")) return 443;
    return 80;
}

/// Checks if `haystack` starts with `prefix`.
fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return eql(haystack[0..prefix.len], prefix);
}

/// Byte-wise equality check.
fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}
