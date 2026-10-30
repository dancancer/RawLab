set(SONY2FUJI_ENABLE_X3F_DEFAULT OFF)
if(APPLE AND NOT IOS)
    set(SONY2FUJI_ENABLE_X3F_DEFAULT ON)
endif()
option(SONY2FUJI_ENABLE_X3F "Build the pinned normal X3F renderer" ${SONY2FUJI_ENABLE_X3F_DEFAULT})
if(SONY2FUJI_ENABLE_X3F)
    find_program(RAWLAB_CARGO cargo HINTS "$ENV{HOME}/.cargo/bin" REQUIRED)
    find_package(Python3 3.11 COMPONENTS Interpreter REQUIRED)
    set(RAWLAB_X3F_RUST_TARGET "" CACHE STRING "Explicit Rust target for cross-compiled X3F rendering")
    if(NOT RAWLAB_X3F_RUST_TARGET)
        if(CMAKE_CROSSCOMPILING OR IOS OR ANDROID)
            message(FATAL_ERROR "Cross-compiling X3F requires RAWLAB_X3F_RUST_TARGET and the corresponding Rust target/linker")
        endif()
        if(APPLE)
            if(CMAKE_OSX_ARCHITECTURES STREQUAL "x86_64")
                set(RAWLAB_X3F_RUST_TARGET x86_64-apple-darwin)
            elseif(CMAKE_OSX_ARCHITECTURES STREQUAL "arm64" OR
                   (NOT CMAKE_OSX_ARCHITECTURES AND CMAKE_SYSTEM_PROCESSOR STREQUAL "arm64"))
                set(RAWLAB_X3F_RUST_TARGET aarch64-apple-darwin)
            else()
                message(FATAL_ERROR "Build X3F for one explicit Mac architecture at a time")
            endif()
        else()
            execute_process(COMMAND "${RAWLAB_CARGO}" -vV OUTPUT_VARIABLE cargo_version RESULT_VARIABLE cargo_result)
            if(NOT cargo_result EQUAL 0)
                message(FATAL_ERROR "Cannot determine the Rust host target")
            endif()
            string(REGEX MATCH "host: ([^\n\r]+)" ignored "${cargo_version}")
            set(RAWLAB_X3F_RUST_TARGET "${CMAKE_MATCH_1}")
        endif()
    endif()
    set(x3f_source "${CMAKE_CURRENT_SOURCE_DIR}/x3f-bridge")
    set(x3f_target "${CMAKE_CURRENT_BINARY_DIR}/x3f-rust")
    set(x3f_archive "${x3f_target}/${RAWLAB_X3F_RUST_TARGET}/release/librawlab_x3f.a")
    if(WIN32)
        set(x3f_archive "${x3f_target}/${RAWLAB_X3F_RUST_TARGET}/release/rawlab_x3f.lib")
    endif()
    file(GLOB_RECURSE x3f_sources CONFIGURE_DEPENDS "${x3f_source}/src/*.rs" "${x3f_source}/profiles/*.json"
        "${x3f_source}/licenses/*" "${x3f_source}/vendor/x3f-sys/src/*.rs"
        "${x3f_source}/vendor/x3f-sys/csrc/*")
    list(APPEND x3f_sources "${x3f_source}/vendor/x3f-sys/Cargo.toml"
        "${x3f_source}/vendor/x3f-sys/build.rs" "${x3f_source}/vendor/x3f-sys/wrapper.h"
        "${x3f_source}/vendor/x3f-sys/LICENSE")
    set(x3f_notices "${CMAKE_CURRENT_BINARY_DIR}/x3f-licenses.txt")
    set(x3f_environment "CARGO_TARGET_DIR=${x3f_target}")
    if(IOS)
        list(APPEND x3f_environment "IPHONEOS_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}")
        # bindgen must use the slice's SDK, including the Intel simulator.
        list(APPEND x3f_environment "BINDGEN_EXTRA_CLANG_ARGS=-isysroot ${CMAKE_OSX_SYSROOT}")
    elseif(APPLE AND CMAKE_OSX_DEPLOYMENT_TARGET)
        list(APPEND x3f_environment "MACOSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}")
    elseif(ANDROID)
        get_filename_component(ndk_bin "${CMAKE_C_COMPILER}" DIRECTORY)
        string(REGEX REPLACE "^android-" "" android_api "${ANDROID_PLATFORM}")
        if(NOT android_api MATCHES "^[0-9]+$")
            message(FATAL_ERROR "X3F requires an explicit numeric ANDROID_PLATFORM")
        endif()
        if(ANDROID_ABI STREQUAL "arm64-v8a")
            set(android_clang_target aarch64-linux-android)
        elseif(ANDROID_ABI STREQUAL "x86_64")
            set(android_clang_target x86_64-linux-android)
        else()
            message(FATAL_ERROR "Unsupported X3F Android ABI: ${ANDROID_ABI}")
        endif()
        string(REPLACE "-" "_" rust_environment_target "${RAWLAB_X3F_RUST_TARGET}")
        string(TOUPPER "${rust_environment_target}" rust_environment_target_upper)
        set(android_cc "${ndk_bin}/${android_clang_target}${android_api}-clang")
        list(APPEND x3f_environment
            "CC_${rust_environment_target}=${android_cc}"
            "AR_${rust_environment_target}=${CMAKE_AR}"
            "CARGO_TARGET_${rust_environment_target_upper}_LINKER=${android_cc}"
            "BINDGEN_EXTRA_CLANG_ARGS=--sysroot=${CMAKE_SYSROOT} --target=${android_clang_target}${android_api}")
    endif()
    add_custom_command(OUTPUT "${x3f_archive}" "${x3f_notices}"
        COMMAND "${CMAKE_COMMAND}" -E env ${x3f_environment}
            "${RAWLAB_CARGO}" build --release --locked --manifest-path "${x3f_source}/Cargo.toml"
            --target "${RAWLAB_X3F_RUST_TARGET}"
        COMMAND "${Python3_EXECUTABLE}" "${x3f_source}/collect_licenses.py" --cargo "${RAWLAB_CARGO}"
            --manifest "${x3f_source}/Cargo.toml" --target "${RAWLAB_X3F_RUST_TARGET}" --output "${x3f_notices}"
        DEPENDS ${x3f_sources} "${x3f_source}/Cargo.toml" "${x3f_source}/Cargo.lock" "${x3f_source}/collect_licenses.py"
        WORKING_DIRECTORY "${x3f_source}"
        COMMENT "Building pinned X3F renderer (${RAWLAB_X3F_RUST_TARGET})" VERBATIM)
    add_custom_target(rawlab_x3f_build DEPENDS "${x3f_archive}" "${x3f_notices}")
    add_library(rawlab_x3f STATIC IMPORTED GLOBAL)
    set_target_properties(rawlab_x3f PROPERTIES IMPORTED_LOCATION "${x3f_archive}"
        INTERFACE_INCLUDE_DIRECTORIES "${x3f_source}")
    add_dependencies(rawlab_x3f rawlab_x3f_build)
    add_compile_definitions(SONY2FUJI_ENABLE_X3F)
    if(WIN32)
        set_property(TARGET rawlab_x3f APPEND PROPERTY INTERFACE_LINK_LIBRARIES ws2_32 userenv bcrypt ntdll)
    elseif(APPLE)
        set_property(TARGET rawlab_x3f APPEND PROPERTY INTERFACE_LINK_LIBRARIES iconv)
    elseif(ANDROID)
        set_property(TARGET rawlab_x3f APPEND PROPERTY INTERFACE_LINK_LIBRARIES dl log m)
    else()
        set_property(TARGET rawlab_x3f APPEND PROPERTY INTERFACE_LINK_LIBRARIES dl pthread m)
    endif()
endif()
