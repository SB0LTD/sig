/* Force-included before zig2.c on Windows.
 * Pre-includes stdlib.h then undefs the environ macro that UCRT defines,
 * which conflicts with struct field names in the generated zig2.c.
 * When zig2.c later does #include <stdlib.h>, the include guard prevents
 * re-inclusion so our #undef stays in effect. */
#include <stdlib.h>
#undef environ
#undef _environ
