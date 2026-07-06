add_library(core INTERFACE)

# Provide include path for consumers
target_include_directories(core INTERFACE ${CMAKE_CURRENT_SOURCE_DIR}/include)
