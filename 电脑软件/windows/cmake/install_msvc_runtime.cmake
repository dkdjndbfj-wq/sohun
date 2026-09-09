# App-local deployment, as required by Flutter's Windows distribution guide.
# Windows 10+ provides the UCRT; only the MSVC redistributables are bundled.
if(MSVC)
  set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)
  set(CMAKE_INSTALL_DEBUG_LIBRARIES FALSE)
  set(CMAKE_INSTALL_DEBUG_LIBRARIES_ONLY FALSE)
  include(InstallRequiredSystemLibraries)

  # New toolsets may provide additional runtime dependencies before CMake's
  # module learns their names. Use only the selected toolset's CRT directory.
  foreach(runtime IN ITEMS vcruntime140_threads.dll vccorlib140.dll)
    if(EXISTS "${MSVC_CRT_DIR}/${runtime}")
      list(APPEND CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS "${MSVC_CRT_DIR}/${runtime}")
    endif()
  endforeach()
  list(REMOVE_DUPLICATES CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS)

  set(SOHUN_MSVC_RUNTIME_NAMES "")
  set(SOHUN_MSVC_RUNTIME_HASHES "")
  foreach(runtime IN LISTS CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS)
    get_filename_component(runtime_name "${runtime}" NAME)
    string(TOLOWER "${runtime_name}" runtime_name)
    list(APPEND SOHUN_MSVC_RUNTIME_NAMES "${runtime_name}")
    file(SHA256 "${runtime}" runtime_hash)
    string(APPEND SOHUN_MSVC_RUNTIME_HASHES "${runtime_hash}  ${runtime_name}\n")
  endforeach()
  foreach(required IN ITEMS msvcp140.dll vcruntime140.dll vcruntime140_1.dll)
    if(NOT required IN_LIST SOHUN_MSVC_RUNTIME_NAMES)
      message(FATAL_ERROR
        "Required redistributable ${required} was not found. Install the MSVC "
        "x64 redistributable build tools; do not copy DLLs from System32.")
    endif()
  endforeach()

  file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/msvc-runtime.sha256"
    "${SOHUN_MSVC_RUNTIME_HASHES}")
  install(FILES ${CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS}
    "${CMAKE_CURRENT_BINARY_DIR}/msvc-runtime.sha256"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
endif()
