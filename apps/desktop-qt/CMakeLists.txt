cmake_minimum_required(VERSION 3.22)
project(tepy_desktop VERSION 0.3.0 LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
list(APPEND CMAKE_PREFIX_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../../.venv/qtmqtt/install")
find_package(Qt6 6.8 REQUIRED COMPONENTS Core Widgets Network SerialPort)
find_package(Qt6Mqtt 6.8 CONFIG REQUIRED
    HINTS "${CMAKE_CURRENT_SOURCE_DIR}/../../.venv/qtmqtt/install/lib/cmake/Qt6Mqtt")
add_library(tepy_desktop_lib STATIC
    src/protocol.cpp src/protocol.hpp
    src/serial_port.cpp src/serial_port.hpp
    src/device_client.cpp src/device_client.hpp
    src/config_form.cpp src/config_form.hpp
    src/flash_job.cpp src/flash_job.hpp
    src/main_window.cpp src/main_window.hpp src/ui.cpp src/ui.hpp
    src/agent_client.cpp src/agent_client.hpp src/agent_page.cpp src/agent_page.hpp
    src/connection_store.cpp src/connection_store.hpp src/mqtt_control.cpp src/mqtt_control.hpp
    src/keyboard_job.cpp src/keyboard_job.hpp src/keyboard_page.cpp src/keyboard_page.hpp)
target_include_directories(tepy_desktop_lib PUBLIC src)
target_link_libraries(tepy_desktop_lib PUBLIC Qt6::Core Qt6::Widgets Qt6::Network Qt6::SerialPort Qt6::Mqtt)
if(WIN32)
    target_link_libraries(tepy_desktop_lib PRIVATE Advapi32)
elseif(APPLE)
    target_link_libraries(tepy_desktop_lib PRIVATE "-framework Security" "-framework CoreFoundation")
endif()
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
    qt_add_executable(tepy-mqtt-tests tests/mqtt_tests.cpp)
    target_link_libraries(tepy-mqtt-tests PRIVATE tepy_desktop_lib Qt6::Test)
    add_test(NAME mqtt COMMAND tepy-mqtt-tests -platform offscreen -o mqtt-tests.txt,txt -o mqtt-tests.xml,junitxml)
    set_tests_properties(mqtt PROPERTIES TIMEOUT 45)
endif()
install(TARGETS tepy-desktop RUNTIME DESTINATION . BUNDLE DESTINATION .)
