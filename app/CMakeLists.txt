add_executable(hangarbaycc src/main.cpp)

# Link with core and platform libraries
target_link_libraries(hangarbaycc PRIVATE core platform)
