//! Run in a fresh temporary directory; owns sig-no-libc-contract.tmp there.
const builtin = @import("builtin");
const sig = @import("sig");
fn check(ok: bool) !void { if (!ok) return error.NativeIoContract; }
pub fn main() !void {
    if (builtin.os.tag == .linux) try check(!builtin.link_libc);
    const before = sig.os.clockMonotonicNs();
    try check(before > 0);
    var source: [4096]u8 = undefined;
    for (&source, 0..) |*byte,index| byte.* = @truncate(index * 17);
    const file = try sig.os.openWrite("sig-no-libc-contract.tmp");
    try check(sig.os.writeAll(file,&source));
    sig.os.closeFd(file);
    const input = try sig.os.openRead("sig-no-libc-contract.tmp");
    defer sig.os.closeFd(input);
    try check(sig.os.fileSize(input) == source.len);
    var target: [4096]u8 = undefined;
    var used: usize = 0;
    while (used < target.len) {
        const amount = sig.os.readFd(input,target[used..].ptr,target.len-used);
        try check(amount != 0); used += amount;
    }
    for (source,target) |expected,actual| try check(expected == actual);
    try check(sig.os.readFd(input,&target,1) == 0);
    if (sig.os.openRead("missing-native-io-file")) |unexpected| {
        sig.os.closeFd(unexpected); return error.MissingFileAccepted;
    } else |err| try check(err == error.FileNotFound);
    try check(sig.os.clockMonotonicNs() >= before);
    try check(sig.os.writeAll(sig.os.stdoutFd(),"PASS native I/O: 4096 checked bytes, EOF, size, missing file and clock\n"));
    sig.os.exitProcess(0);
}
