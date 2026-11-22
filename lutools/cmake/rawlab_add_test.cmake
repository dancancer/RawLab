include_guard(GLOBAL)

# Registers a CTest entry (and optionally creates its executable target) with required LABELS.
#
# Usage:
#   rawlab_add_test(
#       NAME <test_name>
#       [TARGET <target_name>]          # Executable target (defaults to <NAME>_tests when SOURCES is set)
#       [SOURCES <src>...]              # Creates executable TARGET with these sources
#       [COMMAND <cmd> [<arg>...]]      # Explicit command (defaults to TARGET)
#       [ARGS <arg>...]                 # Arguments appended to COMMAND (preserves empty "" args)
#       [INCLUDES <dir>...]             # target_include_directories(TARGET PRIVATE ...)
#       [INCLUDES_BEFORE <dir>...]      # target_include_directories(TARGET BEFORE PRIVATE ...)
#       [LIBRARIES <lib>...]            # target_link_libraries(TARGET PRIVATE ...)
#       [DEFINES <def>...]              # target_compile_definitions(TARGET PRIVATE ...)
#       [COMPILE_OPTIONS <opt>...]      # target_compile_options(TARGET PRIVATE ...)
#       [LINK_OPTIONS <opt>...]         # target_link_options(TARGET PRIVATE ...)
#       LABELS <label>...               # Required CTest LABELS
#       [SKIP_RETURN_CODE <code>]       # Optional SKIP_RETURN_CODE test property
#       [ENVIRONMENT <kv>...]           # Optional ENVIRONMENT test property
#   )
function(rawlab_add_test)
    set(options)
    set(one_value NAME TARGET SKIP_RETURN_CODE)
    set(multi_value
        SOURCES COMMAND ARGS INCLUDES INCLUDES_BEFORE
        LIBRARIES DEFINES COMPILE_OPTIONS LINK_OPTIONS
        LABELS ENVIRONMENT
    )
    cmake_parse_arguments(PARSE_ARGV 0 ARG "${options}" "${one_value}" "${multi_value}")

    if(NOT ARG_NAME)
        message(FATAL_ERROR "rawlab_add_test: NAME is required")
    endif()
    if(NOT ARG_LABELS)
        message(FATAL_ERROR "rawlab_add_test(${ARG_NAME}): LABELS must not be empty")
    endif()
    if(ARG_UNPARSED_ARGUMENTS)
        message(FATAL_ERROR "rawlab_add_test(${ARG_NAME}): unexpected arguments: ${ARG_UNPARSED_ARGUMENTS}")
    endif()

    set(target_name "${ARG_TARGET}")
    if(ARG_SOURCES)
        if(NOT target_name)
            set(target_name "${ARG_NAME}_tests")
        endif()
        add_executable("${target_name}" ${ARG_SOURCES})
        if(ARG_INCLUDES_BEFORE)
            target_include_directories("${target_name}" BEFORE PRIVATE ${ARG_INCLUDES_BEFORE})
        endif()
        if(ARG_INCLUDES)
            target_include_directories("${target_name}" PRIVATE ${ARG_INCLUDES})
        endif()
        if(ARG_DEFINES)
            target_compile_definitions("${target_name}" PRIVATE ${ARG_DEFINES})
        endif()
        if(ARG_COMPILE_OPTIONS)
            target_compile_options("${target_name}" PRIVATE ${ARG_COMPILE_OPTIONS})
        endif()
        if(ARG_LINK_OPTIONS)
            target_link_options("${target_name}" PRIVATE ${ARG_LINK_OPTIONS})
        endif()
        if(ARG_LIBRARIES)
            target_link_libraries("${target_name}" PRIVATE ${ARG_LIBRARIES})
        endif()
    endif()

    if(NOT target_name AND NOT ARG_COMMAND)
        set(target_name "${ARG_NAME}_tests")
    endif()

    # Collect raw ARGV indices for COMMAND and ARGS so empty-string arguments
    # such as "${SONY2FUJI_TEST_RAW}" are preserved verbatim in add_test().
    set(all_keywords
        NAME TARGET SKIP_RETURN_CODE
        SOURCES COMMAND ARGS INCLUDES INCLUDES_BEFORE
        LIBRARIES DEFINES COMPILE_OPTIONS LINK_OPTIONS
        LABELS ENVIRONMENT
    )
    set(cmd_eval "")
    set(capture_mode "")
    math(EXPR last_arg_idx "${ARGC} - 1")
    if(NOT ARG_COMMAND)
        set(cmd_eval "\"\${target_name}\"")
    endif()
    foreach(idx RANGE 0 ${last_arg_idx})
        set(token "${ARGV${idx}}")
        if(token IN_LIST all_keywords)
            if(token STREQUAL "COMMAND" OR token STREQUAL "ARGS")
                set(capture_mode "${token}")
            else()
                set(capture_mode "")
            endif()
        elseif(capture_mode)
            string(APPEND cmd_eval " \"\${ARGV${idx}}\"")
        endif()
    endforeach()

    cmake_language(EVAL CODE "add_test(NAME \"\${ARG_NAME}\" COMMAND ${cmd_eval})")

    set_tests_properties("${ARG_NAME}" PROPERTIES LABELS "${ARG_LABELS}")
    if(DEFINED ARG_SKIP_RETURN_CODE AND NOT "${ARG_SKIP_RETURN_CODE}" STREQUAL "")
        set_tests_properties("${ARG_NAME}" PROPERTIES SKIP_RETURN_CODE "${ARG_SKIP_RETURN_CODE}")
    endif()
    if(ARG_ENVIRONMENT)
        foreach(_env_entry IN LISTS ARG_ENVIRONMENT)
            if(_env_entry MATCHES ";[A-Za-z_][A-Za-z0-9_]*=")
                message(FATAL_ERROR
                    "rawlab_add_test(${ARG_NAME}): pass each ENVIRONMENT entry as a separate argument instead of joining with ';': ${_env_entry}")
            endif()
        endforeach()
        set_tests_properties("${ARG_NAME}" PROPERTIES ENVIRONMENT "${ARG_ENVIRONMENT}")
    endif()
endfunction()
