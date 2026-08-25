const compiler_rt = @import("../compiler_rt.sig");
const symbol = compiler_rt.symbol;
const absv = @import("absv.sig").absv;

comptime {
    symbol(&__absvdi2, "__absvdi2");
}

pub fn __absvdi2(a: i64) callconv(.c) i64 {
    return absv(i64, a);
}
