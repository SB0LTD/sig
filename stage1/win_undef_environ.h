/* Force-included before zig2.c on Windows.
 *
 * 1. Rename UCRT's _msize before including stdlib.h so zig2.c can
 *    declare its own _msize without conflicting types.
 * 2. Pre-include stdlib.h to lock the environ include guard.
 * 3. Undef environ macros that conflict with struct fields. */

/* Rename UCRT _msize to avoid type conflict with zig2.c's declaration */
#define _msize _ucrt_msize
#include <stdlib.h>
#undef _msize

#undef environ
#undef _environ

#pragma clang diagnostic ignored "-Wincompatible-library-redeclaration"
