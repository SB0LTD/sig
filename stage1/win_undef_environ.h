/* Force-included before zig2.c on Windows.
 *
 * 1. Suppress dllimport on CRT declarations — with /MT (static CRT),
 *    functions are linked statically but UCRT headers still use dllimport
 *    by default. This causes conflicts when zig2.c redeclares malloc/free/realloc
 *    without dllimport. Define _CRTIMP= before including headers to prevent it.
 * 2. Rename UCRT's _msize before including stdlib.h so zig2.c can
 *    declare its own _msize without conflicting types.
 * 3. Pre-include stdlib.h to lock the environ include guard.
 * 4. Undef environ macros that conflict with struct fields.
 */

/* Suppress dllimport on CRT functions — prevents conflict with zig2.c's
 * plain extern declarations of malloc, free, realloc, exit */
#ifndef _CRTIMP
#define _CRTIMP
#endif
#ifndef _ACRTIMP
#define _ACRTIMP
#endif

/* Rename UCRT _msize to avoid type conflict with zig2.c's declaration */
#define _msize _ucrt_msize
#include <stdlib.h>
#include <malloc.h>
#undef _msize

#undef environ
#undef _environ

#pragma clang diagnostic ignored "-Wincompatible-library-redeclaration"
#pragma clang diagnostic ignored "-Winconsistent-dllimport"
