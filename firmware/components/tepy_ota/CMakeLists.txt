idf_component_register(SRCS "ota.cpp" INCLUDE_DIRS "include" REQUIRES app_update esp_app_format mbedtls)
target_compile_options(${COMPONENT_LIB} PUBLIC "$<$<COMPILE_LANGUAGE:CXX>:-std=gnu++23>")
