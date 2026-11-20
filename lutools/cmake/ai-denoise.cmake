option(SONY2FUJI_ENABLE_AI_DENOISE "Build experimental native DualDn support" OFF)
option(SONY2FUJI_ENABLE_DIRECTML "Use DirectML for Windows DualDn networks" OFF)
if(BUILD_TESTING OR SONY2FUJI_ENABLE_AI_DENOISE)
    add_library(rawlab_dualdn_core STATIC src/ai/dualdn_geometry.cpp src/ai/noise_profile.cpp src/ai/raw_noise_estimate.cpp
        src/ai/model_package.cpp src/ai/model_sha256.cpp src/ai/dualdn_bridge.cpp src/ai/dualdn_cache.cpp src/ai/scene_rgb_adapter.cpp
        src/ai/directml_device_policy.cpp src/ai/ai_diagnostics.cpp)
    target_include_directories(rawlab_dualdn_core PUBLIC src include PRIVATE third_party)
    if(WIN32)
        target_link_libraries(rawlab_dualdn_core PUBLIC bcrypt)
    endif()
    if(SONY2FUJI_DENOISE_LIBRARIES)
        target_link_libraries(rawlab_dualdn_core PUBLIC ${SONY2FUJI_DENOISE_LIBRARIES})
    endif()
    if(BUILD_TESTING AND NOT IOS AND NOT ANDROID)
        rawlab_add_test(
            NAME ai_device_policy
            SOURCES tests/ai_device_policy_tests.cpp
            LIBRARIES rawlab_dualdn_core
            LABELS ai ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME ai_diagnostics
            SOURCES tests/ai_diagnostics_tests.cpp
            INCLUDES third_party
            LIBRARIES rawlab_dualdn_core
            LABELS ai ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME ai_device_abi
            SOURCES tests/ai_device_abi_tests.cpp
            INCLUDES third_party
            LIBRARIES sony2fuji_core
            LABELS ai ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME dualdn_gpu_policy
            SOURCES tests/dualdn_gpu_policy_tests.cpp src/ai/network_graph.cpp
            INCLUDES src include
            LABELS ai gpu ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME dualdn_geometry
            SOURCES tests/dualdn_geometry_tests.cpp
            LIBRARIES rawlab_dualdn_core
            LABELS ai geometry ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME raw_noise_estimate
            SOURCES tests/raw_noise_estimate_tests.cpp
            LIBRARIES rawlab_dualdn_core
            LABELS ai raw ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME dualdn_package
            SOURCES tests/dualdn_package_tests.cpp
            INCLUDES third_party
            DEFINES RESTORMER_TEST_LICENSE="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/restormer-v1-LICENSE.txt"
            LIBRARIES rawlab_dualdn_core
            ARGS "${CMAKE_CURRENT_BINARY_DIR}/dualdn-package-fixture"
            LABELS ai ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        foreach(path_case IN ITEMS chinese supplementary)
            rawlab_add_test(
                NAME dualdn_package_${path_case}
                COMMAND dualdn_package_tests "${CMAKE_CURRENT_BINARY_DIR}/dualdn-package-${path_case}-fixture" ${path_case}
                LABELS ai ci_macos_arm64 ci_macos_x86_64 ci_windows
            )
        endforeach()
        rawlab_add_test(
            NAME dualdn_raw_bridge
            SOURCES tests/dualdn_raw_bridge_tests.cpp
            LIBRARIES sony2fuji_core
            ARGS "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/bayer-demosaic.dng"
            LABELS ai raw ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME dualdn_color
            SOURCES tests/dualdn_color_tests.cpp
            LIBRARIES rawlab_dualdn_core sony2fuji_core
            LABELS ai core ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME scene_rgb_adapter
            SOURCES tests/scene_rgb_adapter_tests.cpp
            LIBRARIES rawlab_dualdn_core sony2fuji_core
            LABELS ai core ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME dualdn_cache
            SOURCES tests/dualdn_cache_tests.cpp
            LIBRARIES rawlab_dualdn_core
            ARGS "${CMAKE_CURRENT_BINARY_DIR}/dualdn-cache-fixture"
            LABELS ai ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        rawlab_add_test(
            NAME dualdn_cache_memory
            SOURCES tests/dualdn_cache_memory_tests.cpp
            INCLUDES third_party
            LIBRARIES rawlab_dualdn_core
            ARGS "${CMAKE_CURRENT_BINARY_DIR}/dualdn-cache-memory-fixture"
            LABELS ai ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        if(WIN32)
            target_link_libraries(dualdn_cache_memory_tests PRIVATE psapi)
        endif()
        rawlab_add_test(
            NAME dualdn_identity
            SOURCES tests/dualdn_identity_tests.cpp
            LIBRARIES rawlab_dualdn_core
            ARGS "${CMAKE_CURRENT_BINARY_DIR}/dualdn-identity-fixture"
            LABELS ai ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        add_executable(dualdn_api_tests tests/dualdn_api_tests.cpp)
        target_include_directories(dualdn_api_tests PRIVATE third_party)
        target_link_libraries(dualdn_api_tests PRIVATE sony2fuji_core rawlab_dualdn_core)
        if(NOT SONY2FUJI_ENABLE_AI_DENOISE)
            rawlab_add_test(
                NAME dualdn_api_disabled
                COMMAND dualdn_api_tests
                    "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/bayer-demosaic.dng" "unused-model" "${CMAKE_CURRENT_BINARY_DIR}/dualdn-api-cache"
                LABELS ai ci_macos_arm64 ci_macos_x86_64 ci_windows
            )
        endif()
    endif()
endif()
if(SONY2FUJI_ENABLE_AI_DENOISE)
    if(IOS OR ANDROID)
        message(FATAL_ERROR "DualDn is currently validated only for desktop builds")
    endif()
    set(ONNXRUNTIME_ROOT "" CACHE PATH "Unpacked ONNX Runtime C/C++ distribution")
    find_path(RAWLAB_ORT_INCLUDE onnxruntime_cxx_api.h HINTS "${ONNXRUNTIME_ROOT}/include" NO_DEFAULT_PATH)
    find_library(RAWLAB_ORT_LIBRARY NAMES onnxruntime HINTS "${ONNXRUNTIME_ROOT}/lib" NO_DEFAULT_PATH)
    if(NOT RAWLAB_ORT_INCLUDE OR NOT RAWLAB_ORT_LIBRARY)
        message(FATAL_ERROR "Set ONNXRUNTIME_ROOT to the matching ONNX Runtime C/C++ distribution")
    endif()
    add_library(rawlab_dualdn_runtime STATIC src/ai/onnx_graph.cpp src/ai/network_graph.cpp src/ai/directml_device.cpp src/ai/dualdn_runtime.cpp src/ai/ai_session.cpp)
    if(SONY2FUJI_ENABLE_DIRECTML)
        if(NOT WIN32 OR NOT EXISTS "${RAWLAB_ORT_INCLUDE}/dml_provider_factory.h")
            message(FATAL_ERROR "DirectML requires Windows and the matching ONNX Runtime DirectML package")
        endif()
        target_compile_definitions(rawlab_dualdn_runtime PRIVATE SONY2FUJI_ENABLE_DIRECTML)
        target_link_libraries(rawlab_dualdn_runtime PUBLIC d3d12 dxgi version gdi32 advapi32)
    endif()
    if(APPLE)
        enable_language(OBJCXX)
        set_property(TARGET rawlab_dualdn_runtime PROPERTY OBJCXX_STANDARD 17)
        target_sources(rawlab_dualdn_runtime PRIVATE src/ai/coreml_graph.mm)
        set_source_files_properties(src/ai/coreml_graph.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
        target_link_libraries(rawlab_dualdn_runtime PUBLIC "-framework CoreML" "-framework Foundation")
    else()
        target_sources(rawlab_dualdn_runtime PRIVATE src/ai/coreml_graph_stub.cpp)
    endif()
    target_include_directories(rawlab_dualdn_runtime PUBLIC src PRIVATE third_party)
    target_include_directories(rawlab_dualdn_runtime SYSTEM PRIVATE "${RAWLAB_ORT_INCLUDE}")
    target_link_libraries(rawlab_dualdn_runtime PUBLIC rawlab_dualdn_core "${RAWLAB_ORT_LIBRARY}")
    foreach(core_target sony2fuji_core_objects sony2fuji_core sony2fuji)
        if(TARGET ${core_target})
            target_compile_definitions(${core_target} PRIVATE SONY2FUJI_ENABLE_AI_DENOISE)
            if(core_target STREQUAL "sony2fuji_core_objects")
                target_link_libraries(${core_target} PRIVATE rawlab_dualdn_runtime)
            else()
                target_link_libraries(${core_target} rawlab_dualdn_runtime)
            endif()
        endif()
    endforeach()
    if(BUILD_TESTING)
        if(TARGET core_tests)
            target_include_directories(core_tests PRIVATE third_party)
            target_compile_definitions(core_tests PRIVATE SONY2FUJI_ENABLE_AI_DENOISE)
        endif()
        add_executable(dualdn_session_tests tests/dualdn_session_tests.cpp)
        target_include_directories(dualdn_session_tests PRIVATE third_party)
        target_link_libraries(dualdn_session_tests PRIVATE rawlab_dualdn_runtime sony2fuji_core)
        add_executable(dualdn_onnx_tests tests/dualdn_onnx_tests.cpp)
        target_include_directories(dualdn_onnx_tests PRIVATE third_party)
        target_link_libraries(dualdn_onnx_tests PRIVATE rawlab_dualdn_runtime)
        add_executable(dualdn_probe tests/dualdn_probe.cpp)
        target_include_directories(dualdn_probe PRIVATE third_party)
        target_link_libraries(dualdn_probe PRIVATE rawlab_dualdn_runtime sony2fuji_core)
        add_executable(dualdn_native_tests tests/dualdn_native_tests.cpp)
        target_link_libraries(dualdn_native_tests PRIVATE rawlab_dualdn_runtime)
        add_executable(dualdn_directml_tests tests/dualdn_directml_tests.cpp)
        target_link_libraries(dualdn_directml_tests PRIVATE rawlab_dualdn_runtime)
        rawlab_add_test(
            NAME ai_session_memory
            SOURCES tests/ai_session_memory_tests.cpp
            INCLUDES third_party
            DEFINES RESTORMER_TEST_LICENSE="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/restormer-v1-LICENSE.txt"
            LIBRARIES rawlab_dualdn_runtime sony2fuji_core
            ARGS "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/bayer-demosaic.dng" "${CMAKE_CURRENT_BINARY_DIR}/ai-session-memory-fixture"
            LABELS ai ci_macos_arm64 ci_macos_x86_64 ci_windows
        )
        if(APPLE)
            rawlab_add_test(
                NAME coreml_gpu_placement
                SOURCES tests/coreml_gpu_placement_tests.cpp
                LIBRARIES rawlab_dualdn_runtime
                ARGS "${CMAKE_CURRENT_BINARY_DIR}/coreml-gpu-placement-fixture"
                SKIP_RETURN_CODE 77
                LABELS ai gpu ci_macos_arm64 ci_macos_x86_64
            )
        endif()
        set(RAWLAB_DUALDN_TEST_MODEL "" CACHE PATH "Optional exported DualDn package with replay fixtures")
        set(RAWLAB_DUALDN_TEST_PACKAGE "" CACHE PATH "Optional production-geometry DualDn package")
        if(NOT RAWLAB_DUALDN_TEST_MODEL OR NOT RAWLAB_DUALDN_TEST_PACKAGE)
            find_package(Python3 REQUIRED COMPONENTS Interpreter)
        endif()
        if(RAWLAB_DUALDN_TEST_MODEL)
            rawlab_add_test(
                NAME dualdn_onnx
                COMMAND dualdn_onnx_tests "${RAWLAB_DUALDN_TEST_MODEL}"
                LABELS ai onnx ai_model
            )
        else()
            rawlab_add_test(
                NAME dualdn_onnx_skip
                COMMAND "${Python3_EXECUTABLE}" -c
                    "import sys; print('SKIP dualdn_onnx: supply RAWLAB_DUALDN_TEST_MODEL'); sys.exit(77)"
                SKIP_RETURN_CODE 77
                LABELS ai onnx ai_model ci_macos_arm64 ci_macos_x86_64
            )
        endif()
        if(RAWLAB_DUALDN_TEST_PACKAGE)
            target_compile_definitions(dualdn_api_tests PRIVATE RAWLAB_TEST_AI)
            rawlab_add_test(
                NAME dualdn_session
                COMMAND dualdn_session_tests "${RAWLAB_DUALDN_TEST_PACKAGE}" "${CMAKE_CURRENT_BINARY_DIR}/dualdn-session-cache"
                LABELS ai ci_macos_arm64 ci_macos_x86_64 ci_windows
            )
            rawlab_add_test(
                NAME dualdn_api
                COMMAND dualdn_api_tests
                    "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/bayer-demosaic.dng" "${RAWLAB_DUALDN_TEST_PACKAGE}" "${CMAKE_CURRENT_BINARY_DIR}/dualdn-api-cache"
                LABELS ai ci_macos_arm64 ci_macos_x86_64 ci_windows
            )
            rawlab_add_test(
                NAME dualdn_native
                COMMAND dualdn_native_tests "${RAWLAB_DUALDN_TEST_PACKAGE}"
                SKIP_RETURN_CODE 77
                LABELS ai ci_macos_arm64 ci_macos_x86_64 ci_windows
            )
            rawlab_add_test(
                NAME dualdn_directml
                COMMAND dualdn_directml_tests "${RAWLAB_DUALDN_TEST_PACKAGE}"
                LABELS ai directml ci_windows
            )
        else()
            rawlab_add_test(
                NAME dualdn_skip
                COMMAND "${Python3_EXECUTABLE}" -c
                    "import sys; print('SKIP dualdn: supply RAWLAB_DUALDN_TEST_PACKAGE'); sys.exit(77)"
                SKIP_RETURN_CODE 77
                LABELS ai ci_macos_arm64 ci_macos_x86_64 ci_windows
            )
        endif()
    endif()
    if(WIN32)
        set(RAWLAB_AI_RUNTIME_DLLS "${ONNXRUNTIME_ROOT}/lib/onnxruntime.dll")
        if(SONY2FUJI_ENABLE_DIRECTML)
            list(APPEND RAWLAB_AI_RUNTIME_DLLS "${ONNXRUNTIME_ROOT}/lib/onnxruntime_providers_shared.dll"
                "${ONNXRUNTIME_ROOT}/lib/DirectML.dll")
        endif()
        # Windows 的系统目录先于 PATH，必须在程序旁放置匹配头文件的运行库。
        foreach(ai_binary sony2fuji sony2fuji_cli core_tests ai_device_abi_tests dualdn_probe dualdn_api_tests dualdn_onnx_tests
                dualdn_native_tests dualdn_directml_tests dualdn_session_tests ai_session_memory_tests)
            if(TARGET ${ai_binary})
                add_custom_command(TARGET ${ai_binary} POST_BUILD
                    COMMAND ${CMAKE_COMMAND} -E copy_if_different ${RAWLAB_AI_RUNTIME_DLLS} "$<TARGET_FILE_DIR:${ai_binary}>"
                    VERBATIM)
            endif()
        endforeach()
    endif()
endif()
