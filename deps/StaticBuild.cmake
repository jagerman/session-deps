# cmake helpers used to do a full static build, downloading and building all dependencies.

include_guard(GLOBAL)

set(LOCAL_MIRROR "" CACHE STRING "local mirror path/URL for lib downloads")

if(CMAKE_VERSION VERSION_GREATER_EQUAL 3.20)
    include(ExternalProject)
endif()

set(SESSIONDEPS_DESTDIR ${CMAKE_BINARY_DIR}/static-deps CACHE INTERNAL "" FORCE)
set(SESSIONDEPS_SOURCEDIR ${CMAKE_BINARY_DIR}/static-deps-sources CACHE INTERNAL "" FORCE)
# Stand-ins for APIs the C library lacks (proxy-libintl, libiconv) are installed apart from the
# destdir, where only the recipes that ask for them look.  gettext's and iconv's autoconf macros
# search the configure --prefix of their own accord, so in the destdir every autotools recipe would
# find them, and whether it did would depend on which happened to build first: gnutls and libidn2
# turned on NLS against libintl.a that way, and curl's link test against gnutls, which names no
# -lintl, then failed.
set(SESSIONDEPS_PROVIDERS_DIR ${CMAKE_BINARY_DIR}/static-deps-providers CACHE INTERNAL "" FORCE)

file(MAKE_DIRECTORY ${SESSIONDEPS_DESTDIR}/include)
file(MAKE_DIRECTORY ${SESSIONDEPS_PROVIDERS_DIR}/include)

# NB: any variables we set here are local and will go out of scope; they need to be stuffed into
# CACHE INTERNAL variables if they are to be referenced in any of the functions or build scripts.
set(deps_cc "${CMAKE_C_COMPILER}")
set(deps_cxx "${CMAKE_CXX_COMPILER}")
if(CMAKE_C_COMPILER_LAUNCHER)
    set(deps_cc "${CMAKE_C_COMPILER_LAUNCHER} ${deps_cc}")
endif()
if(CMAKE_CXX_COMPILER_LAUNCHER)
    set(deps_cxx "${CMAKE_CXX_COMPILER_LAUNCHER} ${deps_cxx}")
endif()


function(sessiondep_expand_urls output source_file)
    set(expanded)
    foreach(mirror ${ARGN})
        list(APPEND expanded "${mirror}/${source_file}")
    endforeach()
    set(${output} "${expanded}" PARENT_SCOPE)
endfunction()


# Add a static imported target for a single library.  If the static build produces just one library
# then this can be the final `sessiondep_ext_PKG` target.  For a multi-library output you need
# one of these calls per produced output, and then use `sessiondep_bundle()` to produce the
# final required target from multiple targets.
#
# See also the sessiondep_static_simple wrapper for very simple library dependencies.
#
# After a sessiondep_build_external(mypkg ...) that produces a single static library lib/libmypkg.a
# you would typically call this as follows to produce the proper target needed for satisfy a static
# dep:
#
#     sessiondep_static_target(sessiondep_ext_mypkg mypkg libmypkg.a)
#
# For a multi-lib static build producing lib/libmypkg.a and lib/libmypkg-foo.a, there are two
# options.  The first is just to export a single target that links to everything; to do that use
# something like:
#
#     sessiondep_static_target(mypkg_base mypkg libmypkg.a)
#     sessiondep_static_target(mypkg_foo mypkg libmypkg-foo.a)
#     sessiondep_bundle(mypkg mypkg_base mypkg_foo)
#
# which will expose a single sessiondep::mypkg target that links to both libraries.
#
# However if these are independent and can be linked separately (typically with independent
# pkgconfig files), you may not want such a bundle so that the program can choose with components it
# links to.  See deps/nettle.cmake and deps/libngtcp2.cmake for examples of this.
#
# You can append other cmake target dependencies (e.g. `sessiondep::xyz`) after the static library
# filename to set up the proper cmake dependency chain.
#
# `PREFIX dir` names where the library was installed, when that is not SESSIONDEPS_DESTDIR.
function(sessiondep_static_target target ext_target libname)
    cmake_parse_arguments(PARSE_ARGV 3 arg "" "PREFIX" "")
    if(NOT arg_PREFIX)
        set(arg_PREFIX ${SESSIONDEPS_DESTDIR})
    endif()
    add_library(${target} STATIC IMPORTED GLOBAL)
    add_dependencies(${target} sessiondep_${ext_target}_external)
    set_target_properties(${target} PROPERTIES
        IMPORTED_LOCATION ${arg_PREFIX}/lib/${libname}
    )
    target_include_directories(${target} INTERFACE ${arg_PREFIX}/include)
    if (arg_UNPARSED_ARGUMENTS)
        target_link_libraries(${target} INTERFACE ${arg_UNPARSED_ARGUMENTS})
    endif()
endfunction()


# Shortcut for adding an static imported target for a basic single-library static library.
# sessiondep_static_simple(NAME ...deps...) is a approximately a shortcut for
# `sessiondep_static_target(sessiondep_ext_NAME NAME NAME.a ...deps...)`, except that when NAME
# doesn't already starts with `lib` we prepend it to the NAME.a argument.
function(sessiondep_static_simple name)
    set(lib_prefix)
    if(NOT name MATCHES "^lib")
        set(lib_prefix "lib")
    endif()
    sessiondep_static_target(sessiondep_ext_${name} ${name} ${lib_prefix}${name}.a ${ARGN})
endfunction()


# For static builds that link to multiple targets, this helper function is provided to combine them;
# see example above.
#
# The first argument, `name`, should be the same as the script filename (e.g. "libngtcp2" for
# deps/libngtcp2.cmake).  `sessiondep_ext_` will be prepended to the target name automatically.  Any
# remaining arguments are cmake targets to link to the created interface.
function(sessiondep_bundle name)
    add_library(sessiondep_ext_${name} INTERFACE)
    target_link_libraries(sessiondep_ext_${name} INTERFACE ${ARGN})
endfunction()


