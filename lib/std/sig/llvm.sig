pub const BitcodeReader = @import("llvm/BitcodeReader.sig");
pub const bitcode_writer = @import("llvm/bitcode_writer.sig");
pub const Builder = @import("llvm/Builder.sig");

test {
    _ = BitcodeReader;
    _ = bitcode_writer;
    _ = Builder;
}
