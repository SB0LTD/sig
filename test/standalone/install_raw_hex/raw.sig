export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\wfe
        \\b .
    );
}
