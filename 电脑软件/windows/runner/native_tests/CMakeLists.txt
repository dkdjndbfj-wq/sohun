cmake_minimum_required(VERSION 3.14)
project(sohun_desktop_rfid_native_tests LANGUAGES CXX)

if(NOT WIN32)
  message(FATAL_ERROR "This native transport test requires Windows.")
endif()

add_executable(desktop_rfid_serial_transport_test
  desktop_rfid_serial_transport_test.cpp
  ../desktop_rfid_serial_transport.cpp
)
target_include_directories(desktop_rfid_serial_transport_test PRIVATE ..)
target_compile_features(desktop_rfid_serial_transport_test PRIVATE cxx_std_17)
target_compile_options(desktop_rfid_serial_transport_test PRIVATE
  /W4 /WX /EHsc /utf-8 /wd4100)
target_compile_definitions(desktop_rfid_serial_transport_test PRIVATE
  UNICODE _UNICODE NOMINMAX _HAS_EXCEPTIONS=0)
target_link_libraries(desktop_rfid_serial_transport_test PRIVATE
  setupapi.lib advapi32.lib)
enable_testing()
add_test(NAME desktop_rfid_serial_transport
  COMMAND desktop_rfid_serial_transport_test)

# Pass the installed SDK's bin/cache/artifacts/engine/windows-x64 directory to
# also compile the actual Flutter MethodChannel adapter against its real codec.
# These tests use a fake messenger/backend, never a live Flutter engine or COM.
set(SOHUN_FLUTTER_ENGINE_DIR "" CACHE PATH "Flutter Windows engine artifacts")
if(SOHUN_FLUTTER_ENGINE_DIR)
  set(RFID_WRAPPER_DIR "${SOHUN_FLUTTER_ENGINE_DIR}/cpp_client_wrapper")
  if(NOT EXISTS "${RFID_WRAPPER_DIR}/standard_codec.cc" OR
     NOT EXISTS "${SOHUN_FLUTTER_ENGINE_DIR}/flutter_windows.dll.lib")
    message(FATAL_ERROR "Incomplete Flutter Windows engine artifacts.")
  endif()
  add_executable(desktop_rfid_serial_channel_test
    desktop_rfid_serial_channel_test.cpp
    ../desktop_rfid_serial_channel.cpp
    ../desktop_rfid_serial_transport.cpp
    "${RFID_WRAPPER_DIR}/core_implementations.cc"
    "${RFID_WRAPPER_DIR}/standard_codec.cc"
  )
  target_include_directories(desktop_rfid_serial_channel_test PRIVATE
    .. "${RFID_WRAPPER_DIR}/include" "${SOHUN_FLUTTER_ENGINE_DIR}")
  target_compile_features(desktop_rfid_serial_channel_test PRIVATE cxx_std_17)
  target_compile_options(desktop_rfid_serial_channel_test PRIVATE
    /W4 /WX /EHsc /utf-8 /wd4100)
  target_compile_definitions(desktop_rfid_serial_channel_test PRIVATE
    UNICODE _UNICODE NOMINMAX _HAS_EXCEPTIONS=0)
  target_link_libraries(desktop_rfid_serial_channel_test PRIVATE
    setupapi.lib advapi32.lib
    "${SOHUN_FLUTTER_ENGINE_DIR}/flutter_windows.dll.lib")
  add_custom_command(TARGET desktop_rfid_serial_channel_test POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${SOHUN_FLUTTER_ENGINE_DIR}/flutter_windows.dll"
      "$<TARGET_FILE_DIR:desktop_rfid_serial_channel_test>")
  add_test(NAME desktop_rfid_serial_channel
    COMMAND desktop_rfid_serial_channel_test)
endif()
