export fn entry() void {
    _ = @import("zon/inf.zon");
}

// error
// imports=zon/inf.zon
//
// inf.zon:1:1: error: infinity requires a known result type
// tmp.sig:2:17: note: imported here
