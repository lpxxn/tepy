idf_component_register(SRCS "core.cpp" INCLUDE_DIRS "include" REQUIRES espressif__cjson)
target_compile_options(${COMPONENT_LIB} PUBLIC "$<$<COMPILE_LANGUAGE:CXX>:-std=gnu++23>")
