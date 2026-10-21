cmake_minimum_required(VERSION 3.18)

project(session-deps-test LANGUAGES C CXX)

# A project that exists only to build every dependency we ship a recipe for, so that CI notices a
# recipe that has rotted -- an upstream that moved its tarball, a configure option that went away, a
# new platform it never built on -- rather than the next project to need it finding out.
#
# The dependency list is globbed rather than written down: a recipe that is added without being
# listed here would otherwise be exactly the kind of thing that goes untested.

include(${CMAKE_CURRENT_LIST_DIR}/../Deps.cmake)

# This only makes sense as a static build; with system libraries it would test nothing of ours.
set(BUILD_STATIC_DEPS ON CACHE BOOL "" FORCE)

# Deps that genuinely cannot build on the platform being tested, if any turn up.  This comes from
# the CI job rather than living here so that a skip is visible in the one job that needs it instead
# of quietly switching off coverage everywhere.
set(SKIP_DEPS "" CACHE STRING "Dependency recipes to skip, e.g. -DSKIP_DEPS='libunbound;icu-io'")

file(GLOB dep_recipes RELATIVE ${CMAKE_CURRENT_LIST_DIR}/../deps ${CMAKE_CURRENT_LIST_DIR}/../deps/*.cmake)

set(dep_targets)
set(dep_defines)
foreach(recipe IN LISTS dep_recipes)
    string(REGEX REPLACE "\\.cmake$" "" dep "${recipe}")

    # Not a dependency: the shared machinery every recipe uses.
    if(dep STREQUAL "StaticBuild")
        continue()
    endif()
    if(dep IN_LIST SKIP_DEPS)
        message(STATUS "session-deps test: skipping ${dep} (in SKIP_DEPS)")
        continue()
    endif()

    # Version 0: BUILD_STATIC_DEPS means no system package is consulted, so the minimum a caller
    # would ask for is irrelevant here -- we want to build the recipe whatever it produces.
    session_dep(${dep} 0)
    list(APPEND dep_targets sessiondep::${dep})

    string(TOUPPER "${dep}" dep_define)
    string(MAKE_C_IDENTIFIER "${dep_define}" dep_define)
    list(APPEND dep_defines HAVE_DEP_${dep_define})
endforeach()

# Where the target's C library already provides their API these build nothing, so there is nothing
# of theirs to call.
if(NOT sessiondeps_need_libintl)
    list(REMOVE_ITEM dep_defines HAVE_DEP_PROXY_LIBINTL)
endif()
if(NOT sessiondeps_need_libiconv)
    list(REMOVE_ITEM dep_defines HAVE_DEP_LIBICONV)
endif()

if(LIBHEIF_WITH_LIBDE265)
    list(APPEND dep_defines LIBHEIF_WITH_LIBDE265)
endif()

# jpegli's headers put its own copy of <jpeglib.h> ahead of libjpeg-turbo's, so its call is compiled
# on its own: linked privately here, jpegli's include directory never reaches main.cpp.
if(TARGET sessiondep::jpegli)
    list(REMOVE_ITEM dep_targets sessiondep::jpegli)
    add_library(deps-test-jpegli STATIC jpegli.cpp)
    target_link_libraries(deps-test-jpegli PRIVATE sessiondep::jpegli)
    target_compile_features(deps-test-jpegli PRIVATE cxx_std_20)
    list(APPEND dep_targets deps-test-jpegli)
endif()

list(LENGTH dep_targets dep_count)
message(STATUS "session-deps test: building ${dep_count} dependencies")

# The sources call into each library that was built, which is what makes the linker resolve
# anything at all: a static archive nothing references contributes no members, so linking by itself
# would be satisfied by a library whose symbols are missing entirely.  HAVE_DEP_* tells them which
# libraries are present, so SKIP_DEPS drops the calls along with the library.
add_executable(deps-test main.cpp)
target_link_libraries(deps-test PRIVATE ${dep_targets})
target_compile_definitions(deps-test PRIVATE ${dep_defines})
# The rest of our code is C++20, so that is what these headers need to be usable from.
target_compile_features(deps-test PRIVATE cxx_std_20)

if(MINGW)
    # mingw links its own runtime as DLLs by default, which a cross-built binary then cannot find:
    # they live in the cross toolchain's directories, not next to the executable.  Statically linking
    # them makes this runnable (under wine, or on Windows) without arranging a DLL search path.
    target_link_options(deps-test PRIVATE -static)
endif()

# deps-test links everything on one line, so a recipe missing a system library still links whenever
# another recipe brings that library in: gnutls went without the Apple frameworks it needs because
# libcurl's recipe already adds them.  Most of our projects link gnutls without curl (through
# libquic), so check that link on its own; building it is the test.
if(TARGET sessiondep::gnutls)
    add_executable(deps-test-gnutls main.cpp)
    target_link_libraries(deps-test-gnutls PRIVATE sessiondep::gnutls)
    target_compile_definitions(deps-test-gnutls PRIVATE HAVE_DEP_GNUTLS)
    target_compile_features(deps-test-gnutls PRIVATE cxx_std_20)
endif()

# Our archives end up inside shared objects -- libsession in an Android .so, an iOS framework, a Node
# addon -- so every object in them has to be position-independent.  deps-test is an executable, and a
# PIE-default compiler produces code that links into one fine but not into a shared object, so link
# each archive whole into a shared object of its own.  Undefined symbols are allowed (the Android
# toolchain forbids them by default): the linker rejects a non-PIC relocation whether or not its
# symbol resolves, and resolving them would mean pulling in the rest of the link.
#
# Not built by default; CI runs it after the build.  ELF only: Mach-O is always PIC and PE has no
# such distinction.
if(NOT APPLE AND NOT WIN32)
    add_custom_target(check-pic)

    set(pic_archives)
    set(seen)
    set(queue ${dep_targets})
    while(queue)
        list(POP_FRONT queue item)
        if(item MATCHES "^\\$<LINK_ONLY:(.*)>$")
            set(item "${CMAKE_MATCH_1}")
        endif()
        if(NOT TARGET "${item}" OR item IN_LIST seen)
            continue()
        endif()
        list(APPEND seen ${item})

        get_target_property(alias ${item} ALIASED_TARGET)
        if(alias)
            list(APPEND queue ${alias})
            continue()
        endif()
        get_target_property(type ${item} TYPE)
        get_target_property(imported ${item} IMPORTED)
        if(type STREQUAL "STATIC_LIBRARY" AND imported)
            list(APPEND pic_archives ${item})
        endif()
        get_target_property(linked ${item} INTERFACE_LINK_LIBRARIES)
        if(linked)
            list(APPEND queue ${linked})
        endif()
    endwhile()

    foreach(archive IN LISTS pic_archives)
        get_target_property(location ${archive} IMPORTED_LOCATION)
        get_filename_component(name "${location}" NAME_WE)
        add_library(pic-check-${name} SHARED EXCLUDE_FROM_ALL pic-check.c)
        # The path rather than the target, so that only this archive is linked and not everything it
        # depends on; the target is still what makes the archive get built first.
        target_link_libraries(pic-check-${name} PRIVATE
            -Wl,--whole-archive "${location}" -Wl,--no-whole-archive)
        target_link_options(pic-check-${name} PRIVATE -Wl,-z,undefs)
        add_dependencies(pic-check-${name} ${archive})
        add_dependencies(check-pic pic-check-${name})
    endforeach()

    list(LENGTH pic_archives pic_count)
    message(STATUS "session-deps test: check-pic covers ${pic_count} archives")
endif()
