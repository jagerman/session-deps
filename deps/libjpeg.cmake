set(LIBJPEG_VERSION 3.2.0)
set(LIBJPEG_MIRROR https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${LIBJPEG_VERSION})
set(LIBJPEG_SOURCE libjpeg-turbo-${LIBJPEG_VERSION}.tar.gz)
set(LIBJPEG_HASH SHA512=13536db56c16e5364690ae2d31343a203e3b653c853c1f5314d36c8eb06700e92342737f1381f0171b3eb0223384c5fbcde91b55a46576952c4e75dc049cd045)

# Without REQUIRE_SIMD a build that cannot produce its SIMD kernels prints a warning and produces a
# markedly slower library anyway, so where they ought to build -- x86 with nasm, and Arm, whose
# kernels are intrinsics -- a SIMD failure should stop the build.  Elsewhere (s390x, say)
# libjpeg-turbo has no SIMD code at all, and requiring it is a configure error.
sessiondep_nasm_missing(libjpeg_no_nasm libjpeg-turbo "JPEG decoding")
set(libjpeg_require_simd FALSE)
if(sessiondeps_cpu_family MATCHES "^(x86|x86_64|arm|aarch64)$" AND NOT libjpeg_no_nasm)
    set(libjpeg_require_simd TRUE)
endif()

sessiondep_build_external(libjpeg
    CONFIGURE_COMMAND DEFAULT_CMAKE
      -DENABLE_SHARED=FALSE -DENABLE_STATIC=TRUE
      -DWITH_TURBOJPEG=FALSE -DWITH_TOOLS=FALSE -DWITH_TESTS=FALSE
      -DWITH_12BIT=FALSE
      -DREQUIRE_SIMD=${libjpeg_require_simd}
    BUILD_BYPRODUCTS
      ${SESSIONDEPS_DESTDIR}/lib/libjpeg.a
      ${SESSIONDEPS_DESTDIR}/include/jpeglib.h
)

sessiondep_static_simple(libjpeg)
