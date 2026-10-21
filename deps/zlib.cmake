set(ZLIB_VERSION 1.3.2)
set(ZLIB_MIRROR https://zlib.net)
set(ZLIB_SOURCE zlib-${ZLIB_VERSION}.tar.xz)
set(ZLIB_HASH SHA256=d7a0654783a4da529d1bb793b7ad9c3318020af77667bcae35f95d0e42a792f3)


# **zlib's configure takes its platform from `uname`, not from `--host`,** and on a Darwin build
# machine it replaces `AR` with Apple's libtool. Cross-compiling for anything but Apple, that writes
# the target's objects into an archive with no symbol index lld can read, and the failure only shows
# when something links against libz.a. `--uname` names the target instead; `CHOST` would too, but
# it also prefixes every tool configure looks for, and the NDK ships no `<triple>-nm`.
set(zlib_uname "")
if(CMAKE_HOST_APPLE AND NOT APPLE AND sessiondeps_cross_host)
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
