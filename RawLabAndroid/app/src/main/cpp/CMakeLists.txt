cmake_minimum_required(VERSION 3.22.1)
project(rawlab_android LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
include(FetchContent)
# libraw.org resets the TLS handshake from CMake 3.22's bundled client on some hosts.
# Use a pre-fetched local copy when present; URL_HASH verifies either source.
# CMake 3.22 rejects a local path inside a URL list, so this picks exactly one.
set(LIBRAW_URL https://www.libraw.org/data/LibRaw-0.22.2.tar.gz)
if(DEFINED ENV{RAWLAB_ANDROID_SOURCE_CACHE} AND EXISTS "$ENV{RAWLAB_ANDROID_SOURCE_CACHE}/LibRaw-0.22.2.tar.gz")
    set(LIBRAW_URL "$ENV{RAWLAB_ANDROID_SOURCE_CACHE}/LibRaw-0.22.2.tar.gz")
endif()
FetchContent_Declare(libraw
    # CMake 3.22 preserves archive timestamps; isolate ABI versions from old objects.
    SOURCE_DIR "${CMAKE_CURRENT_BINARY_DIR}/_deps/libraw-0.22.2-src"
    URL ${LIBRAW_URL}
    URL_HASH SHA256=de86b035655accff8d4010f1a221fdf50d353cb7b1422ba26f14a0db92612cfa
)
FetchContent_MakeAvailable(libraw)
get_filename_component(REPO "${CMAKE_CURRENT_LIST_DIR}/../../../../.." ABSOLUTE)
set(LIBRAW_SOURCE_DIR "${libraw_SOURCE_DIR}")
include("${REPO}/lutools/cmake/patch-libraw.cmake")
# Exclude upstream placeholder implementations, as in its Makefile.am.
file(GLOB_RECURSE LIBRAW_SOURCES CONFIGURE_DEPENDS "${libraw_SOURCE_DIR}/src/*.cpp")
list(FILTER LIBRAW_SOURCES EXCLUDE REGEX "_ph\\.cpp$")
add_library(raw SHARED ${LIBRAW_SOURCES})
target_include_directories(raw PUBLIC "${libraw_SOURCE_DIR}")
target_compile_definitions(raw PRIVATE USE_ZLIB USE_JPEG USE_JPEG8 USE_X3FTOOLS)
# Keep RAW development responsive in the device-debug build, like sony2fuji_core.
target_compile_options(raw PRIVATE $<$<CONFIG:Debug>:-O3>)
target_link_libraries(raw PRIVATE z)
include("${REPO}/lutools/cmake/raw-jpeg.cmake")
target_link_libraries(raw PRIVATE rawlab_jpeg)
target_link_options(raw PRIVATE "-Wl,-z,max-page-size=16384")
include("${REPO}/lutools/cmake/dng-sdk.cmake")
target_compile_definitions(raw PRIVATE USE_DNGSDK qDNGSupportJXL=1)
target_link_libraries(raw PRIVATE rawlab_dng_sdk)

set(SONY2FUJI_LIBRAW_TARGET raw)
set(SONY2FUJI_DNGSDK_TARGET rawlab_dng_sdk)
set(SONY2FUJI_ENABLE_DNGSDK ON CACHE BOOL "" FORCE)
set(BUILD_CLI OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIB OFF CACHE BOOL "" FORCE)
set(SONY2FUJI_ENABLE_GPU ON CACHE BOOL "" FORCE)
set(SONY2FUJI_ENABLE_X3F ON CACHE BOOL "" FORCE)
if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(RAWLAB_X3F_RUST_TARGET aarch64-linux-android CACHE STRING "" FORCE)
elseif(ANDROID_ABI STREQUAL "x86_64")
    set(RAWLAB_X3F_RUST_TARGET x86_64-linux-android CACHE STRING "" FORCE)
else()
    message(FATAL_ERROR "Unsupported X3F Android ABI: ${ANDROID_ABI}")
endif()
set(SONY2FUJI_ENABLE_LENSFUN ON CACHE BOOL "" FORCE)
set(SONY2FUJI_BUILD_LENS_DEPS ON CACHE BOOL "" FORCE)
set(SONY2FUJI_ENABLE_OPENMP OFF CACHE BOOL "" FORCE)
set(SONY2FUJI_ENABLE_WAVELET_DENOISE ON CACHE BOOL "" FORCE)
set(SONY2FUJI_ENABLE_CHROMA_DENOISE ON CACHE BOOL "" FORCE)
set(SONY2FUJI_BUILD_DENOISE_DEPS ON CACHE BOOL "" FORCE)
add_subdirectory("${REPO}/lutools" "${CMAKE_CURRENT_BINARY_DIR}/core")
# CPU denoise runs inside these dependencies, not only the optimized core wrapper.
foreach(denoise_target wavelib opencv_core opencv_imgproc)
    target_compile_options(${denoise_target} PRIVATE $<$<CONFIG:Debug>:-O3>)
endforeach()
add_library(rawlab-jni SHARED rawlab_jni.cpp)
target_include_directories(rawlab-jni PRIVATE "${REPO}/lutools/include")
target_link_libraries(rawlab-jni PRIVATE sony2fuji_core jnigraphics)
target_link_options(rawlab-jni PRIVATE "-Wl,-z,max-page-size=16384")
set(x3f_packaged_notices "${CMAKE_CURRENT_LIST_DIR}/../../../build/generated/x3fNotices/${CMAKE_BUILD_TYPE}/licenses/x3f/${ANDROID_ABI}")
add_custom_target(rawlab_android_x3f_notices
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${x3f_packaged_notices}"
    COMMAND "${CMAKE_COMMAND}" -E copy "${CMAKE_CURRENT_BINARY_DIR}/core/x3f-licenses.txt" "${x3f_packaged_notices}/Dependencies.txt"
    COMMAND "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_CURRENT_BINARY_DIR}/core/x3f-rust-licenses" "${x3f_packaged_notices}/rust"
    DEPENDS rawlab_x3f_build
    VERBATIM)
add_dependencies(rawlab-jni rawlab_android_x3f_notices)

add_executable(rawlab_gpu_tests EXCLUDE_FROM_ALL "${REPO}/RawLabAndroid/tests/gpu_smoke.cpp")
target_include_directories(rawlab_gpu_tests PRIVATE "${REPO}/lutools/include" "${REPO}/lutools/src" "${REPO}/lutools/tests")
target_link_libraries(rawlab_gpu_tests PRIVATE sony2fuji_core)

add_executable(rawlab_large_image_tests EXCLUDE_FROM_ALL "${REPO}/RawLabAndroid/tests/large_image_smoke.cpp")
target_include_directories(rawlab_large_image_tests PRIVATE "${REPO}/lutools/include" "${REPO}/lutools/src")
target_link_libraries(rawlab_large_image_tests PRIVATE sony2fuji_core)
target_link_options(rawlab_large_image_tests PRIVATE "-Wl,--wrap=glDispatchCompute")

add_executable(rawlab_dng_tests EXCLUDE_FROM_ALL "${REPO}/lutools/tests/dng_jxl_tests.cpp")
target_include_directories(rawlab_dng_tests PRIVATE "${REPO}/lutools/include")
target_compile_definitions(rawlab_dng_tests PRIVATE SONY2FUJI_ENABLE_DNGSDK SONY2FUJI_ENABLE_LENSFUN
    TEST_FIXTURE_DIR="${REPO}/lutools/tests/fixtures")
target_link_libraries(rawlab_dng_tests PRIVATE sony2fuji_core)
