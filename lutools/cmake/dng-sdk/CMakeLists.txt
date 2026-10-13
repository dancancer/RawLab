cmake_minimum_required(VERSION 3.16)

option(RAWLAB_DNGSDK_SHARED "Build the DNG SDK as a shared desktop dependency" OFF)
set(BUILD_SHARED_LIBS OFF)
set(BUILD_TESTING OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_POLICY_DEFAULT_CMP0077 NEW)
foreach(option JPEGXL_ENABLE_TOOLS JPEGXL_ENABLE_DEVTOOLS JPEGXL_ENABLE_FUZZERS
        JPEGXL_ENABLE_JPEGLI JPEGXL_ENABLE_DOXYGEN JPEGXL_ENABLE_MANPAGES
        JPEGXL_ENABLE_BENCHMARK JPEGXL_ENABLE_EXAMPLES JPEGXL_ENABLE_JNI
        JPEGXL_ENABLE_SJPEG JPEGXL_ENABLE_OPENEXR JPEGXL_ENABLE_VIEWERS
        JPEGXL_ENABLE_TCMALLOC JPEGXL_ENABLE_PLUGINS)
    set(${option} OFF CACHE BOOL "" FORCE)
endforeach()
set(JPEGXL_ENABLE_SKCMS ON CACHE BOOL "" FORCE)
set(JPEGXL_FORCE_SYSTEM_HWY OFF CACHE BOOL "" FORCE)
set(JPEGXL_FORCE_SYSTEM_BROTLI OFF CACHE BOOL "" FORCE)
add_subdirectory("${RAWLAB_DNG_SOURCE_DIR}/libjxl/libjxl" "jpeg-xl" EXCLUDE_FROM_ALL)
if(CMAKE_GENERATOR STREQUAL "Xcode")
    # Xcode 需要真实编译单元，才能为只引用 OBJECT targets 的库生成并更新归档。
    target_sources(jxl PRIVATE "${RAWLAB_DNG_SOURCE_DIR}/libjxl/libjxl/lib/nothing.cc")
endif()

file(GLOB dng_sources CONFIGURE_DEPENDS "${RAWLAB_DNG_SOURCE_DIR}/dng_sdk/source/*.cpp")
list(FILTER dng_sources EXCLUDE REGEX "/(dng_validate|dng_xmp_sdk|dng_update_meta)\\.cpp$")
# 2724 的 JXL 元数据代码漏了 XMP 开关，补上保护，避免引入无关的 XMP 编辑工具链。
set(jxl_source "${RAWLAB_DNG_SOURCE_DIR}/dng_sdk/source/dng_jxl.cpp")
file(READ "${jxl_source}" jxl_contents)
string(REPLACE "if (includeXMP && metadata && metadata->GetXMP ())"
    "#if qDNGUseXMP\n\t\tif (includeXMP && metadata && metadata->GetXMP ())" jxl_contents "${jxl_contents}")
string(REPLACE "} // xmp" "} // xmp\n#endif" jxl_contents "${jxl_contents}")
string(REPLACE "void dng_jxl_decoder::ProcessXMPBox"
    "#if qDNGUseXMP\nvoid dng_jxl_decoder::ProcessXMPBox" jxl_contents "${jxl_contents}")
string(REPLACE "void dng_jxl_decoder::ProcessBox"
    "#else\nvoid dng_jxl_decoder::ProcessXMPBox(dng_host &, const std::vector<uint8> &) {}\n#endif\n\nvoid dng_jxl_decoder::ProcessBox"
    jxl_contents "${jxl_contents}")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/dng_jxl.cpp" "${jxl_contents}")
list(REMOVE_ITEM dng_sources "${jxl_source}")
list(APPEND dng_sources "${CMAKE_CURRENT_BINARY_DIR}/dng_jxl.cpp")
if(RAWLAB_DNGSDK_SHARED)
    add_library(rawlab_dng_sdk SHARED ${dng_sources})
else()
    add_library(rawlab_dng_sdk STATIC ${dng_sources})
endif()
target_compile_features(rawlab_dng_sdk PUBLIC cxx_std_17)
target_include_directories(rawlab_dng_sdk SYSTEM PUBLIC
    "$<BUILD_INTERFACE:${RAWLAB_DNG_SOURCE_DIR}/dng_sdk/source>"
    "$<BUILD_INTERFACE:${RAWLAB_DNG_SOURCE_DIR}/libjxl/libjxl/lib/include>"
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_BINARY_DIR}/jpeg-xl/lib/include>"
    "$<INSTALL_INTERFACE:include/rawlab-dng-sdk>")
set(dng_definitions qDNGUseXMP=0 qDNGXMPFiles=0 qDNGXMPDocOps=0
    qDNGValidate=0 qDNGValidateTarget=0 qDNGUseLibJPEG=0 qDNGSupportJXL=1 qDNGThreadSafe=1)
if(ANDROID)
    list(APPEND dng_definitions qAndroid=1)
elseif(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    list(APPEND dng_definitions qiPhone=1)
    if(CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
        list(APPEND dng_definitions qiPhoneSimulator=1)
    endif()
elseif(APPLE)
    list(APPEND dng_definitions qMacOS=1)
elseif(WIN32)
    list(APPEND dng_definitions qWinOS=1)
else()
    list(APPEND dng_definitions qLinux=1)
endif()
target_compile_definitions(rawlab_dng_sdk PUBLIC ${dng_definitions})
if(MSVC)
    target_compile_definitions(rawlab_dng_sdk PRIVATE _CRT_SECURE_NO_WARNINGS NOMINMAX)
else()
    target_compile_options(rawlab_dng_sdk PRIVATE -w)
endif()
if(NOT TARGET ZLIB::ZLIB)
    find_package(ZLIB REQUIRED)
endif()
target_link_libraries(rawlab_dng_sdk PRIVATE jxl jxl_threads ZLIB::ZLIB)
if(APPLE)
    target_link_libraries(rawlab_dng_sdk PRIVATE "-framework CoreFoundation")
    if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
        target_link_libraries(rawlab_dng_sdk PRIVATE "-framework CoreServices")
    endif()
endif()
if(RAWLAB_DNGSDK_SHARED)
    set_target_properties(rawlab_dng_sdk PROPERTIES VERSION 1.7.1 SOVERSION 1)
    install(TARGETS rawlab_dng_sdk EXPORT librawTargets LIBRARY DESTINATION lib RUNTIME DESTINATION bin)
    install(DIRECTORY "${RAWLAB_DNG_SOURCE_DIR}/dng_sdk/source/"
        DESTINATION include/rawlab-dng-sdk FILES_MATCHING PATTERN "*.h")
    install(DIRECTORY "${RAWLAB_DNG_SOURCE_DIR}/libjxl/libjxl/lib/include/jxl"
        DESTINATION include/rawlab-dng-sdk FILES_MATCHING PATTERN "*.h")
    install(DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/jpeg-xl/lib/include/jxl"
        DESTINATION include/rawlab-dng-sdk FILES_MATCHING PATTERN "*.h")
    string(JOIN " -D" dng_pc_definitions ${dng_definitions})
    configure_file("${CMAKE_CURRENT_SOURCE_DIR}/rawlab-dng-sdk.pc.in"
        "${CMAKE_CURRENT_BINARY_DIR}/rawlab-dng-sdk.pc" @ONLY)
    install(FILES "${CMAKE_CURRENT_BINARY_DIR}/rawlab-dng-sdk.pc" DESTINATION lib/pkgconfig)
endif()
