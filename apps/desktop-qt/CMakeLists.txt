cmake_minimum_required(VERSION 3.22)
project(tepy_desktop VERSION 0.1.1 LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 6.8 REQUIRED COMPONENTS Core Widgets Network SerialPort)
add_library(tepy_desktop_lib STATIC
    src/protocol.cpp src/protocol.hpp
    src/serial_port.cpp src/serial_port.hpp
    src/device_client.cpp src/device_client.hpp
    src/config_form.cpp src/config_form.hpp
    src/flash_job.cpp src/flash_job.hpp
    src/main_window.cpp src/main_window.hpp src/ui.cpp src/ui.hpp)
target_include_directories(tepy_desktop_lib PUBLIC src)
target_link_libraries(tepy_desktop_lib PUBLIC Qt6::Core Qt6::Widgets Qt6::Network Qt6::SerialPort)
target_compile_definitions(tepy_desktop_lib PUBLIC QT_NO_CAST_FROM_ASCII QT_NO_CAST_TO_ASCII)
if(MSVC)
    target_compile_options(tepy_desktop_lib PRIVATE /W4 /utf-8)
    target_compile_options(tepy_desktop_lib PUBLIC /GR- /EHs-c-)
else()
    target_compile_options(tepy_desktop_lib PRIVATE -Wall -Wextra -Wpedantic)
    target_compile_options(tepy_desktop_lib PUBLIC -fno-exceptions -fno-rtti)
endif()
qt_add_executable(tepy-desktop WIN32 src/main.cpp)
target_link_libraries(tepy-desktop PRIVATE tepy_desktop_lib)
include(CTest)
if(BUILD_TESTING)
    find_package(Qt6 REQUIRED COMPONENTS Test)
    qt_add_executable(tepy-desktop-tests tests/desktop_tests.cpp)
    target_link_libraries(tepy-desktop-tests PRIVATE tepy_desktop_lib Qt6::Test)
    add_test(NAME desktop COMMAND tepy-desktop-tests -platform offscreen -o desktop-tests.txt,txt -o desktop-tests.xml,junitxml)
    set_tests_properties(desktop PROPERTIES TIMEOUT 45)
endif()
install(TARGETS tepy-desktop RUNTIME DESTINATION . BUNDLE DESTINATION .)
