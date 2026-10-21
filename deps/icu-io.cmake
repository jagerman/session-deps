set(ICU-IO_VERSION 78.3)
set(ICU-IO_MIRROR
    https://github.com/unicode-org/icu/releases/download/release-${ICU-IO_VERSION})
set(ICU-IO_SOURCE icu4c-${ICU-IO_VERSION}-sources.tgz)
set(ICU-IO_HASH SHA512=04a49455e1489030c520a4bfd2664fa2171e7938d08f2acdbbcb1fda976639fd8b1f0704f2eec89ba59a7b6d118ceaab6ec5a096e40d9085a0895d91ce225245)
set(ICU-IO_DATA icu4c-${ICU-IO_VERSION}-data.zip)
set(ICU-IO_DATA_SHA512 d584523acb319be1e05489469cda580fb2929f0950c176a59244ef6565faf44f3506fd25d145dce6d8b57be3ff432af033e9ea6d324d2d3538944c5313edf327)

option(LIBICU_SQLITE_ONLY "Builds libicu without things that are used in sqlite's libicu support, such as non-UTF-8 charset handling, timezone, and currency symbols")

set(libicu_feature_excludes)
if(LIBICU_SQLITE_ONLY)
    set(libicu_feature_excludes "ICU_DATA_FILTER_FILE=${CMAKE_CURRENT_LIST_DIR}/extra/libicu_sqlite_excludes.json")
endif()

# ICU generates its data by running tools it has just built, so a cross build cannot produce its own
# and has to be handed a native build of the same version to take them from.
set(icu_native_dep)
set(icu_cross_build)
if(CMAKE_CROSSCOMPILING)
    set(icu_native_root ${SESSIONDEPS_SOURCEDIR}/src/sessiondep_icu-io-native_external)

    sessiondep_expand_urls(icu_native_urls ${ICU-IO_SOURCE} ${LOCAL_MIRROR} ${ICU-IO_MIRROR})
    ExternalProject_Add(sessiondep_icu-io-native_external
        BUILD_IN_SOURCE ON
        PREFIX ${SESSIONDEPS_SOURCEDIR}
        URL ${icu_native_urls}
        URL_HASH ${ICU-IO_HASH}
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE
        DOWNLOAD_NO_PROGRESS ON
        # No cross host, no toolchain overrides, and no --prefix: this one runs on the build machine
        # and is never installed.  Only its build tree is consumed.
        CONFIGURE_COMMAND ./source/configure --enable-static --disable-shared
            --disable-icu-config --disable-strict --disable-dyload
            --disable-tests --disable-samples --with-data-packaging=static
        BUILD_COMMAND ${sessiondeps_make}
        INSTALL_COMMAND ""
    )

    set(icu_native_dep DEPENDS sessiondep_icu-io-native_external)
    # --disable-tools: the tools exist to generate the data, and a cross build runs the native
    # build's copies instead (its config/icucross.mk points TOOLBINDIR at them), so building them
    # for the target is wasted work.  It is also impossible for iOS, whose SDK makes system(3)
    # unavailable to pkgdata.
    set(icu_cross_build --with-cross-build=${icu_native_root} --disable-tools)
endif()

# -fPIC is ours to give: ICU does not use libtool, so there is no --with-pic, and it compiles the
# objects for its static archives with only STATICCFLAGS, which is empty on Linux.  A PIE-default
# compiler hides this until the archives are linked into a shared object.
sessiondep_build_external(icu-io
    ${icu_native_dep}
    PATCHES icu-mingw-static-libraries-without-s.patch icu-mingw-static-library-names.patch
    CONFIGURE_COMMAND
        ${CMAKE_COMMAND} -E env ${libicu_feature_excludes}
        ./source/configure ${sessiondeps_cross_host} ${icu_cross_build} --enable-static
        --disable-shared --disable-icu-config --disable-strict --disable-dyload
        --disable-tests --disable-samples --with-data-packaging=static
        --prefix=${SESSIONDEPS_DESTDIR}
        CC=${sessiondeps_cc}
        CXX=${sessiondeps_cxx}
        "CFLAGS=${sessiondeps_CFLAGS} -fPIC"
        "CXXFLAGS=${sessiondeps_CXXFLAGS} -fPIC"
    BUILD_COMMAND
        ${CMAKE_COMMAND} -E env ${libicu_feature_excludes}
        ${sessiondeps_make}
    BUILD_BYPRODUCTS
        ${SESSIONDEPS_DESTDIR}/lib/libicudata.a
        ${SESSIONDEPS_DESTDIR}/lib/libicui18n.a
        ${SESSIONDEPS_DESTDIR}/lib/libicuio.a
        ${SESSIONDEPS_DESTDIR}/lib/libicuuc.a
        ${SESSIONDEPS_DESTDIR}/include/unicode/utypes.h
)

if(LIBICU_SQLITE_ONLY)
    set(icu_data_file "${SESSIONDEPS_SOURCEDIR}/src/${ICU-IO_DATA}")
    if(EXISTS "${icu_data_file}")
        file(SHA512 "${icu_data_file}" icudata_hash)
        if(NOT ${icudata_hash} STREQUAL ${ICU-IO_DATA_SHA512})
            message(WARNING "${ICU-IO_DATA} hash mismatch! Deleting invalid ${icu_data_file} to re-download")
            file(REMOVE "${icu_data_file}")
        endif()
    endif()

    if(NOT EXISTS "${icu_data_file}")
        message(STATUS "Downloading ICU data source to rebuild trimmed data (because LIBICU_SQLITE_ONLY=ON)")

        # Unlike the tarball, which sessiondep_build_external() routes through LOCAL_MIRROR for us,
        # this download is ours to make, so it has to consult the mirror itself.  The hash is
        # checked by hand rather than with EXPECTED_HASH so that a bad copy on one mirror falls
        # through to the next instead of failing the configure outright.
        sessiondep_expand_urls(icu_data_urls ${ICU-IO_DATA} ${LOCAL_MIRROR} ${ICU-IO_MIRROR})
        foreach(url IN LISTS icu_data_urls)
            file(DOWNLOAD "${url}" "${icu_data_file}" STATUS icu_data_status)
            list(GET icu_data_status 0 icu_data_code)
            if(icu_data_code EQUAL 0)
                file(SHA512 "${icu_data_file}" icu_data_hash)
                if("${icu_data_hash}" STREQUAL "${ICU-IO_DATA_SHA512}")
                    break()
                endif()
                message(STATUS "${url}: hash mismatch, trying next mirror")
            else()
                list(GET icu_data_status 1 icu_data_error)
                message(STATUS "${url}: ${icu_data_error}, trying next mirror")
            endif()
            file(REMOVE "${icu_data_file}")
        endforeach()

        if(NOT EXISTS "${icu_data_file}")
            message(FATAL_ERROR "Failed to fetch ${ICU-IO_DATA} from any of: ${icu_data_urls}")
        endif()
    endif()

    set(icu_src "${SESSIONDEPS_SOURCEDIR}/src/sessiondep_icu-io_external/source")
    ExternalProject_Add_Step(sessiondep_icu-io_external icu-io_data_overlay
        DEPENDEES download
        DEPENDERS configure
        DEPENDS "${icu_data_file}"

        COMMAND ${CMAKE_COMMAND} -E remove_directory "${icu_src}/data"
        COMMAND ${CMAKE_COMMAND} -E chdir "${icu_src}" ${CMAKE_COMMAND} -E tar xf "${icu_data_file}"
    )
endif()


# These are needed by virtually all libicu usage:
sessiondep_static_target(sessiondep_icudata icu-io libicudata.a)
# icuuc's data loader references the data library, so it has to precede it on the link line or a
# single-pass linker never goes back for it; saying so here is what orders them.
sessiondep_static_target(sessiondep_icuuc icu-io libicuuc.a sessiondep_icudata)
sessiondep_static_target(sessiondep_icui18n icu-io libicui18n.a sessiondep_icuuc)
sessiondep_static_target(sessiondep_icuio icu-io libicuio.a sessiondep_icui18n)

# There are also libicutu.a (tools) and libicutest.a (test suite), which still get built because of
# limitations of icu's build system, but aren't really part of the main icu library interface that
# we are trying to provide:
#sessiondep_static_target(sessiondep_icutest libicutest.a)
#sessiondep_static_target(sessiondep_icutu libicutu.a)

sessiondep_bundle(icu-io sessiondep_icudata sessiondep_icuuc sessiondep_icui18n sessiondep_icuio)
