/* compiler_rt_msvc_math.h — Documentation for the compiler_rt symbol conflict fix.
 *
 * This file is kept for reference only (not force-included).
 *
 * PROBLEM:
 * compiler_rt.c includes lib/zig.h which defines zig_export() on MSVC as:
 *   __pragma(comment(linker, "/alternatename:sqrtf=zig_sqrt_f32"))
 * This aliases internal zig names to standard C library names. The MSVC static
 * CRT (libucrt.lib) already provides these names, causing linker conflicts.
 *
 * SOLUTION (in lib/zig.h + CMakeLists.txt):
 * 1. lib/zig.h checks for ZIG_NO_EXPORT_ALIASES before defining zig_export.
 *    When set, zig_export expands to just ";" (no-op).
 * 2. CMakeLists.txt compiles compiler_rt.c with /DZIG_NO_EXPORT_ALIASES on Windows.
 *
 * RESULT:
 * - Internal functions (zig_sqrt_f32, zig_fabs_f64, etc.) compile normally
 * - No /alternatename directives are emitted for CRT-conflicting names
 * - zig2.c calls compiler_rt functions by their internal mangled names
 * - The CRT provides standard names (sqrtf, fabs, etc.) for direct callers
 */
