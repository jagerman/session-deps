set(ZLIB_VERSION 1.3.2)
set(ZLIB_MIRROR https://zlib.net)
set(ZLIB_SOURCE zlib-${ZLIB_VERSION}.tar.xz)
set(ZLIB_HASH SHA256=d7a0654783a4da529d1bb793b7ad9c3318020af77667bcae35f95d0e42a792f3)


# **zlib's configure takes its platform from `uname`, not from `--host`,** so a cross build has to
# name the target itself, as libssl's does; `--uname` is its spelling of `--host`. Left to guess, it
# reads the build machine: on a mac it then replaces `AR` with Apple's libtool, which archives an
# Android build's objects with no symbol index lld can read, failing only when something links
# against libz.a. Apple targets keep the guess, which is what builds them with that libtool. `CHOST`
# would also name the target, but it prefixes every tool configure looks for, and the NDK ships no
# `<triple>-nm`.
set(zlib_uname "")
if(sessiondeps_cross_host AND NOT APPLE)
    string(REPLACE "--host=" "--uname=" zlib_uname "${sessiondeps_cross_host}")
endif()

sessiondep_build_external(zlib
    CONFIGURE_COMMAND
    ${CMAKE_COMMAND} -E env "CC=${sessiondeps_cc}" "CFLAGS=${sessiondeps_CFLAGS} -fPIC" ${sessiondeps_cross_rc}
    ./configure --prefix=${SESSIONDEPS_DESTDIR} --static ${zlib_uname}
    BUILD_BYPRODUCTS
    ${SESSIONDEPS_DESTDIR}/lib/libz.a
    ${SESSIONDEPS_DESTDIR}/include/zlib.h
)
sessiondep_static_target(sessiondep_ext_zlib zlib libz.a)
