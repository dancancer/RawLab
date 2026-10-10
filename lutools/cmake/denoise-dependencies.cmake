include(FetchContent)

# Build only the image operations used by denoising, with target rather than host libraries.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_WITH_STATIC_CRT OFF CACHE BOOL "" FORCE)
set(BUILD_LIST core,imgproc CACHE STRING "" FORCE)
foreach(option BUILD_TESTS BUILD_PERF_TESTS BUILD_EXAMPLES BUILD_opencv_apps BUILD_JAVA
        BUILD_opencv_python2 BUILD_opencv_python3 WITH_IPP WITH_OPENCL WITH_LAPACK
        WITH_EIGEN WITH_FFMPEG WITH_GSTREAMER WITH_AVFOUNDATION WITH_JPEG WITH_PNG
        WITH_TIFF WITH_WEBP WITH_OPENEXR WITH_JASPER WITH_OPENJPEG WITH_AVIF WITH_GDAL
        WITH_PROTOBUF WITH_ITT WITH_VTK WITH_TBB OPENCV_ENABLE_NONFREE WITH_KLEIDICV
        BUILD_ANDROID_PROJECTS BUILD_ANDROID_EXAMPLES BUILD_ANDROID_SERVICE INSTALL_ANDROID_EXAMPLES
        BUILD_ZLIB WITH_ADE BUILD_opencv_gapi BUILD_opencv_dnn)
    set(${option} OFF CACHE BOOL "" FORCE)
endforeach()
FetchContent_Declare(rawlab_opencv
    URL https://github.com/opencv/opencv/archive/refs/tags/4.12.0.tar.gz
    URL_HASH SHA256=44c106d5bb47efec04e531fd93008b3fcd1d27138985c5baf4eafac0e1ec9e9d)
if(SONY2FUJI_ENABLE_CHROMA_DENOISE)
    FetchContent_Declare(rawlab_opencv_contrib
        URL https://github.com/opencv/opencv_contrib/archive/refs/tags/4.12.0.tar.gz
        URL_HASH SHA256=4197722b4c5ed42b476d42e29beb29a52b6b25c34ec7b4d589c3ae5145fee98e
        SOURCE_SUBDIR rawlab-no-upstream-build)
    FetchContent_MakeAvailable(rawlab_opencv_contrib)
    set(OPENCV_EXTRA_MODULES_PATH "${rawlab_opencv_contrib_SOURCE_DIR}/modules" CACHE PATH "" FORCE)
    set(BUILD_LIST core,imgproc,ximgproc CACHE STRING "" FORCE)
endif()
FetchContent_MakeAvailable(rawlab_opencv)
include_directories(SYSTEM "${rawlab_opencv_SOURCE_DIR}/modules/core/include"
    "${rawlab_opencv_SOURCE_DIR}/modules/imgproc/include" "${OPENCV_CONFIG_FILE_INCLUDE_DIR}")
if(SONY2FUJI_ENABLE_CHROMA_DENOISE)
    include_directories(SYSTEM "${rawlab_opencv_contrib_SOURCE_DIR}/modules/ximgproc/include")
endif()

FetchContent_Declare(rawlab_wavelib
    URL https://github.com/rafat/wavelib/archive/7f61bf592f3c470b2a7d8199431fde821d7253ac.tar.gz
    URL_HASH SHA256=62247c314bc98d395b0558882b37254b653753f0e1635cd5bd9807b27c79f96e
    SOURCE_SUBDIR rawlab-no-upstream-build)
FetchContent_MakeAvailable(rawlab_wavelib)
set(WAVELIB_SOURCE_DIR "${rawlab_wavelib_SOURCE_DIR}")
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/wavelib" "${CMAKE_CURRENT_BINARY_DIR}/wavelib")
set(SONY2FUJI_DENOISE_LIBRARIES opencv_core opencv_imgproc wavelib)
if(SONY2FUJI_ENABLE_CHROMA_DENOISE)
    list(APPEND SONY2FUJI_DENOISE_LIBRARIES opencv_ximgproc)
endif()
file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/licenses")
configure_file("${rawlab_opencv_SOURCE_DIR}/LICENSE" "${CMAKE_BINARY_DIR}/licenses/OpenCV-LICENSE" COPYONLY)
configure_file("${rawlab_wavelib_SOURCE_DIR}/COPYRIGHT" "${CMAKE_BINARY_DIR}/licenses/wavelib-COPYRIGHT" COPYONLY)
