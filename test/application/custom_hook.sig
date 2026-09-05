const app = @import("app");
const Custom = enum {
    item,
    pub fn jsonStringify(_: @This(), writer: anytype) !void { try writer.write("custom"); }
};
test "two-pass encoding excludes custom hooks" {
    var out: [128]u8 = undefined;
    _ = try app.json.encode(Custom.item, &out);
}
