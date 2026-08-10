# LLVM's llvm-config can preserve absolute paths to imported static system
# libraries from the machine that built LLVM. Release closures copy those
# libraries into LLVM's installed lib directory, so resolve only missing
# absolute entries by basename against that directory. Existing paths and
# ordinary linker flags remain untouched.
function(zig_relocate_llvm_system_libraries libraries_variable library_dirs_variable)
  set(_resolved_libraries "")

  foreach(_library IN LISTS ${libraries_variable})
    set(_resolved_library "${_library}")

    if(IS_ABSOLUTE "${_library}" AND NOT EXISTS "${_library}")
      get_filename_component(_library_name "${_library}" NAME)
      set(_relocated_library "")

      foreach(_library_dir IN LISTS ${library_dirs_variable})
        set(_candidate "${_library_dir}/${_library_name}")
        if(EXISTS "${_candidate}")
          set(_relocated_library "${_candidate}")
          break()
        endif()
      endforeach()

      if(NOT _relocated_library)
        message(FATAL_ERROR
          "llvm-config reported missing absolute system library '${_library}', "
          "and '${_library_name}' was not found in LLVM library directories: "
          "${${library_dirs_variable}}")
      endif()

      message(STATUS
        "Relocated llvm-config system library '${_library}' to '${_relocated_library}'")
      set(_resolved_library "${_relocated_library}")
    endif()

    list(APPEND _resolved_libraries "${_resolved_library}")
  endforeach()

  set(${libraries_variable} "${_resolved_libraries}" PARENT_SCOPE)
endfunction()
