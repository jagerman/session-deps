set(LIBMICROHTTPD_VERSION 1.0.10)
set(LIBMICROHTTPD_MIRROR https://ftp.gnu.org/gnu/libmicrohttpd)
set(LIBMICROHTTPD_SOURCE libmicrohttpd-${LIBMICROHTTPD_VERSION}.tar.gz)
set(LIBMICROHTTPD_HASH SHA512=b67458fad556fa0b73edf728efbc30a2304c544d98409b9efbdda5ebfb6668b31c1c96620eac33994ade1255f8170cd4628f0a61b57a9cef255d4980110b362f)


session_dep(gnutls 3.6)

# configure link-tests gnutls with a bare -lgnutls, which a static gnutls cannot satisfy on its own
# (its nettle/hogweed/gmp/tasn1/idn2 halves are separate archives), so hand it the link line cmake
# already resolved for sessiondep::gnutls -- correct whether gnutls was built here or found on the
# system.  Same approach as libcurl.cmake.
sessiondep_link_flags(mhd_tls_libs sessiondep::gnutls)
list(JOIN mhd_tls_libs " " mhd_tls_libs)

# gnutls.h marks its exported data __declspec(dllimport) on Windows unless GNUTLS_INTERNAL_BUILD is
# defined, so code compiled against it looks for __imp_gnutls_malloc and friends -- which only a DLL
# provides, and we build gnutls static.  gnutls offers no other switch for this; defining its
# internal-build macro in a consumer is what MSYS2 does for the same reason (MINGW-packages#10464).
set(mhd_gnutls_static_cppflags)
if(WIN32)
    set(mhd_gnutls_static_cppflags " -DGNUTLS_INTERNAL_BUILD")
endif()

# Apple's 27 SDKs declare pipe2 as available from iOS/macOS 27 only, and configure's check cannot see
# availability, so with any older deployment target the daemon would call a weakly linked pipe2 that
# is null below 27.  Its pipe() and fcntl() fallback is used wherever pipe2 is missing.
set(mhd_configure_vars)
if(APPLE)
    list(APPEND mhd_configure_vars mhd_cv_works_func_pipe2=no)
endif()

# Only the core HTTP(S) server is built: the authentication, form post-processing, cookie and
# HTTP-upgrade layers are optional features that nothing here uses, and each is request-parsing
# surface that has had its own security fixes.
#
# Unlike most recipes this one is routinely built statically on systems where gnutls is *not*: no
# current Debian/Ubuntu release ships a new enough libmicrohttpd, but all of them have gnutls.  So
# pkg-config gets the static destdir prepended (PKG_CONFIG_PATH) rather than substituted
# (PKG_CONFIG_LIBDIR), letting configure find whichever gnutls sessiondep::gnutls resolved to.
sessiondep_build_external(libmicrohttpd
    CONFIGURE_COMMAND ./configure ${sessiondeps_cross_host} --prefix=${SESSIONDEPS_DESTDIR} --with-pic
    --disable-shared --enable-static
    --enable-https --with-gnutls
    --disable-doc --disable-examples --disable-curl
    --disable-bauth --disable-dauth --disable-postprocessor --disable-httpupgrade --disable-cookie
    "PKG_CONFIG_PATH=${SESSIONDEPS_DESTDIR}/lib/pkgconfig" "PKG_CONFIG=pkg-config"
    "CPPFLAGS=-I${SESSIONDEPS_DESTDIR}/include${mhd_gnutls_static_cppflags}"
    "LDFLAGS=${sessiondeps_ldflags}"
    "LIBS=${mhd_tls_libs}"
    "CC=${sessiondeps_cc}" "CXX=${sessiondeps_cxx}"
    "CFLAGS=${sessiondeps_CFLAGS}" "CXXFLAGS=${sessiondeps_CXXFLAGS}"
    ${sessiondeps_cross_rc}
    ${mhd_configure_vars}
    DEPENDS sessiondep::gnutls
    # In epoll mode a TLS handshake that has to wait for the client leaves the connection marked
    # read-ready, so the daemon busy-waits and re-runs the handshake until the client's next
    # flight arrives (or the connection times out).  Present through at least 1.0.10.
    PATCHES libmicrohttpd-epoll-tls-handshake-spin.patch
)

sessiondep_static_simple(libmicrohttpd sessiondep::gnutls)
