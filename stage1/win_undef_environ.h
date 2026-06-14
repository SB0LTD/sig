/* Force-included before zig2.c on Windows.
 * Pre-includes stdlib.h/corecrt_malloc.h then undefs problematic macros.
 * The environ macro conflicts with struct field names.
 * The _msize declaration in UCRT conflicts with zig2.c's declaration
 * (const qualifier difference). We suppress that specific diagnostic. */
#include <stdlib.h>
#undef environ
#undef _environ

/* Suppress the _msize conflicting types error. zig2.c declares it with
 * const void* but UCRT has void*. Functionally identical on x86_64. */
#pragma clang diagnostic ignored "-Wincompatible-library-redeclaration"
#pragma clang diagnostic ignored "-Wmicrosoft-redeclare-static"
