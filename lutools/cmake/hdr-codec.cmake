include(FetchContent)
if(POLICY CMP0135)
    cmake_policy(SET CMP0135 NEW)
endif()

function(rawlab_add_hdr_codec)
    # Xcode 的 iOS toolchain 可以留空 processor；codec 在检查 OSX 架构前就会因此失败。
    # 每个 Apple slice 单独构建，按真实目标补齐，不能继承宿主架构。
    if(APPLE AND CMAKE_OSX_ARCHITECTURES)
        list(LENGTH CMAKE_OSX_ARCHITECTURES hdr_arch_count)
        if(NOT hdr_arch_count EQUAL 1)
            message(FATAL_ERROR "Build each HDR Apple architecture separately before packaging")
        endif()
        set(CMAKE_SYSTEM_PROCESSOR "${CMAKE_OSX_ARCHITECTURES}")
    endif()
    if(NOT FETCHCONTENT_SOURCE_DIR_RAWLAB_ULTRAHDR OR
            (NOT TARGET rawlab_jpeg AND NOT FETCHCONTENT_SOURCE_DIR_RAWLAB_JPEG_SOURCE))
        find_package(Python3 COMPONENTS Interpreter REQUIRED)
        execute_process(COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_LIST_DIR}/hdr_sources.py"
            RESULT_VARIABLE source_result OUTPUT_VARIABLE source_directories ERROR_VARIABLE source_error
            OUTPUT_STRIP_TRAILING_WHITESPACE)
        if(NOT source_result EQUAL 0)
            message(FATAL_ERROR "HDR source preparation failed: ${source_error}")
        endif()
        if(NOT FETCHCONTENT_SOURCE_DIR_RAWLAB_ULTRAHDR)
            list(GET source_directories 0 FETCHCONTENT_SOURCE_DIR_RAWLAB_ULTRAHDR)
        endif()
        if(NOT FETCHCONTENT_SOURCE_DIR_RAWLAB_JPEG_SOURCE)
            list(GET source_directories 1 FETCHCONTENT_SOURCE_DIR_RAWLAB_JPEG_SOURCE)
        endif()
    endif()
    if(NOT TARGET rawlab_jpeg)
        include("${CMAKE_CURRENT_LIST_DIR}/raw-jpeg.cmake")
    endif()
    set(BUILD_SHARED_LIBS OFF)
    foreach(option UHDR_BUILD_EXAMPLES UHDR_BUILD_TESTS UHDR_BUILD_BENCHMARK UHDR_BUILD_FUZZERS
            UHDR_BUILD_DEPS UHDR_BUILD_JAVA UHDR_BUILD_PACKAGING UHDR_ENABLE_INSTALL UHDR_ENABLE_GLES
            UHDR_ENABLE_HEIF UHDR_ENABLE_SMPTE2094_50)
        set(${option} OFF CACHE BOOL "HDR JPEG-only dependency closure" FORCE)
    endforeach()
    set(UHDR_WRITE_ISO ON CACHE BOOL "HDR ISO interoperability" FORCE)
    set(UHDR_WRITE_XMP ON CACHE BOOL "HDR XMP interoperability" FORCE)
    set(UHDR_MAX_DIMENSION 65500 CACHE STRING "Match JPEG dimension ceiling" FORCE)
    # 2.0.2 arm64 NEON 互换 P3/BT.2100 YCbCr 系数；固定 scalar 路径以满足颜色回环合同。
    set(UHDR_ENABLE_INTRINSICS OFF CACHE BOOL "Pinned codec color correctness" FORCE)
    # MSVC 静态 codec 仍使用应用的 DLL CRT；上游以此开关保留 /MD。
    if(MSVC)
        set(BUILD_FOR_WINUI ON)
    endif()
    FetchContent_Declare(rawlab_ultrahdr
        URL https://codeload.github.com/google/libultrahdr/tar.gz/refs/tags/v2.0.2
        URL_HASH SHA256=aa8d193bb887c348c419780511dd03b374f4e07af8812b6d3f80c8537cf1ef2c
        SOURCE_SUBDIR rawlab-no-upstream-build)
    FetchContent_MakeAvailable(rawlab_ultrahdr)
    set(RAWLAB_HDR_UHDR_INCLUDE "${rawlab_ultrahdr_SOURCE_DIR}/lib/include" PARENT_SCOPE)
    set(RAWLAB_HDR_XML_INCLUDE "${rawlab_ultrahdr_SOURCE_DIR}/third_party/image_io/includes" PARENT_SCOPE)
    add_subdirectory("${rawlab_ultrahdr_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/hdr-codec/upstream" EXCLUDE_FROM_ALL)
    set(hdr_target uhdr)
    if(TARGET uhdr-static AND NOT TARGET uhdr)
        set(hdr_target uhdr-static)
        add_library(uhdr ALIAS uhdr-static)
    endif()
    set_target_properties(${hdr_target} PROPERTIES
        ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/hdr-codec/lib"
        ARCHIVE_OUTPUT_DIRECTORY_RELEASE "${CMAKE_BINARY_DIR}/hdr-codec/lib")
    if(CMAKE_GENERATOR STREQUAL "Xcode")
        # Upstream's TARGET_OBJECTS-only archive is otherwise skipped by Xcode.
        file(WRITE "${CMAKE_BINARY_DIR}/hdr-codec/archive-anchor.cpp" "// Xcode archive anchor.\n")
        target_sources(${hdr_target} PRIVATE "${CMAKE_BINARY_DIR}/hdr-codec/archive-anchor.cpp")
    endif()
    file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/licenses/libultrahdr")
    foreach(name LICENSE LICENSE-APACHE LICENSE-MIT)
        configure_file("${rawlab_ultrahdr_SOURCE_DIR}/${name}"
            "${CMAKE_BINARY_DIR}/licenses/libultrahdr/${name}" COPYONLY)
    endforeach()
endfunction()

rawlab_add_hdr_codec()
