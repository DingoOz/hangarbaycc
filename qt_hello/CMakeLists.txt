cmake_minimum_required(VERSION 3.5)
project(QtHello LANGUAGES CXX)

find_package(Qt5 COMPONENTS Widgets REQUIRED)

add_executable(qt_hello main.cpp)
target_link_libraries(qt_hello Qt5::Widgets)
