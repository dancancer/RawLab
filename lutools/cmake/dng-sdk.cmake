include_guard(GLOBAL)
include(FetchContent)

FetchContent_Declare(rawlab_dng_source
    URL https://download.adobe.com/pub/adobe/dng/dng_sdk_1_7_1_2724_20260908.zip
    URL_HASH SHA256=740fbe95c69e09e9cd17654a5e4fef2d7021254b06fd2b8c5557b79a1496b50c
    SOURCE_SUBDIR rawlab-no-upstream-build)
FetchContent_MakeAvailable(rawlab_dng_source)
set(RAWLAB_DNG_SOURCE_DIR "${rawlab_dng_source_SOURCE_DIR}")
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/dng-sdk" "${CMAKE_CURRENT_BINARY_DIR}/dng-sdk")

set(dng_notices "${CMAKE_BINARY_DIR}/licenses/dng-sdk")
file(MAKE_DIRECTORY "${dng_notices}")
foreach(entry
        "LICENSE.txt|Adobe-DNG-SDK-LICENSE.txt"
        "libjxl/libjxl/LICENSE|JPEG-XL-LICENSE.txt"
        "libjxl/libjxl/third_party/brotli/LICENSE|Brotli-LICENSE.txt"
        "libjxl/libjxl/third_party/highway/LICENSE|Highway-LICENSE.txt"
        "libjxl/libjxl/third_party/highway/LICENSE-BSD3|Highway-LICENSE-BSD3.txt"
        "libjxl/libjxl/third_party/skcms/LICENSE|skcms-LICENSE.txt")
    string(REPLACE "|" ";" fields "${entry}")
    list(GET fields 0 source)
    list(GET fields 1 destination)
    configure_file("${RAWLAB_DNG_SOURCE_DIR}/${source}" "${dng_notices}/${destination}" COPYONLY)
endforeach()
install(DIRECTORY "${dng_notices}/" DESTINATION share/licenses/rawlab-dng-sdk)
