add_executable(hangarbaycc src/main.cpp)

# Find SDL2 and required components
find_package(SDL2 REQUIRED)

# Link with core, platform libraries and SDL components
    target_link_libraries(hangarbaycc PRIVATE core platform ${SDL2_LIBRARIES} SDL2_image SDL2_mixer)