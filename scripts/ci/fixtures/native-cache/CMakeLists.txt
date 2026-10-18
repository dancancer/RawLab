cmake_minimum_required(VERSION 3.22)
project(NativeCacheBoundary LANGUAGES CXX)

set(dependency_source "${CMAKE_BINARY_DIR}/_deps/rawlab_dng_source-src/dependency.cpp")
configure_file(dependency.cpp "${dependency_source}" COPYONLY)
configure_file(cvconfig.h.in "${CMAKE_BINARY_DIR}/cvconfig.h" COPYONLY)
add_library(rawlab_dng_sdk STATIC "${dependency_source}")
target_include_directories(rawlab_dng_sdk PRIVATE "${CMAKE_BINARY_DIR}")
set_target_properties(rawlab_dng_sdk PROPERTIES
    ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/raw-dependencies/dng-sdk")

add_library(sony2fuji SHARED product.cpp)
target_link_libraries(sony2fuji PRIVATE rawlab_dng_sdk)
set_target_properties(sony2fuji PROPERTIES FRAMEWORK TRUE
    LIBRARY_OUTPUT_DIRECTORY_RELEASE "${CMAKE_BINARY_DIR}/output")
