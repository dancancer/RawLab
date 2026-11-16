include(FetchContent)
if(POLICY CMP0135)
    cmake_policy(SET CMP0135 NEW)
endif()

set(spng_url https://github.com/randy408/libspng/archive/refs/tags/v0.7.4.tar.gz)
set(spng_sha256 47ec02be6c0a6323044600a9221b049f63e1953faf816903e7383d4dc4234487)
FetchContent_GetProperties(rawlab_spng)
if(NOT rawlab_spng_POPULATED AND NOT FETCHCONTENT_SOURCE_DIR_RAWLAB_SPNG
        AND NOT FETCHCONTENT_FULLY_DISCONNECTED)
    include("${CMAKE_CURRENT_LIST_DIR}/download-archive.cmake")
    set(spng_archive "${FETCHCONTENT_BASE_DIR}/rawlab_spng-cache/libspng-0.7.4.tar.gz")
    rawlab_download_archive("${spng_url}" "${spng_sha256}" "${spng_archive}")
    set(spng_url "${spng_archive}")
endif()
FetchContent_Declare(rawlab_spng
    URL "${spng_url}"
    URL_HASH "SHA256=${spng_sha256}"
    SOURCE_SUBDIR rawlab-no-upstream-build)
FetchContent_MakeAvailable(rawlab_spng)

# 以 OBJECT 目标内联编译单源 spng.c，静态归档 libsony2fuji_core.a 自动包含符号，
# 避免 Apple/Android/Windows 手工链接脚本额外维护第三方静态库路径。
add_library(rawlab_spng OBJECT "${rawlab_spng_SOURCE_DIR}/spng/spng.c")
set_target_properties(rawlab_spng PROPERTIES
    C_STANDARD 99
    POSITION_INDEPENDENT_CODE ON)
target_compile_definitions(rawlab_spng PUBLIC SPNG_STATIC)
target_include_directories(rawlab_spng PUBLIC "${rawlab_spng_SOURCE_DIR}/spng")
target_link_libraries(rawlab_spng PRIVATE ZLIB::ZLIB)
if(NOT WIN32)
    target_link_libraries(rawlab_spng PRIVATE m)
endif()

if(EXISTS "${rawlab_spng_SOURCE_DIR}/LICENSE")
    file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/licenses/libspng")
    configure_file("${rawlab_spng_SOURCE_DIR}/LICENSE"
        "${CMAKE_BINARY_DIR}/licenses/libspng/LICENSE" COPYONLY)
endif()
