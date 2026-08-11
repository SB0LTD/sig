ENTRY(_start)

SECTIONS
{
  . = 0x40200000;
  __sb0_image_start = .;
  .sb0k :
  {
    LONG(0x4b304253)
    SHORT(1)
    SHORT(64)
    SHORT(1)
    SHORT(0)
    LONG(1)
    QUAD(_start - __sb0_image_start)
    QUAD(__sb0_file_end - __sb0_image_start)
    QUAD(0)
    LONG(0)
    LONG(0)
    QUAD(0)
    QUAD(0x40200000)
  }
  .text : ALIGN(16)
  {
    KEEP(*(.text._start .text.*._start .text.*_start))
    *(.text .text.*)
  }
  .rodata : ALIGN(16) { *(.rodata .rodata.*) }
  .data : ALIGN(16) { *(.data .data.*) }
  __sb0_file_end = .;
  .bss (NOLOAD) : ALIGN(16)
  {
    __bss_start = .;
    *(.bss .bss.* COMMON)
    __bss_end = .;
  }
  /DISCARD/ : { *(.comment .note .note.* .eh_frame .eh_frame_hdr) }
}
