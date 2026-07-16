cmake_minimum_required(VERSION 3.5)
project(QtHello LANGUAGES CXX)

set(CMAKE_AUTOMOC ON)

find_package(Qt5 COMPONENTS Widgets PrintSupport REQUIRED)

add_executable(qt_hello wordprocessor.cpp)
target_link_libraries(qt_hello Qt5::Widgets Qt5::PrintSupport)
