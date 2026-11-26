cmake_minimum_required(VERSION 3.15)
project(Sony2FujiLUT VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# 选项
option(BUILD_CLI "Build command line tool" ON)
option(BUILD_SHARED_LIB "Build shared library for mobile integration" ON)
option(BUILD_EXAMPLES "Build examples" OFF)
option(SONY2FUJI_ENABLE_GPU "Enable GPU acceleration" ON)
include(CTest)
include(cmake/ThirdPartyDeps.cmake)
include(cmake/rawlab_add_test.cmake)
if(NOT COMMAND _rawlab_add_test)
    function(rawlab_add_test)
        set(_rawlab_fwd "")
        if(ARGC GREATER 0)
            math(EXPR _rawlab_last_arg "${ARGC} - 1")
            foreach(_rawlab_idx RANGE 0 ${_rawlab_last_arg})
                string(APPEND _rawlab_fwd " \"\${ARGV${_rawlab_idx}}\"")
            endforeach()
        endif()
        cmake_language(EVAL CODE "_rawlab_add_test(${_rawlab_fwd})")

        set(_rawlab_options)
        set(_rawlab_one_value NAME TARGET SKIP_RETURN_CODE)
        set(_rawlab_multi_value
            SOURCES COMMAND ARGS INCLUDES INCLUDES_BEFORE
            LIBRARIES DEFINES COMPILE_OPTIONS LINK_OPTIONS
            LABELS ENVIRONMENT
        )
        cmake_parse_arguments(PARSE_ARGV 0 _RAWLAB_ARG "${_rawlab_options}" "${_rawlab_one_value}" "${_rawlab_multi_value}")

        set(_rawlab_targets)
        if(_RAWLAB_ARG_SOURCES)
            if(_RAWLAB_ARG_TARGET)
                list(APPEND _rawlab_targets "${_RAWLAB_ARG_TARGET}")
            elseif(_RAWLAB_ARG_NAME)
                list(APPEND _rawlab_targets "${_RAWLAB_ARG_NAME}_tests")
            endif()
        endif()
        if(_RAWLAB_ARG_COMMAND)
            list(GET _RAWLAB_ARG_COMMAND 0 _rawlab_cmd_head)
            if(TARGET "${_rawlab_cmd_head}")
                list(APPEND _rawlab_targets "${_rawlab_cmd_head}")
            endif()
            foreach(_rawlab_tok IN LISTS _RAWLAB_ARG_COMMAND _RAWLAB_ARG_ARGS)
                if(_rawlab_tok MATCHES "\\$<TARGET_FILE:([^>]+)>")
                    if(TARGET "${CMAKE_MATCH_1}")
                        list(APPEND _rawlab_targets "${CMAKE_MATCH_1}")
                    endif()
                endif()
            endforeach()
        endif()
        foreach(_rawlab_tgt IN LISTS _rawlab_targets)
            if(TARGET "${_rawlab_tgt}")
                get_target_property(_rawlab_tgt_type "${_rawlab_tgt}" TYPE)
                if(_rawlab_tgt_type STREQUAL "EXECUTABLE")
                    set_property(GLOBAL APPEND PROPERTY RAWLAB_REGISTERED_TEST_TARGETS "${_rawlab_tgt}")
                endif()
            endif()
        endforeach()
    endfunction()
endif()

include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${LIBRAW_INCLUDE_DIRS}
)

