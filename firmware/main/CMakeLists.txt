idf_component_register(SRCS "app_main.cpp" INCLUDE_DIRS "."
    REQUIRES tepy_core tepy_config tepy_ble tepy_network tepy_mqtt tepy_web tepy_ota
    nvs_flash esp_driver_gpio esp_app_format esp_hw_support)
target_compile_options(${COMPONENT_LIB} PUBLIC "$<$<COMPILE_LANGUAGE:CXX>:-std=gnu++23>")
