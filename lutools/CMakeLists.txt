cmake_minimum_required(VERSION 3.15)
project(Sony2FujiLUT VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# 选项
option(BUILD_CLI "Build command line tool" ON)
option(BUILD_SHARED_LIB "Build shared library for mobile integration" ON)
option(BUILD_EXAMPLES "Build examples" OFF)
include(CTest)

# 依赖库查找
find_package(PkgConfig)
if(NOT TARGET ZLIB::ZLIB)
    find_package(ZLIB REQUIRED)
endif()

# OpenMP (optional)
set(SONY2FUJI_ENABLE_OPENMP_DEFAULT ON)
if(IOS OR ANDROID)
    set(SONY2FUJI_ENABLE_OPENMP_DEFAULT OFF)
endif()
option(SONY2FUJI_ENABLE_OPENMP "Enable OpenMP for CPU parallelism" ${SONY2FUJI_ENABLE_OPENMP_DEFAULT})
if(SONY2FUJI_ENABLE_OPENMP)
    find_package(OpenMP)
endif()

# GPU acceleration (optional)
option(SONY2FUJI_ENABLE_GPU "Enable GPU acceleration" ON)
if(IOS)
    add_compile_definitions(SONY2FUJI_PLATFORM_IOS)
endif()
if(ANDROID)
    add_compile_definitions(SONY2FUJI_PLATFORM_ANDROID)
endif()

# LibRaw
if(SONY2FUJI_LIBRAW_TARGET AND TARGET ${SONY2FUJI_LIBRAW_TARGET})
    set(LIBRAW_LIBRARY ${SONY2FUJI_LIBRAW_TARGET})
else()
    pkg_check_modules(LIBRAW REQUIRED libraw>=0.22.2)
    # Keep the library in sync with headers when switching dependency prefixes.
    unset(LIBRAW_LIBRARY CACHE)
    find_library(LIBRAW_LIBRARY NAMES raw HINTS ${LIBRAW_LIBRARY_DIRS} NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH)
    if(NOT LIBRAW_LIBRARY)
        message(FATAL_ERROR "libraw not found in ${LIBRAW_LIBRARY_DIRS}")
    endif()
endif()

# 包含目录
include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${LIBRAW_INCLUDE_DIRS}
)

# 核心库源文件
set(CORE_SOURCES
    src/core/lut_parser.cpp
    src/core/lut_applicator.cpp
    src/core/dcp_look.cpp
    src/core/color_converter.cpp
    src/core/raw_processor.cpp
    src/core/white_balance.cpp
    src/core/preview_exposure.cpp
    src/ffi/sony2fuji_c.cpp
    src/gpu/lut_gpu.cpp
    src/gpu/image_stats.cpp
)

