# Run by the check-weak-imports target in CMakeLists.txt: cmake -DNM=... -DARCHIVES=... -DALLOWED=...
# -P check-weak-imports.cmake.  Fails if any archive weakly imports a symbol not in ALLOWED.
#
# ALLOWED entries are archive:symbol, both regular expressions matched in full: archive against the
# file name without its extension, symbol against the Mach-O name, leading underscore included.

cmake_policy(VERSION 3.18)

set(allowed_archive)
set(allowed_symbol)
foreach(entry IN LISTS ALLOWED)
    if(NOT entry MATCHES "^([^:]+):(.+)$")
        message(FATAL_ERROR "check-weak-imports: malformed allowlist entry '${entry}'")
    endif()
    list(APPEND allowed_archive "${CMAKE_MATCH_1}")
    list(APPEND allowed_symbol "${CMAKE_MATCH_2}")
endforeach()
list(LENGTH allowed_archive allowed_count)

set(failures)
set(allowed_seen)
foreach(archive IN LISTS ARCHIVES)
    get_filename_component(name "${archive}" NAME_WE)
    execute_process(COMMAND "${NM}" -m -A "${archive}"
        OUTPUT_VARIABLE out ERROR_VARIABLE err RESULT_VARIABLE rc)
    if(NOT rc EQUAL 0)
        message(FATAL_ERROR "check-weak-imports: ${NM} -m -A ${archive} failed:\n${err}")
    endif()

    # -A prefixes each line with archive:member: so the member that imports it can be named.  nm
    # prints the same "(undefined) weak external" for machine code and for LTO bitcode.
    string(REGEX MATCHALL "[^\n]*\\(undefined\\) weak external [^\n]*" lines "${out}")
    foreach(line IN LISTS lines)
        if(NOT line MATCHES "^.*:([^:]+): +\\(undefined\\) weak external ([^ ]+)")
            message(FATAL_ERROR "check-weak-imports: cannot parse nm line: ${line}")
        endif()
        set(member "${CMAKE_MATCH_1}")
        set(symbol "${CMAKE_MATCH_2}")

        set(ok FALSE)
        if(allowed_count GREATER 0)
            math(EXPR last "${allowed_count} - 1")
            foreach(i RANGE ${last})
                list(GET allowed_archive ${i} a)
                list(GET allowed_symbol ${i} s)
                if(name MATCHES "^(${a})$" AND symbol MATCHES "^(${s})$")
                    set(ok TRUE)
                    list(APPEND allowed_seen "${a}:${s}")
                    break()
                endif()
            endforeach()
        endif()
        if(NOT ok)
            list(APPEND failures "${name}(${member}): ${symbol}")
        endif()
    endforeach()
endforeach()

# An entry that no longer matches anything is either a fixed import or a typo, and either way it
# should not sit there silently permitting a future one.
foreach(entry IN LISTS ALLOWED)
    if(NOT entry IN_LIST allowed_seen)
        message(WARNING "check-weak-imports: allowlist entry '${entry}' matched nothing")
    endif()
endforeach()

if(failures)
    list(REMOVE_DUPLICATES failures)
    list(JOIN failures "\n  " report)
    message(FATAL_ERROR "check-weak-imports: unexpected weak imports\n  ${report}\n"
        "Each is a function the SDK declares as newer than the deployment target, and is null when "
        "called on an older OS.  Make configure not find it (see deps/libevent_core.cmake), or, only "
        "if every call is behind __builtin_available, add it to the allowlist in test/CMakeLists.txt.")
endif()

list(LENGTH ARCHIVES archive_count)
message(STATUS "check-weak-imports: ${archive_count} archives, no unexpected weak imports")
