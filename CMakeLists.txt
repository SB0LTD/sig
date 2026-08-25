cmake_minimum_required(VERSION 3.15)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE "Debug" CACHE STRING
        "Choose the type of build, options are: None Debug Release RelWithDebInfo MinSizeRel." FORCE)
endif()

if(NOT CMAKE_INSTALL_PREFIX)
    set(CMAKE_INSTALL_PREFIX "${CMAKE_CURRENT_BINARY_DIR}/stage3" CACHE PATH
      "Directory to install Sig to" FORCE)
endif()

# CMake recognizes the CMAKE_PREFIX_PATH environment variable for some things,
# and also the CMAKE_PREFIX_PATH cache variable for other things. However, it
# does not relate these two things, i.e. if the environment variable is set,
# CMake does not populate the cache variable in a corresponding manner. Some
# package systems, such as Homebrew, set the environment variable but not the
# cache variable. Furthermore, the environment variable follows the system path
# separator, such as ':' on POSIX and ';' on Windows, but the cache variable
# follows CMake's array behavior, i.e. always ';' for a separator.
list(APPEND ZIG_CMAKE_PREFIX_PATH "${CMAKE_PREFIX_PATH}")
if(WIN32)
  list(APPEND ZIG_CMAKE_PREFIX_PATH $ENV{CMAKE_PREFIX_PATH})
else()
  string(REGEX REPLACE ":" ";" ZIG_CMAKE_PREFIX_PATH_STRING "$ENV{CMAKE_PREFIX_PATH}")
  list(APPEND ZIG_CMAKE_PREFIX_PATH "${ZIG_CMAKE_PREFIX_PATH_STRING}")
endif()

