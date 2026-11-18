include_guard(GLOBAL)

set(_RAWLAB_LIBRAW_DIR "${CMAKE_CURRENT_LIST_DIR}")
get_filename_component(_RAWLAB_LUTOOLS_CMAKE_DIR "${_RAWLAB_LIBRAW_DIR}/.." ABSOLUTE)
if(NOT DEFINED RAWLAB_LIBRAW_MANIFEST_PATH)
    set(RAWLAB_LIBRAW_MANIFEST_PATH "${_RAWLAB_LIBRAW_DIR}/manifest.json")
endif()
set(RAWLAB_LIBRAW_DNGSDK_COMPILE_DEFINITIONS USE_DNGSDK qDNGSupportJXL=1)

function(rawlab_load_libraw_manifest)
    file(READ "${RAWLAB_LIBRAW_MANIFEST_PATH}" manifest_json)
    string(JSON schema_version GET "${manifest_json}" "schema_version")
    if(NOT schema_version EQUAL 1)
        message(FATAL_ERROR "Unsupported LibRaw manifest schema_version: ${schema_version}")
    endif()
    string(JSON version GET "${manifest_json}" "libraw" "version")
    string(JSON tag GET "${manifest_json}" "libraw" "tag")
    string(JSON archive GET "${manifest_json}" "libraw" "archive")
    string(JSON directory GET "${manifest_json}" "libraw" "directory")
    string(JSON url GET "${manifest_json}" "libraw" "url")
    string(JSON sha256 GET "${manifest_json}" "libraw" "sha256")
    string(JSON license_count LENGTH "${manifest_json}" "libraw" "license_files")
    set(license_files)
    if(license_count GREATER 0)
        math(EXPR last_license "${license_count} - 1")
        foreach(idx RANGE ${last_license})
            string(JSON item GET "${manifest_json}" "libraw" "license_files" ${idx})
            list(APPEND license_files "${item}")
        endforeach()
    endif()
    string(JSON cmake_rev GET "${manifest_json}" "libraw_cmake" "revision")
    string(JSON cmake_archive GET "${manifest_json}" "libraw_cmake" "archive")
    string(JSON cmake_dir GET "${manifest_json}" "libraw_cmake" "directory")
    string(JSON cmake_url GET "${manifest_json}" "libraw_cmake" "url")
    string(JSON cmake_sha256 GET "${manifest_json}" "libraw_cmake" "sha256")

    set(RAWLAB_LIBRAW_VERSION "${version}" PARENT_SCOPE)
    set(RAWLAB_LIBRAW_TAG "${tag}" PARENT_SCOPE)
    set(RAWLAB_LIBRAW_ARCHIVE "${archive}" PARENT_SCOPE)
    set(RAWLAB_LIBRAW_DIRECTORY "${directory}" PARENT_SCOPE)
    set(RAWLAB_LIBRAW_URL "${url}" PARENT_SCOPE)
    set(RAWLAB_LIBRAW_SHA256 "${sha256}" PARENT_SCOPE)
    set(RAWLAB_LIBRAW_LICENSE_FILES "${license_files}" PARENT_SCOPE)
    set(RAWLAB_LIBRAW_CMAKE_REVISION "${cmake_rev}" PARENT_SCOPE)
    set(RAWLAB_LIBRAW_CMAKE_ARCHIVE "${cmake_archive}" PARENT_SCOPE)
    set(RAWLAB_LIBRAW_CMAKE_DIRECTORY "${cmake_dir}" PARENT_SCOPE)
    set(RAWLAB_LIBRAW_CMAKE_URL "${cmake_url}" PARENT_SCOPE)
    set(RAWLAB_LIBRAW_CMAKE_SHA256 "${cmake_sha256}" PARENT_SCOPE)
endfunction()

function(rawlab_add_libraw_shared)
    include(FetchContent)
    rawlab_load_libraw_manifest()

    # libraw.org resets the TLS handshake from CMake 3.22's bundled client on some hosts.
    # Use a pre-fetched local copy when present; URL_HASH verifies either source.
    # CMake 3.22 rejects a local path inside a URL list, so this picks exactly one.
    set(fetch_url "${RAWLAB_LIBRAW_URL}")
    if(ANDROID AND DEFINED ENV{RAWLAB_ANDROID_SOURCE_CACHE}
            AND EXISTS "$ENV{RAWLAB_ANDROID_SOURCE_CACHE}/${RAWLAB_LIBRAW_ARCHIVE}")
        set(fetch_url "$ENV{RAWLAB_ANDROID_SOURCE_CACHE}/${RAWLAB_LIBRAW_ARCHIVE}")
    endif()

    set(fetch_args
        URL "${fetch_url}"
        URL_HASH "SHA256=${RAWLAB_LIBRAW_SHA256}"
    )
    if(ANDROID)
        # CMake 3.22 preserves archive timestamps; isolate ABI versions from old objects.
        list(APPEND fetch_args SOURCE_DIR "${CMAKE_CURRENT_BINARY_DIR}/_deps/libraw-${RAWLAB_LIBRAW_VERSION}-src")
    else()
        list(APPEND fetch_args DOWNLOAD_EXTRACT_TIMESTAMP FALSE)
    endif()

    FetchContent_Declare(libraw ${fetch_args})
    FetchContent_MakeAvailable(libraw)

    set(LIBRAW_SOURCE_DIR "${libraw_SOURCE_DIR}")
    include("${_RAWLAB_LUTOOLS_CMAKE_DIR}/patch-libraw.cmake")

    # Exclude upstream placeholder implementations, as in its Makefile.am.
    file(GLOB_RECURSE libraw_sources CONFIGURE_DEPENDS "${LIBRAW_SOURCE_DIR}/src/*.cpp")
    list(FILTER libraw_sources EXCLUDE REGEX "_ph\\.cpp$")
    add_library(raw SHARED ${libraw_sources})
    target_include_directories(raw PUBLIC "${LIBRAW_SOURCE_DIR}")
    target_compile_definitions(raw PRIVATE
        USE_ZLIB USE_JPEG USE_JPEG8 USE_X3FTOOLS ${RAWLAB_LIBRAW_DNGSDK_COMPILE_DEFINITIONS})

    include("${_RAWLAB_LUTOOLS_CMAKE_DIR}/raw-jpeg.cmake")
    target_link_libraries(raw PRIVATE rawlab_jpeg)
    include("${_RAWLAB_LUTOOLS_CMAKE_DIR}/dng-sdk.cmake")
    target_link_libraries(raw PRIVATE rawlab_dng_sdk)

    set(LIBRAW_SOURCE_DIR "${LIBRAW_SOURCE_DIR}" PARENT_SCOPE)
    set(RAWLAB_LIBRAW_VERSION "${RAWLAB_LIBRAW_VERSION}" PARENT_SCOPE)
    set(RAWLAB_LIBRAW_TAG "${RAWLAB_LIBRAW_TAG}" PARENT_SCOPE)
    set(RAWLAB_LIBRAW_LICENSE_FILES "${RAWLAB_LIBRAW_LICENSE_FILES}" PARENT_SCOPE)
    set(SONY2FUJI_LIBRAW_TARGET raw PARENT_SCOPE)
    set(SONY2FUJI_DNGSDK_TARGET rawlab_dng_sdk PARENT_SCOPE)
endfunction()