set(deps_cross_host "")
set(deps_cross_rc "")
if(CMAKE_CROSSCOMPILING)
    if(APPLE AND NOT ARCH_TRIPLET AND APPLE_TARGET_TRIPLE)
        set(ARCH_TRIPLET "${APPLE_TARGET_TRIPLE}")
    endif()
    set(deps_cross_host "--host=${ARCH_TRIPLET}")
    if (ARCH_TRIPLET MATCHES mingw AND CMAKE_RC_COMPILER)
        set(deps_cross_rc "WINDRES=${CMAKE_RC_COMPILER}")
    endif()
    # Every autoconf configure line splices this list, so the cross archiver goes here too.  Left to
    # itself, configure looks for `<host>-ar`, which the NDK no longer ships, and falls back to the
    # build machine's `ar`: on a mac that writes target objects into an archive with no usable
    # symbol table (libsodium.a comes out at 96 bytes) and the failure only shows at final link.
    if(CMAKE_AR AND CMAKE_RANLIB)
        list(APPEND deps_cross_rc "AR=${CMAKE_AR}" "RANLIB=${CMAKE_RANLIB}")
    endif()
endif()
if(ANDROID)
    set(android_compiler_suffix linux-android23)
    if(CMAKE_ANDROID_ARCH_ABI MATCHES x86_64)
        set(deps_android_machine x86_64)
        set(deps_cross_host "--host=x86_64-linux-android")
        set(android_compiler_prefix x86_64)
        set(android_compiler_suffix linux-android23)
    elseif(CMAKE_ANDROID_ARCH_ABI MATCHES x86)
        set(deps_android_machine x86)
        set(deps_cross_host "--host=i686-linux-android")
        set(android_compiler_prefix i686)
        set(android_compiler_suffix linux-android23)
    elseif(CMAKE_ANDROID_ARCH_ABI MATCHES armeabi-v7a)
        set(deps_android_machine arm)
        set(deps_cross_host "--host=armv7a-linux-androideabi")
        set(android_compiler_prefix armv7a)
        set(android_compiler_suffix linux-androideabi23)
    elseif(CMAKE_ANDROID_ARCH_ABI MATCHES arm64-v8a)
        set(deps_android_machine arm64)
        set(deps_cross_host "--host=aarch64-linux-android")
        set(android_compiler_prefix aarch64)
        set(android_compiler_suffix linux-android23)
    else()
        message(FATAL_ERROR "unknown android arch: ${CMAKE_ANDROID_ARCH_ABI}")
    endif()
    # The NDK ships one prebuilt toolchain per *host*, and the directory is named for it. Hardcoding
    # the Linux one meant these autoconf dependencies were pointed at a path that does not exist on
    # a mac, which surfaces as "C compiler cannot create executables" from configure -- a message
    # that says nothing about which compiler it could not find. The CMake half of the build never
    # hit it because the toolchain file resolves the host itself.
    if(CMAKE_HOST_APPLE)
        set(android_ndk_host "darwin-x86_64")
    elseif(CMAKE_HOST_WIN32)
        set(android_ndk_host "windows-x86_64")
    else()
        set(android_ndk_host "linux-x86_64")
    endif()
    set(deps_cc "${CMAKE_ANDROID_NDK}/toolchains/llvm/prebuilt/${android_ndk_host}/bin/${android_compiler_prefix}-${android_compiler_suffix}-clang")
    set(deps_cxx "${CMAKE_ANDROID_NDK}/toolchains/llvm/prebuilt/${android_ndk_host}/bin/${android_compiler_prefix}-${android_compiler_suffix}-clang++")
endif()

set(deps_apple_cflags_arch)
set(deps_apple_cxxflags_arch)
set(deps_apple_ldflags_arch)
set(deps_cmake_osx_args)
set(deps_raw_cross_host "${deps_cross_host}")
if(APPLE AND CMAKE_CROSSCOMPILING)
    if(deps_cross_host MATCHES "^(.*-)ios([0-9.]+)(-.*)?$")
        set(deps_cross_host "${CMAKE_MATCH_1}darwin${CMAKE_MATCH_2}${CMAKE_MATCH_3}")
    endif()
    if(deps_cross_host MATCHES "^(.*)-simulator$")
        set(deps_cross_host "${CMAKE_MATCH_1}")
    endif()

    set(apple_arch)
    if(ARCH_TRIPLET MATCHES "^(arm|aarch)64.*")
        set(apple_arch "arm64")
    elseif(ARCH_TRIPLET MATCHES "^x86_64.*")
        set(apple_arch "x86_64")
    else()
        message(FATAL_ERROR "Don't know how to specify -arch for GMP for ${ARCH_TRIPLET} (${APPLE_TARGET_TRIPLE})")
    endif()

    set(deps_apple_cflags_arch " -arch ${apple_arch}")
    set(deps_apple_cxxflags_arch " -arch ${apple_arch}")
    if(CMAKE_OSX_DEPLOYMENT_TARGET)
      if (SDK_NAME)
        set(deps_apple_ldflags_arch " -m${SDK_NAME}-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}")
      elseif(CMAKE_OSX_DEPLOYMENT_TARGET)
        set(deps_apple_ldflags_arch " -mmacosx-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}")
      endif()
    endif()
    set(deps_apple_ldflags_arch "${deps_apple_ldflags_arch} -arch ${apple_arch}")

    if(CMAKE_OSX_SYSROOT)
      foreach(f c cxx ld)
        set(deps_apple_${f}flags_arch "${deps_apple_${f}flags_arch} -isysroot ${CMAKE_OSX_SYSROOT}")
      endforeach()
    endif()

    # CMake-based deps (built via DEFAULT_CMAKE) don't use CFLAGS/CXXFLAGS, so pass the target arch
    # to their sub-cmake instead; the sysroot and deployment target follow below.
    set(deps_cmake_osx_args "-DCMAKE_OSX_ARCHITECTURES=${apple_arch}")
elseif(deps_cross_host STREQUAL "" AND CMAKE_LIBRARY_ARCHITECTURE)
    set(deps_cross_host "--build=${CMAKE_LIBRARY_ARCHITECTURE}")
endif()

