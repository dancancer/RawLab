cmake_minimum_required(VERSION 3.22.1)
project(rawlab_android LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
get_filename_component(REPO "${CMAKE_CURRENT_LIST_DIR}/../../../../.." ABSOLUTE)
include("${REPO}/lutools/cmake/libraw/libraw.cmake")
rawlab_add_libraw_shared()
# Keep RAW development responsive in the device-debug build, like sony2fuji_core.
target_compile_options(raw PRIVATE $<$<CONFIG:Debug>:-O3>)
target_link_libraries(raw PRIVATE z)
target_link_options(raw PRIVATE "-Wl,-z,max-page-size=16384")
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
add_library(rawlab-jni SHARED jni_sdr.cpp jni_hdr.cpp jni_hdr_display.cpp jni_lens_lut.cpp jni_inspection.cpp jni_viewport.cpp jni_camera_protocol.cpp jni_camera_focus.cpp)
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
# OpenCV 编进 JNI 库的第三方代码许可（lutools/cmake/denoise-dependencies.cmake 生成），按 ABI 分开：
# Carotene 只在 arm64 编入。复用上面这个随 ABI 构建打包的资产目录。
set(opencv_packaged_notices "${CMAKE_CURRENT_LIST_DIR}/../../../build/generated/x3fNotices/${CMAKE_BUILD_TYPE}/licenses/OpenCV/${ANDROID_ABI}")
add_custom_target(rawlab_android_opencv_notices
    COMMAND "${CMAKE_COMMAND}" -E rm -rf "${opencv_packaged_notices}"
    COMMAND "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_BINARY_DIR}/licenses/OpenCV" "${opencv_packaged_notices}"
    VERBATIM)
add_dependencies(rawlab-jni rawlab_android_opencv_notices)

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
