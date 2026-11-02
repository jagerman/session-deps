set(LIBIDN2_VERSION 2.3.8)
set(LIBIDN2_MIRROR https://ftp.gnu.org/gnu/libidn)
set(LIBIDN2_SOURCE libidn2-${LIBIDN2_VERSION}.tar.gz)
set(LIBIDN2_HASH SHA512=4d8427c0f115268132f7544e80a808c883ab1406338f6c529b1a586b016d57aedb0857f66166eb8d9f37d70efc9dccf907b673b43b17bcf258c8797db1e829ce)

session_dep(libunistring 0.9)

# Apple's SDKs declare strchrnul as available from iOS/macOS 18.4 only. Configure's link test cannot
# see availability, so it finds strchrnul and idn2_lookup then calls it unconditionally: with any
# older deployment target the symbol is weakly linked and null below 18.4. gnulib's "future OS
# version" result is what makes it compile its own copy, as a private rpl_strchrnul, and point the
# call there; ac_cv_func_strchrnul=no alone still leaves lookup.c calling the SDK's declaration
# weakly and adds a global strchrnul to the archive.
set(libidn2_configure_vars)
if(APPLE)
    list(APPEND libidn2_configure_vars gl_cv_onwards_func_strchrnul=future)
endif()

sessiondep_build_external(libidn2
    # Patch out building the tools because they make a compilation with -flto take a very long time:
    PATCHES libidn2-no-tools.patch
    CONFIGURE_COMMAND ./configure ${sessiondeps_cross_host} --disable-shared --disable-doc --prefix=${SESSIONDEPS_DESTDIR} --with-pic
        --disable-nls
        "CC=${sessiondeps_cc}" "CXX=${sessiondeps_cxx}"
        "CFLAGS=${sessiondeps_CFLAGS}"
        "CXXFLAGS=${sessiondeps_CXXFLAGS}"
        ${sessiondeps_cross_rc}
        ${libidn2_configure_vars}
    DEPENDS sessiondep::libunistring
    BUILD_BYPRODUCTS ${SESSIONDEPS_DESTDIR}/lib/libidn2.a ${SESSIONDEPS_DESTDIR}/include/idn2.h)

sessiondep_static_simple(libidn2 sessiondep::libunistring)