# On every Apple build, native as well as cross: a sub-cmake left to itself targets the SDK's own
# macOS version rather than our deployment target, so the CMake-based deps of a native macOS build
# were built for whatever the build machine's SDK was (15.0 on a current Xcode) and linked with a
# warning into something that cannot run on anything older.  Autotools and meson deps get the same
# settings through deps_CFLAGS, below.
if(APPLE)
    if(CMAKE_OSX_SYSROOT)
        list(APPEND deps_cmake_osx_args "-DCMAKE_OSX_SYSROOT=${CMAKE_OSX_SYSROOT}")
    endif()
    if(CMAKE_OSX_DEPLOYMENT_TARGET)
        list(APPEND deps_cmake_osx_args "-DCMAKE_OSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}")
    endif()
endif()

set(deps_CFLAGS "-O2")
set(deps_CXXFLAGS "-O2")

# Every autotools dep needs to be pointed at the destdir it and its siblings install into, so keep
# that (and the apple arch flags that have to ride along with it) in one place rather than having
# each build spell it out.
set(deps_ldflags "-L${SESSIONDEPS_DESTDIR}/lib${deps_apple_ldflags_arch}")

set(default_lto ON)
if(WIN32)
    set(default_lto OFF)
endif()
option(SESSIONDEPS_LTO "Use LTO for static dependency builds, where supported" ${default_lto})
if(SESSIONDEPS_LTO)
    set(deps_CFLAGS "${deps_CFLAGS} -flto")
endif()

if(APPLE AND CMAKE_OSX_DEPLOYMENT_TARGET)
    # Use the SDK-appropriate deployment-target flag: on iOS/simulator/etc. SDK_NAME is set (e.g.
    # "iphonesimulator" -> -miphonesimulator-version-min), otherwise fall back to macOS.  Passing
    # -mmacosx-version-min alongside a non-macOS -isysroot makes clang unable to link (autotools
    # configure then fails with "C compiler cannot create executables").  This mirrors the LDFLAGS
    # handling above (deps_apple_ldflags_arch).
    if(SDK_NAME)
        set(deps_CFLAGS "${deps_CFLAGS} -m${SDK_NAME}-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}")
        set(deps_CXXFLAGS "${deps_CXXFLAGS} -m${SDK_NAME}-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}")
    else()
        set(deps_CFLAGS "${deps_CFLAGS} -mmacosx-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}")
        set(deps_CXXFLAGS "${deps_CXXFLAGS} -mmacosx-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}")
    endif()
endif()

# Fold the Apple -arch/-isysroot flags into the base compile flags so that *every* dependency picks
# them up, rather than requiring each dep script to remember to append them (which is error-prone --
# several deps did not, and built for the host arch during a cross build).  These are empty except on
# an Apple cross build.  The link-time equivalents are folded into deps_ldflags, above.
set(deps_CFLAGS "${deps_CFLAGS}${deps_apple_cflags_arch}")
set(deps_CXXFLAGS "${deps_CXXFLAGS}${deps_apple_cxxflags_arch}")

# Propagate the C++ standard library selection (e.g. -stdlib=libc++) from the main build to the
# dependency builds so their C++ ABI matches; otherwise clang defaults to libstdc++ and linking a
# dep into a libc++ program fails with undefined std::__1 / std::__cxx11 symbols.
set(deps_cxx_stdlib)
if(CMAKE_CXX_FLAGS MATCHES "(^| )(-stdlib=[A-Za-z0-9+_-]+)")
    set(deps_cxx_stdlib "${CMAKE_MATCH_2}")
    set(deps_CXXFLAGS "${deps_CXXFLAGS} ${deps_cxx_stdlib}")
endif()

# CMake-based deps (DEFAULT_CMAKE) run their own sub-cmake, which otherwise picks the system default
# toolchain (e.g. /usr/bin/c++ = libstdc++ on Linux) instead of the one used for the rest of the
# build.  Forward the compiler, any launcher, and the C++ stdlib so they match.  (Apple arch/sysroot
# are forwarded separately via deps_cmake_osx_args.)
set(deps_cmake_toolchain_args
    "-DCMAKE_C_COMPILER=${CMAKE_C_COMPILER}"
    "-DCMAKE_CXX_COMPILER=${CMAKE_CXX_COMPILER}")
if(CMAKE_C_COMPILER_LAUNCHER)
    list(APPEND deps_cmake_toolchain_args "-DCMAKE_C_COMPILER_LAUNCHER=${CMAKE_C_COMPILER_LAUNCHER}")
endif()
if(CMAKE_CXX_COMPILER_LAUNCHER)
    list(APPEND deps_cmake_toolchain_args "-DCMAKE_CXX_COMPILER_LAUNCHER=${CMAKE_CXX_COMPILER_LAUNCHER}")
endif()
if(deps_cxx_stdlib)
    list(APPEND deps_cmake_toolchain_args "-DCMAKE_CXX_FLAGS=${deps_cxx_stdlib}")
endif()

# CMake-based dependencies need the cross toolchain, not just the compiler binary.  A cross
# compiler invoked without its target builds for the host, and the result is an archive that
# links against the wrong platform's standard library -- on Android, libstdc++ symbols that do
# not exist there.  Autotools deps do not need this because deps_cc above is already the
# target-prefixed driver.
#
# Keyed on the toolchain file rather than on a named platform: it is the thing that decides the
# target, and if this build used one then a dependency built without it is building something
# else.  Each toolchain file reads its own variables, so the ones that are set are forwarded and
# the rest are absent anyway.
if(CMAKE_TOOLCHAIN_FILE)
    list(APPEND deps_cmake_toolchain_args "-DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}")

    foreach(var IN ITEMS
            # Android NDK's toolchain file
            ANDROID_ABI ANDROID_PLATFORM ANDROID_STL ANDROID_ARM_MODE
            # ios-cmake's toolchain file
            PLATFORM DEPLOYMENT_TARGET ENABLE_BITCODE ENABLE_ARC ENABLE_VISIBILITY ARCHS)
        if(DEFINED ${var})
            list(APPEND deps_cmake_toolchain_args "-D${var}=${${var}}")
        endif()
    endforeach()

    # Cross toolchain files set CMAKE_FIND_ROOT_PATH_MODE_* to ONLY, which re-roots every find_*
    # search under the toolchain's sysroot -- so one dependency looking for another it was built
    # after (libheif for libde265 and dav1d) finds nothing in the destdir and
    # quietly builds without it.  Directories below CMAKE_STAGING_PREFIX are searched even in ONLY
    # mode, and toolchain files do not set it, unlike CMAKE_FIND_ROOT_PATH which they overwrite.
    # It is also where install() then puts things, which is the destdir either way.
    list(APPEND deps_cmake_toolchain_args "-DCMAKE_STAGING_PREFIX=${SESSIONDEPS_DESTDIR}")
