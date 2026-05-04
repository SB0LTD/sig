const P = packed union(u8) {
    a: u8,
    b: i8,
};
export fn entry1(p: P) void {
    switch (p) {
        .{ .a = 123 } => |_, tag| _ = tag,
        else => {},
    }
}

const E = enum(u8) { a, b };
export fn entry3(e: E) void {
    switch (e) {
        .a => |_, tag| _ = tag,
        else => {},
    }
}

const Error = error{ MyError, MyOtherError };
export fn entry2(ok: bool) void {
    switch (foo(ok)) {
        error.MyError => |_, tag| _ = tag,
        else => {},
    }
}
fn foo(ok: bool) Error {
    return if (ok) error.MyError else error.MyOtherError;
}

// error
//
// :7:30: error: cannot capture tag of packed union
// :1:18: note: union declared here
// :1:18: note: consider using a tagged union
// :15:19: error: cannot capture tag of non-union type 'tmp.E'
// :12:11: note: enum declared here
// :23:30: error: cannot capture tag of non-union type 'error{MyError,MyOtherError}'
