//! Runtime proof that the fixed-capacity pipeline does not hide its phase
//! storage in a native call frame. CI executes this AArch64 binary under an
//! explicit 8 MiB QEMU stack limit.

const target_mod = @import("core/target.sig");
const streaming = @import("pipeline/streaming.sig");

var workspace: streaming.Pipeline_Workspace = undefined;

pub fn main() u8 {
    const target = target_mod.Target_Triple{ .arch = .aarch64, .os = .linux, .abi = .musl };
    var controller = streaming.Streaming_Controller.init(target, &workspace);
    const result = controller.processFile(.{});
    return if (result.success) 0 else 1;
}
