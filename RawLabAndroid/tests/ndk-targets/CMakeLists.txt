cmake_minimum_required(VERSION 3.22.1)
project(rawlab_android_ndk_targets LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

get_filename_component(REPO "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)

option(RAWLAB_BUILD_GLES_LUT_BINDING_TESTS "Build gles_lut_binding_tests" ON)

add_library(rawlab_gles_lut_core OBJECT
    "${REPO}/lutools/src/gpu/gles_lut.cpp"
    "${REPO}/lutools/src/gpu/lut_gpu.cpp"
    "${REPO}/lutools/src/core/lut_applicator.cpp"
    "${REPO}/lutools/src/core/lut_parser.cpp"
)
target_include_directories(rawlab_gles_lut_core PRIVATE
    "${REPO}/lutools/include"
    "${REPO}/lutools/src"
)
target_compile_definitions(rawlab_gles_lut_core PRIVATE
    SONY2FUJI_ENABLE_GLES
    SONY2FUJI_PLATFORM_ANDROID
)

if(RAWLAB_BUILD_GLES_LUT_BINDING_TESTS)
    add_executable(gles_lut_binding_tests
        "${REPO}/lutools/tests/gles_lut_binding_tests.cpp"
        $<TARGET_OBJECTS:rawlab_gles_lut_core>
    )
    target_include_directories(gles_lut_binding_tests PRIVATE
        "${REPO}/lutools/include"
        "${REPO}/lutools/src"
    )
    target_compile_definitions(gles_lut_binding_tests PRIVATE
        SONY2FUJI_ENABLE_GLES
        SONY2FUJI_PLATFORM_ANDROID
    )
    target_compile_options(gles_lut_binding_tests PRIVATE -UNDEBUG)
    target_link_libraries(gles_lut_binding_tests PRIVATE EGL GLESv3)
endif()

add_executable(rawlab_gles_lut_tests
    "${REPO}/RawLabAndroid/tests/gles_lut.cpp"
    $<TARGET_OBJECTS:rawlab_gles_lut_core>
)
target_include_directories(rawlab_gles_lut_tests PRIVATE
    "${REPO}/lutools/include"
    "${REPO}/lutools/src"
)
target_compile_definitions(rawlab_gles_lut_tests PRIVATE
    SONY2FUJI_ENABLE_GLES
    SONY2FUJI_PLATFORM_ANDROID
)
target_compile_options(rawlab_gles_lut_tests PRIVATE -Wall -Wextra)
foreach(wrapped_fn glGetIntegeri_v glGetInteger64v glBufferData glBufferSubData glDispatchCompute glMapBufferRange glUnmapBuffer)
    target_link_options(rawlab_gles_lut_tests PRIVATE "-Wl,--wrap=${wrapped_fn}")
endforeach()
target_link_libraries(rawlab_gles_lut_tests PRIVATE EGL GLESv3)

add_library(rawlab_gpu_test_objects OBJECT
    "${REPO}/RawLabAndroid/tests/gpu_smoke.cpp"
    "${REPO}/RawLabAndroid/tests/large_image_smoke.cpp"
    "${REPO}/lutools/src/gpu/gles_photo.cpp"
    "${REPO}/lutools/src/gpu/gles_denoise.cpp"
    "${REPO}/lutools/src/gpu/compute_denoise.cpp"
    "${REPO}/lutools/src/gpu/denoise.cpp"
)
target_include_directories(rawlab_gpu_test_objects PRIVATE
    "${REPO}/lutools/include"
    "${REPO}/lutools/src"
    "${REPO}/lutools/tests"
)
target_compile_definitions(rawlab_gpu_test_objects PRIVATE
    SONY2FUJI_ENABLE_GLES
    SONY2FUJI_PLATFORM_ANDROID
)
target_compile_options(rawlab_gpu_test_objects PRIVATE -UNDEBUG)
