cmake_minimum_required(VERSION 3.15)

if(NOT DEFINED TEST_ROOT)
  message(FATAL_ERROR "TEST_ROOT is required")
endif()

include("${CMAKE_CURRENT_LIST_DIR}/../RelocateLlvmSystemLibraries.cmake")

set(_llvm_libdir "${TEST_ROOT}/llvm/lib")
set(_existing_libdir "${TEST_ROOT}/system/lib")
file(MAKE_DIRECTORY "${_llvm_libdir}" "${_existing_libdir}")
file(WRITE "${_llvm_libdir}/libzstd.a" "")
file(WRITE "${_existing_libdir}/libz.a" "")

set(LLVM_LIBDIRS "${_llvm_libdir}")
set(LLVM_SYSTEM_LIBS
  "/sig-producer-path-that-does-not-exist/zstd-out/lib/libzstd.a"
  "${_existing_libdir}/libz.a"
  "-lpthread")

zig_relocate_llvm_system_libraries(LLVM_SYSTEM_LIBS LLVM_LIBDIRS)

set(_expected
  "${_llvm_libdir}/libzstd.a"
  "${_existing_libdir}/libz.a"
  "-lpthread")
if(NOT LLVM_SYSTEM_LIBS STREQUAL _expected)
  message(FATAL_ERROR
    "Unexpected relocation result: '${LLVM_SYSTEM_LIBS}', expected '${_expected}'")
endif()

message(STATUS "llvm-config system-library relocation test passed")
