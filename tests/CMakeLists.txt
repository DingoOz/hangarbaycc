include(FetchContent)

FetchContent_Declare(
    doctest
    GIT_REPOSITORY https://github.com/onqtam/doctest.git
    GIT_TAG v2.4.11
)
FetchContent_MakeAvailable(doctest)

add_executable(test_core test_main.cpp)
# Link with core library and doctest for headers
target_link_libraries(test_core PRIVATE core doctest::doctest)
