//! A small HTTP adapter over std.Io.net and std.http.Server.
//! Intended for local services and framework development. Connections are
//! sequential and closed after one response; TLS, deadlines, concurrency,
//! authentication and durable storage belong in higher-level integrations.
const std = @import("std");
const encoding = @import("encoding.sig");

pub const Options = struct {
    address: []const u8 = "127.0.0.1:8080",
    /// Useful for deterministic integration tests and bounded worker lifetimes.
    max_connections: ?usize = null,
};

pub const Context = struct {
    request: *std.http.Server.Request,
    output: []u8,
    responded: bool = false,

    pub fn method(self: *const Context) std.http.Method { return self.request.head.method; }
    /// Borrows the HTTP header buffer for this handler invocation only.
    pub fn path(self: *const Context) []const u8 {
        const target = self.request.head.target;
        return target[0..(std.mem.findScalar(u8, target, '?') orelse target.len)];
    }
    pub fn json(self: *Context, status: std.http.Status, value: anytype) !void {
        const body = try encoding.encode(value, self.output);
        try self.respond(status, "application/json; charset=utf-8", body);
    }
    pub fn text(self: *Context, status: std.http.Status, body: []const u8) !void {
        try self.respond(status, "text/plain; charset=utf-8", body);
    }
    fn respond(self: *Context, status: std.http.Status, comptime content_type: []const u8, body: []const u8) !void {
        if (self.responded) return error.AlreadyResponded;
        self.responded = true;
        try self.request.respond(body, .{
            .status = status,
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = content_type },
                .{ .name = "x-content-type-options", .value = "nosniff" },
            },
        });
    }
};

/// One 8 KiB header buffer, 4 KiB transport writer and 16 KiB response buffer
/// are reused per connection. The standard HTTP parser handles framing and HEAD.
pub fn serve(io: std.Io, options: Options, comptime handler: fn (*Context) anyerror!void) !void {
    const address = try std.Io.net.IpAddress.parseLiteral(options.address);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    var count: usize = 0;
    while (options.max_connections == null or count < options.max_connections.?) : (count += 1) {
        const stream = try listener.accept(io);
        defer stream.close(io);
        var receive_buffer: [8192]u8 = undefined;
        var send_buffer: [4096]u8 = undefined;
        var output: [16384]u8 = undefined;
        var reader = stream.reader(io, &receive_buffer);
        var writer = stream.writer(io, &send_buffer);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = server.receiveHead() catch continue;
        var context = Context{ .request = &request, .output = &output };
        handler(&context) catch {
            if (!context.responded) context.text(.internal_server_error, "Internal server error") catch {};
        };
        if (!context.responded) context.text(.no_content, "") catch {};
    }
}
