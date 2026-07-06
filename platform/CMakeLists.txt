include(FetchContent)

FetchContent_Declare(
    raylib
    GIT_REPOSITORY https://github.com/raysan5/raylib.git
    GIT_TAG v5.0
)
FetchContent_MakeAvailable(raylib)

add_library(platform STATIC src/platform.cpp)

target_include_directories(platform PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)

# Link platform with raylib
target_link_libraries(platform PRIVATE raylib)
