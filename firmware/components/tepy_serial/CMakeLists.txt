idf_component_register(SRCS "serial.cpp" "serial_protocol.cpp" INCLUDE_DIRS "include"
    REQUIRES tepy_management esp_driver_usb_serial_jtag esp_timer)
target_compile_options(${COMPONENT_LIB} PUBLIC "$<$<COMPILE_LANGUAGE:CXX>:-std=gnu++23>")