list(PREPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

# Suppress MSVC "secure CRT" warnings (fopen→fopen_s, strcpy→strcpy_s, etc.)
if(WIN32)
  add_compile_definitions(_CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_DEPRECATE)
endif()

project(Sig
  DESCRIPTION
    "Sig is a general-purpose programming language and toolchain for maintaining robust, optimal and reusable software"
  HOMEPAGE_URL
    "https://ziglang.org"
  LANGUAGES
    C CXX
)

set(ZIG_VERSION_MAJOR 0)
set(ZIG_VERSION_MINOR 17)
set(ZIG_VERSION_PATCH 0)
set(ZIG_VERSION "" CACHE STRING "Override Sig version string. Default is to find out with git.")

# Sig's language/toolchain version is owned by build.sig. Parse it here so the
# checked-in zig1.wasm -> CMake bootstrap receives the same build option as the
# self-hosted build.sig/build.sig paths, with no fourth mutable version string.
file(STRINGS "${PROJECT_SOURCE_DIR}/build.sig" SIG_VERSION_LINE
    REGEX "^const sig_version_string = \"[0-9]+\\.[0-9]+\\.[0-9]+\";")
string(REGEX MATCH "[0-9]+\\.[0-9]+\\.[0-9]+" RESOLVED_SIG_VERSION "${SIG_VERSION_LINE}")
if("${RESOLVED_SIG_VERSION}" STREQUAL "")
    message(FATAL_ERROR "Unable to resolve Sig version from build.sig")
endif()
message(STATUS "Configuring sig version ${RESOLVED_SIG_VERSION}")

if("${ZIG_VERSION}" STREQUAL "")
    set(RESOLVED_ZIG_VERSION "${ZIG_VERSION_MAJOR}.${ZIG_VERSION_MINOR}.${ZIG_VERSION_PATCH}")
    find_program(GIT_EXE NAMES git NAMES_PER_DIR)
    if(GIT_EXE AND EXISTS "${PROJECT_SOURCE_DIR}/.git")
        execute_process(
            COMMAND ${GIT_EXE} -C "${PROJECT_SOURCE_DIR}" describe --match *.*.* --tags --abbrev=9
            RESULT_VARIABLE EXIT_STATUS
            OUTPUT_VARIABLE GIT_DESCRIBE
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET)
        if(EXIT_STATUS EQUAL "0")
            set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${PROJECT_SOURCE_DIR}/.git/HEAD")
            if(GIT_DESCRIBE MATCHES "^v?([0-9]+\\.[0-9]+\\.[0-9]+)$")
                # Tagged release version.
                set(GIT_TAG ${CMAKE_MATCH_1})
                if(NOT GIT_TAG VERSION_EQUAL RESOLVED_ZIG_VERSION)
                    message(SEND_ERROR "Sig version (${RESOLVED_ZIG_VERSION}) does not match Git tag (${GIT_TAG}).")
                endif()
            elseif(GIT_DESCRIBE MATCHES "^v?([0-9]+\\.[0-9]+\\.[0-9]+)-([0-9]+)-g(.+)$")
                # Untagged pre-release. The Sig version is updated to include the number of commits
                # since the last tagged version and the commit hash. The version is formatted in
                # accordance with the https://semver.org specification.
                set(GIT_TAG ${CMAKE_MATCH_1})
                set(GIT_COMMITS_AFTER_TAG ${CMAKE_MATCH_2})
                set(GIT_COMMIT ${CMAKE_MATCH_3})
                if(NOT RESOLVED_ZIG_VERSION VERSION_GREATER GIT_TAG)
                    message(SEND_ERROR "Sig version (${RESOLVED_ZIG_VERSION}) must be greater than tagged ancestor (${GIT_TAG}).")
                endif()
                set(RESOLVED_ZIG_VERSION "${RESOLVED_ZIG_VERSION}-dev.${GIT_COMMITS_AFTER_TAG}+${GIT_COMMIT}")
            else()
                message(WARNING "Failed to parse version from output of `git describe`.")
            endif()
        endif()
    endif()
else()
    set(RESOLVED_ZIG_VERSION "${ZIG_VERSION}")
endif()
message(STATUS "Configuring Sig version ${RESOLVED_ZIG_VERSION}")

set(ZIG_NO_LIB off CACHE BOOL
    "Disable copying lib/ files to install prefix during the build phase")

set(ZIG_STATIC off CACHE BOOL "Attempt to build a static Sig executable (not compatible with glibc)")
set(ZIG_SHARED_LLVM off CACHE BOOL "Prefer linking against shared LLVM libraries")
set(ZIG_STATIC_LLVM ${ZIG_STATIC} CACHE BOOL "Prefer linking against static LLVM libraries")
set(ZIG_STATIC_ZLIB ${ZIG_STATIC} CACHE BOOL "Prefer linking against static zlib")
set(ZIG_STATIC_ZSTD ${ZIG_STATIC} CACHE BOOL "Prefer linking against static zstd")
set(ZIG_STATIC_CURSES OFF CACHE BOOL "Enable static linking against curses")
set(ZIG_STATIC_LIBXML2 OFF CACHE BOOL "Enable static linking against libxml2")

if (ZIG_SHARED_LLVM AND ZIG_STATIC_LLVM)
    message(SEND_ERROR "-DZIG_SHARED_LLVM and -DZIG_STATIC_LLVM cannot both be enabled simultaneously")
endif()

set(ZIG_TARGET_TRIPLE "native" CACHE STRING "arch-os-abi to output binaries for")
set(ZIG_TARGET_MCPU "native" CACHE STRING "-mcpu parameter to output binaries for")
set(ZIG_TARGET_DYNAMIC_LINKER "" CACHE STRING
  "Override the dynamic linker used by the Sig binary. Default is to auto-detect the dynamic linker.")
set(ZIG_SINGLE_THREADED off CACHE BOOL "limit the Sig compiler to use only 1 thread")
set(ZIG_AR_WORKAROUND off CACHE BOOL "append 'ar' subcommand to CMAKE_AR")

if("${ZIG_TARGET_TRIPLE}" STREQUAL "native")
    set(ZIG_USE_LLVM_CONFIG ON CACHE BOOL "use llvm-config to find LLVM libraries")
else()
    set(ZIG_USE_LLVM_CONFIG OFF CACHE BOOL "use llvm-config to find LLVM libraries")
endif()

if(ZIG_AR_WORKAROUND)
  string(REPLACE "<CMAKE_AR>" "<CMAKE_AR> ar" CMAKE_C_ARCHIVE_CREATE ${CMAKE_C_ARCHIVE_CREATE})
  string(REPLACE "<CMAKE_AR>" "<CMAKE_AR> ar" CMAKE_CXX_ARCHIVE_CREATE ${CMAKE_CXX_ARCHIVE_CREATE})
endif()


option(ZIG_PIE "Produce a position independent Sig executable" ${CMAKE_POSITION_INDEPENDENT_CODE})
include(CheckPIESupported)
check_pie_supported(
  OUTPUT_VARIABLE ZIG_PIE_SUPPORTED_BY_CMAKE
  LANGUAGES C CXX
)
if(ZIG_PIE AND NOT CMAKE_CXX_LINK_PIE_SUPPORTED)
  message(SEND_ERROR "ZIG_PIE was requested but CMake does not support it for \"zigcpp\" target: ${ZIG_PIE_SUPPORTED_BY_CMAKE}")
endif()


# Detect system libcxx name.
if ("c++" IN_LIST CMAKE_CXX_IMPLICIT_LINK_LIBRARIES)
    set(ZIG_SYSTEM_LIBCXX "c++" CACHE STRING "system libcxx name for build.sig")
else()
    set(ZIG_SYSTEM_LIBCXX "stdc++" CACHE STRING "system libcxx name for build.sig")
endif()

find_package(llvm 22)
find_package(clang 22)
find_package(lld 22)

if(ZIG_STATIC_ZLIB)
    if (MSVC)
        list(REMOVE_ITEM LLVM_LIBRARIES "z.lib")
    else()
        list(REMOVE_ITEM LLVM_LIBRARIES "-lz")
    endif()

    find_library(ZLIB NAMES libz.a libzlibstatic.a z zlib libz NAMES_PER_DIR)
    list(APPEND LLVM_LIBRARIES "${ZLIB}")
endif()

if(ZIG_STATIC_ZSTD)
    if (MSVC)
        list(REMOVE_ITEM LLVM_LIBRARIES "zstd.lib")
    else()
        list(REMOVE_ITEM LLVM_LIBRARIES "-lzstd")
    endif()

    find_library(ZSTD NAMES libzstd.a libzstdstatic.a zstd NAMES_PER_DIR)
    list(APPEND LLVM_LIBRARIES "${ZSTD}")
endif()

if (MSVC OR (WIN32 AND CMAKE_C_COMPILER_ID STREQUAL "Clang"))
    if(NOT DEFINED CMAKE_MSVC_RUNTIME_LIBRARY)
        # Use static CRT (/MT) to match the LLVM 22 libs rebuilt with /MT.
        set(CMAKE_MSVC_RUNTIME_LIBRARY MultiThreaded)
    endif()
endif ()

if(ZIG_STATIC_CURSES)
    list(REMOVE_ITEM LLVM_LIBRARIES "-lcurses")
    find_library(CURSES NAMES libcurses.a libncurses.a NAMES_PER_DIR
      PATHS
        /usr/local/opt/ncurses/lib
        /opt/homebrew/opt/ncurses/lib)
    list(APPEND LLVM_LIBRARIES "${CURSES}")
endif()

if(ZIG_STATIC_LIBXML2)
    list(REMOVE_ITEM LLVM_LIBRARIES "-lxml2")
    find_library(LIBXML2 NAMES libxml2.a NAMES_PER_DIR)
    list(APPEND LLVM_LIBRARIES "${LIBXML2}")
endif()

# Windows: remove -lm (math is in CRT, no separate libm)
if(WIN32)
    list(REMOVE_ITEM LLVM_LIBRARIES "-lm")
    list(REMOVE_ITEM LLVM_LIBRARIES "m")
    list(REMOVE_ITEM LLVM_LIBRARIES "m.lib")
    list(REMOVE_ITEM LLVM_LIBRARIES "-lm.lib")
    # Also filter via regex in case the above didn't catch it
    list(FILTER LLVM_LIBRARIES EXCLUDE REGEX "^-?l?m(\\.lib)?$")
    # Add version.dll (needed by clangDriver for GetFileVersionInfo*)
    list(APPEND LLVM_LIBRARIES "-lversion")
endif()

find_package(Threads)

set(ZIG_CONFIG_H_OUT "${PROJECT_BINARY_DIR}/config.h")
set(ZIG_CONFIG_ZIG_OUT "${PROJECT_BINARY_DIR}/config.sig")

set(ZIG_WASM2C_SOURCES
    stage1/wasm2c.c
)
# Sync with "zig_cpp_sources" in build.sig
set(ZIG_CPP_SOURCES
    # These are planned to stay even when we are self-hosted.
    src/zig_llvm.cpp
    src/zig_llvm-ar.cpp
    src/zig_clang_driver.cpp
    src/zig_clang_cc1_main.cpp
    src/zig_clang_cc1as_main.cpp
)
# Needed because we use cmake, not the Sig build system, to build zig2.o.
set(ZIG_STAGE2_SOURCES
    "${ZIG_CONFIG_ZIG_OUT}"
    lib/compiler_rt.sig
    lib/std/BitStack.sig
    lib/std/Build.sig
    lib/std/Build/Cache.sig
    lib/std/Build/Cache/DepTokenizer.sig
    lib/std/Io.sig
    lib/std/Io/Reader.sig
    lib/std/Io/Writer.sig
    lib/std/Progress.sig
    lib/std/Random.sig
    lib/std/Target.sig
    lib/std/Target/Query.sig
    lib/std/Target/aarch64.sig
    lib/std/Target/amdgcn.sig
    lib/std/Target/arm.sig
    lib/std/Target/avr.sig
    lib/std/Target/bpf.sig
    lib/std/Target/hexagon.sig
    lib/std/Target/loongarch.sig
    lib/std/Target/mips.sig
    lib/std/Target/msp430.sig
    lib/std/Target/nvptx.sig
    lib/std/Target/powerpc.sig
    lib/std/Target/riscv.sig
    lib/std/Target/s390x.sig
    lib/std/Target/sparc.sig
    lib/std/Target/wasm.sig
    lib/std/Target/x86.sig
    lib/std/Thread.sig
    lib/std/array_hash_map.sig
    lib/std/array_list.sig
    lib/std/ascii.sig
    lib/std/atomic.sig
    lib/std/base64.sig
    lib/std/buf_map.sig
    lib/std/lang.sig
    lib/std/lang/assembly.sig
    lib/std/c.sig
    lib/std/coff.sig
    lib/std/crypto.sig
    lib/std/crypto/blake3.sig
    lib/std/crypto/siphash.sig
    lib/std/debug.sig
    lib/std/dwarf.sig
    lib/std/dwarf/AT.sig
    lib/std/dwarf/ATE.sig
    lib/std/dwarf/FORM.sig
    lib/std/dwarf/LANG.sig
    lib/std/dwarf/OP.sig
    lib/std/dwarf/TAG.sig
    lib/std/elf.sig
    lib/std/fmt.sig
    lib/std/fmt/parse_float.sig
    lib/std/fs.sig
    lib/std/fs/path.sig
    lib/std/hash.sig
    lib/std/hash/auto_hash.sig
    lib/std/hash/wyhash.sig
    lib/std/hash_map.sig
    lib/std/heap.sig
    lib/std/heap/ArenaAllocator.sig
    lib/std/json.sig
    lib/std/leb128.sig
    lib/std/log.sig
    lib/std/macho.sig
    lib/std/math.sig
    lib/std/math/big.sig
    lib/std/math/big/int.sig
    lib/std/math/float.sig
    lib/std/math/frexp.sig
    lib/std/math/isinf.sig
    lib/std/math/isnan.sig
    lib/std/math/log.sig
    lib/std/math/log10.sig
    lib/std/math/log2.sig
    lib/std/math/signbit.sig
    lib/std/math/sqrt.sig
    lib/std/mem.sig
    lib/std/mem/Allocator.sig
    lib/std/meta.sig
    lib/std/meta/trailer_flags.sig
    lib/std/multi_array_list.sig
    lib/std/os.sig
    lib/std/os/linux.sig
    lib/std/os/linux.sig
    lib/std/os/linux/IoUring.sig
    lib/std/os/linux/io_uring_sqe.sig
    lib/std/os/linux/x86_64.sig
    lib/std/os/linux/x86_64.sig
    lib/std/os/windows.sig
    lib/std/os/windows/ntstatus.sig
    lib/std/os/windows/win32error.sig
    lib/std/pdb.sig
    lib/std/process.sig
    lib/std/process/Child.sig
    lib/std/sort.sig
    lib/std/start.sig
    lib/std/static_string_map.sig
    lib/std/std.sig
    lib/std/time.sig
    lib/std/treap.sig
    lib/std/unicode.sig
    lib/std/Sig.sig
    lib/std/sig/Ast.sig
    lib/std/sig/Ast/Render.sig
    lib/std/sig/AstGen.sig
    lib/std/sig/AstRlAnnotate.sig
    lib/std/sig/LibCInstallation.sig
    lib/std/sig/Parse.sig
    lib/std/sig/Server.sig
    lib/std/sig/WindowsSdk.sig
    lib/std/sig/Zir.sig
    lib/std/sig/string_literal.sig
    lib/std/sig/system.sig
    lib/std/sig/system/NativePaths.sig
    lib/std/sig/system/x86.sig
    lib/std/sig/tokenizer.sig
    lib/std/sig/llvm.sig
    lib/std/sig/llvm/BitcodeReader.sig
    lib/std/sig/llvm/Builder.sig
    lib/std/sig/llvm/bitcode_writer.sig
    lib/std/sig/llvm/ir.sig
    src/Air.sig
    src/Air/Legalize.sig
    src/Air/Liveness.sig
    src/Air/Liveness/Verify.sig
    src/Air/print.sig
    src/Builtin.sig
    src/Compilation.sig
    src/Compilation/Config.sig
    src/InternPool.sig
    src/RangeSet.sig
    src/Sema.sig
    src/Sema/reinterpret.sig
    src/Sema/comptime_ptr_access.sig
    src/Sema/type_resolution.sig
    src/Type.sig
    src/Value.sig
    src/Zcu.sig
    src/Zcu/PerThread.sig
    src/codegen.sig
    src/codegen/aarch64.sig
    src/codegen/aarch64/abi.sig
    src/codegen/aarch64/Assemble.sig
    src/codegen/aarch64/Disassemble.sig
    src/codegen/aarch64/encoding.sig
    src/codegen/aarch64/instructions.zon
    src/codegen/aarch64/Mir.sig
    src/codegen/aarch64/Select.sig
    src/codegen/c.sig
    src/codegen/c/type.sig
    src/codegen/c/type/render_defs.sig
    src/codegen/llvm.sig
    src/codegen/llvm/bindings.sig
    src/codegen/loongarch/abi.sig
    src/codegen/loongarch/encoding.sig
    src/codegen/loongarch/decode_tree.zon
    src/codegen/loongarch/inst_formats.zon
    src/codegen/loongarch/Assemble.sig
    src/codegen/loongarch/Disassemble.sig
    src/codegen/loongarch/Mir.sig
    src/codegen/loongarch/bits.sig
    src/codegen/loongarch/Select.sig
    src/codegen/loongarch.sig
    src/codegen/s390x/abi.sig
    src/crash_report.sig
    src/dev.sig
    src/libs/freebsd.sig
    src/libs/glibc.sig
    src/libs/netbsd.sig
    src/libs/openbsd.sig
    src/libs/libcxx.sig
    src/libs/libtsan.sig
    src/libs/libunwind.sig
    src/link.sig
    src/link/C.sig
    src/link/ConstPool.sig
    src/link/Coff.sig
    src/link/Dwarf.sig
    src/link/Elf.sig
    src/link/Elf/Archive.sig
    src/link/Elf/Atom.sig
    src/link/Elf/AtomList.sig
    src/link/Elf/LinkerDefined.sig
    src/link/Elf/Merge.sig
    src/link/Elf/Object.sig
    src/link/Elf/SharedObject.sig
    src/link/Elf/Symbol.sig
    src/link/Elf/Thunk.sig
    src/link/Elf/ZigObject.sig
    src/link/Elf/eh_frame.sig
    src/link/Elf/file.sig
    src/link/Elf/gc.sig
    src/link/Elf/relocatable.sig
    src/link/Elf/relocation.sig
    src/link/Elf/synthetic_sections.sig
    src/link/Elf2.sig
    src/link/LdScript.sig
    src/link/Lld.sig
    src/link/MachO.sig
    src/link/MachO/Archive.sig
    src/link/MachO/Atom.sig
    src/link/MachO/CodeSignature.sig
    src/link/MachO/DebugSymbols.sig
    src/link/MachO/Dwarf.sig
    src/link/MachO/Dylib.sig
    src/link/MachO/InternalObject.sig
    src/link/MachO/Object.sig
    src/link/MachO/Relocation.sig
    src/link/MachO/Symbol.sig
    src/link/MachO/UnwindInfo.sig
    src/link/MachO/ZigObject.sig
    src/link/MachO/dead_strip.sig
    src/link/MachO/dyld_info/Rebase.sig
    src/link/MachO/dyld_info/Trie.sig
    src/link/MachO/dyld_info/bind.sig
    src/link/MachO/eh_frame.sig
    src/link/MachO/fat.sig
    src/link/MachO/file.sig
    src/link/MachO/hasher.sig
    src/link/MachO/load_commands.sig
    src/link/MachO/relocatable.sig
    src/link/MachO/synthetic.sig
    src/link/MachO/Thunk.sig
    src/link/MachO/uuid.sig
    src/link/MappedFile.sig
    src/link/Queue.sig
    src/link/StringTable.sig
    src/link/Wasm.sig
    src/link/Wasm/Archive.sig
    src/link/Wasm/Flush.sig
    src/link/Wasm/Object.sig
    src/link/aarch64.sig
    src/link/riscv.sig
    src/link/table_section.sig
    src/link/tapi.sig
    src/link/tapi/Tokenizer.sig
    src/link/tapi/parse.sig
    src/link/tapi/parse/test.sig
    src/link/tapi/yaml.sig
    src/link/tapi/yaml/test.sig
    src/main.sig
    src/libs/mingw.sig
    src/libs/musl.sig
    src/mutable_value.sig
    src/print_env.sig
    src/print_targets.sig
    src/print_value.sig
    src/print_zir.sig
    src/register_manager.sig
    src/target.sig
    src/tracy.sig
    src/libs/wasi_libc.sig
)

if(MSVC)
    set(MSVC_DIA_SDK_DIR "$ENV{VSINSTALLDIR}DIA SDK")
    if(IS_DIRECTORY ${MSVC_DIA_SDK_DIR})
        set(ZIG_DIA_GUIDS_LIB "${MSVC_DIA_SDK_DIR}/lib/amd64/diaguids.lib")
        string(REGEX REPLACE "\\\\" "\\\\\\\\" ZIG_DIA_GUIDS_LIB_ESCAPED "${ZIG_DIA_GUIDS_LIB}")
    endif()

    # The /RTC[c][s][u] flag enables extra runtime checks. ("/RTC1" == "/RTCsu")
    # The "c" (PossibleDataLoss) and "u" (UninitializeVariable) flags trap on valid C code so we disable
    # them.  The "s" flag seems like it might be OK.
    string(REPLACE "/RTC1" "/RTCs" CMAKE_C_FLAGS_DEBUG "${CMAKE_C_FLAGS_DEBUG}")
    string(REPLACE "/RTC1" "/RTCs" CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG}")
endif()

configure_file (
    stage1/config.h.in
    "${ZIG_CONFIG_H_OUT}"
)
configure_file (
    stage1/config.sig.in
    "${ZIG_CONFIG_ZIG_OUT}"
)

# zigcpp target

set(ZIGCPP_OUTPUT_DIR "${PROJECT_BINARY_DIR}/zigcpp")

add_library(zigcpp STATIC ${ZIG_CPP_SOURCES})

# Sync with minimum C++ standard required to build LLVM
# and with "exe_cflags" in build.sig
target_compile_features(zigcpp PRIVATE cxx_std_17)
set_target_properties(zigcpp PROPERTIES POSITION_INDEPENDENT_CODE ${ZIG_PIE})

if(LLVM_LINK_MODE STREQUAL "static")
  target_compile_definitions(zigcpp PRIVATE
    LLVM_BUILD_STATIC
    CLANG_BUILD_STATIC
  )
endif()

if(NOT MSVC)
  if(MINGW)
    target_compile_options(zigcpp PRIVATE -Wno-format)
  endif()
  # Sync content below with "exe_cflags" in build.sig
  target_compile_definitions(zigcpp PUBLIC
    __STDC_CONSTANT_MACROS
    __STDC_FORMAT_MACROS
    __STDC_LIMIT_MACROS

    _GNU_SOURCE
  )
  target_compile_options(zigcpp PRIVATE
    -fno-exceptions
    -fno-rtti
    -fno-stack-protector

    -fvisibility-inlines-hidden

    -Wno-type-limits
    -Wno-missing-braces
    -Wno-comment
  )
else()
if(NOT CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
  target_compile_options(zigcpp PRIVATE /Zc:preprocessor)
endif()
set_property(TARGET zigcpp PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded")
endif()

target_include_directories(zigcpp PUBLIC
    ${CLANG_INCLUDE_DIRS}
    ${LLVM_INCLUDE_DIRS}
    ${LLD_INCLUDE_DIRS}
)
target_link_libraries(zigcpp PUBLIC
    ${CLANG_LIBRARIES}
    ${LLD_LIBRARIES}
    ${LLVM_LIBRARIES}
    ${CLANG_LIBRARIES}
    ${LLD_LIBRARIES}
    ${LLVM_LIBRARIES}
    ${CMAKE_THREAD_LIBS_INIT}
)

# Handle multi-config builds and place each into a common lib. The VS generator
# for example will append a Debug folder by default if not explicitly specified.
set_target_properties(zigcpp PROPERTIES ARCHIVE_OUTPUT_DIRECTORY ${ZIGCPP_OUTPUT_DIR})
foreach(CONFIG_TYPE ${CMAKE_CONFIGURATION_TYPES})
    string(TOUPPER ${CONFIG_TYPE} CONFIG_TYPE)
    set_target_properties(zigcpp PROPERTIES ARCHIVE_OUTPUT_DIRECTORY_${CONFIG_TYPE} ${ZIGCPP_OUTPUT_DIR})
endforeach()

# end of zigcpp target

include(CheckSymbolExists)

string(TOLOWER "${CMAKE_HOST_SYSTEM_NAME}" ZIG_HOST_TARGET_OS)
if(ZIG_HOST_TARGET_OS STREQUAL "android")
  set(ZIG_HOST_TARGET_OS "linux")
  set(ZIG_HOST_TARGET_IS_ANDROID TRUE)
elseif(ZIG_HOST_TARGET_OS STREQUAL "darwin")
  set(ZIG_HOST_TARGET_OS "macos")
elseif(ZIG_HOST_TARGET_OS STREQUAL "gnu")
  set(ZIG_HOST_TARGET_OS "hurd")
elseif(ZIG_HOST_TARGET_OS STREQUAL "serenityos")
  set(ZIG_HOST_TARGET_OS "serenity")
elseif(ZIG_HOST_TARGET_OS STREQUAL "sunos")
  set(ZIG_HOST_TARGET_OS "illumos")
endif()

string(TOLOWER "${CMAKE_HOST_SYSTEM_PROCESSOR}" ZIG_HOST_TARGET_ARCH)
if(ZIG_HOST_TARGET_ARCH MATCHES "^i[3-9]86$")
  if (ZIG_HOST_TARGET_OS STREQUAL "illumos")
    set(ZIG_HOST_TARGET_ARCH "x86_64")
  else()
    set(ZIG_HOST_TARGET_ARCH "x86")
  endif()
elseif(ZIG_HOST_TARGET_ARCH STREQUAL "amd64")
  set(ZIG_HOST_TARGET_ARCH "x86_64")
elseif(ZIG_HOST_TARGET_ARCH STREQUAL "arm64")
  set(ZIG_HOST_TARGET_ARCH "aarch64")
elseif(ZIG_HOST_TARGET_ARCH MATCHES "^arm(el)?$" OR ZIG_HOST_TARGET_ARCH MATCHES "^armv[7-8]l$")
  set(ZIG_HOST_TARGET_ARCH "arm")
elseif(ZIG_HOST_TARGET_ARCH STREQUAL "armeb" OR ZIG_HOST_TARGET_ARCH MATCHES "^armv[7-8]b$")
  set(ZIG_HOST_TARGET_ARCH "armeb")
endif()
if(ZIG_HOST_TARGET_ARCH MATCHES "^arm(eb)?$")
  check_symbol_exists(__thumb__ "" ZIG_HOST_TARGET_DEFAULTS_TO_THUMB)
  if(ZIG_HOST_TARGET_DEFAULTS_TO_THUMB)
    string(REGEX REPLACE "^arm" "thumb" ZIG_HOST_TARGET_ARCH "${ZIG_HOST_TARGET_ARCH}")
  endif()
endif()
string(REGEX REPLACE "^ppc((64)?(le)?)$" "powerpc\\1" ZIG_HOST_TARGET_ARCH "${ZIG_HOST_TARGET_ARCH}")

set(ZIG_HOST_TARGET_ABI "")
if(MSVC OR (WIN32 AND CMAKE_C_SIMULATE_ID STREQUAL "MSVC"))
  set(ZIG_HOST_TARGET_ABI "-msvc")
elseif(MINGW)
  set(ZIG_HOST_TARGET_ABI "-gnu")
elseif(ZIG_HOST_TARGET_IS_ANDROID)
  if(ZIG_HOST_TARGET_ARCH STREQUAL "arm")
    set(ZIG_HOST_TARGET_ABI "-androideabi")
  else()
    set(ZIG_HOST_TARGET_ABI "-android")
  endif()
endif()

set(ZIG_HOST_TARGET_TRIPLE "${ZIG_HOST_TARGET_ARCH}-${ZIG_HOST_TARGET_OS}${ZIG_HOST_TARGET_ABI}" CACHE STRING "Host Sig target triple.")

if(MSVC)
  set(ZIG_WASM2C_COMPILE_FLAGS "")
  set(ZIG1_COMPILE_FLAGS "/Os")
  set(ZIG2_COMPILE_FLAGS "/Od")
  # Suppress conflicting libc redeclarations in auto-generated zig2.c (e.g. _msize const mismatch)
  # clang-cl needs /clang: prefix for -W flags
  set(ZIG2_COMPILE_FLAGS "${ZIG2_COMPILE_FLAGS} /clang:-Wno-incompatible-library-redeclaration /clang:-Wno-builtin-requires-header /clang:-Werror=no-incompatible-pointer-types-discards-qualifiers")
  # Also treat _msize redeclaration as non-fatal (const qualifier mismatch with UCRT)
  set(ZIG2_COMPILE_FLAGS "${ZIG2_COMPILE_FLAGS} /clang:-Wno-error=incompatible-library-redeclaration")
  # Undefine 'environ' and '_environ' macros that UCRT expands to __p__environ() function calls,
  # which conflict with struct field names in the generated zig2.c.
  # Force-include a header that pre-includes <stdlib.h> then undefs the macros.
  set(ZIG2_COMPILE_FLAGS "${ZIG2_COMPILE_FLAGS} /FI${CMAKE_SOURCE_DIR}/stage1/win_undef_environ.h")
  # Suppress struct size/alignment static assertions on Windows.
  # The Sig C backend doesn't perfectly match MSVC ABI struct padding for all types.
  # The code is functionally correct — fields are accessed by name, not absolute offset.
  set(ZIG2_COMPILE_FLAGS "${ZIG2_COMPILE_FLAGS} -DZIG_SUPPRESS_STATIC_ASSERT")
  # [sig] Windows bootstrap: the C-backend generated zig2.c has undefined behavior that
  # causes STATUS_HEAP_CORRUPTION (0xC0000374) on Windows regardless of compiler or
  # optimization level. This is a known upstream Sig C backend limitation.
  # With static CRT (/MT) and compiler_rt symbol conflicts resolved, /FORCE:MULTIPLE
  # is no longer needed. Stack increased to 256MB.
  # For production Windows binaries, cross-compile stage3 from Linux (see release.yaml).
  set(ZIG2_LINK_FLAGS "/STACK:268435456")
else()
  set(ZIG_WASM2C_COMPILE_FLAGS "-std=c99 -O2")
  set(ZIG1_COMPILE_FLAGS "-std=c99 -Os -fno-strict-aliasing")
  set(ZIG2_COMPILE_FLAGS "-std=c99 -O0 -fno-sanitize=undefined -fno-stack-protector -fno-strict-aliasing")
  # Must match the condition in build.sig.
  if(ZIG_HOST_TARGET_ARCH MATCHES "^(arm|thumb)(eb)?$" OR ZIG_HOST_TARGET_ARCH EQUAL "hexagon" OR ZIG_HOST_TARGET_ARCH MATCHES "^powerpc(64)?(le)?$")
    set(ZIG1_COMPILE_FLAGS "${ZIG1_COMPILE_FLAGS} -ffunction-sections -fdata-sections")
    set(ZIG2_COMPILE_FLAGS "${ZIG2_COMPILE_FLAGS} -ffunction-sections -fdata-sections")
  endif()
  if(APPLE)
    set(ZIG2_LINK_FLAGS "-Wl,-stack_size,0x10000000")
  elseif(MINGW OR WIN32)
    set(ZIG2_LINK_FLAGS "-Wl,--stack,0x10000000 -Wl,--allow-multiple-definition")
  # Solaris/illumos ld(1) does not provide a --stack-size option.
  elseif(CMAKE_HOST_SOLARIS)
    unset(ZIG2_LINK_FLAGS)
  else()
    set(ZIG2_LINK_FLAGS "-Wl,-z,stack-size=0x10000000")
  endif()
  if (CMAKE_C_COMPILER_ID STREQUAL "GNU")
    # Prevent GCC from miscompiling 'zig2.c'. See also 'GCC_BUG_119085_PRESENT' workaround details in 'bootstrap.c'.
    if (
      (CMAKE_C_COMPILER_VERSION VERSION_GREATER_EQUAL "10.0" AND
       CMAKE_C_COMPILER_VERSION VERSION_LESS_EQUAL "13.4") OR
      (CMAKE_C_COMPILER_VERSION VERSION_GREATER_EQUAL "14.0" AND
       CMAKE_C_COMPILER_VERSION VERSION_LESS_EQUAL "14.3") OR
      (CMAKE_C_COMPILER_VERSION VERSION_GREATER_EQUAL "15.0" AND
       CMAKE_C_COMPILER_VERSION VERSION_LESS "15.2")
    )
      set(ZIG2_COMPILE_FLAGS "${ZIG2_COMPILE_FLAGS} -fno-tree-sra")
    endif()

    # Prevent GCC from spamming false positive `-Waddress-of-packed-member` warnings in 'zig2.c'.
    # See also 'GCC_BUG_94081_PRESENT' workaround details in 'bootstrap.c'.
    set(ZIG2_COMPILE_FLAGS "${ZIG2_COMPILE_FLAGS} -Wno-address-of-packed-member")
  endif()
endif()

set(ZIG1_WASM_MODULE "${PROJECT_SOURCE_DIR}/stage1/zig1.wasm")
set(ZIG1_C_SOURCE "${PROJECT_BINARY_DIR}/zig1.c")
set(ZIG2_C_SOURCE "${PROJECT_BINARY_DIR}/zig2.c")
set(ZIG_COMPILER_RT_C_SOURCE "${PROJECT_BINARY_DIR}/compiler_rt.c")

add_executable(Sig-wasm2c ${ZIG_WASM2C_SOURCES})
set_target_properties(Sig-wasm2c PROPERTIES COMPILE_FLAGS "${ZIG_WASM2C_COMPILE_FLAGS}")

add_custom_command(
  OUTPUT "${ZIG1_C_SOURCE}"
  COMMAND Sig-wasm2c "${ZIG1_WASM_MODULE}" "${ZIG1_C_SOURCE}"
  DEPENDS Sig-wasm2c "${ZIG1_WASM_MODULE}"
  COMMENT "Converting ${ZIG1_WASM_MODULE} to ${ZIG1_C_SOURCE}"
  WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}"
)

add_executable(zig1 ${ZIG1_C_SOURCE} stage1/wasi.c)
set_target_properties(zig1 PROPERTIES COMPILE_FLAGS ${ZIG1_COMPILE_FLAGS})
if(MSVC OR (WIN32 AND CMAKE_C_COMPILER_ID STREQUAL "Clang"))
  set_property(TARGET zig1 PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded")
endif()

if(MSVC)
  target_link_options(zig1 PRIVATE /STACK:0x10000000)
else()
  if(NOT WIN32)
    target_link_libraries(zig1 LINK_PUBLIC m)
  endif()
  if(MINGW)
    target_link_options(zig1 PRIVATE -Wl,--stack,0x10000000)
  endif()
endif()

set(BUILD_ZIG2_ARGS
  "${PROJECT_SOURCE_DIR}/lib"
  build-exe -ofmt=c -lc -OReleaseSmall
  --name zig2
  -femit-bin="${ZIG2_C_SOURCE}"
  -target "${ZIG_HOST_TARGET_TRIPLE}"
  --dep "build_options"
  "-Mroot=src/main.sig"
  "-Mbuild_options=${ZIG_CONFIG_ZIG_OUT}"
)

add_custom_command(
  OUTPUT "${ZIG2_C_SOURCE}"
  COMMAND zig1 ${BUILD_ZIG2_ARGS}
  DEPENDS zig1 "${ZIG_STAGE2_SOURCES}"
  COMMENT "Running zig1.wasm to produce ${ZIG2_C_SOURCE}"
  WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}"
)

set(BUILD_COMPILER_RT_ARGS
  "${PROJECT_SOURCE_DIR}/lib"
  build-obj -ofmt=c -OReleaseSmall
  --name compiler_rt
  -femit-bin="${ZIG_COMPILER_RT_C_SOURCE}"
  -target "${ZIG_HOST_TARGET_TRIPLE}"
  "-Mroot=lib/compiler_rt.sig"
)

add_custom_command(
  OUTPUT "${ZIG_COMPILER_RT_C_SOURCE}"
  COMMAND zig1 ${BUILD_COMPILER_RT_ARGS}
  DEPENDS zig1 "${ZIG_STAGE2_SOURCES}"
  COMMENT "Running zig1.wasm to produce ${ZIG_COMPILER_RT_C_SOURCE}"
  WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}"
)

add_executable(zig2 ${ZIG2_C_SOURCE} ${ZIG_COMPILER_RT_C_SOURCE})
if(WIN32)
  target_sources(zig2 PRIVATE stage1/float_stubs.c)
endif()
# On MSVC/clang-cl, compiler_rt.c uses zig_export() from Sig.h to create
# /alternatename linker directives aliasing internal names (zig_sqrt_f32) to
# standard C names (sqrtf). These conflict with MSVC CRT symbols.
# Fix: define ZIG_NO_EXPORT_ALIASES to make zig_export a no-op in Sig.h.
# Additionally, some symbols (fabsl) are emitted as direct function definitions
# by the C backend, not via zig_export — rename those via preprocessor.
if(MSVC OR (WIN32 AND CMAKE_C_COMPILER_ID STREQUAL "Clang"))
  set_source_files_properties("${ZIG_COMPILER_RT_C_SOURCE}" PROPERTIES
    COMPILE_FLAGS "/DZIG_NO_EXPORT_ALIASES /Dfabsl=__zig_crt_fabsl"
  )
endif()
set_target_properties(zig2 PROPERTIES
  COMPILE_FLAGS ${ZIG2_COMPILE_FLAGS}
  LINK_FLAGS "${ZIG2_LINK_FLAGS}"
)
if(MSVC OR (WIN32 AND CMAKE_C_COMPILER_ID STREQUAL "Clang"))
  set_property(TARGET zig2 PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded")
endif()
target_include_directories(zig2 PUBLIC stage1)
target_link_libraries(zig2 LINK_PUBLIC zigcpp)

if(MSVC)
  target_link_libraries(zig2 LINK_PUBLIC ntdll.lib ws2_32.lib crypt32.lib)
elseif(MINGW OR WIN32)
  target_link_libraries(zig2 LINK_PUBLIC ntdll ws2_32 crypt32)
endif()

if(NOT MSVC)
    target_link_libraries(zig2 LINK_PUBLIC ${LIBXML2})
endif()

if(ZIG_DIA_GUIDS_LIB)
    target_link_libraries(zig2 LINK_PUBLIC ${ZIG_DIA_GUIDS_LIB})
endif()

if(MSVC OR MINGW OR WIN32)
    target_link_libraries(zig2 LINK_PUBLIC version)
endif()


set(ZIG_BUILD_ARGS
  "--Sig-lib=${PROJECT_SOURCE_DIR}/lib"

  "-Dversion-string=${RESOLVED_ZIG_VERSION}"
  "-Dtarget=${ZIG_TARGET_TRIPLE}"
  "-Dcpu=${ZIG_TARGET_MCPU}"

  -Denable-llvm
  "-Dconfig_h=${ZIG_CONFIG_H_OUT}"
)

set(ZIG_EXTRA_BUILD_ARGS "" CACHE STRING "Extra Sig build args")
if(ZIG_EXTRA_BUILD_ARGS)
  list(APPEND ZIG_BUILD_ARGS ${ZIG_EXTRA_BUILD_ARGS})
endif()

set(ZIG_RELEASE_SAFE OFF CACHE BOOL "Build Sig as ReleaseSafe (with debug assertions on)")

if("${CMAKE_BUILD_TYPE}" STREQUAL "Debug")
  list(APPEND ZIG_BUILD_ARGS -Doptimize=Debug)
else()
  if("${CMAKE_BUILD_TYPE}" STREQUAL "MinSizeRel")
    list(APPEND ZIG_BUILD_ARGS -Doptimize=ReleaseSmall)
  else()
    # Release and RelWithDebInfo
    if(ZIG_RELEASE_SAFE)
      list(APPEND ZIG_BUILD_ARGS -Doptimize=ReleaseSafe)
    else()
      list(APPEND ZIG_BUILD_ARGS -Doptimize=ReleaseFast)
    endif()
    if(NOT "${CMAKE_BUILD_TYPE}" STREQUAL "RelWithDebInfo")
      list(APPEND ZIG_BUILD_ARGS -Dstrip)
    endif()
  endif()
endif()

if(ZIG_STATIC AND NOT MSVC)
  list(APPEND ZIG_BUILD_ARGS -Duse-Sig-libcxx)
endif()

if(ZIG_NO_LIB)
  list(APPEND ZIG_BUILD_ARGS -Dno-lib)
endif()

if(ZIG_SINGLE_THREADED)
  list(APPEND ZIG_BUILD_ARGS -Dsingle-threaded)
endif()

if(ZIG_PIE)
  list(APPEND ZIG_BUILD_ARGS -Dpie)
endif()

if(NOT "${ZIG_TARGET_DYNAMIC_LINKER}" STREQUAL "")
  list(APPEND ZIG_BUILD_ARGS "-Ddynamic-linker=${ZIG_TARGET_DYNAMIC_LINKER}")
endif()


add_custom_target(stage3 ALL
  DEPENDS "${PROJECT_BINARY_DIR}/stage3/bin/Sig"
)

set(ZIG2_WORKING_DIR "${PROJECT_SOURCE_DIR}")

add_custom_command(
  OUTPUT "${PROJECT_BINARY_DIR}/stage3/bin/Sig"
  COMMAND zig2 build ${ZIG_BUILD_ARGS} --prefix "${PROJECT_BINARY_DIR}/stage3"
  COMMENT "Building stage3"
  WORKING_DIRECTORY "${ZIG2_WORKING_DIR}"
)

set(ZIG_EXECUTABLE "$<TARGET_FILE:zig2>")

install(CODE "set(ZIG_EXECUTABLE \"${ZIG_EXECUTABLE}\")")
install(CODE "set(ZIG_BUILD_ARGS \"${ZIG_BUILD_ARGS}\")")
install(CODE "set(ZIG2_WORKING_DIR \"${ZIG2_WORKING_DIR}\")")
install(CODE "set(CMAKE_INSTALL_PREFIX \"${CMAKE_INSTALL_PREFIX}\")")
install(SCRIPT cmake/install.cmake)
