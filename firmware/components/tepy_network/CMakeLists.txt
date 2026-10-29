idf_component_register(SRCS "network.cpp" INCLUDE_DIRS "include" REQUIRES tepy_config esp_wifi esp_netif esp_event esp_timer espressif__mdns)
target_compile_options(${COMPONENT_LIB} PUBLIC "$<$<COMPILE_LANGUAGE:CXX>:-std=gnu++23>")