endif()



if("${CMAKE_GENERATOR}" STREQUAL "Unix Makefiles")
    set(deps_make "$(MAKE)")
else()
    set(deps_make make)
endif()

# -N -f so that patch never stops to ask a question: run from a terminal, a patch that no longer
# applies waits for an answer forever instead of failing.  Both flags make it fail rather than
# guess, unlike --batch, which answers "yes, it looks reversed" and then exits successfully having
# undone the patch.
set(deps_patch patch -N -f)

# libjpeg-turbo and dav1d both carry hand-written x86 assembly that nasm assembles, and both fall
# back to plain C without it -- building and working correctly, just several times slower, with the
# explanation buried in one dependency's configure output.  That is exactly the kind of regression
# that ships unnoticed, so the check happens once, here, and says so loudly.
#
# Only x86 is affected: on Arm, dav1d's assembly goes through the C compiler and libjpeg-turbo uses
# intrinsics, neither of which wants nasm.
set(deps_no_x86_asm FALSE)
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^([Xx]86_64|[Aa][Mm][Dd]64|i[3-6]86)$"
        OR ARCH_TRIPLET MATCHES "^(x86_64|i[3-6]86)")
    find_program(SESSIONDEPS_NASM NAMES nasm)
    if(NOT SESSIONDEPS_NASM)
        set(deps_no_x86_asm TRUE)
        message(WARNING "nasm was not found: libjpeg-turbo and dav1d will be built without their "
            "x86 assembly, which makes JPEG and AVIF decoding markedly slower.  Install nasm.")
    endif()
endif()

# Whether the target's C library lacks gettext or iconv, which glib needs and the proxy-libintl and
# libiconv recipes provide.  iconv is only wanted from them off Windows, where glib bundles
# win_iconv.c, and off Apple, whose system libiconv is a public dylib.  The checks run against the
# target's own headers, so they follow the platform and API level: bionic has no gettext at all, and
# its iconv.h only declares iconv_open from API 28.
include(CheckSymbolExists)
check_symbol_exists(ngettext "libintl.h" _sdep_libc_has_gettext)
set(deps_need_libintl FALSE)
if(NOT _sdep_libc_has_gettext)
    set(deps_need_libintl TRUE)
endif()
set(deps_need_libiconv FALSE)
if(NOT WIN32 AND NOT APPLE)
    check_symbol_exists(iconv_open "iconv.h" _sdep_libc_has_iconv)
    if(NOT _sdep_libc_has_iconv)
        set(deps_need_libiconv TRUE)
    endif()
endif()

