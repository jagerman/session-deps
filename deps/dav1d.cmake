set(DAV1D_VERSION 1.5.4)
set(DAV1D_MIRROR https://downloads.videolan.org/pub/videolan/dav1d/${DAV1D_VERSION})
set(DAV1D_SOURCE dav1d-${DAV1D_VERSION}.tar.xz)
set(DAV1D_HASH SHA512=75ab7c922bc9647d73534c9f6c95a514748557adbf7a4debf95eee52ef1db681012cbaad165a46141d904cdd01c1e6319cdea33d254afb5c6b3d968679e55b98)

# dav1d treats a missing nasm as a hard error rather than falling back, so asm has to be turned off
# explicitly when there is none.  Only x86 needs nasm: elsewhere dav1d's assembly goes through the C
# compiler.
sessiondep_nasm_missing(dav1d_no_nasm dav1d "AVIF decoding")
set(dav1d_asm true)
if(dav1d_no_nasm)
    set(dav1d_asm false)
endif()

sessiondep_build_external(dav1d
    CONFIGURE_COMMAND DEFAULT_MESON
      -Denable_asm=${dav1d_asm}
      -Denable_tools=false
      -Denable_tests=false
      -Denable_examples=false
    BUILD_BYPRODUCTS
      ${SESSIONDEPS_DESTDIR}/lib/libdav1d.a
      ${SESSIONDEPS_DESTDIR}/include/dav1d/dav1d.h
)

set(dav1d_threads)
if(NOT WIN32)
    find_package(Threads REQUIRED)
    set(dav1d_threads Threads::Threads)
endif()
sessiondep_static_simple(dav1d ${dav1d_threads})
