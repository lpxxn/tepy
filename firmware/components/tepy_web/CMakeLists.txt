idf_component_register(SRCS "web.cpp" INCLUDE_DIRS "include"
    REQUIRES tepy_management tepy_ota esp_http_server esp_timer
    EMBED_FILES "web/index.html")
target_compile_options(${COMPONENT_LIB} PUBLIC "$<$<COMPILE_LANGUAGE:CXX>:-std=gnu++23>")
