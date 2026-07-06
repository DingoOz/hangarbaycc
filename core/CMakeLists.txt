add_library(core STATIC
    src/game_state.cpp
)

# Public include directory for consumers of core
target_include_directories(core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)

# Ensure warnings are applied to this target as well
target_compile_options(core PRIVATE -Wall -Wextra -Wpedantic)
