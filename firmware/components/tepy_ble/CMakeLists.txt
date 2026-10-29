idf_component_register(SRCS "ble.cpp" "hid_profile.cpp" "gatt.cpp" INCLUDE_DIRS "include" REQUIRES tepy_core bt esp_timer esp_app_format)
target_compile_options(${COMPONENT_LIB} PUBLIC "$<$<COMPILE_LANGUAGE:CXX>:-std=gnu++23>")
