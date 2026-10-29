cmake_minimum_required(VERSION 3.24)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    project(RawLabHDRCodecProbe LANGUAGES CXX OBJCXX)
    include(CTest)
endif()

if(NOT APPLE)
    message(FATAL_ERROR "The Apple HDR codec probe requires an Apple SDK")
endif()

add_executable(hdr_codec_probe hdr_codec_probe.mm)
set_target_properties(hdr_codec_probe PROPERTIES MACOSX_BUNDLE FALSE)
option(HDR_DEVICE_APP "Build an isolated iOS codec test application" OFF)
if(HDR_DEVICE_APP)
    if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
        message(FATAL_ERROR "HDR_DEVICE_APP requires an iOS target")
    endif()
    set(HDR_DEVICE_BUNDLE_ID "com.rawlab.tests.hdrcodec" CACHE STRING "Private test bundle identifier")
    target_sources(hdr_codec_probe PRIVATE hdr_device_main.mm)
    target_compile_definitions(hdr_codec_probe PRIVATE RAWLAB_HDR_DEVICE_APP=1)
    target_link_libraries(hdr_codec_probe PRIVATE "-framework UIKit")
    set_target_properties(hdr_codec_probe PROPERTIES
        MACOSX_BUNDLE TRUE
        MACOSX_BUNDLE_GUI_IDENTIFIER "${HDR_DEVICE_BUNDLE_ID}"
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/DeviceInfo.plist.in"
        XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${HDR_DEVICE_BUNDLE_ID}"
        XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2")
endif()
target_compile_features(hdr_codec_probe PRIVATE cxx_std_17)
target_compile_options(hdr_codec_probe PRIVATE -fobjc-arc -Werror=unguarded-availability)
target_link_libraries(hdr_codec_probe PRIVATE
    "-framework Foundation" "-framework CoreGraphics" "-framework ImageIO" "-framework CoreImage")

set(HDR_ULTRAHDR_SOURCE "" CACHE PATH "Verified libultrahdr 2.0.2 source directory")
set(HDR_JPEG_PREFIX "" CACHE PATH "Target-specific libjpeg-turbo 3.1.3 static install")
if(HDR_ULTRAHDR_SOURCE)
    if(NOT EXISTS "${HDR_JPEG_PREFIX}/lib/libjpeg.a" OR NOT EXISTS "${HDR_JPEG_PREFIX}/include/jpeglib.h")
        message(FATAL_ERROR "Ultra HDR probe requires an explicit target-specific static JPEG prefix")
    endif()
    enable_language(C)
    set(JPEG_LIBRARY "${HDR_JPEG_PREFIX}/lib/libjpeg.a" CACHE FILEPATH "" FORCE)
    set(JPEG_INCLUDE_DIR "${HDR_JPEG_PREFIX}/include" CACHE PATH "" FORCE)
    set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
    foreach(option IN ITEMS UHDR_BUILD_EXAMPLES UHDR_BUILD_TESTS UHDR_BUILD_BENCHMARK UHDR_BUILD_FUZZERS
            UHDR_BUILD_DEPS UHDR_BUILD_JAVA UHDR_BUILD_PACKAGING UHDR_ENABLE_INSTALL UHDR_ENABLE_GLES
            UHDR_ENABLE_HEIF UHDR_ENABLE_SMPTE2094_50)
        set(${option} OFF CACHE BOOL "" FORCE)
    endforeach()
    set(UHDR_WRITE_ISO ON CACHE BOOL "" FORCE)
    set(UHDR_WRITE_XMP ON CACHE BOOL "" FORCE)
    set(UHDR_MAX_DIMENSION 65500 CACHE STRING "JPEG dimension ceiling" FORCE)
    # 与产品相同：2.0.2 的 arm64 NEON P3/BT.2100 系数选择有误。
    set(UHDR_ENABLE_INTRINSICS OFF CACHE BOOL "Pinned codec color correctness" FORCE)
    add_subdirectory("${HDR_ULTRAHDR_SOURCE}" "${CMAKE_CURRENT_BINARY_DIR}/ultrahdr" EXCLUDE_FROM_ALL)
    if(CMAKE_GENERATOR STREQUAL "Xcode")
        # 上游 uhdr 只有 TARGET_OBJECTS，Xcode 会跳过没有编译源的归档目标。
        target_sources(uhdr PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/hdr_codec_anchor.cpp")
    endif()
    target_sources(hdr_codec_probe PRIVATE ultrahdr_probe.mm)
    target_include_directories(hdr_codec_probe PRIVATE "${HDR_ULTRAHDR_SOURCE}")
    target_compile_definitions(hdr_codec_probe PRIVATE RAWLAB_HDR_ULTRAHDR=1)
    target_link_libraries(hdr_codec_probe PRIVATE uhdr)
    target_sources(hdr_codec_probe PRIVATE hdr_native_probe.mm
        ../../src/core/hdr_rendering.cpp ../../src/core/photo_geometry.cpp
        ../../src/core/hdr_jpeg.cpp ../../src/platform/hdr_image_apple.mm)
    target_include_directories(hdr_codec_probe PRIVATE ../../include ../../src)
    target_compile_definitions(hdr_codec_probe PRIVATE RAWLAB_HDR_PRODUCTION=1)
    foreach(case IN ITEMS iso rgb_map heic orientation ultrahdr)
        add_test(NAME hdr_codec_production_${case} COMMAND hdr_codec_probe production_${case})
        set_tests_properties(hdr_codec_production_${case} PROPERTIES SKIP_RETURN_CODE 77)
    endforeach()
    foreach(case IN ITEMS ultrahdr dual_metadata)
        add_test(NAME hdr_codec_${case} COMMAND hdr_codec_probe ${case})
        set_tests_properties(hdr_codec_${case} PROPERTIES SKIP_RETURN_CODE 77)
    endforeach()
endif()

set(HDR_FINAL_FIXTURE "" CACHE FILEPATH "Read-only fixture for full-resolution production core verification")
get_filename_component(HDR_FINAL_FIXTURE_NAME "${HDR_FINAL_FIXTURE}" NAME)
set(provenance_sources hdr_codec_probe.mm hdr_device_main.mm hdr_native_probe.mm ultrahdr_probe.mm
    ../../src/core/hdr_rendering.cpp ../../src/core/photo_geometry.cpp ../../src/core/hdr_jpeg.cpp
    ../../src/core/hdr_rendering.h ../../src/core/hdr_jpeg.h ../../src/platform/hdr_image.h
    ../../src/platform/hdr_image_apple.mm ../../include/sony2fuji/ffi/sony2fuji_hdr.h
    ../../cmake/hdr-codec-dependencies.json CMakeLists.txt DeviceInfo.plist.in)
set(provenance "")
foreach(source IN LISTS provenance_sources)
    file(SHA256 "${CMAKE_CURRENT_SOURCE_DIR}/${source}" source_hash)
    string(APPEND provenance "${source}:${source_hash};")
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/${source}")
endforeach()
string(SHA256 HDR_SOURCE_REVISION "${provenance}")
if(HDR_FINAL_FIXTURE AND HDR_ULTRAHDR_SOURCE)
    add_test(NAME hdr_codec_production_final COMMAND hdr_codec_probe production_external_final "${HDR_FINAL_FIXTURE}")
endif()

foreach(case IN ITEMS iso rgb_map heic orientation bad_aux)
    add_test(NAME hdr_codec_${case} COMMAND hdr_codec_probe ${case})
    set_tests_properties(hdr_codec_${case} PROPERTIES SKIP_RETURN_CODE 77)
endforeach()

set(HDR_EXTERNAL_FIXTURE_ROOT "" CACHE PATH "Read-only, user-authorized phone fixture directory")
if(HDR_EXTERNAL_FIXTURE_ROOT)
    file(GLOB phone_fixtures LIST_DIRECTORIES FALSE
        "${HDR_EXTERNAL_FIXTURE_ROOT}/*.HEIC" "${HDR_EXTERNAL_FIXTURE_ROOT}/*.heic"
        "${HDR_EXTERNAL_FIXTURE_ROOT}/*.jpg" "${HDR_EXTERNAL_FIXTURE_ROOT}/*.jpeg")
    list(SORT phone_fixtures)
    list(LENGTH phone_fixtures phone_count)
    if(phone_count EQUAL 0)
        message(FATAL_ERROR "No supported external phone fixtures found")
    endif()
    set(phone_index 0)
    foreach(fixture IN LISTS phone_fixtures)
        if(HDR_DEVICE_APP)
            target_sources(hdr_codec_probe PRIVATE "${fixture}")
            set_source_files_properties("${fixture}" PROPERTIES MACOSX_PACKAGE_LOCATION "Resources/HDRFixtures")
        endif()
        math(EXPR phone_index "${phone_index} + 1")
        add_test(NAME hdr_codec_phone_${phone_index} COMMAND hdr_codec_probe external "${fixture}")
        set_tests_properties(hdr_codec_phone_${phone_index} PROPERTIES SKIP_RETURN_CODE 77)
    endforeach()
endif()
