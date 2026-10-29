idf_component_register(SRCS "config.cpp" INCLUDE_DIRS "include" REQUIRES tepy_core nvs_flash esp_hw_support bootloader_support)
target_compile_options(${COMPONENT_LIB} PUBLIC "$<$<COMPILE_LANGUAGE:CXX>:-std=gnu++23>")
