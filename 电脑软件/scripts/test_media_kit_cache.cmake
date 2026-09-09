# Run with cmake -P scripts/test_media_kit_cache.cmake. No network is required.
include("${CMAKE_CURRENT_LIST_DIR}/../windows/cmake/prepare_media_kit.cmake")
set(SOHUN_MEDIA_KIT_ALLOW_DOWNLOADS OFF)

if(MODE STREQUAL "reject")
  sohun_prepare_media_kit("${FIXTURE_ROOT}/plugin.cmake"
    "${FIXTURE_ROOT}/cache" "${FIXTURE_ROOT}/build")
  message(FATAL_ERROR "A corrupt archive was unexpectedly accepted.")
endif()

string(RANDOM LENGTH 12 ALPHABET 0123456789abcdef nonce)
get_filename_component(root
  "${CMAKE_CURRENT_LIST_DIR}/../build/media_kit_cache_test/${nonce}" ABSOLUTE)
file(MAKE_DIRECTORY "${root}/cache" "${root}/build")
file(WRITE "${root}/plugin.cmake" "# synthetic plugin metadata\n")
foreach(dependency LIBMPV ANGLE)
  set(archive "${dependency}.7z")
  file(WRITE "${root}/cache/${archive}" "verified fixture for ${dependency}")
  file(MD5 "${root}/cache/${archive}" expected)
  file(APPEND "${root}/plugin.cmake"
    "set(${dependency} \"${archive}\")\n"
    "set(${dependency}_MD5 \"${expected}\")\n"
    "set(${dependency}_URL \"https://example.invalid/\${${dependency}}\")\n")
  # Reproduce the original zero-byte build artifact.
  file(WRITE "${root}/build/${archive}" "")
endforeach()

sohun_prepare_media_kit("${root}/plugin.cmake" "${root}/cache" "${root}/build")
foreach(dependency LIBMPV ANGLE)
  file(MD5 "${root}/cache/${dependency}.7z" expected)
  file(MD5 "${root}/build/${dependency}.7z" actual)
  if(NOT actual STREQUAL expected)
    message(FATAL_ERROR "A zero-byte build artifact was not repaired.")
  endif()
endforeach()
message(STATUS "PASS: verified cache repairs empty build artifacts without downloads")

sohun_prepare_media_kit("${root}/plugin.cmake" "${root}/new-cache" "${root}/build")
foreach(dependency LIBMPV ANGLE)
  file(MD5 "${root}/cache/${dependency}.7z" expected)
  file(MD5 "${root}/new-cache/${dependency}.7z" actual)
  if(NOT actual STREQUAL expected)
    message(FATAL_ERROR "A verified build artifact was not cached.")
  endif()
endforeach()
message(STATUS "PASS: verified build artifacts populate a fresh shared cache")

file(WRITE "${root}/cache/LIBMPV.7z" "invalid response")
file(WRITE "${root}/build/LIBMPV.7z" "")
execute_process(COMMAND "${CMAKE_COMMAND}" -DMODE=reject "-DFIXTURE_ROOT=${root}"
  -P "${CMAKE_CURRENT_LIST_FILE}" RESULT_VARIABLE result
  OUTPUT_VARIABLE output ERROR_VARIABLE error)
if(result EQUAL 0 OR NOT error MATCHES "No verified media_kit archive")
  message(FATAL_ERROR "Corrupt cache rejection failed: ${output}\n${error}")
endif()
file(SIZE "${root}/build/LIBMPV.7z" staged_size)
if(NOT staged_size EQUAL 0)
  message(FATAL_ERROR "Corrupt cache was copied into the build.")
endif()
message(STATUS "PASS: corrupt caches fail closed and never become build artifacts")
