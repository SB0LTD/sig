/* Stub implementations for f16/f80 math functions on Windows.
 * The bootstrap zig2 never calls these at runtime — they exist only
 * because the C backend emits references for all target float types.
 * These stubs satisfy the linker without pulling in a full soft-float library.
 */
#include <stdint.h>

#if defined(_WIN32)

/* f16 is represented as uint16_t on Windows (no native _Float16) */
typedef uint16_t zig_f16;
uint16_t zig_abs_f16(uint16_t x)  { return x & 0x7FFF; }
uint16_t zig_sqrt_f16(uint16_t x) { (void)x; return 0; }
uint16_t zig_sin_f16(uint16_t x)  { (void)x; return 0; }
uint16_t zig_cos_f16(uint16_t x)  { (void)x; return 0; }
uint16_t zig_tan_f16(uint16_t x)  { (void)x; return 0; }
uint16_t zig_exp_f16(uint16_t x)  { (void)x; return 0; }
uint16_t zig_exp2_f16(uint16_t x) { (void)x; return 0; }
uint16_t zig_log_f16(uint16_t x)  { (void)x; return 0; }
uint16_t zig_log2_f16(uint16_t x) { (void)x; return 0; }
uint16_t zig_fma_f16(uint16_t x, uint16_t y, uint16_t z) { (void)x; (void)y; (void)z; return 0; }

/* f80 is represented as a 128-bit type on Windows (no native long double = 80-bit) */
typedef struct { uint64_t lo; uint64_t hi; } zig_f80;
static const zig_f80 zero80 = {0, 0};
zig_f80 zig_abs_f80(zig_f80 x)  { x.hi &= 0x7FFFFFFFFFFFFFFF; return x; }
zig_f80 zig_sqrt_f80(zig_f80 x) { (void)x; return zero80; }
zig_f80 zig_sin_f80(zig_f80 x)  { (void)x; return zero80; }
zig_f80 zig_cos_f80(zig_f80 x)  { (void)x; return zero80; }
zig_f80 zig_tan_f80(zig_f80 x)  { (void)x; return zero80; }
zig_f80 zig_exp_f80(zig_f80 x)  { (void)x; return zero80; }
zig_f80 zig_exp2_f80(zig_f80 x) { (void)x; return zero80; }
zig_f80 zig_log_f80(zig_f80 x)  { (void)x; return zero80; }
zig_f80 zig_log2_f80(zig_f80 x) { (void)x; return zero80; }
zig_f80 zig_fma_f80(zig_f80 x, zig_f80 y, zig_f80 z) { (void)x; (void)y; (void)z; return zero80; }

#endif /* _WIN32 */
