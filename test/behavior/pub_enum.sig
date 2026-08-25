const builtin = @import("builtin");
const other = @import("pub_enum/other.sig");
const expect = @import("std").testing.expect;

test "pub enum" {
    if (builtin.sig_backend == .stage2_riscv64) return error.SkipZigTest;

    try pubEnumTest(other.APubEnum.Two);
}
fn pubEnumTest(foo: other.APubEnum) !void {
    try expect(foo == other.APubEnum.Two);
}

test "cast with imported symbol" {
    if (builtin.sig_backend == .stage2_riscv64) return error.SkipZigTest;

    try expect(@as(other.size_t, 42) == 42);
}
