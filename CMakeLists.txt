cmake_minimum_required(VERSION 3.20)

project(hangarbaycc LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Common compile options
add_compile_options(-Wall -Wextra -Wpedantic)

# Enable testing via CTest
include(CTest)

# Add subdirectories
add_subdirectory(core)
add_subdirectory(platform)
add_subdirectory(app)
add_subdirectory(tests)