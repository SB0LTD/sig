const app = @import("app");
const Record = struct { name: []const u8 };
const Broken = app.Schema(Record, .{.{ .field = "naem", .check = app.validation.nonEmpty, .message = "Required" }});
test "unknown schema field fails compilation" { try Broken.validate(.{ .name = "Ada" }); }