if(SONY2FUJI_ENABLE_GPU)
    if(WIN32)
        list(APPEND CORE_SOURCES src/gpu/d3d11_photo.cpp)
        add_compile_definitions(SONY2FUJI_ENABLE_D3D11)
    endif()
    if(APPLE)
        enable_language(OBJCXX)
        list(APPEND CORE_SOURCES src/gpu/metal_lut.mm src/gpu/metal_photo.mm src/gpu/metal_stats.mm)
        add_compile_definitions(SONY2FUJI_ENABLE_METAL)
        set_source_files_properties(src/gpu/metal_lut.mm src/gpu/metal_photo.mm src/gpu/metal_stats.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
    endif()
    if(ANDROID)
        list(APPEND CORE_SOURCES src/gpu/gles_lut.cpp src/gpu/gles_photo.cpp)
        add_compile_definitions(SONY2FUJI_ENABLE_GLES)
    endif()
endif()

# 创建核心库
add_library(sony2fuji_core STATIC ${CORE_SOURCES})
if(SONY2FUJI_ENABLE_GPU AND WIN32)
    target_link_libraries(sony2fuji_core d3d11 dxgi d3dcompiler)
endif()
target_link_libraries(sony2fuji_core ${LIBRAW_LIBRARY})
if(MSVC)
    target_compile_options(sony2fuji_core PRIVATE /W4 /O2 /utf-8)
    target_compile_definitions(sony2fuji_core PRIVATE NOMINMAX _CRT_SECURE_NO_WARNINGS)
else()
    target_compile_options(sony2fuji_core PRIVATE -Wall -Wextra -O3)
endif()
if(SONY2FUJI_ENABLE_OPENMP AND OpenMP_CXX_FOUND)
    target_link_libraries(sony2fuji_core OpenMP::OpenMP_CXX)
endif()
if(TARGET ZLIB::ZLIB)
    target_link_libraries(sony2fuji_core ZLIB::ZLIB)
endif()
if(SONY2FUJI_ENABLE_GPU AND APPLE)
    target_link_libraries(sony2fuji_core "-framework Metal" "-framework Foundation")
endif()
if(SONY2FUJI_ENABLE_GPU AND ANDROID)
    target_link_libraries(sony2fuji_core EGL GLESv3 log)
endif()

# 创建共享库 (用于移动端集成)
if(BUILD_SHARED_LIB)
    add_library(sony2fuji SHARED ${CORE_SOURCES})
    if(SONY2FUJI_ENABLE_GPU AND WIN32)
        target_link_libraries(sony2fuji d3d11 dxgi d3dcompiler)
    endif()
    target_link_libraries(sony2fuji ${LIBRAW_LIBRARY})
    if(MSVC)
        target_compile_options(sony2fuji PRIVATE /W4 /O2 /utf-8)
        target_compile_definitions(sony2fuji PRIVATE NOMINMAX _CRT_SECURE_NO_WARNINGS)
        set_target_properties(sony2fuji PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
    else()
        target_compile_options(sony2fuji PRIVATE -Wall -Wextra -O3)
    endif()
    if(SONY2FUJI_ENABLE_OPENMP AND OpenMP_CXX_FOUND)
        target_link_libraries(sony2fuji OpenMP::OpenMP_CXX)
    endif()
    if(TARGET ZLIB::ZLIB)
        target_link_libraries(sony2fuji ZLIB::ZLIB)
    endif()
    if(SONY2FUJI_ENABLE_GPU AND APPLE)
        target_link_libraries(sony2fuji "-framework Metal" "-framework Foundation")
    endif()
    if(SONY2FUJI_ENABLE_GPU AND ANDROID)
        target_link_libraries(sony2fuji EGL GLESv3 log)
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
    add_executable(sony2fuji_cli src/cli/main.cpp)
    target_link_libraries(sony2fuji_cli sony2fuji_core)
    set_target_properties(sony2fuji_cli PROPERTIES OUTPUT_NAME sony2fuji)
endif()

# 示例
if(BUILD_EXAMPLES)
    add_executable(sony2fuji_example examples/simple_example.cpp)
    target_link_libraries(sony2fuji_example sony2fuji_core)
endif()

if(BUILD_TESTING AND NOT IOS AND NOT ANDROID)
    set(SONY2FUJI_TEST_RAW "" CACHE FILEPATH "External RAW fixture (never bundled)")
    file(TO_CMAKE_PATH "${SONY2FUJI_TEST_RAW}" SONY2FUJI_TEST_RAW)
    find_package(Threads REQUIRED)
    add_executable(core_tests tests/core_tests.cpp)
    target_link_libraries(core_tests sony2fuji_core Threads::Threads)
    target_compile_definitions(core_tests PRIVATE TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}" TEST_RAW_PATH="${SONY2FUJI_TEST_RAW}")
    add_test(NAME color_contracts COMMAND core_tests)
    add_executable(dcp_look_tests tests/dcp_look_tests.cpp)
    target_link_libraries(dcp_look_tests sony2fuji_core)
    add_test(NAME native_dcp_look COMMAND dcp_look_tests)
    if(SONY2FUJI_ENABLE_GPU AND APPLE)
        add_test(NAME native_dcp_metal COMMAND dcp_look_tests --metal)
    endif()
    add_executable(image_stats_tests tests/image_stats_tests.cpp)
    target_link_libraries(image_stats_tests sony2fuji_core)
    add_test(NAME image_stats COMMAND image_stats_tests)
    if(SONY2FUJI_ENABLE_GPU AND (APPLE OR WIN32))
        add_executable(gpu_photo_tests tests/gpu_photo_tests.cpp)
        target_link_libraries(gpu_photo_tests sony2fuji_core)
        add_test(NAME gpu_photo COMMAND gpu_photo_tests)
        set_tests_properties(gpu_photo PROPERTIES ENVIRONMENT "SONY2FUJI_TEST_GPU=1")
        add_executable(acceleration_tests tests/acceleration_tests.cpp)
        target_link_libraries(acceleration_tests sony2fuji_core)
        if(WIN32 AND EXISTS "${SONY2FUJI_TEST_RAW}")
            add_test(NAME acceleration_sony_windows COMMAND acceleration_tests
                "${SONY2FUJI_TEST_RAW}"
                "${CMAKE_CURRENT_SOURCE_DIR}/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube")
        endif()
        foreach(fixture "${CMAKE_CURRENT_SOURCE_DIR}/examples/DSC06251.ARW" "${CMAKE_CURRENT_SOURCE_DIR}/examples/DJI_20250602164503_0444_D.DNG")
            if(EXISTS "${fixture}")
                get_filename_component(fixture_name "${fixture}" NAME_WE)
                add_test(NAME acceleration_${fixture_name} COMMAND acceleration_tests "${fixture}"
                    "${CMAKE_CURRENT_SOURCE_DIR}/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube")
            endif()
        endforeach()
    endif()
    add_executable(raw_reuse_tests tests/raw_reuse_tests.cpp)
    add_executable(render_benchmark EXCLUDE_FROM_ALL tests/render_benchmark.cpp)
    target_link_libraries(render_benchmark sony2fuji_core)
    target_link_libraries(raw_reuse_tests sony2fuji_core)
    if(EXISTS "${SONY2FUJI_TEST_RAW}")
        add_test(NAME raw_reuse COMMAND raw_reuse_tests "${SONY2FUJI_TEST_RAW}")
    endif()
    add_executable(raw_smoke tests/raw_smoke.cpp)
    target_link_libraries(raw_smoke sony2fuji_core)
    add_executable(highlight_regression tests/highlight_regression.cpp)
    add_executable(white_balance_tests tests/white_balance_tests.cpp)
    target_link_libraries(white_balance_tests sony2fuji_core)
    if(EXISTS "${SONY2FUJI_TEST_RAW}")
        add_test(NAME raw_white_balance COMMAND white_balance_tests "${SONY2FUJI_TEST_RAW}")
    endif()
    target_link_libraries(highlight_regression sony2fuji_core)
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/examples/DSC06251.ARW")
        add_test(NAME sony_highlights COMMAND highlight_regression
            "${CMAKE_CURRENT_SOURCE_DIR}/examples/DSC06251.ARW"
            "${CMAKE_CURRENT_SOURCE_DIR}/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube")
    else()
        message(STATUS "sony_highlights requires the local DSC06251.ARW fixture")
    endif()
    if(EXISTS "${SONY2FUJI_TEST_RAW}")
        add_test(NAME raw_input COMMAND raw_smoke "${SONY2FUJI_TEST_RAW}")
    endif()
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/examples/DJI_20250602164503_0444_D.DNG")
        add_test(NAME dng_white_balance COMMAND white_balance_tests "${CMAKE_CURRENT_SOURCE_DIR}/examples/DJI_20250602164503_0444_D.DNG")
        add_test(NAME dji_raw COMMAND raw_smoke "${CMAKE_CURRENT_SOURCE_DIR}/examples/DJI_20250602164503_0444_D.DNG")
    endif()
endif()

# 安装规则
install(TARGETS sony2fuji_core
    ARCHIVE DESTINATION lib
)

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
