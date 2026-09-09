# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(consumable_tracker_desktop LANGUAGES CXX)

# The build script selects one immutable desktop product through an environment
# variable. ProductName is also varied in Runner.rc so Windows gives each app
# its own SharedPreferences / app-support directory.
set(SOHUN_APP_VARIANT "$ENV{SOHUN_APP_VARIANT}")
if(SOHUN_APP_VARIANT STREQUAL "farm")
  set(BINARY_NAME "sohun-farm")
  set(SOHUN_FARM_PRODUCT TRUE)
else()
  set(BINARY_NAME "sohun")
  set(SOHUN_FARM_PRODUCT FALSE)
endif()

# scripts/prepare_sqlite_cache.ps1 exposes a verified local SQLite source
# directory through the environment. FetchContent only reads a CMake variable,
# so promote the environment value before generated plugin CMake files run.
if(DEFINED ENV{FETCHCONTENT_SOURCE_DIR_SQLITE3})
  file(TO_CMAKE_PATH "$ENV{FETCHCONTENT_SOURCE_DIR_SQLITE3}"
    SQLITE3_LOCAL_SOURCE_DIR)
  if(EXISTS "${SQLITE3_LOCAL_SOURCE_DIR}/sqlite3.c")
    set(FETCHCONTENT_SOURCE_DIR_SQLITE3 "${SQLITE3_LOCAL_SOURCE_DIR}"
      CACHE PATH "Verified local SQLite source" FORCE)
  else()
    message(FATAL_ERROR
      "FETCHCONTENT_SOURCE_DIR_SQLITE3 does not contain sqlite3.c: "
      "${SQLITE3_LOCAL_SOURCE_DIR}")
  endif()
endif()

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_options(${TARGET} PRIVATE /utf-8)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
# CMake's upstream downloader can leave an empty archive on connection reset.
# Share verified downloads between direct Flutter builds and staged builds.
set(SOHUN_MEDIA_KIT_PLUGIN
  "${FLUTTER_MANAGED_DIR}/ephemeral/.plugin_symlinks/media_kit_libs_windows_video/windows/CMakeLists.txt")
if(EXISTS "${SOHUN_MEDIA_KIT_PLUGIN}")
  include(cmake/prepare_media_kit.cmake)
  if(DEFINED ENV{SOHUN_MEDIA_KIT_CACHE_DIR})
    file(TO_CMAKE_PATH "$ENV{SOHUN_MEDIA_KIT_CACHE_DIR}" SOHUN_MEDIA_KIT_CACHE_DIR)
  elseif(DEFINED ENV{LOCALAPPDATA})
    file(TO_CMAKE_PATH "$ENV{LOCALAPPDATA}/consumable_build_cache/media_kit"
      SOHUN_MEDIA_KIT_CACHE_DIR)
  else()
    set(SOHUN_MEDIA_KIT_CACHE_DIR "${CMAKE_BINARY_DIR}/dependency_cache/media_kit")
  endif()
  sohun_prepare_media_kit("${SOHUN_MEDIA_KIT_PLUGIN}"
    "${SOHUN_MEDIA_KIT_CACHE_DIR}" "${CMAKE_BINARY_DIR}")
endif()
include(flutter/generated_plugins.cmake)

# webview_windows 0.4.x still enables MSVC's legacy /await mode. Newer
# Visual Studio toolchains treat the resulting experimental coroutine header
# diagnostic as a hard error, so silence only that compatibility diagnostic for
# the plugin target (the app itself keeps the normal warning policy).
if(TARGET webview_windows_plugin)
  target_compile_definitions(webview_windows_plugin PRIVATE
    _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)
endif()


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
# A Flutter desktop build installs into the runner output so it can execute in
# place. Newer CMake releases may pre-populate Program Files before exposing
# CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT, which would require elevation.
set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

# A clean Windows machine need not have Visual Studio's C++ runtime installed.
# Bundle the compiler's redistributable (not Debug_NonRedist) next to the exe.
include(cmake/install_msvc_runtime.cmake)

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
