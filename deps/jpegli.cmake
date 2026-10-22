# jpegli has never made a release, so this pins a commit.  GitHub serves a commit's tarball at any
# filename under archive/COMMIT/, so the name carries the commit date for the deps cache and mirrors.
set(JPEGLI_COMMIT 031a0077f5799a6041004267fc12b956c1f52a20)
set(JPEGLI_VERSION 0.0.0.20260601)
set(JPEGLI_MIRROR https://github.com/google/jpegli/archive/${JPEGLI_COMMIT})
set(JPEGLI_SOURCE jpegli-20260601-031a007.tar.gz)
set(JPEGLI_HASH SHA512=4d57baf7ff88a2a40f46dc0c4fe121df1455064ad36c3a6a479e6536f02c9e436088fb15462336f65bc5c7c6dda54bb740e1c05744399c834aa88a36c6635db9)

# Only jpegli's core library (its jpegli_* API) is built: not the libjpeg-compatible library, which
# would define jpeg_* symbols clashing with libjpeg-turbo, and none of the tools.  It is an encoder
# for pixels we have already decoded, so it never parses untrusted input.

# The core library links highway; lcms2 is only needed because jpegli's configure refuses to run
# without a colour management library, though nothing built here links it.
session_dep(libhwy 1.0.7)
session_dep(lcms2 2.12)
find_package(Threads REQUIRED)

# jpegli's find modules search the system before our destdir (and its pkg-config lookup sees only
# the system), so when highway or lcms2 was built here, point jpegli straight at our copies:
# compiling against a system highway's headers while linking ours would be a silent mismatch.
set(jpegli_dep_args)
if(TARGET sessiondep_ext_libhwy)
    list(APPEND jpegli_dep_args
        -DHWY_INCLUDE_DIR=${SESSIONDEPS_DESTDIR}/include
        -DHWY_LIBRARY=${SESSIONDEPS_DESTDIR}/lib/libhwy.a)
endif()
if(TARGET sessiondep_ext_lcms2)
    list(APPEND jpegli_dep_args
        -DLCMS2_INCLUDE_DIR=${SESSIONDEPS_DESTDIR}/include
        -DLCMS2_LIBRARY=${SESSIONDEPS_DESTDIR}/lib/liblcms2.a)
endif()

set(jpegli_include ${SESSIONDEPS_DESTDIR}/include/jpegli)

sessiondep_build_external(jpegli
    # The tarball has no submodule contents, and jpegli takes libjpeg's API declarations from its
    # libjpeg-turbo submodule; see extra/jpegli/libjpeg-turbo/README.md.
    PATCH_COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${CMAKE_CURRENT_LIST_DIR}/extra/jpegli/libjpeg-turbo <SOURCE_DIR>/third_party/libjpeg-turbo
    CONFIGURE_COMMAND DEFAULT_CMAKE
      -DBUILD_SHARED_LIBS=OFF
      -DBUILD_TESTING=OFF
      -DJPEGLI_ENABLE_TOOLS=OFF
      -DJPEGLI_ENABLE_JPEGLI_LIBJPEG=OFF
      -DJPEGLI_ENABLE_DEVTOOLS=OFF
      -DJPEGLI_ENABLE_BENCHMARK=OFF
      -DJPEGLI_ENABLE_FUZZERS=OFF
      -DJPEGLI_ENABLE_JNI=OFF
      -DJPEGLI_ENABLE_SJPEG=OFF
      -DJPEGLI_ENABLE_OPENEXR=OFF
      -DJPEGLI_ENABLE_SKCMS=OFF
      -DJPEGLI_ENABLE_DOXYGEN=OFF
      -DJPEGLI_ENABLE_MANPAGES=OFF
      -DJPEGLI_BUNDLE_LIBPNG=OFF
      -DCMAKE_DISABLE_FIND_PACKAGE_PNG=ON
      -DJPEGLI_FORCE_SYSTEM_HWY=ON
      -DJPEGLI_FORCE_SYSTEM_LCMS2=ON
      ${jpegli_dep_args}
    # The core library is EXCLUDE_FROM_ALL and has no install rule, so it is built by name and its
    # API headers installed by hand, under include/jpegli; see below for why they are kept apart.
    BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --target jpegli-static
    INSTALL_COMMAND
      ${CMAKE_COMMAND} -E make_directory ${jpegli_include}/lib/jpegli ${jpegli_include}/lib/base
      COMMAND ${CMAKE_COMMAND} -E copy <BINARY_DIR>/lib/libjpegli-static.a ${SESSIONDEPS_DESTDIR}/lib/libjpegli.a
      COMMAND ${CMAKE_COMMAND} -E copy
        <SOURCE_DIR>/lib/jpegli/encode.h <SOURCE_DIR>/lib/jpegli/common.h <SOURCE_DIR>/lib/jpegli/types.h
        ${jpegli_include}/lib/jpegli/
      COMMAND ${CMAKE_COMMAND} -E copy <SOURCE_DIR>/lib/base/include_jpeglib.h ${jpegli_include}/lib/base/
      COMMAND ${CMAKE_COMMAND} -E copy
        <BINARY_DIR>/lib/include/jpegli/jpeglib.h <BINARY_DIR>/lib/include/jpegli/jmorecfg.h
        <BINARY_DIR>/lib/include/jpegli/jconfig.h
        ${jpegli_include}/
    DEPENDS sessiondep::libhwy sessiondep::lcms2
    BUILD_BYPRODUCTS
      ${SESSIONDEPS_DESTDIR}/lib/libjpegli.a
      ${jpegli_include}/lib/jpegli/encode.h
)

# jpegli's headers include <jpeglib.h> expecting its own copy, installed alongside them, and the
# struct sizes it checks at runtime depend on that copy's JPEG_LIB_VERSION -- 62 here, where a
# libjpeg-turbo built with the libjpeg 8 API (MacPorts') says 80, and jpegli then refuses every
# call.  So its directory has to win over every other jpeglib.h: libjpeg-turbo's in our include/, or
# a system one that any other dependency's include directory can bring in (/opt/local/include).
#
# -I is searched before every -isystem, which settles that regardless of order, but cmake makes an
# IMPORTED target's include directories -isystem (overridable only from 3.23).  Those of a plain
# INTERFACE library stay -I, so the headers get one of their own.
add_library(sessiondep_ext_jpegli_headers INTERFACE)
target_include_directories(sessiondep_ext_jpegli_headers INTERFACE ${jpegli_include})

sessiondep_static_simple(jpegli sessiondep_ext_jpegli_headers sessiondep::libhwy Threads::Threads)
set_target_properties(sessiondep_ext_jpegli PROPERTIES IMPORTED_LINK_INTERFACE_LANGUAGES CXX)
