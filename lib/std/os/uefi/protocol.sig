const std = @import("std");
const uefi = std.os.uefi;

pub const ServiceBinding = @import("protocol/service_binding.sig").ServiceBinding;

pub const LoadedImage = @import("protocol/loaded_image.sig").LoadedImage;
pub const DevicePath = @import("protocol/device_path.sig").DevicePath;
pub const Rng = @import("protocol/rng.sig").Rng;
pub const ShellParameters = @import("protocol/shell_parameters.sig").ShellParameters;

pub const SimpleFileSystem = @import("protocol/simple_file_system.sig").SimpleFileSystem;
pub const File = @import("protocol/file.sig").File;
pub const BlockIo = @import("protocol/block_io.sig").BlockIo;

pub const SimpleTextInput = @import("protocol/simple_text_input.sig").SimpleTextInput;
pub const SimpleTextInputEx = @import("protocol/simple_text_input_ex.sig").SimpleTextInputEx;
pub const SimpleTextOutput = @import("protocol/simple_text_output.sig").SimpleTextOutput;

pub const SimplePointer = @import("protocol/simple_pointer.sig").SimplePointer;
pub const AbsolutePointer = @import("protocol/absolute_pointer.sig").AbsolutePointer;

pub const SerialIo = @import("protocol/serial_io.sig").SerialIo;

pub const GraphicsOutput = @import("protocol/graphics_output.sig").GraphicsOutput;

pub const edid = @import("protocol/edid.sig");

pub const SimpleNetwork = @import("protocol/simple_network.sig").SimpleNetwork;
pub const ManagedNetwork = @import("protocol/managed_network.sig").ManagedNetwork;

pub const Ip6ServiceBinding = ServiceBinding(.{
    .time_low = 0xec835dd3,
    .time_mid = 0xfe0f,
    .time_high_and_version = 0x617b,
    .clock_seq_high_and_reserved = 0xa6,
    .clock_seq_low = 0x21,
    .node = [_]u8{ 0xb3, 0x50, 0xc3, 0xe1, 0x33, 0x88 },
});
pub const Ip6 = @import("protocol/ip6.sig").Ip6;
pub const Ip6Config = @import("protocol/ip6_config.sig").Ip6Config;

pub const Udp6ServiceBinding = ServiceBinding(.{
    .time_low = 0x66ed4721,
    .time_mid = 0x3c98,
    .time_high_and_version = 0x4d3e,
    .clock_seq_high_and_reserved = 0x81,
    .clock_seq_low = 0xe3,
    .node = [_]u8{ 0xd0, 0x3d, 0xd3, 0x9a, 0x72, 0x54 },
});
pub const Udp6 = @import("protocol/udp6.sig").Udp6;

pub const HiiDatabase = @import("protocol/hii_database.sig").HiiDatabase;
pub const HiiPopup = @import("protocol/hii_popup.sig").HiiPopup;

test {
    std.testing.refAllDecls(@This());
}
