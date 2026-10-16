set(LIBEVENT_VERSION 2.1.13-stable)
set(LIBEVENT_MIRROR https://github.com/libevent/libevent/releases/download/release-${LIBEVENT_VERSION})
set(LIBEVENT_SOURCE libevent-${LIBEVENT_VERSION}.tar.gz)
set(LIBEVENT_HASH SHA512=5c7a1b9f48087258f49653ecb4ce24d7015a9ef4015ad6ffa910a101d5bd37c657c26fc948eaae30c4abeb54d1cda33290878161bd73bb50e4e85f7dc667c36d)


# libevent doesn't like --host=arm64-whatever, but is okay with aarch64-whatever
set(libevent_build_host "${sessiondeps_cross_host}")
if(libevent_build_host MATCHES "(.*--host=)arm64-(.*)")
    set(libevent_build_host "${CMAKE_MATCH_1}aarch64-${CMAKE_MATCH_2}")
endif()

# Apple's 27 SDKs declare pipe2 as available from iOS/macOS 27 only. Configure's link test cannot
# see availability, so it finds pipe2 and libevent then calls it unconditionally: with any older
# deployment target the symbol is weakly linked and null below 27, and the first event loop crashes
# at a call through a null pointer. The pipe() and fcntl() fallback costs nothing, so pipe2 is
# never used on Apple platforms.
set(libevent_configure_vars)
if(APPLE)
    list(APPEND libevent_configure_vars ac_cv_func_pipe2=no)
endif()

set(lib_pthreads ${SESSIONDEPS_DESTDIR}/lib/libevent_pthreads.a)
if(WIN32)
    set(lib_pthreads)
endif()

sessiondep_build_external(libevent
    CONFIGURE_COMMAND ./configure ${libevent_build_host} --prefix=${SESSIONDEPS_DESTDIR}
    --enable-static --disable-shared --with-pic
    --disable-openssl --disable-libevent-regress --disable-samples
    "CPPFLAGS=-I${SESSIONDEPS_DESTDIR}/include" "LDFLAGS=${sessiondeps_ldflags}"
    "CC=${sessiondeps_cc}"
    "CXX=${sessiondeps_cxx}"
    "CFLAGS=${sessiondeps_CFLAGS}"
    "CXXFLAGS=${sessiondeps_CXXFLAGS}"
    ${sessiondeps_cross_rc}
    ${libevent_configure_vars}
    BUILD_BYPRODUCTS
    ${SESSIONDEPS_DESTDIR}/lib/libevent_core.a
    ${lib_pthreads}
    ${SESSIONDEPS_DESTDIR}/include/event2/event.h
)

sessiondep_static_target(sessiondep_ext_libevent_core libevent libevent_core.a)

if(lib_pthreads)
    sessiondep_static_target(sessiondep_ext_libevent_pthreads libevent libevent_pthreads.a)
else()
    # On windows we don't actually use pthreads but just adding a fake pthreads library makes
    # linking this much easier in various deps.
    add_library(sessiondep_ext_libevent_pthreads INTERFACE)
endif()
