include(FetchContent)
if(POLICY CMP0135)
    cmake_policy(SET CMP0135 NEW)
endif()

# The DNG writer needs TIFF directory/strip handling only. Keep this dependency
# static and turn off every optional codec/tool target so mobile builds do not
# pull in unrelated image formats.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(tiff-static ON CACHE BOOL "" FORCE)
set(tiff-tools OFF CACHE BOOL "" FORCE)
set(tiff-tests OFF CACHE BOOL "" FORCE)
set(tiff-contrib OFF CACHE BOOL "" FORCE)
set(tiff-docs OFF CACHE BOOL "" FORCE)
set(tiff-cxx OFF CACHE BOOL "" FORCE)
set(tiff-install OFF CACHE BOOL "" FORCE)
set(ccitt OFF CACHE BOOL "" FORCE)
set(packbits OFF CACHE BOOL "" FORCE)
set(lzw OFF CACHE BOOL "" FORCE)
set(thunder OFF CACHE BOOL "" FORCE)
set(next OFF CACHE BOOL "" FORCE)
set(logluv OFF CACHE BOOL "" FORCE)
set(mdi OFF CACHE BOOL "" FORCE)
set(zlib OFF CACHE BOOL "" FORCE)
set(libdeflate OFF CACHE BOOL "" FORCE)
set(jpeg OFF CACHE BOOL "" FORCE)
set(old-jpeg OFF CACHE BOOL "" FORCE)
set(lzma OFF CACHE BOOL "" FORCE)
set(zstd OFF CACHE BOOL "" FORCE)
set(webp OFF CACHE BOOL "" FORCE)

FetchContent_Declare(rawlab_libtiff
    URL https://download.osgeo.org/libtiff/tiff-4.7.1.tar.gz
    URL_HASH SHA256=f698d94f3103da8ca7438d84e0344e453fe0ba3b7486e04c5bf7a9a3fabe9b69)
FetchContent_MakeAvailable(rawlab_libtiff)
if(TARGET tiff)
    set_target_properties(tiff PROPERTIES POSITION_INDEPENDENT_CODE ON)
endif()
if(EXISTS "${rawlab_libtiff_SOURCE_DIR}/LICENSE.md")
    file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/licenses/libtiff")
    configure_file("${rawlab_libtiff_SOURCE_DIR}/LICENSE.md"
        "${CMAKE_BINARY_DIR}/licenses/libtiff/LICENSE.md" COPYONLY)
endif()
set(SONY2FUJI_TIFF_TARGET TIFF::tiff)
