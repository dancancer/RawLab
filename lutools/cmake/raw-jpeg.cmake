include(FetchContent)
FetchContent_Declare(rawlab_jpeg_source
    URL https://github.com/libjpeg-turbo/libjpeg-turbo/archive/refs/tags/3.1.3.tar.gz
    URL_HASH SHA256=3a13a5ba767dc8264bc40b185e41368a80d5d5f945944d1dbaa4b2fb0099f4e5
    SOURCE_SUBDIR rawlab-no-upstream-build)
FetchContent_MakeAvailable(rawlab_jpeg_source)

# 上游不允许 add_subdirectory；独立构建目标平台 JPEG8，避免误链接宿主机库。
set(jpeg_build "${CMAKE_BINARY_DIR}/raw-jpeg/build")
set(jpeg_prefix "${CMAKE_BINARY_DIR}/raw-jpeg/install")
set(jpeg_args -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=${jpeg_prefix}
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    -DWITH_JPEG8=ON -DENABLE_STATIC=ON -DENABLE_SHARED=OFF
    -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF -DWITH_SIMD=OFF)
foreach(variable CMAKE_TOOLCHAIN_FILE CMAKE_SYSTEM_NAME CMAKE_SYSTEM_VERSION
        CMAKE_SYSTEM_PROCESSOR CMAKE_MAKE_PROGRAM
        CMAKE_OSX_ARCHITECTURES CMAKE_OSX_SYSROOT CMAKE_OSX_DEPLOYMENT_TARGET
        CMAKE_ANDROID_ARCH_ABI ANDROID_ABI ANDROID_PLATFORM ANDROID_NDK ANDROID_STL)
    if(DEFINED ${variable} AND NOT "${${variable}}" STREQUAL "")
        list(APPEND jpeg_args "-D${variable}=${${variable}}")
    endif()
endforeach()
if(NOT CMAKE_SYSTEM_PROCESSOR AND MSVC)
    list(APPEND jpeg_args "-DCMAKE_SYSTEM_PROCESSOR=${CMAKE_VS_PLATFORM_NAME}")
elseif(NOT CMAKE_SYSTEM_PROCESSOR AND APPLE)
    list(APPEND jpeg_args "-DCMAKE_SYSTEM_PROCESSOR=${CMAKE_OSX_ARCHITECTURES}")
endif()
set(jpeg_generator -G "${CMAKE_GENERATOR}")
if(CMAKE_GENERATOR_PLATFORM)
    list(APPEND jpeg_generator -A "${CMAKE_GENERATOR_PLATFORM}")
endif()
if(MSVC)
    list(APPEND jpeg_args -DWITH_CRT_DLL=ON)
    set(jpeg_library "${jpeg_prefix}/lib/jpeg-static.lib")
else()
    set(jpeg_library "${jpeg_prefix}/lib/libjpeg.a")
endif()
execute_process(COMMAND "${CMAKE_COMMAND}" -S "${rawlab_jpeg_source_SOURCE_DIR}"
    -B "${jpeg_build}" ${jpeg_generator} ${jpeg_args}
    RESULT_VARIABLE jpeg_result OUTPUT_VARIABLE jpeg_output ERROR_VARIABLE jpeg_error)
if(NOT jpeg_result EQUAL 0)
    message(FATAL_ERROR "Target JPEG configure failed: ${jpeg_output}\n${jpeg_error}")
endif()
execute_process(COMMAND "${CMAKE_COMMAND}" --build "${jpeg_build}" --config Release
    --target install --parallel 2
    RESULT_VARIABLE jpeg_result OUTPUT_VARIABLE jpeg_output ERROR_VARIABLE jpeg_error)
if(NOT jpeg_result EQUAL 0)
    message(FATAL_ERROR "Target JPEG build failed: ${jpeg_output}\n${jpeg_error}")
endif()
set(JPEG_INCLUDE_DIR "${jpeg_prefix}/include" CACHE PATH "Target JPEG8 headers" FORCE)
set(JPEG_LIBRARY "${jpeg_library}" CACHE FILEPATH "Target JPEG8 library" FORCE)
set(CMAKE_DISABLE_FIND_PACKAGE_JPEG OFF CACHE BOOL "" FORCE)
add_library(rawlab_jpeg STATIC IMPORTED GLOBAL)
set_target_properties(rawlab_jpeg PROPERTIES IMPORTED_LOCATION "${jpeg_library}"
    INTERFACE_INCLUDE_DIRECTORIES "${JPEG_INCLUDE_DIR}")
file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/licenses/libjpeg-turbo")
foreach(name LICENSE.md README.ijg)
    configure_file("${rawlab_jpeg_source_SOURCE_DIR}/${name}"
        "${CMAKE_BINARY_DIR}/licenses/libjpeg-turbo/${name}" COPYONLY)
endforeach()
