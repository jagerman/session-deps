set(VIPS_VERSION 8.18.6)
set(VIPS_MIRROR https://github.com/libvips/libvips/releases/download/v${VIPS_VERSION})
set(VIPS_SOURCE vips-${VIPS_VERSION}.tar.xz)
set(VIPS_HASH SHA512=0a0127aa941eb8d3ce72d80c43287e402059532ba4f241962fd22ccdb2d525997f5bba6bb4bc89eb28710403cbcff2b6d24df904aaa61639ea5b14742fee91e4)

session_dep(glib-2.0 2.52 WITH gobject-2.0 gio-2.0 gmodule-2.0)
session_dep(expat 2)

session_dep(libjpeg 2)
session_dep(spng 0.7)
session_dep(libwebp 0.6 WITH libwebpmux libwebpdemux)
session_dep(libexif 0.6.22)
session_dep(lcms2 2)
session_dep(libhwy 1.0.5)
session_dep(libheif 1.20)
session_dep(cgif 0.2)
session_dep(imagequant 2)

# Every feature option is listed, including the ones being turned off: 37 of libvips' 38 default to
# 'auto', so the set of formats compiled in would otherwise depend on which -dev packages happen to
# be installed on the build host.  Since vips_foreign_find_load_buffer() selects a loader by
# sniffing content with is_a_buffer() and never by filename, a format compiled in is reachable from
# any input regardless of its name or declared type.
#
# png is off so that spng is used: libvips takes libpng in preference whenever it finds one.  Both
# register the same `pngload` operation, so the operation table cannot distinguish them -- check
# HAVE_SPNG in the generated config.h instead.
#
# Re-check this list on a version bump; a newly added option defaults to 'auto' like the rest.
#
# glib's headers include <libintl.h>, which on some targets comes from a provider outside the
# destdir.
sessiondep_providers_meson_args(vips_providers_meson)

sessiondep_build_external(vips
    PATCHES vips-no-tools-test-fuzz.patch
    CONFIGURE_COMMAND DEFAULT_MESON
      # --- core ---
      -Ddeprecated=false
      -Dexamples=false
      -Dcplusplus=true
      -Dcpp-docs=false
      -Ddocs=false
      -Dmodules=disabled
      -Dintrospection=disabled
      -Dvapi=false
      # --- formats we support ---
      -Djpeg=enabled
      -Dspng=enabled
      -Dwebp=enabled
      -Dheif=enabled
      -Dcgif=enabled
      -Dimagequant=enabled
      -Dexif=enabled
      -Dlcms=enabled
      -Dhighway=enabled
      -Dzlib=enabled
      -Dnsgif=true
      # --- everything else, explicitly off ---
      -Dpng=disabled
      -Dtiff=disabled
      -Drsvg=disabled
      -Dmagick=disabled
      -Dmagick-module=disabled
      -Dpoppler=disabled
      -Dpoppler-module=disabled
      -Dpdfium=disabled
      -Dopenslide=disabled
      -Dopenslide-module=disabled
      -Djpeg-xl=disabled
      -Djpeg-xl-module=disabled
      -Dheif-module=disabled
      -Duhdr=disabled
      -Draw=disabled
      -Dopenjpeg=disabled
      -Dopenexr=disabled
      -Dcfitsio=disabled
      -Dmatio=disabled
      -Dnifti=disabled
      -Darchive=disabled
      -Dfftw=disabled
      -Dfontconfig=disabled
      -Dpangocairo=disabled
      -Dorc=disabled
      # libvips falls back to quantizr only when imagequant is absent; pinned off so the quantiser
      # in use cannot change silently.
      -Dquantizr=disabled
      -Dppm=false
      -Danalyze=false
      -Dradiance=false
      ${vips_providers_meson}
    DEPENDS
      sessiondep::glib-2.0 sessiondep::expat
      sessiondep::libjpeg sessiondep::spng sessiondep::libwebp sessiondep::libexif
      sessiondep::lcms2 sessiondep::libhwy sessiondep::libheif
      sessiondep::cgif sessiondep::imagequant
    BUILD_BYPRODUCTS
      ${SESSIONDEPS_DESTDIR}/lib/libvips.a
      ${SESSIONDEPS_DESTDIR}/lib/libvips-cpp.a
      ${SESSIONDEPS_DESTDIR}/include/vips/vips.h
)

sessiondep_static_target(sessiondep_ext_vips vips libvips.a
    sessiondep::glib-2.0 sessiondep::gobject-2.0 sessiondep::gio-2.0 sessiondep::gmodule-2.0
    sessiondep::expat
    sessiondep::libjpeg sessiondep::spng
    sessiondep::libwebp sessiondep::libwebpmux sessiondep::libwebpdemux
    sessiondep::libexif sessiondep::lcms2 sessiondep::libhwy
    sessiondep::libheif sessiondep::cgif sessiondep::imagequant)

# The C++ binding is a separate archive that calls into the C one, so it has to come first.
sessiondep_static_target(sessiondep_ext_vips-cpp vips libvips-cpp.a sessiondep_ext_vips)

# Never `include/vips` on the include path: its semaphore.h would shadow the system <semaphore.h>.
# libvips' headers reach each other as <vips/...>, or quoted from beside themselves.
foreach(tgt sessiondep_ext_vips sessiondep_ext_vips-cpp)
    set_target_properties(${tgt} PROPERTIES IMPORTED_LINK_INTERFACE_LANGUAGES CXX)
endforeach()