# Meson-based deps (DEFAULT_MESON).  Not required unless a recipe asks for one, so a missing tool is
# diagnosed in sessiondep_build_external() rather than here.
#
# 1.4 is what glib requires.  Older ones fail in less obvious ways first: before 0.63, the
# -Dprefer_static every recipe passes is an unknown option.
set(deps_meson_min_version 1.4.0)
find_program(SESSIONDEPS_MESON meson)
find_program(SESSIONDEPS_NINJA NAMES ninja ninja-build)
set(deps_meson "${SESSIONDEPS_MESON}")
set(deps_ninja "${SESSIONDEPS_NINJA}")
set(deps_meson_missing "meson and ninja are required to build this dependency, but were not found")
if(deps_meson)
    execute_process(COMMAND ${deps_meson} --version
        OUTPUT_VARIABLE _sdep_meson_version OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
    if(_sdep_meson_version VERSION_LESS deps_meson_min_version)
        set(deps_meson_missing "meson >= ${deps_meson_min_version} is required to build this dependency, but ${deps_meson} is version ${_sdep_meson_version}")
        set(deps_meson "")
    endif()
endif()

# meson resolves dependencies through pkg-config, and has to see both what we have installed into
# the destdir and anything session_dep() satisfied from the system, with ours taking precedence: a
# static libvips can perfectly well sit on a system glib.  This is PKG_CONFIG_LIBDIR rather than
# PKG_CONFIG_PATH because the latter is searched *after* the default path, which would let a system
# copy of something we just built win.
set(deps_pkg_config_libdir "${SESSIONDEPS_DESTDIR}/lib/pkgconfig")
if(NOT CMAKE_CROSSCOMPILING)
    # Cross builds get only our destdir appended: the host's .pc files describe the wrong
    # architecture, and picking one up produces a link failure a long way from its cause.
    find_package(PkgConfig)
    if(PKG_CONFIG_EXECUTABLE)
        execute_process(COMMAND ${PKG_CONFIG_EXECUTABLE} --variable pc_path pkg-config
            OUTPUT_VARIABLE deps_pkg_config_syspath
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET)
        if(deps_pkg_config_syspath)
            set(deps_pkg_config_libdir "${deps_pkg_config_libdir}:${deps_pkg_config_syspath}")
        endif()
    endif()
endif()

# The same for a recipe running pkg-config from its own configure, as the variable assignments to
# pass it.  A cross build that falls back to building one dependency can still see system packages
# when its toolchain names a pkg-config for the target triplet -- Debian multiarch's
# `s390x-linux-gnu-pkg-config`, say -- because that one searches the target's directories.  It
# reports the build machine's as its pc_path all the same, so they cannot be written into
# PKG_CONFIG_LIBDIR; ours go in PKG_CONFIG_PATH instead, which is searched ahead of them.
#
# Not for BUILD_STATIC_DEPS: everything is built here then, and a system package found this way is
# an optional dependency leaking into what was meant to be fully static.
set(deps_pkg_config_env "PKG_CONFIG=pkg-config" "PKG_CONFIG_LIBDIR=${deps_pkg_config_libdir}")
if(CMAKE_CROSSCOMPILING AND NOT BUILD_STATIC_DEPS AND ARCH_TRIPLET
        AND PKG_CONFIG_EXECUTABLE MATCHES "(^|/)${ARCH_TRIPLET}-pkg-config$")
    set(deps_pkg_config_env "PKG_CONFIG=${PKG_CONFIG_EXECUTABLE}"
        "PKG_CONFIG_PATH=${SESSIONDEPS_DESTDIR}/lib/pkgconfig")
endif()

# Cross toolchain files are not required to set CMAKE_SYSTEM_PROCESSOR, and none of the mingw ones
# in use across these projects do.  cmake leaves it empty rather than guessing, which most
# dependencies never notice -- but libjpeg-turbo runs string(TOLOWER) on it during CPU detection and
# an empty argument there is a hard cmake error.  Deriving it once from the triplet and forwarding
# it below keeps that working without every consumer having to amend its toolchain file.
set(_sdep_target_cpu "${CMAKE_SYSTEM_PROCESSOR}")
if(ARCH_TRIPLET)
    string(REGEX REPLACE "-.*" "" _sdep_target_cpu "${ARCH_TRIPLET}")
endif()
if(CMAKE_CROSSCOMPILING AND NOT CMAKE_SYSTEM_PROCESSOR AND _sdep_target_cpu)
    list(APPEND deps_cmake_toolchain_args "-DCMAKE_SYSTEM_PROCESSOR=${_sdep_target_cpu}")
endif()

# meson has no equivalent of autoconf's --host: a cross build is described entirely by a cross file
# naming the target machine and the tools to reach it, so we have to write one.  Generated here, at
# configure time, rather than per-recipe, because every meson dep needs the same one.
set(deps_meson_cross "")
if(CMAKE_CROSSCOMPILING)
    set(_sdep_meson_host_extra "")
    if(CMAKE_SYSTEM_NAME MATCHES "^(iOS|tvOS|watchOS|visionOS|Darwin)$")
        set(_sdep_meson_system darwin)
        # meson cannot tell the Apple platforms apart from `darwin` alone, and glib asks which one
        # it is building for (host_machine.subsystem()), which is a hard error when unset.  Named
        # in meson's vocabulary, from the SDK the toolchain file selected.  A macOS cross-arch build
        # (arm64 <-> x86_64) has no toolchain file and so no SDK_NAME, but there cmake's own Darwin
        # system name already says macOS: the other Apple platforms have system names of their own.
        set(_sdep_meson_subsystems
            macosx=macos iphoneos=ios iphonesimulator=ios-simulator
            appletvos=tvos appletvsimulator=tvos-simulator
            watchos=watchos watchsimulator=watchos-simulator
            xros=visionos xrsimulator=visionos-simulator)
        set(_sdep_meson_subsystem "")
        if(CMAKE_SYSTEM_NAME STREQUAL "Darwin" AND NOT SDK_NAME)
            set(_sdep_meson_subsystem macos)
        endif()
        foreach(pair IN LISTS _sdep_meson_subsystems)
            if(pair MATCHES "^([a-z]+)=(.*)$" AND CMAKE_MATCH_1 STREQUAL "${SDK_NAME}")
                set(_sdep_meson_subsystem "${CMAKE_MATCH_2}")
            endif()
        endforeach()
        if(NOT _sdep_meson_subsystem)
            message(FATAL_ERROR "Don't know how to name Apple SDK '${SDK_NAME}' for a meson cross file")
        endif()
        set(_sdep_meson_host_extra "kernel = 'xnu'\nsubsystem = '${_sdep_meson_subsystem}'\n")
    else()
        string(TOLOWER "${CMAKE_SYSTEM_NAME}" _sdep_meson_system)
    endif()

    # meson matches cpu_family against its own fixed vocabulary, which is neither cmake's spelling
    # nor the triplet's, so the triplet gets translated rather than passed through.
    set(_sdep_meson_cpu "${_sdep_target_cpu}")
    set(_sdep_meson_endian little)
    if(_sdep_meson_cpu MATCHES "^(x86_64|amd64)$")
        set(_sdep_meson_cpu_family x86_64)
    elseif(_sdep_meson_cpu MATCHES "^i[3-6]86$")
        set(_sdep_meson_cpu_family x86)
    elseif(_sdep_meson_cpu MATCHES "^(aarch64|arm64)")
        set(_sdep_meson_cpu_family aarch64)
    elseif(_sdep_meson_cpu MATCHES "^arm")
        set(_sdep_meson_cpu_family arm)
    elseif(_sdep_meson_cpu STREQUAL "s390x")
        set(_sdep_meson_cpu_family s390x)
        set(_sdep_meson_endian big)
    else()
        message(FATAL_ERROR "Don't know how to name cpu '${_sdep_meson_cpu}' for a meson cross file")
    endif()

    # deps_cc can carry a compiler launcher ("ccache gcc"); meson wants that as a list.
    foreach(lang cc cxx)
        string(REPLACE " " ";" _sdep_meson_${lang}_parts "${deps_${lang}}")
        set(_sdep_meson_${lang} "")
        foreach(part IN LISTS _sdep_meson_${lang}_parts)
            string(APPEND _sdep_meson_${lang} "'${part}', ")
        endforeach()
        string(REGEX REPLACE ", $" "" _sdep_meson_${lang} "${_sdep_meson_${lang}}")
    endforeach()

    set(_sdep_meson_extra_bins "")
    if(CMAKE_AR)
        string(APPEND _sdep_meson_extra_bins "ar = '${CMAKE_AR}'\n")
    endif()
    if(CMAKE_STRIP)
        string(APPEND _sdep_meson_extra_bins "strip = '${CMAKE_STRIP}'\n")
    endif()
    if(CMAKE_RC_COMPILER AND ARCH_TRIPLET MATCHES mingw)
        string(APPEND _sdep_meson_extra_bins "windres = '${CMAKE_RC_COMPILER}'\n")
    endif()

    set(deps_meson_cross "${CMAKE_BINARY_DIR}/sessiondeps-meson-cross.ini")
    file(WRITE "${deps_meson_cross}"
"# Generated by session-deps; edits will be overwritten.
[binaries]
c = [${_sdep_meson_cc}]
cpp = [${_sdep_meson_cxx}]
pkg-config = 'pkg-config'
${_sdep_meson_extra_bins}
[host_machine]
system = '${_sdep_meson_system}'
cpu_family = '${_sdep_meson_cpu_family}'
cpu = '${_sdep_meson_cpu}'
endian = '${_sdep_meson_endian}'
${_sdep_meson_host_extra}")
endif()

# Promote any variables set above as `deps_whatever` to a cache variable `sessiondeps_whatever` so
# that the functions below and build scripts can reference them:
foreach(var IN ITEMS
        cc cxx CFLAGS CXXFLAGS cxx_stdlib ldflags make patch cross_host raw_cross_host cross_rc
        android_machine cmake_osx_args cmake_toolchain_args
        meson ninja meson_missing meson_cross pkg_config_libdir pkg_config_env no_x86_asm need_libintl
        need_libiconv)
    if(DEFINED deps_${var})
        set(sessiondeps_${var} "${deps_${var}}" CACHE INTERNAL "" FORCE)
    endif()
endforeach()

# Flattens cmake targets into a plain linker argument list, for handing to a build system that has
# never heard of cmake -- an autotools `LIBS=`, typically.  Takes an output variable followed by any
# number of targets or link items.
#
# This exists so that a dep whose build system needs to be told about another dep does not have to
# restate that dep's own link requirements: cmake already worked them out, whether it built the
# library or found a system one, and this asks it rather than guessing.
#
# Each target is emitted before the things it links to, which is the order a single-pass static link
# needs.
#
# Libraries are named with -l against a -L search path rather than by their path, because libtool
# takes a .a named on a link line to be a convenience archive and copies its members into whatever
# it is building -- which gets you a libcurl.a with libgnutls.a sitting inside it as a member.
function(sessiondep_link_flags out_var)
    set(result)
    set(libdirs)
    set(seen)
    set(queue ${ARGN})
    while(queue)
        list(POP_FRONT queue item)

        # $<LINK_ONLY:x> is just x as far as a link line is concerned; any other generator
        # expression we cannot evaluate here, and emitting it raw would be worse than omitting it.
        if(item MATCHES "^\\$<LINK_ONLY:(.*)>$")
            set(item "${CMAKE_MATCH_1}")
        endif()
        if(item MATCHES "^\\$<")
            continue()
        endif()

        if(item IN_LIST seen)
            continue()
        endif()
        list(APPEND seen "${item}")

        if(TARGET ${item})
            get_target_property(alias ${item} ALIASED_TARGET)
            if(alias)
                list(APPEND queue ${alias})
                continue()
            endif()
            get_target_property(location ${item} IMPORTED_LOCATION)
            if(location)
                get_filename_component(libdir "${location}" DIRECTORY)
                get_filename_component(libname "${location}" NAME_WE)
                string(REGEX REPLACE "^lib" "" libname "${libname}")
                if(NOT "-L${libdir}" IN_LIST libdirs)
                    list(APPEND libdirs "-L${libdir}")
                endif()
                list(APPEND result "-l${libname}")
            endif()
            get_target_property(linked ${item} INTERFACE_LINK_LIBRARIES)
            if(linked)
                list(APPEND queue ${linked})
            endif()
        elseif(item MATCHES "^-" OR IS_ABSOLUTE "${item}")
            list(APPEND result "${item}")
        else()
            list(APPEND result "-l${item}")
        endif()
    endwhile()
    list(APPEND libdirs ${result})
    set(${out_var} "${libdirs}" PARENT_SCOPE)
endfunction()

# Extra DEFAULT_MESON arguments for a recipe that needs the providers in SESSIONDEPS_PROVIDERS_DIR:
# glib itself, and anything that includes glib's headers, since <glib/gi18n-lib.h> includes
# <libintl.h>.  Empty where the target needs no providers.
#
# meson's has_header() probes see only c_args, not the Cflags of dependencies already found, and its
# find_library() link test sees only the link args, so the directories go in both.  C++ as well as
# C, because meson runs some dependency checks through the C++ compiler, and Objective-C on Apple,
# where glib has .m sources.  Each restates the base flags, since the last -Dc_args given wins, and
# each is a single argument, or meson reads the flags as option assignments.
function(sessiondep_providers_meson_args out_var)
    set(result)
    if(sessiondeps_need_libintl OR sessiondeps_need_libiconv)
        set(cflags " -I${SESSIONDEPS_PROVIDERS_DIR}/include")
        if(sessiondeps_need_libintl)
            # libintl.h declares its API __declspec(dllimport) on Windows unless told the library is
            # static.
            string(APPEND cflags " -DG_INTL_STATIC_COMPILATION")
        endif()
        set(ldflags "${sessiondeps_ldflags} -L${SESSIONDEPS_PROVIDERS_DIR}/lib")
        list(APPEND result
            "-Dc_args=${sessiondeps_CFLAGS}${cflags}"
            "-Dcpp_args=${sessiondeps_CXXFLAGS}${cflags}"
            "-Dc_link_args=${ldflags}"
            "-Dcpp_link_args=${ldflags}")
        if(APPLE)
            list(APPEND result
                "-Dobjc_args=${sessiondeps_CFLAGS}${cflags}"
                "-Dobjc_link_args=${ldflags}")
        endif()
    endif()
    set(${out_var} "${result}" PARENT_SCOPE)
endfunction()

# Builds a target; takes the target name (e.g. "readline") and builds it in an external project with
# target name suffixed with `_external`.  Its upper-case value is used to get the download details
# (from the variables set above).  The following options are supported and passed through to
# ExternalProject_Add if specified.  If omitted, these defaults are used:
#
# PREFIX sets the install prefix DEFAULT_CMAKE and DEFAULT_MESON use, when it is not
# SESSIONDEPS_DESTDIR.
function(sessiondep_build_external target)
    set(options DEPENDS PATCHES PATCH_COMMAND CONFIGURE_COMMAND BUILD_COMMAND INSTALL_COMMAND BUILD_BYPRODUCTS)
    cmake_parse_arguments(PARSE_ARGV 1 arg "" "PREFIX" "${options}")
    if(NOT arg_PREFIX)
        set(arg_PREFIX ${SESSIONDEPS_DESTDIR})
    endif()

    # PATCHES takes bare file names in patches/ and expands to the patch invocations; every patch is
    # applied with -p1, so a patch taken from somewhere that strips differently needs its paths
    # adjusted (a/ and b/ prefixes) rather than a different strip level here.
    if(arg_PATCHES)
        if(arg_PATCH_COMMAND)
            message(FATAL_ERROR "sessiondep_build_external(${target}): PATCHES and PATCH_COMMAND are mutually exclusive")
        endif()
        foreach(patch IN LISTS arg_PATCHES)
            set(patch_path "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/patches/${patch}")
            if(NOT EXISTS "${patch_path}")
                message(FATAL_ERROR "sessiondep_build_external(${target}): no such patch: ${patch_path}")
            endif()
            if(arg_PATCH_COMMAND)
                list(APPEND arg_PATCH_COMMAND COMMAND)
            endif()
            list(APPEND arg_PATCH_COMMAND ${sessiondeps_patch} -p1 -i "${patch_path}")
        endforeach()
    endif()

    set(build_def_DEPENDS "")
    set(build_def_PATCH_COMMAND "")
    set(build_def_CONFIGURE_COMMAND ./configure ${sessiondeps_cross_host} --disable-shared --prefix=${SESSIONDEPS_DESTDIR} --with-pic
        "CC=${sessiondeps_cc}" "CXX=${sessiondeps_cxx}" "CFLAGS=${sessiondeps_CFLAGS}" "CXXFLAGS=${sessiondeps_CXXFLAGS}" ${sessiondeps_cross_rc})
    set(build_def_BUILD_COMMAND ${sessiondeps_make})
    set(build_def_INSTALL_COMMAND ${sessiondeps_make} install)
    if(target MATCHES "^lib(.*)")
        set(_sdep_lib_prefix "")
        set(_sdep_base_name "${CMAKE_MATCH_1}")
    else()
        set(_sdep_lib_prefix "lib")
        set(_sdep_base_name "${target}")
    endif()
    set(build_def_BUILD_BYPRODUCTS ${SESSIONDEPS_DESTDIR}/lib/${_sdep_lib_prefix}___TARGET___.a ${SESSIONDEPS_DESTDIR}/include/${_sdep_base_name}.h)

    # Recorded before the defaults are filled in below, so that DEFAULT_CMAKE can tell a recipe's
    # own build/install command apart from the autotools default it would otherwise ignore.
    set(_explicit_build ${arg_BUILD_COMMAND})
    set(_explicit_install ${arg_INSTALL_COMMAND})

    foreach(o ${options})
        if(NOT DEFINED arg_${o})
            set(arg_${o} ${build_def_${o}})
        endif()
    endforeach()
    string(REPLACE ___TARGET___ ${target} arg_BUILD_BYPRODUCTS "${arg_BUILD_BYPRODUCTS}")

    if(arg_CONFIGURE_COMMAND MATCHES "^DEFAULT_CMAKE")
        # GNUInstallDirs resolves libdir to lib64 on Fedora/openSUSE and lib/<triplet> on Debian,
        # neither of which is where sessiondep_static_target() looks.  Pin it, as the meson path
        # does with --libdir.
        #
        # The build type is pinned too, as the meson path does with --buildtype: with none set, cmake
        # adds no optimisation flags at all, so a project that does not supply its own default
        # (jpegli does not) silently builds unoptimised.  A recipe's own -DCMAKE_BUILD_TYPE comes
        # later on the command line and overrides this.
        #
        # PIC because these archives end up inside shared objects; a PIE-default compiler hides a
        # missing one until that link.
        set(_default_cmake_args
            "-DCMAKE_INSTALL_PREFIX=${arg_PREFIX}"
            "-DCMAKE_INSTALL_LIBDIR=lib"
            "-DCMAKE_BUILD_TYPE=Release"
            "-DCMAKE_POSITION_INDEPENDENT_CODE=ON")
        if(sessiondeps_cmake_toolchain_args)
            list(APPEND _default_cmake_args ${sessiondeps_cmake_toolchain_args})
        endif()
        if(sessiondeps_cmake_osx_args)
            list(APPEND _default_cmake_args ${sessiondeps_cmake_osx_args})
        endif()
        string(REGEX REPLACE "^DEFAULT_CMAKE(;?)" "CMAKE_ARGS;${_default_cmake_args}\\1" configure "${arg_CONFIGURE_COMMAND}")
        # Empty means ExternalProject's own `cmake --build` and `cmake --install`; a recipe whose
        # project cannot be built or installed that way (jpegli: the library is EXCLUDE_FROM_ALL and
        # has no install rule) supplies its own.
        set(build "")
        set(install "")
        if(_explicit_build)
            set(build BUILD_COMMAND ${_explicit_build})
        endif()
        if(_explicit_install)
            set(install INSTALL_COMMAND ${_explicit_install})
        endif()
        # CMake projects build out-of-source, and some (utf8proc) refuse in-source outright.
        set(in_source OFF)
    elseif(arg_CONFIGURE_COMMAND MATCHES "^DEFAULT_MESON")
        if(NOT sessiondeps_meson OR NOT sessiondeps_ninja)
            message(FATAL_ERROR "sessiondep_build_external(${target}): ${sessiondeps_meson_missing}")
        endif()

        string(REGEX REPLACE "^DEFAULT_MESON;?" "" _meson_extra "${arg_CONFIGURE_COMMAND}")

        set(_meson_cross_arg)
        if(sessiondeps_meson_cross)
            set(_meson_cross_arg --cross-file ${sessiondeps_meson_cross})
        endif()

        # A project with Objective-C sources compiles them with objc_args, and links anything
        # containing them with objc_link_args -- glib has .m files on Apple, so even its C-only
        # executables link as Objective-C.  Without these the objc code misses the -arch/-isysroot
        # an iOS cross build puts in the C flags, and the link misses the destdir's -L.  meson
        # accepts them for projects that do not enable Objective-C.
        set(_meson_objc_args)
        if(APPLE)
            set(_meson_objc_args
                -Dobjc_args=${sessiondeps_CFLAGS}
                -Dobjc_link_args=${sessiondeps_ldflags})
        endif()

        # --wrap-mode=nodownload is what keeps a meson dep honest: left to itself meson silently
        # fetches a missing dependency from WrapDB at configure time, which would pull in code that
        # never passed through our hash-pinned tarballs.  Subprojects already vendored in the
        # tarball (glib ships gvdb this way) still resolve.
        set(configure CONFIGURE_COMMAND ${CMAKE_COMMAND} -E env
            "PKG_CONFIG_LIBDIR=${sessiondeps_pkg_config_libdir}"
            "CC=${sessiondeps_cc}" "CXX=${sessiondeps_cxx}"
            ${sessiondeps_meson} setup <BINARY_DIR> <SOURCE_DIR>
                --prefix=${arg_PREFIX}
                --libdir=lib
                --default-library=static
                --buildtype=release
                --wrap-mode=nodownload
                # --default-library only governs what this project builds; without prefer_static,
                # meson still resolves its *dependencies* with a plain `pkg-config --libs`, which
                # omits Requires.private and Libs.private.  Those are exactly where a static
                # library records what it needs -- libheif.pc puts libde265 and dav1d there -- so
                # the link fails on symbols from a dependency's dependency.  It also picks up
                # Cflags.private, which is where a library hides its "I am static" define for
                # Windows.
                -Dprefer_static=true
                -Dc_args=${sessiondeps_CFLAGS}
                -Dcpp_args=${sessiondeps_CXXFLAGS}
                -Dc_link_args=${sessiondeps_ldflags}
                -Dcpp_link_args=${sessiondeps_ldflags}
                ${_meson_objc_args}
                ${_meson_cross_arg}
                ${_meson_extra})
        set(build BUILD_COMMAND ${sessiondeps_ninja} -C <BINARY_DIR>)
        # Install only what a consumer links against.  meson offers no way to avoid *building* a
        # project's command line tools, but nothing here runs them, and statically linked they
        # dwarf the libraries -- libvips' four are 19MB each.
        #
        # bin-devel is needed alongside devel: it is the tag glib puts on glib-mkenums and
        # glib-genmarshal, which are not end-user tools but build tools that libvips invokes
        # through gnome.mkenums().  meson locates them via glib-2.0.pc's own `glib_mkenums`
        # variable and treats a path that does not exist as a fatal packaging error, so omitting
        # them fails libvips' configure rather than falling back to a copy on PATH.
        set(install INSTALL_COMMAND
            ${sessiondeps_meson} install -C <BINARY_DIR> --tags devel,bin-devel --no-rebuild)
        set(in_source OFF)
    else()
        set(configure CONFIGURE_COMMAND ${arg_CONFIGURE_COMMAND})
        set(build BUILD_COMMAND ${arg_BUILD_COMMAND})
        set(install INSTALL_COMMAND ${arg_INSTALL_COMMAND})
        # The default configure command above is a relative ./configure, which resolves only with
        # the source directory as the working directory.
        set(in_source ON)
    endif()

    set(no_idiotic_extract)
    if(NOT CMAKE_VERSION VERSION_LESS 3.24)
        # CMake 3.24 ExternalProject changed the default to "don't extract timestamps" by default that
        # wipes out all the timestamps of extracted packages, breaking pretty much all autotools
        # packages.  That's a exceptionally brilliant default for an "external project" builder, thanks
        # so much CMake!  (see cmake issue #24003)
        set(no_idiotic_extract DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
    endif()

    # For any sessiondep::TGT things we have listed in DEPENDS we have to convert to the raw name (if
    # it exists), because in the sessiondep::TGT form cmake helpfully just assumes things are built
    # instantly, because god forbid cmake adds a feature without massive gotchas.
    set(fixed_depends)
    foreach(dep IN LISTS arg_DEPENDS)
        if(dep MATCHES "^sessiondep::(.*)")
            set(tgt "sessiondep_${CMAKE_MATCH_1}_external")
            if(TARGET ${tgt})
                list(APPEND fixed_depends "sessiondep_${CMAKE_MATCH_1}_external")
            else()
                message(DEBUG "${tgt} not found for ${dep}, probably a secondary target?")
            endif()
        else()
            list(APPEND fixed_depends "${dep}")
        endif()
    endforeach()

    string(TOUPPER "${target}" prefix)

    if(NOT ${prefix}_SOURCE)
        message(FATAL_ERROR "Unable to build ${target}: ${prefix}_SOURCE not set")
    endif()

    if(CMAKE_VERSION VERSION_LESS 3.20)
        # cmake <3.20 has scoping issues with ExternalProject_Add that makes it throw a fatal error
        # if the include was outside this function, so we have to include it here every time to
        # workaround cmake's buggy older design.
        include(ExternalProject)
    endif()

    # The byproducts are files in the destdir, which the install step writes, not the build step.
    # Declared on the build step, ninja re-stats them once it finishes, finds them unchanged, and
    # prunes everything downstream -- so rebuilding a dependency never relinks what uses it.
    # INSTALL_BYPRODUCTS is 3.26+; older cmake keeps the old, clean-build-only behaviour.
    set(byproducts_kw BUILD_BYPRODUCTS)
    if(NOT CMAKE_VERSION VERSION_LESS 3.26)
        set(byproducts_kw INSTALL_BYPRODUCTS)
    endif()

    sessiondep_expand_urls(urls ${${prefix}_SOURCE} ${LOCAL_MIRROR} ${${prefix}_MIRROR})
    ExternalProject_Add("sessiondep_${target}_external"
        DEPENDS ${fixed_depends}
        BUILD_IN_SOURCE ${in_source}
        PREFIX ${SESSIONDEPS_SOURCEDIR}
        URL ${urls}
        URL_HASH ${${prefix}_HASH}
        ${no_idiotic_extract}
        DOWNLOAD_NO_PROGRESS ON
        PATCH_COMMAND ${arg_PATCH_COMMAND}
        ${configure}
        ${build}
        ${install}
        ${byproducts_kw} ${arg_BUILD_BYPRODUCTS}
    )
endfunction()