# 核心库源文件
set(CORE_SOURCES
    src/core/lut_parser.cpp
    src/core/lut_compatibility.cpp
    src/core/lut_preview_comparison.cpp
    src/core/lut_applicator.cpp
    src/core/dcp_look.cpp
    src/core/dcp_compiler.cpp
    src/core/color_converter.cpp
    src/core/raw_processor.cpp
    src/core/x3f_processor.cpp
    src/core/lens_correction.cpp
    src/core/display_lens_correction.cpp
    src/core/chroma_denoise.cpp
    src/core/noise_aware_sharpen.cpp
    src/core/wavelet_denoise.cpp
    src/core/photo_effects.cpp
    src/core/photo_geometry.cpp
    src/core/inspection_overlay.cpp
    src/core/hdr_rendering.cpp
    src/core/hdr_pipeline.cpp
    src/core/hdr_detail.cpp
    src/core/hdr_look.cpp
    src/core/photo_color.cpp
    src/core/photo_tone_controls.cpp
    src/core/photo_basic_controls_v3.cpp
    src/core/processing_migration.cpp
    src/core/photo_atmosphere.cpp
    src/core/photo_color_grading.cpp
    src/core/photo_calibration.cpp
    src/core/photo_point_color.cpp
    src/core/photo_selective_color.cpp
    src/core/photo_bw_mixer.cpp
    src/core/photo_sharpen_v2.cpp
    src/core/photo_defringe.cpp
    src/core/photo_film_optics.cpp
    src/core/photo_tone_curve.cpp
    src/core/white_balance.cpp
    src/core/preview_exposure.cpp
    src/core/rendered_dng.cpp
    src/core/pinned_source_file.cpp
    src/core/atomic_output_transaction.cpp
    src/core/render_params.cpp
    src/core/edit_recipe_core.cpp
    src/core/gui_store.cpp
    src/platform/file_lock.cpp
    src/core/image_header_probe.cpp
    src/core/photo_pipeline_stages.cpp
    src/core/hsl_probe.cpp
    src/core/bsh_diagnostics.cpp
    src/core/pipeline.cpp
    src/core/pipeline_raw.cpp
    src/core/pipeline_lens.cpp
    src/core/pipeline_ai.cpp
    src/core/pipeline_x3f.cpp
    src/core/pipeline_geometry.cpp
    src/core/pipeline_io.cpp
    src/core/viewport_pyramid.cpp
    src/core/sony_ptpip.cpp
    src/ffi/sony2fuji_c.cpp
    src/ffi/viewport_pyramid_c.cpp
    src/ffi/sony_ptpip_c.cpp
    src/ffi/edit_recipe.cpp
    src/ffi/sony2fuji_lens_c.cpp
    src/ffi/sony2fuji_buffer_c.cpp
    src/ffi/inspection_c.cpp
    src/ffi/sony2fuji_hdr.cpp
    src/ffi/dcp_compiler_c.cpp
    src/ffi/lut_compatibility_c.cpp
    src/gpu/lut_gpu.cpp
    src/gpu/image_stats.cpp
    src/gpu/denoise.cpp
    src/gpu/compute_denoise.cpp
)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    # P3 的硬阈值需与冻结的 float32 分步计算一致，避免 FMA 改变分支。
    set_source_files_properties(src/core/noise_aware_sharpen.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
elseif(MSVC)
    set_source_files_properties(src/core/noise_aware_sharpen.cpp PROPERTIES COMPILE_OPTIONS "/fp:strict")
endif()
if(WIN32)
    list(APPEND CORE_SOURCES src/platform/display_image_windows.cpp)
else()
    list(APPEND CORE_SOURCES src/platform/display_image.cpp)
endif()
if(APPLE)
    list(APPEND CORE_SOURCES src/platform/hdr_image_apple.mm)
    set_source_files_properties(src/platform/hdr_image_apple.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc -Werror=unguarded-availability")
else()
    list(APPEND CORE_SOURCES src/platform/hdr_image_portable.cpp src/platform/hdr_heif.cpp src/platform/hdr_heif_color.cpp src/platform/hdr_metadata.cpp)
endif()
list(APPEND CORE_SOURCES src/core/jpeg_mpf.cpp src/core/hdr_jpeg.cpp
    src/core/proraw_source.cpp src/core/hdr_storage.cpp src/core/hdr_stream.cpp)

if(SONY2FUJI_ENABLE_GPU)
    if(WIN32)
        list(APPEND CORE_SOURCES src/gpu/d3d11_photo.cpp src/gpu/d3d11_denoise.cpp)
        add_compile_definitions(SONY2FUJI_ENABLE_D3D11)
    endif()
    if(APPLE)
        list(APPEND CORE_SOURCES src/gpu/metal_lut.mm src/gpu/metal_photo.mm src/gpu/metal_stats.mm src/gpu/metal_denoise.mm src/gpu/metal_sharpen.mm)
        add_compile_definitions(SONY2FUJI_ENABLE_METAL)
        set_source_files_properties(src/gpu/metal_lut.mm src/gpu/metal_photo.mm src/gpu/metal_stats.mm src/gpu/metal_denoise.mm src/gpu/metal_sharpen.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
    endif()
    if(ANDROID)
        list(APPEND CORE_SOURCES src/gpu/gles_lut.cpp src/gpu/gles_photo.cpp src/gpu/gles_denoise.cpp)
        add_compile_definitions(SONY2FUJI_ENABLE_GLES)
    endif()
endif()

# 创建核心对象库（仅编译一次，静态库与共享库共同消费）
add_library(sony2fuji_core_objects OBJECT ${CORE_SOURCES})
set_target_properties(sony2fuji_core_objects PROPERTIES POSITION_INDEPENDENT_CODE ON)

set(SONY2FUJI_CORE_LINK_LIBRARIES
    uhdr rawlab_jpeg rawlab_spng
    ${LIBRAW_LIBRARY}
    ${SONY2FUJI_TIFF_TARGET}
)
if(SONY2FUJI_ENABLE_X3F)
    list(APPEND SONY2FUJI_CORE_LINK_LIBRARIES rawlab_x3f)
endif()
if(NOT APPLE)
    list(APPEND SONY2FUJI_CORE_LINK_LIBRARIES heif rawlab_lcms)
    target_include_directories(sony2fuji_core_objects BEFORE PRIVATE "${RAWLAB_HDR_LCMS_INCLUDE}")
endif()
if(APPLE)
    list(APPEND SONY2FUJI_CORE_LINK_LIBRARIES
        "-framework Foundation" "-framework CoreImage"
        "-framework CoreGraphics" "-framework ImageIO" "-framework CoreFoundation")
endif()
target_include_directories(sony2fuji_core_objects PRIVATE
    third_party
    "${RAWLAB_HDR_UHDR_INCLUDE}"
    "${RAWLAB_HDR_XML_INCLUDE}"
)
if(WIN32)
    list(APPEND SONY2FUJI_CORE_LINK_LIBRARIES windowscodecs ole32 psapi bcrypt normaliz)
endif()
if(SONY2FUJI_ENABLE_GPU AND WIN32)
    list(APPEND SONY2FUJI_CORE_LINK_LIBRARIES d3d11 dxgi d3dcompiler)
endif()
if(SONY2FUJI_ENABLE_LENSFUN)
    list(APPEND SONY2FUJI_CORE_LINK_LIBRARIES ${LENSFUN_LIBRARY})
endif()
if(SONY2FUJI_ENABLE_DNGSDK)
    target_compile_definitions(sony2fuji_core_objects PRIVATE SONY2FUJI_ENABLE_DNGSDK)
    list(APPEND SONY2FUJI_CORE_LINK_LIBRARIES ${DNGSDK_LIBRARY})
endif()
if(SONY2FUJI_DENOISE_LIBRARIES)
    list(APPEND SONY2FUJI_CORE_LINK_LIBRARIES ${SONY2FUJI_DENOISE_LIBRARIES})
endif()
if(MSVC)
    target_compile_options(sony2fuji_core_objects PRIVATE /W4 /O2 /utf-8)
    target_compile_definitions(sony2fuji_core_objects PRIVATE NOMINMAX _CRT_SECURE_NO_WARNINGS)
else()
    target_compile_options(sony2fuji_core_objects PRIVATE -Wall -Wextra -O3)
endif()
if(SONY2FUJI_ENABLE_OPENMP AND OpenMP_CXX_FOUND)
    list(APPEND SONY2FUJI_CORE_LINK_LIBRARIES OpenMP::OpenMP_CXX)
endif()
if(TARGET ZLIB::ZLIB)
    list(APPEND SONY2FUJI_CORE_LINK_LIBRARIES ZLIB::ZLIB)
endif()
if(SONY2FUJI_ENABLE_GPU AND APPLE)
    list(APPEND SONY2FUJI_CORE_LINK_LIBRARIES "-framework Metal")
endif()
if(SONY2FUJI_ENABLE_GPU AND ANDROID)
    list(APPEND SONY2FUJI_CORE_LINK_LIBRARIES EGL GLESv3 log)
endif()

target_link_libraries(sony2fuji_core_objects PRIVATE ${SONY2FUJI_CORE_LINK_LIBRARIES})

# 静态核心库（供 CLI、macOS Swift、Android JNI 与测试链接）
add_library(sony2fuji_core STATIC $<TARGET_OBJECTS:sony2fuji_core_objects>)
if(CMAKE_GENERATOR STREQUAL "Xcode")
    # Xcode skips static archives that contain only TARGET_OBJECTS without a compiled source.
    file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/sony2fuji-core-anchor.cpp" "// Xcode archive anchor.\n")
    target_sources(sony2fuji_core PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/sony2fuji-core-anchor.cpp")
endif()
target_link_libraries(sony2fuji_core ${SONY2FUJI_CORE_LINK_LIBRARIES})

# 创建共享库 (用于移动端/桌面端集成)
if(BUILD_SHARED_LIB)
    add_library(sony2fuji SHARED $<TARGET_OBJECTS:sony2fuji_core_objects>)
    if(CMAKE_GENERATOR STREQUAL "Xcode")
        # Xcode skips linking targets that contain only TARGET_OBJECTS without a compiled source.
        file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/sony2fuji-shared-anchor.cpp" "// Xcode framework anchor.\n")
        target_sources(sony2fuji PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/sony2fuji-shared-anchor.cpp")
    endif()
    target_link_libraries(sony2fuji ${SONY2FUJI_CORE_LINK_LIBRARIES})
    if(MSVC)
        target_compile_options(sony2fuji PRIVATE /W4 /O2 /utf-8)
        target_compile_definitions(sony2fuji PRIVATE NOMINMAX _CRT_SECURE_NO_WARNINGS)
        set_target_properties(sony2fuji PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
    else()
        target_compile_options(sony2fuji PRIVATE -Wall -Wextra -O3)
    endif()

    # iOS/Android 特定配置
    if(IOS)
        set_target_properties(sony2fuji PROPERTIES
            FRAMEWORK TRUE
            FRAMEWORK_VERSION A
            MACOSX_FRAMEWORK_IDENTIFIER com.sony2fuji.lib
            XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER com.sony2fuji.lib
        )
    endif()
endif()

# 命令行工具
if(BUILD_CLI)
    add_executable(rawlab_lut_probe tools/lut_contract_probe.cpp)
    target_include_directories(rawlab_lut_probe PRIVATE third_party)
    target_link_libraries(rawlab_lut_probe sony2fuji_core)
    add_executable(sony2fuji_cli src/cli/main.cpp src/cli/agent_commands.cpp src/cli/bsh_cli_report.cpp src/cli/raw_info.cpp)
    if(SONY2FUJI_ENABLE_DNGSDK)
        target_compile_definitions(sony2fuji_cli PRIVATE SONY2FUJI_ENABLE_DNGSDK)
    endif()
    target_include_directories(sony2fuji_cli PRIVATE third_party)
    target_link_libraries(sony2fuji_cli sony2fuji_core)
    set_target_properties(sony2fuji_cli PROPERTIES OUTPUT_NAME sony2fuji)
endif()

# 示例
if(BUILD_EXAMPLES)
    add_executable(sony2fuji_example examples/simple_example.cpp)
    target_link_libraries(sony2fuji_example sony2fuji_core)
endif()

if(ANDROID AND SONY2FUJI_ENABLE_WAVELET_DENOISE)
    add_executable(wavelet_denoise_tests EXCLUDE_FROM_ALL tests/wavelet_denoise_tests.cpp)
    target_link_libraries(wavelet_denoise_tests sony2fuji_core ${SONY2FUJI_DENOISE_LIBRARIES})
    target_compile_options(wavelet_denoise_tests PRIVATE -UNDEBUG)
endif()

if(ANDROID AND SONY2FUJI_ENABLE_GPU)
    add_executable(gles_lut_binding_tests EXCLUDE_FROM_ALL tests/gles_lut_binding_tests.cpp)
    target_link_libraries(gles_lut_binding_tests sony2fuji_core)
    target_compile_options(gles_lut_binding_tests PRIVATE -UNDEBUG)
endif()

if(ANDROID AND SONY2FUJI_ENABLE_GPU AND SONY2FUJI_ENABLE_CHROMA_DENOISE AND SONY2FUJI_ENABLE_WAVELET_DENOISE)
    add_executable(gpu_filter_tests EXCLUDE_FROM_ALL tests/metal_denoise_tests.cpp)
    target_link_libraries(gpu_filter_tests sony2fuji_core ${SONY2FUJI_DENOISE_LIBRARIES})
    target_compile_options(gpu_filter_tests PRIVATE -UNDEBUG)
endif()

if(BUILD_TESTING)
    if(MSVC)
        set(RAWLAB_UNDEBUG_FLAG /UNDEBUG)
        set(RAWLAB_OPT_FLAG /O2)
    else()
        set(RAWLAB_UNDEBUG_FLAG -UNDEBUG)
        set(RAWLAB_OPT_FLAG -O3)
    endif()
endif()

if(BUILD_TESTING AND NOT IOS)
    foreach(contract_test lut_contract lut_contract_render lut_compatibility lut_guided_import)
        rawlab_add_test(
            NAME ${contract_test}
            SOURCES tests/${contract_test}_tests.cpp
            INCLUDES third_party
            LIBRARIES sony2fuji_core
            LABELS core lut contracts ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
    endforeach()
    rawlab_add_test(
        NAME lut_parser
        SOURCES tests/lut_parser_tests.cpp
        INCLUDES third_party
        LIBRARIES sony2fuji_core
        LABELS core lut ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    set(hsl_boundary_libs)
    if(SONY2FUJI_DENOISE_LIBRARIES)
        list(APPEND hsl_boundary_libs ${SONY2FUJI_DENOISE_LIBRARIES})
    endif()
    rawlab_add_test(
        NAME hsl_boundary
        SOURCES tests/hsl_boundary_tests.cpp src/core/photo_color.cpp src/core/color_converter.cpp
        LIBRARIES ${hsl_boundary_libs}
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    foreach(contract default off fast)
        set(look_test look_exactness)
        set(look_labels core lut ci_macos_arm64 ci_macos_x86_64)
        if(NOT contract STREQUAL default)
            if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
                continue()
            endif()
            set(look_test "look_exactness_${contract}")
        else()
            list(APPEND look_labels ci_windows)
        endif()
        set(look_libs)
        if(MINGW)
            list(APPEND look_libs bcrypt)
        endif()
        if(SONY2FUJI_DENOISE_LIBRARIES)
            list(APPEND look_libs ${SONY2FUJI_DENOISE_LIBRARIES})
        endif()
        set(look_opts)
        if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
            list(APPEND look_opts -O3)
            if(NOT contract STREQUAL default)
                list(APPEND look_opts "-ffp-contract=${contract}")
            endif()
        endif()
        rawlab_add_test(
            NAME ${look_test}
            SOURCES tests/look_exactness_tests.cpp
                tests/look_lut_oracle.cpp tests/look_gamma_oracle.cpp
                src/core/lut_applicator.cpp src/core/lut_parser.cpp src/core/color_converter.cpp
            LIBRARIES ${look_libs}
            COMPILE_OPTIONS ${look_opts}
            LABELS ${look_labels}
        )
    endforeach()
endif()

if(BUILD_TESTING AND NOT IOS AND NOT ANDROID)
    if(NOT Python3_EXECUTABLE)
        find_package(Python3 QUIET COMPONENTS Interpreter)
    endif()
    if(Python3_EXECUTABLE AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/assets/prepare.py")
        execute_process(
            COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/assets/prepare.py" --group all --check --quiet
            RESULT_VARIABLE _rawlab_assets_check
            OUTPUT_QUIET ERROR_QUIET
        )
        if(NOT _rawlab_assets_check EQUAL 0)
            execute_process(
                COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/assets/prepare.py" --group all
                RESULT_VARIABLE _rawlab_assets_prepare
            )
            if(NOT _rawlab_assets_prepare EQUAL 0)
                message(FATAL_ERROR "Externalized test assets are missing or corrupted; run `python3 scripts/assets/prepare.py --group all`.")
            endif()
        endif()
    endif()
    rawlab_add_test(
        NAME tiff_ifd
        SOURCES tests/tiff_ifd_tests.cpp
        INCLUDES src
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME pinned_source_atomic_write
        SOURCES tests/pinned_source_atomic_write_tests.cpp
        INCLUDES src third_party
        LIBRARIES sony2fuji_core
        COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
        LABELS core hdr ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME jpeg_mpf
        SOURCES tests/jpeg_mpf_tests.cpp
        INCLUDES src
        LIBRARIES sony2fuji_core
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME x3f_render
        SOURCES tests/x3f_render_tests.cpp
        LIBRARIES sony2fuji_core
        LABELS x3f raw ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME recipe_wb_abi
        SOURCES tests/recipe_wb_abi_tests.cpp
        LIBRARIES sony2fuji_core
        ARGS "${CMAKE_CURRENT_SOURCE_DIR}/examples/DJI_20250602164503_0444_D.DNG"
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME bsh_diagnostics
        SOURCES tests/bsh_diagnostics_tests.cpp
        LIBRARIES sony2fuji_core
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME rgba16_api
        SOURCES tests/rgba16_api_tests.cpp
        DEFINES TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
        LIBRARIES sony2fuji_core
        LABELS core hdr ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    if(SONY2FUJI_ENABLE_X3F)
        rawlab_add_test(
            NAME x3f_bridge_contracts
            COMMAND "${CMAKE_COMMAND}" -E env ${x3f_environment}
                "${RAWLAB_CARGO}" test --release --locked --offline
                --manifest-path "${x3f_source}/Cargo.toml" --target "${RAWLAB_X3F_RUST_TARGET}"
            LABELS x3f contracts ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME x3f_parallel_contracts
            COMMAND "${CMAKE_COMMAND}" -E env ${x3f_environment}
                "${RAWLAB_CARGO}" test --release --locked --offline
                --manifest-path "${x3f_source}/Cargo.toml" --target "${RAWLAB_X3F_RUST_TARGET}"
                -p x3f-sys --lib parallel
            LABELS x3f contracts ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        # 上游的逐位原生参考来自 ARM64 macOS；MSVC 软件 FMA/libm 的末位不同。
        if(RAWLAB_X3F_RUST_TARGET STREQUAL "aarch64-apple-darwin")
            rawlab_add_test(
                NAME x3f_decoder_contracts
                COMMAND "${CMAKE_COMMAND}" -E env ${x3f_environment}
                    "${RAWLAB_CARGO}" test --release --locked --offline
                    --manifest-path "${x3f_source}/Cargo.toml" --target "${RAWLAB_X3F_RUST_TARGET}"
                    -p x3f-sys --lib
                LABELS x3f contracts arm64_only ci_macos_arm64
            )
        endif()
    endif()
    rawlab_add_test(
        NAME cpu_workspace
        SOURCES tests/cpu_workspace_tests.cpp
        LIBRARIES sony2fuji_core
        ARGS "${CMAKE_CURRENT_SOURCE_DIR}/flog-2-new/FLog2_to_Velvia_65grid_V.1.00.cube"
        LABELS core lut ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    if(APPLE AND SONY2FUJI_ENABLE_GPU)
        rawlab_add_test(
            NAME metal_workspace
            SOURCES tests/metal_workspace_tests.mm
            LIBRARIES sony2fuji_core "-framework Metal" "-framework Foundation"
            ENVIRONMENT
                "MTL_SHADER_VALIDATION=1"
                "MTL_SHADER_VALIDATION_REPORT_TO_STDERR=1"
                "MTL_SHADER_VALIDATION_ABORT_ON_FAULT=1"
            LABELS gpu metal metal_arm64 ci_macos_arm64
        )
    endif()
    rawlab_add_test(
        NAME raw_formats
        TARGET raw_format_tests
        SOURCES tests/raw_format_tests.cpp
        INCLUDES ${LIBRAW_INCLUDE_DIRS} src
        LIBRARIES ${LIBRAW_LIBRARY} ${DNGSDK_LIBRARY}
        LABELS raw ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    set(SONY2FUJI_TEST_FORMAT_DIRECTORY "" CACHE PATH "External CC0 RAW format fixtures (never bundled)")
    rawlab_add_test(
        NAME raw_format_photos
        COMMAND raw_format_tests "${SONY2FUJI_TEST_FORMAT_DIRECTORY}"
        SKIP_RETURN_CODE 77
        LABELS raw external_raw ci_macos_arm64 ci_macos_x86_64
    )
    # ARW6 是 RawLab 对 LibRaw 的回移植：本树构建的 LibRaw，或带补丁指纹的依赖前缀才具备；
    # 未打补丁的系统 LibRaw 只跳过这些测试，其余验证照常进行。
    if((SONY2FUJI_LIBRAW_TARGET AND TARGET ${SONY2FUJI_LIBRAW_TARGET})
        OR EXISTS "${LIBRAW_PREFIX}/share/rawlab/libraw-patch.sha256")
        set(SONY2FUJI_LIBRAW_RAWLAB_PATCHES ON)
    else()
        set(SONY2FUJI_LIBRAW_RAWLAB_PATCHES OFF)
        message(STATUS "LibRaw at ${LIBRAW_LIBRARY} lacks RawLab patches; skipping Sony ARW6 decoder tests")
    endif()
    if(SONY2FUJI_LIBRAW_RAWLAB_PATCHES)
        rawlab_add_test(
            NAME sony_arw6
            SOURCES tests/sony_arw6_tests.cpp
            INCLUDES ${LIBRAW_INCLUDE_DIRS}
            LIBRARIES ${LIBRAW_LIBRARY} ${DNGSDK_LIBRARY}
            LABELS raw ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        set(SONY2FUJI_TEST_LIBRAW_SOURCE "${LIBRAW_SOURCE_DIR}" CACHE PATH "Patched LibRaw source for decoder boundary tests")
        if(EXISTS "${SONY2FUJI_TEST_LIBRAW_SOURCE}/src/decoders/sony_arw6.cpp")
            # 编译仓库内的解码器源码；LibRaw 源码树只提供内部头文件，避免测到过期副本。
            set(arw6_bounds_opts)
            set(arw6_bounds_link_opts)
            if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
                list(APPEND arw6_bounds_opts -fsanitize=undefined -fno-sanitize-recover=undefined)
                list(APPEND arw6_bounds_link_opts -fsanitize=undefined)
            endif()
            rawlab_add_test(
                NAME sony_arw6_bounds
                SOURCES tests/sony_arw6_bounds_tests.cpp
                INCLUDES "${SONY2FUJI_TEST_LIBRAW_SOURCE}" "${SONY2FUJI_TEST_LIBRAW_SOURCE}/src/decoders"
                DEFINES LIBRAW_NODLL RAWLAB_ARW6_SOURCE="${CMAKE_CURRENT_SOURCE_DIR}/third_party/libraw/sony_arw6.cpp"
                LIBRARIES ${LIBRAW_LIBRARY} ${DNGSDK_LIBRARY}
                COMPILE_OPTIONS ${arw6_bounds_opts}
                LINK_OPTIONS ${arw6_bounds_link_opts}
                LABELS raw ci_macos_arm64 ci_macos_x86_64 ci_windows
            )
        endif()
        set(SONY2FUJI_TEST_SONY_ARW6 "$ENV{RAWLAB_TEST_SONY_ARW6}" CACHE FILEPATH "External DSC06333.ARW regression photo (never bundled)")
        rawlab_add_test(
            NAME sony_arw6_photo
            COMMAND sony_arw6_tests "${SONY2FUJI_TEST_SONY_ARW6}"
            SKIP_RETURN_CODE 77
            LABELS raw external_raw ci_macos_arm64 ci_macos_x86_64
        )
    endif()
    add_executable(denoise_quality_probe tests/denoise_quality_probe.cpp src/cli/raw_info.cpp)
    target_include_directories(denoise_quality_probe PRIVATE third_party)
    target_compile_definitions(denoise_quality_probe PRIVATE
        QUALITY_COMPILER="${CMAKE_CXX_COMPILER_ID}-${CMAKE_CXX_COMPILER_VERSION}"
        QUALITY_BUILD_TYPE="$<CONFIG>")
    target_link_libraries(denoise_quality_probe sony2fuji_core)
    add_executable(denoise_sharpen_probe tests/denoise_sharpen_probe.cpp)
    target_include_directories(denoise_sharpen_probe PRIVATE third_party)
    target_link_libraries(denoise_sharpen_probe sony2fuji_core)
    if(SONY2FUJI_ENABLE_GPU AND APPLE)
        add_executable(denoise_display_probe tests/denoise_display_probe.cpp)
        target_include_directories(denoise_display_probe PRIVATE third_party)
        target_link_libraries(denoise_display_probe sony2fuji_core)
    endif()
    rawlab_add_test(
        NAME denoise_quality_metrics
        SOURCES tests/denoise_quality_metrics_tests.cpp
        LIBRARIES sony2fuji_core
        COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
        LABELS denoise ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME noise_aware_sharpen
        SOURCES tests/noise_aware_sharpen_tests.cpp
        LIBRARIES sony2fuji_core
        COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
        LABELS denoise ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    set(sharpen_disabled_undefs -USONY2FUJI_ENABLE_CHROMA_DENOISE -USONY2FUJI_ENABLE_WAVELET_DENOISE -USONY2FUJI_ENABLE_METAL)
    set(metal_undef -USONY2FUJI_ENABLE_METAL)
    if(MSVC)
        set(sharpen_disabled_undefs /USONY2FUJI_ENABLE_CHROMA_DENOISE /USONY2FUJI_ENABLE_WAVELET_DENOISE /USONY2FUJI_ENABLE_METAL)
        set(metal_undef /USONY2FUJI_ENABLE_METAL)
    endif()
    rawlab_add_test(
        NAME noise_aware_sharpen_disabled
        SOURCES tests/noise_aware_sharpen_tests.cpp src/core/noise_aware_sharpen.cpp
        COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG} ${sharpen_disabled_undefs}
        LABELS denoise ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    if(SONY2FUJI_ENABLE_CHROMA_DENOISE OR SONY2FUJI_ENABLE_WAVELET_DENOISE)
        rawlab_add_test(
            NAME noise_aware_sharpen_cpu_only
            SOURCES tests/noise_aware_sharpen_tests.cpp src/core/noise_aware_sharpen.cpp
            LIBRARIES ${SONY2FUJI_DENOISE_LIBRARIES}
            COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG} ${metal_undef}
            LABELS denoise ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME noise_aware_sharpen_failure
            SOURCES tests/noise_aware_sharpen_failure_tests.cpp src/core/noise_aware_sharpen.cpp
            LIBRARIES ${SONY2FUJI_DENOISE_LIBRARIES}
            # 此目标链接 GPU 替身，CPU 异常与调用方回退测试不依赖 Metal 设备。
            DEFINES SONY2FUJI_ENABLE_METAL
            COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
            LABELS denoise ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        if(SONY2FUJI_ENABLE_GPU AND APPLE)
            rawlab_add_test(
                NAME noise_aware_sharpen_metal
                COMMAND noise_aware_sharpen_tests --metal
                LABELS denoise metal ci_macos_arm64 ci_macos_x86_64
            )
            rawlab_add_test(
                NAME noise_aware_sharpen_metal_failure
                SOURCES tests/noise_aware_sharpen_metal_failure_tests.mm
                    src/core/noise_aware_sharpen.cpp src/gpu/metal_sharpen.mm
                LIBRARIES ${SONY2FUJI_DENOISE_LIBRARIES} "-framework Metal" "-framework Foundation"
                COMPILE_OPTIONS -UNDEBUG
                DEFINES SONY2FUJI_TEST_P3_READBACK
                SKIP_RETURN_CODE 77
                LABELS denoise metal ci_macos_arm64 ci_macos_x86_64
            )
        endif()
    endif()
    set(WAVELET_DIAGNOSTIC_TEST_SOURCES tests/wavelet_diagnostics_tests.cpp
        src/core/wavelet_denoise.cpp src/core/color_converter.cpp)
    set(wavelet_diag_libs)
    if(SONY2FUJI_DENOISE_LIBRARIES)
        list(APPEND wavelet_diag_libs ${SONY2FUJI_DENOISE_LIBRARIES})
    endif()
    set(wavelet_undef -USONY2FUJI_ENABLE_WAVELET_DENOISE)
    if(MSVC)
        set(wavelet_undef /USONY2FUJI_ENABLE_WAVELET_DENOISE)
    endif()
    rawlab_add_test(
        NAME wavelet_diagnostics_disabled
        SOURCES ${WAVELET_DIAGNOSTIC_TEST_SOURCES}
        LIBRARIES ${wavelet_diag_libs}
        COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG} ${wavelet_undef}
        LABELS denoise ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    if(SONY2FUJI_ENABLE_WAVELET_DENOISE)
        rawlab_add_test(
            NAME eaw_denoise
            SOURCES tests/eaw_denoise_tests.cpp
            LIBRARIES sony2fuji_core
            COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG} ${RAWLAB_OPT_FLAG}
            LABELS denoise ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME eaw_failure
            SOURCES tests/eaw_failure_tests.cpp
            LIBRARIES sony2fuji_core
            LABELS denoise ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME wavelet_noise_model
            SOURCES tests/wavelet_noise_model_tests.cpp
            LIBRARIES sony2fuji_core
            COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG} ${RAWLAB_OPT_FLAG}
            LABELS denoise ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME wavelet_luminance
            SOURCES tests/wavelet_luminance_tests.cpp
            LIBRARIES sony2fuji_core
            COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG} ${RAWLAB_OPT_FLAG}
            LABELS denoise ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME wavelet_chroma
            SOURCES tests/wavelet_chroma_tests.cpp
            LIBRARIES sony2fuji_core
            COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG} ${RAWLAB_OPT_FLAG}
            LABELS denoise ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME wavelet_restore
            SOURCES tests/wavelet_restore_tests.cpp
            LIBRARIES sony2fuji_core
            COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG} ${RAWLAB_OPT_FLAG}
            LABELS denoise ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        if(UNIX AND CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|AARCH64|ARM64|arm64)")
            # 62.9 MP 实测单独运行，避免普通 CTest 并发叠加大图内存。
            add_executable(wavelet_legacy_memory_tests EXCLUDE_FROM_ALL tests/wavelet_legacy_memory_tests.cpp)
            target_link_libraries(wavelet_legacy_memory_tests sony2fuji_core)
        endif()
        rawlab_add_test(
            NAME wavelet_diagnostics
            SOURCES ${WAVELET_DIAGNOSTIC_TEST_SOURCES}
            LIBRARIES ${SONY2FUJI_DENOISE_LIBRARIES}
            COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG} ${RAWLAB_OPT_FLAG}
            LABELS denoise ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
    endif()
    find_package(Python3 QUIET COMPONENTS Interpreter)
    if(Python3_Interpreter_FOUND)
        rawlab_add_test(
            NAME denoise_quality_runner
            COMMAND ${Python3_EXECUTABLE}
                "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_denoise_quality.py" --probe $<TARGET_FILE:denoise_quality_probe>
            LABELS denoise ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
    endif()
    rawlab_add_test(
        NAME nikon_he_codec
        TARGET nikon_he_codec_tests
        SOURCES tests/nikon_he_tests.cpp
            third_party/nikon_he/parser.cpp third_party/nikon_he/entropy.cpp
            third_party/nikon_he/dwt.cpp third_party/nikon_he/output.cpp
        INCLUDES third_party/nikon_he
        LABELS raw ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    add_executable(nikon_he_reference_tests tests/nikon_he_reference_tests.cpp)
    target_link_libraries(nikon_he_reference_tests sony2fuji_core)
    set(SONY2FUJI_TEST_RAW "" CACHE FILEPATH "External RAW fixture (never bundled)")
    file(TO_CMAKE_PATH "${SONY2FUJI_TEST_RAW}" SONY2FUJI_TEST_RAW)
    set(SONY2FUJI_TEST_LENS_WAVELET_RAW "" CACHE FILEPATH "External RAW with calibrated Lens and applied wavelet NR")
    file(TO_CMAKE_PATH "${SONY2FUJI_TEST_LENS_WAVELET_RAW}" SONY2FUJI_TEST_LENS_WAVELET_RAW)
    find_package(Threads REQUIRED)
    rawlab_add_test(
        NAME display_render
        SOURCES tests/display_render_tests.cpp
        LIBRARIES sony2fuji_core
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    set(hdr_render_libs sony2fuji_core)
    set(hdr_render_defs)
    if(SONY2FUJI_DENOISE_LIBRARIES)
        list(APPEND hdr_render_libs ${SONY2FUJI_DENOISE_LIBRARIES})
        if(SONY2FUJI_ENABLE_CHROMA_DENOISE)
            list(APPEND hdr_render_defs SONY2FUJI_ENABLE_CHROMA_DENOISE)
        endif()
        if(SONY2FUJI_ENABLE_WAVELET_DENOISE)
            list(APPEND hdr_render_defs SONY2FUJI_ENABLE_WAVELET_DENOISE)
        endif()
    endif()
    add_executable(hdr_render_tests tests/hdr_render_tests.cpp)
    target_link_libraries(hdr_render_tests ${hdr_render_libs})
    if(hdr_render_defs)
        target_compile_definitions(hdr_render_tests PRIVATE ${hdr_render_defs})
    endif()
    if(SONY2FUJI_DENOISE_LIBRARIES)
        rawlab_add_test(
            NAME hdr_render_parallel
            COMMAND hdr_render_tests parallel
            LABELS hdr ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
    endif()
    foreach(case IN ITEMS identity headroom_fusion tone color rendition effects detail white_balance geometry validation move_reuse look_cache_alternating look_cache_overwrite look_cache_content_addressed)
        rawlab_add_test(
            NAME hdr_render_${case}
            COMMAND hdr_render_tests ${case}
            LABELS hdr ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
    endforeach()
    rawlab_add_test(
        NAME hdr_render_look
        COMMAND hdr_render_tests look "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/hdr-look-linear.cube"
        LABELS hdr ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME hdr_render_bundled_silver
        COMMAND hdr_render_tests silver "${CMAKE_CURRENT_SOURCE_DIR}/../Shared/BundledLooks/HDR/HDR Silver.cube"
        LABELS hdr ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME hdr_stream_geometry
        SOURCES tests/hdr_stream_geometry_tests.cpp
        LIBRARIES sony2fuji_core
        LABELS hdr geometry ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME hdr_resample
        SOURCES tests/hdr_resample_tests.cpp
        LIBRARIES sony2fuji_core
        LABELS hdr ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    if(APPLE OR WIN32 OR ANDROID)
        rawlab_add_test(
            NAME hdr_stream
            SOURCES tests/hdr_stream_tests.cpp
            LIBRARIES sony2fuji_core
            ARGS "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/hdr-look-linear.cube"
            LABELS hdr ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME hdr_stream_api
            SOURCES tests/hdr_stream_api_tests.cpp
            LIBRARIES sony2fuji_core
            ARGS "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/hdr-look-linear.cube"
            LABELS hdr ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
    endif()
    enable_language(C)
    add_library(hdr_c_header_check OBJECT tests/hdr_c_header.c)
    set_target_properties(hdr_c_header_check PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED ON)
    rawlab_add_test(
        NAME hdr_api_validation
        TARGET hdr_api_tests
        SOURCES tests/hdr_api_tests.cpp
        LIBRARIES sony2fuji_core
        ARGS
            "${CMAKE_CURRENT_SOURCE_DIR}/../Shared/BundledLooks/HDR/HDR Silver.cube"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/hdr-look-linear.cube"
        LABELS hdr ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME camera_raw_hdr
        SOURCES tests/camera_raw_hdr_tests.cpp
        DEFINES TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
        LIBRARIES sony2fuji_core
        LABELS hdr raw ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    set(proraw_hdr_defs TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures")
    if(SONY2FUJI_ENABLE_DNGSDK)
        list(APPEND proraw_hdr_defs SONY2FUJI_TEST_DNGSDK)
    endif()
    rawlab_add_test(
        NAME proraw_hdr
        SOURCES tests/proraw_hdr_tests.cpp
        DEFINES ${proraw_hdr_defs}
        LIBRARIES sony2fuji_core
        SKIP_RETURN_CODE 77
        LABELS hdr raw ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    if(SONY2FUJI_TEST_PORTABLE_HDR)
        set(hdr_portable_srcs tests/hdr_portable_tests.cpp
            src/platform/hdr_image_portable.cpp src/platform/hdr_heif.cpp src/platform/hdr_heif_color.cpp src/platform/hdr_metadata.cpp)
        set(hdr_portable_defs TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures")
        if(APPLE)
            list(APPEND hdr_portable_srcs tests/hdr_heif_fixture.mm)
            set_source_files_properties(tests/hdr_heif_fixture.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
            list(APPEND hdr_portable_defs RAWLAB_HDR_TEST_APPLE_AUTHOR)
        endif()
        rawlab_add_test(
            NAME hdr_portable_files
            TARGET hdr_portable_tests
            SOURCES ${hdr_portable_srcs}
            INCLUDES_BEFORE src "${RAWLAB_HDR_LCMS_INCLUDE}" "${RAWLAB_HDR_UHDR_INCLUDE}" "${RAWLAB_HDR_XML_INCLUDE}"
            LIBRARIES sony2fuji_core heif rawlab_lcms
            DEFINES ${hdr_portable_defs}
            LABELS hdr ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        if(APPLE)
            foreach(test_name IN ITEMS proraw_hdr hdr_stream_api)
                set(portable_defs TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
                    RAWLAB_HDR_PORTABLE_ADAPTER=1)
                if(SONY2FUJI_ENABLE_DNGSDK)
                    list(APPEND portable_defs SONY2FUJI_TEST_DNGSDK)
                endif()
                set(portable_args)
                set(portable_skip "")
                if(test_name STREQUAL "hdr_stream_api")
                    set(portable_args "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/hdr-look-linear.cube")
                else()
                    set(portable_skip 77)
                endif()
                rawlab_add_test(
                    NAME ${test_name}_portable
                    TARGET ${test_name}_portable_tests
                    SOURCES tests/${test_name}_tests.cpp
                        src/platform/hdr_image_portable.cpp src/platform/hdr_heif.cpp src/platform/hdr_heif_color.cpp src/platform/hdr_metadata.cpp
                    INCLUDES_BEFORE src "${RAWLAB_HDR_LCMS_INCLUDE}" "${RAWLAB_HDR_UHDR_INCLUDE}" "${RAWLAB_HDR_XML_INCLUDE}"
                    LIBRARIES sony2fuji_core heif rawlab_lcms
                    DEFINES ${portable_defs}
                    ARGS ${portable_args}
                    SKIP_RETURN_CODE ${portable_skip}
                    LABELS hdr ci_macos_arm64 ci_macos_x86_64
                )
            endforeach()
        endif()
    endif()
    rawlab_add_test(
        NAME hdr_half_float
        TARGET hdr_half_tests
        SOURCES tests/hdr_half_tests.cpp
        INCLUDES src
        LABELS hdr ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    if(APPLE)
        rawlab_add_test(
            NAME display_image
            SOURCES tests/display_image_tests.cpp
            LIBRARIES sony2fuji_core
            LABELS core hdr ci_macos_arm64 ci_macos_x86_64
        )
        rawlab_add_test(
            NAME display_image_decode_count
            SOURCES tests/display_image_decode_count_tests.cpp
            INCLUDES src
            LIBRARIES sony2fuji_core
            LABELS core hdr ci_macos_arm64 ci_macos_x86_64
        )
        rawlab_add_test(
            NAME hdr_image_decode
            TARGET hdr_image_tests
            SOURCES tests/hdr_image_tests.mm
            INCLUDES src
            DEFINES TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
            COMPILE_OPTIONS -fobjc-arc
            LIBRARIES sony2fuji_core "-framework Foundation" "-framework CoreImage"
            SKIP_RETURN_CODE 77
            LABELS hdr ci_macos_arm64 ci_macos_x86_64
        )
    endif()
    set(geometry_libs)
    if(SONY2FUJI_DENOISE_LIBRARIES)
        list(APPEND geometry_libs ${SONY2FUJI_DENOISE_LIBRARIES})
    endif()
    rawlab_add_test(
        NAME photo_geometry
        SOURCES tests/photo_geometry_tests.cpp src/core/photo_geometry.cpp
        LIBRARIES ${geometry_libs}
        LABELS geometry ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME photo_geometry_exactness
        SOURCES tests/photo_geometry_exactness_tests.cpp
            tests/photo_geometry_oracle.cpp src/core/photo_geometry.cpp
        LIBRARIES ${geometry_libs}
        LABELS geometry ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    add_executable(geometry_benchmark EXCLUDE_FROM_ALL
        tests/geometry_benchmark.cpp src/core/photo_geometry.cpp)
    if(geometry_libs)
        target_link_libraries(geometry_benchmark ${geometry_libs})
    endif()
    rawlab_add_test(
        NAME perspective
        SOURCES tests/perspective_tests.cpp src/core/photo_geometry.cpp
        LIBRARIES ${geometry_libs}
        LABELS geometry ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME inspection_geometry_parity
        SOURCES tests/inspection_geometry_parity_tests.cpp src/core/photo_geometry.cpp src/core/inspection_overlay.cpp src/ffi/inspection_c.cpp
        LIBRARIES ${geometry_libs}
        LABELS geometry ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME inspection_overlay
        SOURCES tests/inspection_overlay_tests.cpp src/core/photo_geometry.cpp src/core/inspection_overlay.cpp src/ffi/inspection_c.cpp
        LIBRARIES ${geometry_libs}
        LABELS inspection ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME sony_ptpip
        SOURCES tests/sony_ptpip_tests.cpp src/core/sony_ptpip.cpp src/ffi/sony_ptpip_c.cpp
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME perspective_api
        SOURCES tests/perspective_api_tests.cpp
        LIBRARIES sony2fuji_core
        LABELS geometry ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME perspective_raw
        COMMAND perspective_api_tests "${SONY2FUJI_TEST_RAW}"
        SKIP_RETURN_CODE 77
        LABELS geometry external_raw ci_macos_arm64 ci_macos_x86_64
    )
    rawlab_add_test(
        NAME geometry_api
        SOURCES tests/geometry_api_tests.cpp
        LIBRARIES sony2fuji_core
        LABELS geometry ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME geometry_viewport
        SOURCES tests/geometry_viewport_tests.cpp
        LIBRARIES sony2fuji_core
        LABELS geometry ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME geometry_size
        SOURCES tests/geometry_size_tests.cpp src/core/photo_geometry.cpp
        LIBRARIES ${geometry_libs}
        LABELS geometry ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    add_executable(geometry_viewport_probe EXCLUDE_FROM_ALL tests/geometry_viewport_probe.cpp)
    target_link_libraries(geometry_viewport_probe sony2fuji_core)
    rawlab_add_test(
        NAME geometry_raw
        COMMAND geometry_api_tests "${SONY2FUJI_TEST_RAW}"
        SKIP_RETURN_CODE 77
        LABELS geometry external_raw ci_macos_arm64 ci_macos_x86_64
    )
    rawlab_add_test(
        NAME edit_recipe
        SOURCES tests/edit_recipe_tests.cpp
        LIBRARIES sony2fuji_core
        LABELS recipe ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME processing_recipe
        SOURCES tests/processing_recipe_tests.cpp
        INCLUDES third_party
        LIBRARIES sony2fuji_core
        LABELS recipe ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME edit_recipe_raster
        SOURCES tests/edit_recipe_raster_tests.cpp
        INCLUDES third_party
        LIBRARIES sony2fuji_core
        LABELS recipe ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME apply_params_api
        SOURCES tests/apply_params_api_tests.cpp
        LIBRARIES sony2fuji_core
        LABELS core recipe ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME viewport_pyramid
        SOURCES tests/viewport_pyramid_tests.cpp
        INCLUDES third_party
        DEFINES TEST_EXAMPLES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/examples" TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
        LIBRARIES sony2fuji_core
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME hdr_recipe_roundtrip
        TARGET hdr_recipe_tests
        SOURCES tests/hdr_recipe_tests.cpp
        INCLUDES third_party
        LIBRARIES sony2fuji_core
        LABELS hdr recipe ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME hdr_recipe_native_parity
        TARGET hdr_recipe_native_tests
        SOURCES tests/hdr_recipe_native_tests.cpp
        INCLUDES third_party
        LIBRARIES sony2fuji_core
        LABELS hdr recipe ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME edit_recipe_geometry
        SOURCES tests/edit_recipe_geometry_tests.cpp
        LIBRARIES sony2fuji_core
        LABELS recipe geometry ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME edit_recipe_perspective
        SOURCES tests/edit_recipe_perspective_tests.cpp
        LIBRARIES sony2fuji_core
        LABELS recipe geometry ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME edit_pixel_golden
        SOURCES tests/edit_pixel_golden_tests.cpp
        INCLUDES third_party
        DEFINES TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
        LIBRARIES sony2fuji_core
        LABELS core recipe ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    if(APPLE AND SONY2FUJI_ENABLE_GPU)
        rawlab_add_test(
            NAME metal_edit_pixel_golden
            COMMAND edit_pixel_golden_tests --metal
            ENVIRONMENT
                "MTL_SHADER_VALIDATION=1"
                "MTL_SHADER_VALIDATION_REPORT_TO_STDERR=1"
                "MTL_SHADER_VALIDATION_ABORT_ON_FAULT=1"
            LABELS gpu metal metal_arm64 ci_macos_arm64
        )
    endif()
    if(BUILD_CLI)
        find_package(Python3 QUIET COMPONENTS Interpreter)
        if(Python3_Interpreter_FOUND)
            if(APPLE)
                rawlab_add_test(
                    NAME hdr_recipe_cli
                    COMMAND ${Python3_EXECUTABLE}
                        "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_hdr_agent.py"
                        --cli $<TARGET_FILE:sony2fuji_cli> --fixture $<TARGET_FILE:hdr_image_tests>
                    LABELS hdr recipe cli ci_macos_arm64 ci_macos_x86_64
                )
            endif()
            set(CLI_DEFAULT_RAW "${CMAKE_CURRENT_SOURCE_DIR}/examples/DJI_20250602164503_0444_D.DNG")
            set(CLI_RAW_ARGS --default-raw "${CLI_DEFAULT_RAW}")
            if(NOT "${SONY2FUJI_TEST_RAW}" STREQUAL "")
                list(APPEND CLI_RAW_ARGS --raw "${SONY2FUJI_TEST_RAW}")
            endif()
            rawlab_add_test(
                NAME geometry_cli
                COMMAND ${Python3_EXECUTABLE}
                    "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_geometry_cli.py"
                    --cli $<TARGET_FILE:sony2fuji_cli>
                    ${CLI_RAW_ARGS}
                    --fixtures "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
                SKIP_RETURN_CODE 77
                LABELS geometry cli ci_macos_arm64 ci_macos_x86_64 ci_windows
            )
            rawlab_add_test(
                NAME agent_preview
                COMMAND ${Python3_EXECUTABLE}
                    "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_agent_preview.py"
                    --cli $<TARGET_FILE:sony2fuji_cli>
                    ${CLI_RAW_ARGS}
                    --fixtures "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
                SKIP_RETURN_CODE 77
                LABELS cli ci_macos_arm64 ci_macos_x86_64 ci_windows
            )
            rawlab_add_test(
                NAME raw_info_cli
                COMMAND ${Python3_EXECUTABLE}
                    "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_raw_info_cli.py"
                    --cli $<TARGET_FILE:sony2fuji_cli>
                    ${CLI_RAW_ARGS}
                    --fixtures "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
                SKIP_RETURN_CODE 77
                LABELS raw cli ci_macos_arm64 ci_macos_x86_64 ci_windows
            )
            rawlab_add_test(
                NAME hdr_source_cache
                COMMAND ${Python3_EXECUTABLE}
                    "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_hdr_sources.py"
                LABELS hdr cli ci_macos_arm64 ci_macos_x86_64 ci_windows
            )
            rawlab_add_test(
                NAME agent_commands
                COMMAND ${Python3_EXECUTABLE}
                    "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_agent_commands.py"
                    --cli $<TARGET_FILE:sony2fuji_cli>
                    ${CLI_RAW_ARGS}
                SKIP_RETURN_CODE 77
                LABELS cli ci_macos_arm64 ci_macos_x86_64 ci_windows
            )
            rawlab_add_test(
                NAME bsh_cli
                COMMAND ${Python3_EXECUTABLE}
                    "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_bsh_cli.py"
                    --cli $<TARGET_FILE:sony2fuji_cli>
                    --fixtures "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
                LABELS cli ci_macos_arm64 ci_macos_x86_64 ci_windows
            )
            rawlab_add_test(
                NAME edit_recipe_cli
                COMMAND ${Python3_EXECUTABLE}
                    "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_edit_recipe_cli.py"
                    --cli $<TARGET_FILE:sony2fuji_cli>
                    ${CLI_RAW_ARGS}
                SKIP_RETURN_CODE 77
                LABELS recipe cli ci_macos_arm64 ci_macos_x86_64 ci_windows
            )
            rawlab_add_test(
                NAME edit_recipe_schema
                COMMAND ${Python3_EXECUTABLE}
                    "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_edit_recipe_schema.py"
                    --cli $<TARGET_FILE:sony2fuji_cli>
                SKIP_RETURN_CODE 77
                LABELS recipe cli contracts ci_macos_arm64 ci_macos_x86_64 ci_windows
            )
        endif()
    endif()
    set(rendered_dng_defs)
    if(SONY2FUJI_ENABLE_DNGSDK AND SONY2FUJI_ENABLE_LENSFUN)
        list(APPEND rendered_dng_defs TEST_LENS_SDK_DNG TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}")
    endif()
    if(SONY2FUJI_ENABLE_LENSFUN AND SONY2FUJI_ENABLE_WAVELET_DENOISE)
        list(APPEND rendered_dng_defs TEST_LENS_WAVELET_DNG TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}")
    endif()
    rawlab_add_test(
        NAME rendered_dng
        SOURCES tests/rendered_dng_tests.cpp
        DEFINES ${rendered_dng_defs}
        LIBRARIES sony2fuji_core
        LABELS raw hdr ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    if(APPLE AND NOT IOS)
        rawlab_add_test(
            NAME rendered_dng_imageio
            SOURCES tests/rendered_dng_imageio_tests.mm
            COMPILE_OPTIONS -fobjc-arc
            LIBRARIES sony2fuji_core "-framework Foundation" "-framework ImageIO" "-framework CoreGraphics"
            LABELS raw hdr ci_macos_arm64 ci_macos_x86_64
        )
    endif()
    if(SONY2FUJI_ENABLE_LENSFUN AND SONY2FUJI_ENABLE_WAVELET_DENOISE)
        rawlab_add_test(
            NAME rendered_dng_lens_wavelet
            COMMAND rendered_dng_tests "${SONY2FUJI_TEST_LENS_WAVELET_RAW}"
            SKIP_RETURN_CODE 77
            LABELS raw external_raw ci_macos_arm64 ci_macos_x86_64
        )
    endif()
    rawlab_add_test(
        NAME color_contracts
        TARGET core_tests
        SOURCES tests/core_tests.cpp
        DEFINES TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}"
        LIBRARIES sony2fuji_core Threads::Threads
        LABELS core contracts ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME color_contracts_raw
        COMMAND core_tests "${SONY2FUJI_TEST_RAW}"
        SKIP_RETURN_CODE 77
        LABELS core external_raw ci_macos_arm64 ci_macos_x86_64
    )
    rawlab_add_test(
        NAME processing_cancellation
        SOURCES tests/processing_cancellation_tests.cpp
        LIBRARIES sony2fuji_core
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME native_dcp_look
        TARGET dcp_look_tests
        SOURCES tests/dcp_look_tests.cpp
        LIBRARIES sony2fuji_core
        LABELS dcp core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME dcp_compiler
        SOURCES tests/dcp_compiler_tests.cpp
        DEFINES TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
        LIBRARIES sony2fuji_core
        LABELS dcp core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    if(SONY2FUJI_ENABLE_GPU AND APPLE)
        rawlab_add_test(
            NAME native_dcp_metal
            COMMAND dcp_look_tests --metal
            LABELS dcp metal hw_gpu
        )
    endif()
    rawlab_add_test(
        NAME image_stats
        SOURCES tests/image_stats_tests.cpp
        LIBRARIES sony2fuji_core
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME image_data_bounds_release
        SOURCES tests/image_data_bounds_release_tests.cpp
        DEFINES NDEBUG
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    if(MSVC)
        set(pipeline_ai_rollback_opts /W4 /utf-8 /USONY2FUJI_ENABLE_METAL /USONY2FUJI_ENABLE_GLES /USONY2FUJI_ENABLE_D3D11)
        set(pipeline_ai_rollback_defs SONY2FUJI_ENABLE_AI_DENOISE NOMINMAX)
    else()
        set(pipeline_ai_rollback_opts -Wall -Wextra -USONY2FUJI_ENABLE_METAL -USONY2FUJI_ENABLE_GLES -USONY2FUJI_ENABLE_D3D11)
        set(pipeline_ai_rollback_defs SONY2FUJI_ENABLE_AI_DENOISE)
    endif()
    set(pipeline_ai_rollback_includes ${LIBRAW_INCLUDE_DIRS})
    if(SONY2FUJI_LIBRAW_TARGET AND TARGET ${SONY2FUJI_LIBRAW_TARGET})
        list(APPEND pipeline_ai_rollback_includes
            "$<TARGET_PROPERTY:${SONY2FUJI_LIBRAW_TARGET},INTERFACE_INCLUDE_DIRECTORIES>")
    endif()
    rawlab_add_test(
        NAME pipeline_ai_rollback
        SOURCES tests/pipeline_ai_rollback_tests.cpp src/core/pipeline_ai.cpp
        INCLUDES_BEFORE tests/ai_stub
        INCLUDES ${pipeline_ai_rollback_includes}
        DEFINES ${pipeline_ai_rollback_defs}
        COMPILE_OPTIONS ${pipeline_ai_rollback_opts}
        LABELS ai core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    if(WIN32)
        rawlab_add_test(
            NAME d3d11_shader
            SOURCES tests/d3d11_shader_tests.cpp
            INCLUDES "${CMAKE_CURRENT_SOURCE_DIR}/src"
            LIBRARIES d3dcompiler
            LABELS gpu d3d11 ci_windows
        )
    endif()
    find_program(RAWLAB_GLSLANG NAMES glslangValidator glslang)
    # 优先复用已解析的 Python3_EXECUTABLE，避免 Windows 下 find_program 命中应用商店占位符或漏找导致静默跳过。
    if(Python3_EXECUTABLE)
        set(RAWLAB_SHADER_PYTHON "${Python3_EXECUTABLE}")
    else()
        find_program(RAWLAB_SHADER_PYTHON NAMES python3 python)
    endif()
    if(RAWLAB_GLSLANG AND RAWLAB_SHADER_PYTHON)
        rawlab_add_test(
            NAME gles_shader
            COMMAND "${RAWLAB_SHADER_PYTHON}"
                "${CMAKE_CURRENT_SOURCE_DIR}/tests/check_gles_shader.py" --validator "${RAWLAB_GLSLANG}"
            LABELS gpu gles_shader ci_macos_arm64 ci_macos_x86_64
        )
    elseif(RAWLAB_SHADER_PYTHON)
        rawlab_add_test(
            NAME gles_shader
            COMMAND "${RAWLAB_SHADER_PYTHON}" -c
                "import sys; print('SKIP gles_shader: glslangValidator unavailable'); sys.exit(77)"
            SKIP_RETURN_CODE 77
            LABELS gpu gles_shader ci_macos_arm64 ci_macos_x86_64
        )
    endif()
    if(UNIX)
        find_program(RAWLAB_ABI_CLANGXX NAMES clang++)
        find_program(RAWLAB_ABI_BASH NAMES bash)
        if(RAWLAB_ABI_CLANGXX AND RAWLAB_ABI_BASH AND RAWLAB_SHADER_PYTHON)
            rawlab_add_test(
                NAME abi_layout_fixture
                COMMAND "${RAWLAB_SHADER_PYTHON}"
                    "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/ci/test_abi_layout.py"
                ENVIRONMENT
                    "CXX=${RAWLAB_ABI_CLANGXX}"
                    "RAWLAB_REQUIRE_ABI_CHECK=1"
                LABELS contracts abi ci_macos_arm64 ci_macos_x86_64
            )
        endif()
    endif()
    if(RAWLAB_SHADER_PYTHON)
        # 编译真实 Binding 代码块，避免为顺序测试桩化整套 photo/denoise 渲染 API。
        set(gles_bindings_header "${CMAKE_CURRENT_BINARY_DIR}/gles_binding_order_bindings.h")
        add_custom_command(OUTPUT "${gles_bindings_header}"
            COMMAND "${RAWLAB_SHADER_PYTHON}" "${CMAKE_CURRENT_SOURCE_DIR}/tests/extract_gles_bindings.py"
                "${gles_bindings_header}"
            DEPENDS tests/extract_gles_bindings.py src/gpu/gles_lut.cpp src/gpu/gles_photo.cpp src/gpu/gles_denoise.cpp
            VERBATIM)
        set(gles_order_opts -Wall -Wextra)
        if(MSVC)
            set(gles_order_opts /W4 /utf-8)
        endif()
        add_executable(gles_binding_order_tests tests/gles_binding_order_tests.cpp "${gles_bindings_header}")
        target_include_directories(gles_binding_order_tests PRIVATE tests/gles_stub "${CMAKE_CURRENT_BINARY_DIR}")
        target_compile_options(gles_binding_order_tests PRIVATE ${gles_order_opts})
        foreach(binding lut photo denoise)
            rawlab_add_test(
                NAME gpu_gles_binding_order_${binding}
                COMMAND gles_binding_order_tests ${binding}
                LABELS gpu gles_shader ci_macos_arm64 ci_macos_x86_64
            )
        endforeach()
    endif()
    set(gles_stub_libs Threads::Threads)
    if(MINGW)
        list(APPEND gles_stub_libs bcrypt)
    endif()
    if(SONY2FUJI_DENOISE_LIBRARIES)
        list(APPEND gles_stub_libs ${SONY2FUJI_DENOISE_LIBRARIES})
    endif()
    if(MSVC)
        set(gles_stub_opts /W4 /utf-8 /UNDEBUG /USONY2FUJI_ENABLE_METAL)
        set(gles_photo_opts /W4 /utf-8 /UNDEBUG /USONY2FUJI_ENABLE_METAL /USONY2FUJI_ENABLE_D3D11)
        set(gles_stub_defs SONY2FUJI_ENABLE_GLES SONY2FUJI_FAKE_EGL_GLES NOMINMAX)
    else()
        set(gles_stub_opts -Wall -Wextra -UNDEBUG -USONY2FUJI_ENABLE_METAL)
        set(gles_photo_opts -Wall -Wextra -UNDEBUG -USONY2FUJI_ENABLE_METAL -USONY2FUJI_ENABLE_D3D11)
        set(gles_stub_defs SONY2FUJI_ENABLE_GLES SONY2FUJI_FAKE_EGL_GLES)
    endif()
    rawlab_add_test(
        NAME gpu_gles_lut_binding
        TARGET gles_lut_binding_tests
        SOURCES tests/gles_lut_binding_tests.cpp
            src/gpu/gles_lut.cpp src/gpu/lut_gpu.cpp src/core/lut_applicator.cpp src/core/lut_parser.cpp
        INCLUDES tests/gles_stub
        LIBRARIES ${gles_stub_libs}
        DEFINES ${gles_stub_defs}
        COMPILE_OPTIONS ${gles_stub_opts}
        LABELS gpu gles_shader ci_macos_arm64 ci_macos_x86_64
    )
    rawlab_add_test(
        NAME gpu_gles_lut_init_failure_binding
        COMMAND gles_lut_binding_tests --init-failure
        LABELS gpu gles_shader ci_macos_arm64 ci_macos_x86_64
    )
    rawlab_add_test(
        NAME gpu_gles_lut_init_retry
        COMMAND gles_lut_binding_tests --init-retry
        LABELS gpu gles_shader ci_macos_arm64 ci_macos_x86_64
    )
    set(compute_reuse_defs ${gles_stub_defs})
    if(RAWLAB_GLSLANG)
        list(APPEND compute_reuse_defs RAWLAB_GLSLANG_PATH="${RAWLAB_GLSLANG}")
    endif()
    rawlab_add_test(
        NAME compute_denoise_reuse
        SOURCES tests/compute_denoise_reuse_tests.cpp
            src/gpu/compute_denoise.cpp src/gpu/gles_denoise.cpp src/core/photo_effects.cpp
        INCLUDES tests/gles_stub
        LIBRARIES ${gles_stub_libs}
        DEFINES ${compute_reuse_defs}
        COMPILE_OPTIONS ${gles_photo_opts}
        LABELS gpu gles_shader denoise ci_macos_arm64 ci_macos_x86_64
    )
    if(RAWLAB_GLSLANG)
        set(gles_photo_sources
            src/gpu/gles_photo.cpp src/gpu/gles_denoise.cpp src/gpu/compute_denoise.cpp
            src/gpu/denoise.cpp src/gpu/gles_lut.cpp src/gpu/lut_gpu.cpp
            src/core/chroma_denoise.cpp src/core/lut_applicator.cpp src/core/lut_parser.cpp
            src/core/color_converter.cpp src/core/photo_color.cpp src/core/photo_effects.cpp
            src/core/photo_tone_controls.cpp src/core/photo_basic_controls_v3.cpp
            src/core/dcp_look.cpp src/core/pinned_source_file.cpp
            src/core/photo_atmosphere.cpp src/core/photo_color_grading.cpp src/core/photo_tone_curve.cpp
            src/core/photo_calibration.cpp src/core/photo_point_color.cpp src/core/photo_selective_color.cpp
            src/core/photo_bw_mixer.cpp src/core/photo_sharpen_v2.cpp src/core/photo_defringe.cpp
            src/core/photo_film_optics.cpp)
        rawlab_add_test(
            NAME gpu_gles_photo_pixel
            TARGET gles_photo_pixel_tests
            SOURCES tests/gles_photo_pixel_tests.cpp ${gles_photo_sources}
            INCLUDES tests/gles_stub third_party
            LIBRARIES ${gles_stub_libs}
            DEFINES ${gles_stub_defs} RAWLAB_GLSLANG_PATH="${RAWLAB_GLSLANG}"
            COMPILE_OPTIONS ${gles_photo_opts}
            LABELS gpu gles_shader ci_macos_arm64 ci_macos_x86_64
        )
        # 未接真实硬件适配器前的占位探针：所有平台统一返回 77 SKIP，避免空壳绿灯。
        rawlab_add_test(
            NAME gpu_gles_hw_photo
            COMMAND gles_photo_pixel_tests --hardware-gles
            SKIP_RETURN_CODE 77
            LABELS gpu gles_shader ci_macos_arm64 ci_macos_x86_64
        )
        rawlab_add_test(
            NAME gpu_d3d11_hw_photo
            COMMAND gles_photo_pixel_tests --hardware-d3d11
            SKIP_RETURN_CODE 77
            LABELS gpu gles_shader ci_macos_arm64 ci_macos_x86_64
        )
        rawlab_add_test(
            NAME gpu_gles_renderer_retry
            TARGET gles_renderer_retry_tests
            SOURCES tests/gles_renderer_retry_tests.cpp ${gles_photo_sources}
            INCLUDES tests/gles_stub tests third_party
            LIBRARIES ${gles_stub_libs}
            DEFINES ${gles_stub_defs} RAWLAB_GLES_TESTING RAWLAB_GLSLANG_PATH="${RAWLAB_GLSLANG}"
            COMPILE_OPTIONS ${gles_photo_opts}
            LABELS gpu gles_shader ci_macos_arm64 ci_macos_x86_64
        )
    elseif(RAWLAB_SHADER_PYTHON)
        foreach(gles_skip_test gpu_gles_photo_pixel gpu_gles_hw_photo gpu_d3d11_hw_photo)
            rawlab_add_test(
                NAME ${gles_skip_test}
                COMMAND "${RAWLAB_SHADER_PYTHON}" -c
                    "import sys; print('SKIP ${gles_skip_test}: glslangValidator unavailable'); sys.exit(77)"
                SKIP_RETURN_CODE 77
                LABELS gpu gles_shader ci_macos_arm64 ci_macos_x86_64
            )
        endforeach()
    endif()
    set(d3d11_cache_libs)
    if(WIN32)
        list(APPEND d3d11_cache_libs d3dcompiler)
    endif()
    set(d3d11_cache_opts -Wall -Wextra)
    if(MSVC)
        set(d3d11_cache_opts /W4 /utf-8)
    endif()
    rawlab_add_test(
        NAME d3d11_shader_cache
        SOURCES tests/d3d11_shader_cache_tests.cpp src/core/atomic_output_transaction.cpp
        LIBRARIES ${d3d11_cache_libs}
        COMPILE_OPTIONS ${d3d11_cache_opts}
        LABELS gpu d3d11 ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    if(APPLE)
        set(metal_retry_libs Threads::Threads "-framework Metal" "-framework Foundation")
        if(SONY2FUJI_DENOISE_LIBRARIES)
            list(APPEND metal_retry_libs ${SONY2FUJI_DENOISE_LIBRARIES})
        endif()
        rawlab_add_test(
            NAME gpu_metal_lut_init_retry
            TARGET metal_lut_init_retry_tests
            SOURCES tests/metal_lut_init_retry_tests.mm
                src/gpu/lut_gpu.cpp src/core/lut_applicator.cpp src/core/lut_parser.cpp
            LIBRARIES ${metal_retry_libs}
            COMPILE_OPTIONS -UNDEBUG "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
            LABELS gpu metal lut ci_macos_arm64 ci_macos_x86_64
        )
        rawlab_add_test(
            NAME gpu_metal_lut_bounds
            TARGET metal_lut_bounds_tests
            SOURCES tests/metal_lut_bounds_tests.mm
                src/gpu/lut_gpu.cpp src/core/lut_applicator.cpp src/core/lut_parser.cpp
            LIBRARIES ${metal_retry_libs}
            COMPILE_OPTIONS -UNDEBUG "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
            LABELS gpu metal lut ci_macos_arm64 ci_macos_x86_64
        )
    endif()
    set(no_backend_libs Threads::Threads)
    if(MINGW)
        list(APPEND no_backend_libs bcrypt)
    endif()
    if(SONY2FUJI_DENOISE_LIBRARIES)
        list(APPEND no_backend_libs ${SONY2FUJI_DENOISE_LIBRARIES})
    endif()
    if(MSVC)
        set(no_backend_opts /W4 /utf-8 /UNDEBUG /USONY2FUJI_ENABLE_METAL /USONY2FUJI_ENABLE_GLES /USONY2FUJI_ENABLE_D3D11)
        set(no_backend_defs NOMINMAX)
    else()
        set(no_backend_opts -Wall -Wextra -UNDEBUG -USONY2FUJI_ENABLE_METAL -USONY2FUJI_ENABLE_GLES -USONY2FUJI_ENABLE_D3D11)
        set(no_backend_defs)
    endif()
    rawlab_add_test(
        NAME lut_gpu_no_backend
        SOURCES tests/lut_gpu_no_backend_tests.cpp
            src/gpu/lut_gpu.cpp src/core/lut_applicator.cpp src/core/lut_parser.cpp
        LIBRARIES ${no_backend_libs}
        DEFINES ${no_backend_defs}
        COMPILE_OPTIONS ${no_backend_opts}
        LABELS gpu lut ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    if(SONY2FUJI_ENABLE_GPU AND (APPLE OR WIN32))
        rawlab_add_test(
            NAME gpu_photo
            SOURCES tests/gpu_photo_tests.cpp
            LIBRARIES sony2fuji_core
            ENVIRONMENT "SONY2FUJI_TEST_GPU=1"
            SKIP_RETURN_CODE 77
            LABELS gpu hw_gpu
        )
        add_executable(acceleration_tests tests/acceleration_tests.cpp)
        target_link_libraries(acceleration_tests sony2fuji_core)
        if(WIN32)
            rawlab_add_test(
                NAME acceleration_sony_windows
                COMMAND acceleration_tests
                    "${SONY2FUJI_TEST_RAW}"
                    "${CMAKE_CURRENT_SOURCE_DIR}/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube"
                SKIP_RETURN_CODE 77
                LABELS gpu d3d11 hw_gpu
            )
            rawlab_add_test(
                NAME acceleration_sony_bundled_2383
                COMMAND acceleration_tests
                    "${SONY2FUJI_TEST_RAW}"
                    "${CMAKE_CURRENT_SOURCE_DIR}/../Shared/BundledLooks/RawLab_look_2383_sRGB_v1.cube"
                SKIP_RETURN_CODE 77
                LABELS gpu d3d11 hw_gpu
            )
        endif()
        foreach(fixture "${CMAKE_CURRENT_SOURCE_DIR}/examples/DSC06251.ARW" "${CMAKE_CURRENT_SOURCE_DIR}/examples/DJI_20250602164503_0444_D.DNG")
            get_filename_component(fixture_name "${fixture}" NAME_WE)
            if(APPLE)
                set(accel_labels gpu metal ci_macos_arm64 ci_macos_x86_64)
            else()
                set(accel_labels gpu d3d11 hw_gpu)
            endif()
            rawlab_add_test(
                NAME acceleration_${fixture_name}
                COMMAND acceleration_tests --default-raw "${fixture}"
                    "${CMAKE_CURRENT_SOURCE_DIR}/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube"
                SKIP_RETURN_CODE 77
                LABELS ${accel_labels}
            )
        endforeach()
    endif()
    add_executable(raw_reuse_tests tests/raw_reuse_tests.cpp)
    add_executable(raw_cache_preview_tests tests/raw_cache_preview_tests.cpp)
    add_executable(raw_active_area_tests tests/raw_active_area_tests.cpp)
    target_link_libraries(raw_active_area_tests sony2fuji_core)
    set(SONY2FUJI_TEST_SONY_ASPECT_RAW "" CACHE FILEPATH "Optional Sony ILCE-7CM2 4:3 RAW regression photo (never bundled)")
    if(SONY2FUJI_LIBRAW_RAWLAB_PATCHES)
        rawlab_add_test(
            NAME raw_active_area_metadata
            COMMAND raw_active_area_tests
            LABELS raw ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME raw_active_area_sony
            COMMAND raw_active_area_tests "${SONY2FUJI_TEST_SONY_ASPECT_RAW}"
            SKIP_RETURN_CODE 77
            LABELS raw ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        if(APPLE AND BUILD_CLI AND Python3_Interpreter_FOUND)
            rawlab_add_test(
                NAME raw_active_area_sony_cli
                COMMAND ${Python3_EXECUTABLE}
                    "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_hdr_agent.py"
                    --cli $<TARGET_FILE:sony2fuji_cli> --fixture $<TARGET_FILE:hdr_image_tests>
                    --sony-raw "${SONY2FUJI_TEST_SONY_ASPECT_RAW}" HDRAgent.test_v14_sony_raw_retains_crop
                SKIP_RETURN_CODE 77
                LABELS raw cli ci_macos_arm64 ci_macos_x86_64
            )
        endif()
    endif()
    rawlab_add_test(
        NAME tone_curve
        SOURCES tests/tone_curve_tests.cpp src/core/photo_tone_curve.cpp
        INCLUDES third_party
        DEFINES SONY2FUJI_CURVE_REFERENCE="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/tone-curve-v1-reference.json"
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME tone_curve_api
        SOURCES tests/tone_curve_api_tests.cpp
        LIBRARIES sony2fuji_core
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME tone_curve_raw
        COMMAND tone_curve_api_tests "${SONY2FUJI_TEST_RAW}"
        SKIP_RETURN_CODE 77
        LABELS core external_raw ci_macos_arm64 ci_macos_x86_64
    )
    rawlab_add_test(
        NAME tone_curve_recipe
        SOURCES tests/tone_curve_recipe_tests.cpp
        INCLUDES third_party
        LIBRARIES sony2fuji_core
        LABELS recipe ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    set(tone_libs)
    if(SONY2FUJI_DENOISE_LIBRARIES)
        list(APPEND tone_libs ${SONY2FUJI_DENOISE_LIBRARIES})
    endif()
    rawlab_add_test(
        NAME basic_controls_v3
        SOURCES tests/basic_controls_v3_tests.cpp
            src/core/photo_basic_controls_v3.cpp src/core/photo_atmosphere.cpp
        LIBRARIES ${tone_libs}
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME processing_migration
        SOURCES tests/processing_migration_tests.cpp src/core/processing_migration.cpp
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME processing_migration_api
        SOURCES tests/processing_migration_api_tests.cpp
        LIBRARIES sony2fuji_core
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME atmosphere
        SOURCES tests/atmosphere_tests.cpp src/core/photo_atmosphere.cpp
        INCLUDES third_party
        DEFINES SONY2FUJI_ATMOSPHERE_REFERENCE="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/atmosphere-v1-reference.json"
        LIBRARIES ${tone_libs}
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME atmosphere_api
        SOURCES tests/atmosphere_api_tests.cpp
        LIBRARIES sony2fuji_core
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    add_executable(atmosphere_quality_probe tests/atmosphere_quality_probe.cpp)
    target_link_libraries(atmosphere_quality_probe sony2fuji_core)
    rawlab_add_test(
        NAME atmosphere_raw
        COMMAND atmosphere_api_tests "${SONY2FUJI_TEST_RAW}"
        SKIP_RETURN_CODE 77
        LABELS core external_raw ci_macos_arm64 ci_macos_x86_64
    )
    rawlab_add_test(
        NAME tone_controls
        SOURCES tests/tone_controls_tests.cpp src/core/photo_tone_controls.cpp
        INCLUDES third_party
        DEFINES SONY2FUJI_TONE_REFERENCE="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/tone-controls-v1-reference.json"
        LIBRARIES ${tone_libs}
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME tone_controls_api
        SOURCES tests/tone_controls_api_tests.cpp
        LIBRARIES sony2fuji_core
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME tone_controls_raw
        COMMAND tone_controls_api_tests "${SONY2FUJI_TEST_RAW}"
        SKIP_RETURN_CODE 77
        LABELS core external_raw ci_macos_arm64 ci_macos_x86_64
    )
    rawlab_add_test(
        NAME tone_recipe
        SOURCES tests/tone_recipe_tests.cpp
        INCLUDES third_party
        LIBRARIES sony2fuji_core
        LABELS recipe ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME color_grading
        SOURCES tests/color_grading_tests.cpp src/core/photo_color_grading.cpp
        INCLUDES third_party
        DEFINES SONY2FUJI_GRADING_REFERENCE="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/color-grading-v1-reference.json"
        LIBRARIES ${tone_libs}
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME color_grading_api
        SOURCES tests/color_grading_api_tests.cpp
        LIBRARIES sony2fuji_core
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME color_grading_raw
        COMMAND color_grading_api_tests "${SONY2FUJI_TEST_RAW}"
        SKIP_RETURN_CODE 77
        LABELS core external_raw ci_macos_arm64 ci_macos_x86_64
    )
    rawlab_add_test(
        NAME color_grading_recipe
        SOURCES tests/color_grading_recipe_tests.cpp
        INCLUDES third_party
        LIBRARIES sony2fuji_core
        LABELS recipe ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME hsl_probe
        SOURCES tests/hsl_probe_tests.cpp
        LIBRARIES sony2fuji_core
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME hsl_probe_raw
        COMMAND hsl_probe_tests "${SONY2FUJI_TEST_RAW}"
        SKIP_RETURN_CODE 77
        LABELS core external_raw ci_macos_arm64 ci_macos_x86_64
    )
    rawlab_add_test(
        NAME photo_color
        SOURCES tests/photo_color_tests.cpp
        LIBRARIES sony2fuji_core
        COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME photo_color_raw
        COMMAND photo_color_tests "${SONY2FUJI_TEST_RAW}"
        SKIP_RETURN_CODE 77
        LABELS core external_raw ci_macos_arm64 ci_macos_x86_64
    )
    rawlab_add_test(
        NAME photo_effects
        SOURCES tests/photo_effects_tests.cpp
        LIBRARIES sony2fuji_core
        COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME gpu_diagnostics
        SOURCES tests/gpu_diagnostics_tests.cpp
        LIBRARIES sony2fuji_core
        COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME photo_spatial_gpu
        TARGET photo_spatial_gpu_tests
        SOURCES tests/photo_spatial_gpu_tests.cpp
        INCLUDES third_party
        LIBRARIES sony2fuji_core
        COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
        LABELS core gpu ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME cpu_parallel_determinism
        SOURCES tests/cpu_parallel_determinism_tests.cpp
        INCLUDES src
        LIBRARIES sony2fuji_core
        COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME cpu_parallel_determinism_raw
        COMMAND cpu_parallel_determinism_tests "${SONY2FUJI_TEST_RAW}"
        SKIP_RETURN_CODE 77
        LABELS core external_raw ci_macos_arm64 ci_macos_x86_64
    )
    rawlab_add_test(
        NAME srgb_look
        SOURCES tests/srgb_look_tests.cpp
        DEFINES BUNDLED_LOOKS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../Shared/BundledLooks"
        LIBRARIES sony2fuji_core
        COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
        LABELS core lut hw_gpu ci_macos_arm64 ci_macos_x86_64
    )
    rawlab_add_test(
        NAME lens_api
        SOURCES tests/lens_api_tests.cpp
        DEFINES TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
            TEST_CONFIGURED_RAW_PATH="${SONY2FUJI_TEST_RAW}"
            TEST_DEFAULT_RAW_PATH="${CMAKE_CURRENT_SOURCE_DIR}/examples/DJI_20250602164503_0444_D.DNG"
        LIBRARIES sony2fuji_core
        COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
        SKIP_RETURN_CODE 77
        LABELS lens ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    if(SONY2FUJI_ENABLE_LENSFUN)
        rawlab_add_test(
            NAME display_lens
            SOURCES tests/display_lens_tests.cpp
            DEFINES TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
            LIBRARIES sony2fuji_core
            COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
            LABELS lens ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME lens_correction
            SOURCES tests/lens_correction_tests.cpp
            DEFINES TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
            LIBRARIES sony2fuji_core
            COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
            LABELS lens ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
    endif()
    if(SONY2FUJI_ENABLE_GPU AND (APPLE OR WIN32) AND SONY2FUJI_ENABLE_CHROMA_DENOISE AND SONY2FUJI_ENABLE_WAVELET_DENOISE)
        rawlab_add_test(
            NAME metal_denoise
            SOURCES tests/metal_denoise_tests.cpp
            LIBRARIES sony2fuji_core
            COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
            SKIP_RETURN_CODE 77
            LABELS gpu metal denoise hw_gpu
        )
    endif()
    add_executable(raw_noise_tests tests/raw_noise_tests.cpp)
    if(SONY2FUJI_ENABLE_WAVELET_DENOISE)
        set(wavelet_denoise_defs)
        if(NOT SONY2FUJI_ENABLE_GPU)
            list(APPEND wavelet_denoise_defs TEST_WAVELET_GPU_DISABLED)
        endif()
        rawlab_add_test(
            NAME wavelet_denoise
            SOURCES tests/wavelet_denoise_tests.cpp
            DEFINES ${wavelet_denoise_defs}
            LIBRARIES sony2fuji_core
            COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
            LABELS denoise ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME processing_version
            SOURCES tests/processing_version_tests.cpp
            INCLUDES third_party
            DEFINES TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
            LIBRARIES sony2fuji_core
            LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME processing_session
            SOURCES tests/processing_session_tests.cpp
            DEFINES TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
            LIBRARIES sony2fuji_core
            LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        add_executable(processing_export_probe EXCLUDE_FROM_ALL tests/processing_export_probe.cpp)
        target_link_libraries(processing_export_probe sony2fuji_core)
        if(SONY2FUJI_ENABLE_GPU AND (APPLE OR WIN32))
            rawlab_add_test(
                NAME wavelet_fallback
                SOURCES tests/wavelet_fallback_tests.cpp
                LIBRARIES sony2fuji_core
                COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
                ARGS "${SONY2FUJI_TEST_LENS_WAVELET_RAW}"
                SKIP_RETURN_CODE 77
                LABELS denoise external_raw ci_macos_arm64 ci_macos_x86_64
            )
        endif()
        rawlab_add_test(
            NAME wavelet_render
            SOURCES tests/wavelet_render_tests.cpp
            DEFINES TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}"
            LIBRARIES sony2fuji_core
            COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
            LABELS denoise ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME wavelet_cache
            SOURCES tests/wavelet_cache_tests.cpp
            DEFINES TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}"
            LIBRARIES sony2fuji_core
            COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
            LABELS denoise ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME wavelet_exposure_cache
            COMMAND wavelet_cache_tests "${SONY2FUJI_TEST_RAW}"
            SKIP_RETURN_CODE 77
            LABELS denoise external_raw ci_macos_arm64 ci_macos_x86_64
        )
        rawlab_add_test(
            NAME hsl_wavelet_cache
            SOURCES tests/hsl_wavelet_cache_tests.cpp
            DEFINES TEST_EXAMPLES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/examples"
            LIBRARIES sony2fuji_core
            LABELS denoise ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        add_executable(denoise_cache_benchmark EXCLUDE_FROM_ALL tests/denoise_cache_benchmark.cpp)
        target_link_libraries(denoise_cache_benchmark sony2fuji_core)
    endif()
    if(SONY2FUJI_ENABLE_CHROMA_DENOISE)
        rawlab_add_test(
            NAME chroma_denoise
            SOURCES tests/chroma_denoise_tests.cpp
            LIBRARIES sony2fuji_core
            COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
            LABELS denoise ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
    endif()
    target_link_libraries(raw_noise_tests sony2fuji_core)
    rawlab_add_test(
        NAME raw_demosaic
        SOURCES tests/raw_demosaic_tests.cpp
        DEFINES TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
        LIBRARIES sony2fuji_core
        LABELS raw ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    add_executable(raw_decode_benchmark EXCLUDE_FROM_ALL tests/raw_decode_benchmark.cpp)
    target_include_directories(raw_decode_benchmark PRIVATE third_party)
    target_link_libraries(raw_decode_benchmark sony2fuji_core)
    add_executable(vng_parallel_tests tests/vng_parallel_tests.cpp)
    target_include_directories(vng_parallel_tests PRIVATE ${LIBRAW_INCLUDE_DIRS})
    target_link_libraries(vng_parallel_tests PRIVATE ${LIBRAW_LIBRARY} ${DNGSDK_LIBRARY})
    rawlab_add_test(
        NAME vng_parallel_single
        COMMAND vng_parallel_tests
        ENVIRONMENT "OMP_NUM_THREADS=1"
        LABELS raw ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME vng_parallel_multi
        COMMAND vng_parallel_tests
        ENVIRONMENT "OMP_NUM_THREADS=4"
        LABELS raw ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME raw_thread_safety
        SOURCES tests/raw_thread_safety_tests.cpp
        LIBRARIES sony2fuji_core Threads::Threads
        LABELS raw ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    set(SONY2FUJI_TEST_NON_BAYER_RAW "" CACHE FILEPATH "Optional X-Trans RAW fixture for denoise capability checks")
    rawlab_add_test(
        NAME raw_demosaic_xtrans
        COMMAND raw_demosaic_tests "${SONY2FUJI_TEST_NON_BAYER_RAW}"
        SKIP_RETURN_CODE 77
        LABELS raw external_raw ci_macos_arm64 ci_macos_x86_64
    )
    rawlab_add_test(
        NAME raw_noise
        COMMAND raw_noise_tests "${SONY2FUJI_TEST_RAW}" "${SONY2FUJI_TEST_NON_BAYER_RAW}"
        SKIP_RETURN_CODE 77
        LABELS raw external_raw ci_macos_arm64 ci_macos_x86_64
    )
    add_executable(render_benchmark EXCLUDE_FROM_ALL tests/render_benchmark.cpp)
    target_link_libraries(render_benchmark sony2fuji_core)
    target_link_libraries(raw_reuse_tests sony2fuji_core)
    rawlab_add_test(
        NAME raw_reuse
        COMMAND raw_reuse_tests "${SONY2FUJI_TEST_RAW}"
        SKIP_RETURN_CODE 77
        LABELS raw external_raw ci_macos_arm64 ci_macos_x86_64
    )
    target_link_libraries(raw_cache_preview_tests sony2fuji_core)
    target_compile_definitions(raw_cache_preview_tests PRIVATE TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures")
    rawlab_add_test(
        NAME raw_cache_preview
        COMMAND raw_cache_preview_tests
        LABELS raw ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME raw_cache_preview_raw
        COMMAND raw_cache_preview_tests "${SONY2FUJI_TEST_RAW}"
        SKIP_RETURN_CODE 77
        LABELS raw external_raw ci_macos_arm64 ci_macos_x86_64
    )
    rawlab_add_test(
        NAME preview_exposure_cache
        SOURCES tests/preview_exposure_cache_tests.cpp
        DEFINES TEST_EXAMPLES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/examples"
        LIBRARIES sony2fuji_core
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    add_executable(raw_smoke tests/raw_smoke.cpp)
    target_link_libraries(raw_smoke sony2fuji_core)
    if(SONY2FUJI_ENABLE_DNGSDK)
        target_compile_definitions(raw_smoke PRIVATE SONY2FUJI_ENABLE_DNGSDK)
    endif()
    add_executable(dng_jxl_tests tests/dng_jxl_tests.cpp)
    target_compile_definitions(dng_jxl_tests PRIVATE TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures")
    target_link_libraries(dng_jxl_tests sony2fuji_core)
    if(SONY2FUJI_ENABLE_DNGSDK)
        target_compile_definitions(dng_jxl_tests PRIVATE SONY2FUJI_ENABLE_DNGSDK)
        rawlab_add_test(
            NAME dng_jxl
            COMMAND dng_jxl_tests
            LABELS raw ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
    endif()
    add_executable(highlight_regression tests/highlight_regression.cpp)
    add_executable(white_balance_tests tests/white_balance_tests.cpp)
    target_link_libraries(white_balance_tests sony2fuji_core)
    rawlab_add_test(
        NAME camera_white_balance
        COMMAND white_balance_tests
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME raw_white_balance
        COMMAND white_balance_tests "${SONY2FUJI_TEST_RAW}"
        SKIP_RETURN_CODE 77
        LABELS core external_raw ci_macos_arm64 ci_macos_x86_64
    )
    target_link_libraries(highlight_regression sony2fuji_core)
    rawlab_add_test(
        NAME sony_highlights
        COMMAND highlight_regression
            --default-raw "${CMAKE_CURRENT_SOURCE_DIR}/examples/DSC06251.ARW"
            "${CMAKE_CURRENT_SOURCE_DIR}/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube"
        SKIP_RETURN_CODE 77
        LABELS raw external_raw ci_macos_arm64 ci_macos_x86_64
    )
    rawlab_add_test(
        NAME raw_input
        COMMAND raw_smoke "${SONY2FUJI_TEST_RAW}"
        SKIP_RETURN_CODE 77
        LABELS raw external_raw ci_macos_arm64 ci_macos_x86_64
    )
    rawlab_add_test(
        NAME dng_white_balance
        COMMAND white_balance_tests --default-raw "${CMAKE_CURRENT_SOURCE_DIR}/examples/DJI_20250602164503_0444_D.DNG"
        SKIP_RETURN_CODE 77
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME dji_raw
        COMMAND raw_smoke --default-raw "${CMAKE_CURRENT_SOURCE_DIR}/examples/DJI_20250602164503_0444_D.DNG"
        SKIP_RETURN_CODE 77
        LABELS raw ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME session_boundary
        SOURCES tests/session_boundary_tests.cpp
        DEFINES TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
        LIBRARIES sony2fuji_core
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME viewport_roi
        SOURCES tests/viewport_roi_tests.cpp
        DEFINES TEST_EXAMPLES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/examples"
        LIBRARIES sony2fuji_core
        LABELS core ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME export_color_delivery
        SOURCES tests/export_color_delivery_tests.cpp
        INCLUDES src
        LIBRARIES sony2fuji_core
        COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
        LABELS core recipe ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME gui_store
        SOURCES tests/gui_store_tests.cpp
        INCLUDES src third_party
        LIBRARIES sony2fuji_core
        COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
        LABELS core cli ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    rawlab_add_test(
        NAME canonical_edit_state
        SOURCES tests/canonical_edit_state_tests.cpp
        INCLUDES src third_party
        LIBRARIES sony2fuji_core
        COMPILE_OPTIONS ${RAWLAB_UNDEBUG_FLAG}
        LABELS core hdr recipe ci_macos_arm64 ci_macos_x86_64 ci_windows
    )
    if(SONY2FUJI_ENABLE_LENSFUN)
        rawlab_add_test(
            NAME lens_database_cache
            SOURCES tests/lens_database_cache_tests.cpp
            DEFINES TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
            LIBRARIES sony2fuji_core
            LABELS lens ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
    endif()
endif()

include(cmake/ai-denoise.cmake)

if(TARGET rawlab_dualdn_core)
    target_sources(rawlab_dualdn_core PRIVATE src/core/atomic_output_transaction.cpp)
endif()

if(BUILD_TESTING)
    get_property(_rawlab_registered_test_targets GLOBAL PROPERTY RAWLAB_REGISTERED_TEST_TARGETS)
    if(_rawlab_registered_test_targets)
        list(REMOVE_DUPLICATES _rawlab_registered_test_targets)
        add_custom_target(rawlab_test_binaries DEPENDS ${_rawlab_registered_test_targets})
    else()
        add_custom_target(rawlab_test_binaries)
    endif()
endif()

# 安装规则
install(TARGETS sony2fuji_core
    ARCHIVE DESTINATION lib
)
install(FILES third_party/nlohmann/LICENSE.MIT DESTINATION share/licenses/sony2fuji)

if(BUILD_SHARED_LIB)
    install(TARGETS sony2fuji
        LIBRARY DESTINATION lib
        FRAMEWORK DESTINATION Library/Frameworks
    )
endif()

if(BUILD_CLI)
    install(TARGETS sony2fuji_cli
        RUNTIME DESTINATION bin
    )
endif()

install(DIRECTORY include/sony2fuji
    DESTINATION include
)
