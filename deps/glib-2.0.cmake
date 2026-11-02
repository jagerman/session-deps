set(GLIB-2.0_VERSION 2.90.0)
string(REGEX REPLACE "^([0-9]+\\.[0-9]+).*" "\\1" GLIB-2.0_SERIES ${GLIB-2.0_VERSION})
set(GLIB-2.0_MIRROR https://download.gnome.org/sources/glib/${GLIB-2.0_SERIES})
set(GLIB-2.0_SOURCE glib-${GLIB-2.0_VERSION}.tar.xz)
set(GLIB-2.0_HASH SHA512=5ca18b4e89d0efef40d6921c33903cad242ac664e4125e8161fa7d0f0c9c65c9a7ff61d9e3ac3eb7b780b7e113392a87d12b402000f8af76b8050ddae26d0a01)

session_dep(libffi 3.0)
session_dep(libpcre2-8 10.32)
session_dep(zlib 1.2)

find_package(Threads REQUIRED)

# glib calls dependency('intl') unconditionally -- -Dnls=disabled only gates xgettext -- and, except
# on Windows where it bundles win_iconv.c, dependency('iconv').  meson resolves both from the C
# library when it provides them, and otherwise with a find_library() link test that honours the -L
# in c_link_args.  That link test only runs when the library type is not forced static:
# prefer_static replaces it with a scan of the compiler's built-in directories, which never include
# the destdir.  glib is therefore built with prefer_static off (meson takes the last -D of a given
# name, overriding DEFAULT_MESON's); its own dependencies arrive through pkg-config files that list
# everything in Libs, so it loses nothing by it.
#
# Where the C library lacks either, the provider built here is supplied; StaticBuild.cmake works out
# which the target needs, and installs them apart from the destdir, where
# sessiondep_providers_meson_args() points glib at them.
set(glib_extra_deps)
if(sessiondeps_need_libintl)
    session_dep(proxy-libintl 0.5)
    list(APPEND glib_extra_deps sessiondep::proxy-libintl)
endif()
if(sessiondeps_need_libiconv)
    session_dep(libiconv 1.17)
    list(APPEND glib_extra_deps sessiondep::libiconv)
endif()

sessiondep_providers_meson_args(glib_extra_meson)
list(APPEND glib_extra_meson -Dprefer_static=false)

set(glib_extra_libs)
if(APPLE)
    # Every Apple SDK, iOS and the simulator included, carries iconv.h and a libiconv.2.tbd stub --
    # Apple's mark of a public, linkable system library -- and it exists only as a dylib.  resolv
    # backs gio's DNS on every Apple platform.
    set(glib_extra_libs iconv resolv)
    # The rest is what glib-2.0.pc and gio-2.0.pc declare on macOS: gio's notification backend is
    # Objective-C, so the frameworks behind it have to be named for a static link.  glib builds its
    # Cocoa and Carbon support only for the macos subsystem; iOS has no AppKit or Carbon to link.
    if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
        list(APPEND glib_extra_libs
            "-framework Foundation" "-framework CoreFoundation"
            "-framework AppKit" "-framework Carbon")
    endif()
endif()

# Apple SDKs declare pipe2 only from iOS/macOS 27, and glib's has_function check cannot see that;
# the patch says why it takes pipe2 off the list rather than presetting a result.
set(glib_patches "")
if(APPLE)
    set(glib_patches PATCHES glib-apple-no-pipe2.patch)
endif()

# Consumers reach glib's build tools through glib-2.0.pc's own `glib_mkenums` and `glib_genmarshal`
# variables, and meson treats a path there that does not exist as a fatal packaging error rather
# than falling back to one on PATH -- so those tools have to be installed even though nothing runs
# them by hand.  They are Python, so a cross build can execute them; glib-compile-resources is an
# ELF binary built for the target, so anything calling gnome.compile_resources() will not cross.
sessiondep_build_external(glib-2.0
    ${glib_patches}
    CONFIGURE_COMMAND DEFAULT_MESON
      -Dtests=false
      -Dinstalled_tests=false
      -Dnls=disabled
      -Dselinux=disabled
      -Dlibmount=disabled
      -Dxattr=false
      -Dlibelf=disabled
      -Dsysprof=disabled
      -Ddtrace=disabled
      -Dsystemtap=disabled
      -Dintrospection=disabled
      -Ddocumentation=false
      -Dman-pages=disabled
      -Dmultiarch=false
      ${glib_extra_meson}
    DEPENDS sessiondep::libffi sessiondep::libpcre2-8 sessiondep::zlib ${glib_extra_deps}
    BUILD_BYPRODUCTS
      ${SESSIONDEPS_DESTDIR}/lib/libglib-2.0.a
      ${SESSIONDEPS_DESTDIR}/lib/libgobject-2.0.a
      ${SESSIONDEPS_DESTDIR}/lib/libgmodule-2.0.a
      ${SESSIONDEPS_DESTDIR}/lib/libgio-2.0.a
      ${SESSIONDEPS_DESTDIR}/include/glib-2.0/glib.h
)

# glib_checks and glib_assert are left at their defaults on purpose: they are what turns a
# g_return_if_fail() precondition into an early return rather than undefined behaviour, and this
# library ends up parsing images from strangers.

# Declared in link order -- gio references gobject references glib -- because a single-pass linker
# takes each archive once, in the order given.
sessiondep_static_target(sessiondep_glib glib-2.0 libglib-2.0.a sessiondep::libpcre2-8)
sessiondep_static_target(sessiondep_gmodule glib-2.0 libgmodule-2.0.a sessiondep_glib)
sessiondep_static_target(sessiondep_gobject glib-2.0 libgobject-2.0.a sessiondep_glib sessiondep::libffi)
sessiondep_static_target(sessiondep_gio glib-2.0 libgio-2.0.a sessiondep_gobject sessiondep_gmodule sessiondep::zlib)

# glib splits its headers: the public ones go in include/glib-2.0, but glibconfig.h is generated per
# target and installed under lib/, so a consumer needs both directories.  Everything downstream
# includes <glib.h>, which is only findable this way.
foreach(tgt sessiondep_glib sessiondep_gmodule sessiondep_gobject sessiondep_gio)
    target_include_directories(${tgt} INTERFACE
        ${SESSIONDEPS_DESTDIR}/include/glib-2.0
        ${SESSIONDEPS_DESTDIR}/lib/glib-2.0/include)
endforeach()

# Each component's *-visibility.h declares its API __declspec(dllimport) on Windows unless told the
# library is static, and glib's own .pc files do not say so.
target_compile_definitions(sessiondep_glib INTERFACE GLIB_STATIC_COMPILATION)
target_compile_definitions(sessiondep_gmodule INTERFACE GMODULE_STATIC_COMPILATION)
target_compile_definitions(sessiondep_gobject INTERFACE GOBJECT_STATIC_COMPILATION)
target_compile_definitions(sessiondep_gio INTERFACE GIO_STATIC_COMPILATION)

if(NOT WIN32)
    target_link_libraries(sessiondep_glib INTERFACE m ${CMAKE_DL_LIBS} Threads::Threads ${glib_extra_libs})
else()
    # This mirrors what glib's own meson declares and what the installed glib-2.0.pc and gio-2.0.pc
    # carry in their Libs, which is where to check it after a version bump: gio reaches for the
    # adapter and routing table APIs (iphlpapi) and the resolver (dnsapi) on top of the socket
    # stack, and none of that is implicit in a static link.
    target_link_libraries(sessiondep_glib INTERFACE
        ws2_32 iphlpapi dnsapi winmm ole32 shlwapi uuid)
endif()

if(glib_extra_deps)
    target_link_libraries(sessiondep_glib INTERFACE ${glib_extra_deps})
endif()

sessiondep_bundle(glib-2.0 sessiondep_glib)
sessiondep_bundle(gmodule-2.0 sessiondep_gmodule)
sessiondep_bundle(gobject-2.0 sessiondep_gobject)
sessiondep_bundle(gio-2.0 sessiondep_gio)
