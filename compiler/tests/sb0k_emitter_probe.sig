const linker_mod = @import("../backend/linker.sig");
const target_mod = @import("../core/target.sig");

pub fn main() !void {
    const target = target_mod.Target_Triple{
        .arch = .aarch64,
        .os = .sb0,
        .abi = .sb0,
    };
    var emitter = linker_mod.Linker.init(target);
    const reset_code = [_]u8{
        0x5f, 0x20, 0x03, 0xd5,
        0xff, 0xff, 0xff, 0x17,
    };
    var image: [128]u8 = undefined;
    const written = emitter.emitSb0Kernel(
        &image,
        &reset_code,
        0x0102_0304_0506_0708,
        0x0000_0000_8000_0000,
    );
    if (written != linker_mod.SB0_KERNEL_HEADER_SIZE + reset_code.len)
        return error.InvalidImageSize;
    if (image[0] != 'S' or image[1] != 'B' or image[2] != '0' or image[3] != 'K')
        return error.InvalidImageMagic;
    if (image[16] != 64 or image[24] != @as(u8, @intCast(written)))
        return error.InvalidImageLayout;
    for (reset_code, 0..) |byte, i| {
        if (image[linker_mod.SB0_KERNEL_HEADER_SIZE + i] != byte)
            return error.InvalidResetCode;
    }
}
