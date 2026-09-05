const std = @import("std");
const app = @import("app");
fn handle(ctx: *app.http.Context) !void {
 if (ctx.method() != .GET and ctx.method() != .HEAD) return ctx.json(.method_not_allowed, .{ .error_code = "method_not_allowed" });
 if (std.mem.eql(u8, ctx.path(), "/health")) return ctx.json(.ok, .{ .status = "ok", .ecosystem = "Sig" });
 if (std.mem.eql(u8, ctx.path(), "/fail")) return error.Sample;
 return ctx.json(.not_found, .{ .error_code = "not_found" });
}
pub fn main(init: std.process.Init) !void {
 try app.http.serve(init.io, .{ .address = "127.0.0.1:18173", .max_connections = 5 }, handle);
}
