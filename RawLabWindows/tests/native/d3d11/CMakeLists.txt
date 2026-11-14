cmake_minimum_required(VERSION 3.20)
project(RawLabD3D11Regressions LANGUAGES CXX)
if(NOT WIN32)
    message(FATAL_ERROR "These tests require the Windows SDK and WARP runtime")
endif()
enable_testing()
get_filename_component(core "${CMAKE_CURRENT_LIST_DIR}/../../../../lutools" ABSOLUTE)
add_library(d3d11_test_backend STATIC
    "${core}/src/gpu/d3d11_photo.cpp" "${core}/src/gpu/d3d11_denoise.cpp"
    "${core}/src/gpu/denoise.cpp" "${core}/src/gpu/compute_denoise.cpp"
    "${core}/src/core/chroma_denoise.cpp" "${core}/src/core/color_converter.cpp"
    "${core}/src/core/lut_parser.cpp" "${core}/src/core/lut_compatibility.cpp" "${core}/src/core/photo_color.cpp"
    "${core}/src/core/photo_effects.cpp" "${core}/src/core/photo_tone_controls.cpp"
    "${core}/src/core/photo_color_grading.cpp" "${core}/src/core/photo_tone_curve.cpp")
target_compile_features(d3d11_test_backend PUBLIC cxx_std_17)
target_include_directories(d3d11_test_backend PUBLIC "${core}/src" "${core}/include" "${CMAKE_CURRENT_LIST_DIR}")
target_compile_definitions(d3d11_test_backend PUBLIC NOMINMAX SONY2FUJI_ENABLE_D3D11 RAWLAB_D3D11_TESTING)
target_compile_options(d3d11_test_backend PUBLIC /W4 /utf-8)
target_link_libraries(d3d11_test_backend PUBLIC d3d11 dxgi d3dcompiler)
add_executable(d3d11_trio_tests trio_tests.cpp)
target_link_libraries(d3d11_trio_tests PRIVATE d3d11_test_backend)
add_executable(d3d11_tiling_tests tiling_tests.cpp)
target_link_libraries(d3d11_tiling_tests PRIVATE d3d11_test_backend)
add_executable(d3d11_shader_tests "${core}/tests/d3d11_shader_tests.cpp")
target_link_libraries(d3d11_shader_tests PRIVATE d3d11_test_backend)
add_test(NAME d3d11_recovery_warp COMMAND d3d11_trio_tests recovery)
add_test(NAME d3d11_filter_recovery_warp COMMAND d3d11_trio_tests filter-recovery)
add_test(NAME d3d11_tiling_warp COMMAND d3d11_tiling_tests)
add_test(NAME d3d11_shader_layout COMMAND d3d11_shader_tests)
