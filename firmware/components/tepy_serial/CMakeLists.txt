idf_component_register(SRCS "serial.cpp" "serial_protocol.cpp" "serial_upload.cpp" INCLUDE_DIRS "include"
    REQUIRES tepy_management tepy_ota esp_driver_usb_serial_jtag esp_timer esp_hw_support mbedtls)
target_compile_options(${COMPONENT_LIB} PUBLIC "$<$<COMPILE_LANGUAGE:CXX>:-std=gnu++23>")
