idf_component_register(SRCS "mqtt.cpp" INCLUDE_DIRS "include" REQUIRES tepy_config espressif__mqtt esp_timer mbedtls)
target_compile_options(${COMPONENT_LIB} PUBLIC "$<$<COMPILE_LANGUAGE:CXX>:-std=gnu++23>")
