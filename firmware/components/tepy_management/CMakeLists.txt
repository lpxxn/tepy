idf_component_register(SRCS "management.cpp" INCLUDE_DIRS "include"
    REQUIRES tepy_config tepy_ble tepy_network)
target_compile_options(${COMPONENT_LIB} PUBLIC "$<$<COMPILE_LANGUAGE:CXX>:-std=gnu++23>")
