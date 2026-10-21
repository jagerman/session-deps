# Session Project CMake static dependency build tools

This package contains various common cmake code for loading dependencies, optionally from the system
or with fallback (or in some cases, only) static builds.

The scripts contained in this repository used to be scattered and duplicated around several separate
Session projects; this repo exists to consolidate the efforts of maintaining the various
dependencies of the many Session subprojects.

## Usage example:

    include(session-deps/Deps.cmake)

    # Search for a dependency, setting up a static build if not found or system deps are disabled.
    # This call requires that the package be one of the packages with static builds supported by
    # this repository.
    session_dep(libngtcp2 1.5.0)
    target_link_libraries(mylib PRIVATE sessiondep::libngtcp2)

    # Look for a system dependency and, if not found, add the given subdirectory for submodule
    # cmake projects *outside* this repository.  The first two arguments are as above; the third is
    # the subdirectory to add if the system lib is not found; and the fourth (and beyond, if given)
    # is the name of the target that session::${pkg} should point at if the subdirectory approach is
    # taken.
    sessiondep_or_submodule(CLI11 2.2.0 path/to/cli11 CLI11::CLI11)

The first example above will attempt to find ngtcp2 via system library (at least version 1.5.0), and
if not found will fall back to a static build.  The second example loads attempts to load CLI11 via
system library, and if found makes `CLI11::CLI11` an alias for it; if not found then it runs
`add_subdirectory(path/to/cli11)` and expects the submodule itself to provide the CLI11::CLI11
target.

## CMake options

### `BUILD_STATIC_DEPS=ON`

This is the "all static" master switch: if set to true (e.g. via `-DBUILD_STATIC_DEPS=ON` or
`set(BUILD_STATIC_DEPS ON CACHE BOOL "")`) then all `session_dep(...)` calls build static
dependencies and ignore anything on the system, and all `sessiondep_or_submodule(...)` calls
similarly force the submodule to be used (as if `DEPS_FORCE_SUBMODULE=ON` was set).

### `BUILD_STATIC_${pkg}=ON`

This variable is a per-package override that forces the named package in question to ignore system
libraries and use a static build.  Note that system library dependencies of ${pkg} may still be
used.  This option has no effect when the global `SESSIONDEPS_STATIC` option is turned on.

### `SESSIONDEPS_LTO=ON/OFF`

Enabled or disable LTO for static dependency builds, where supported.

### `LIBHEIF_WITH_LIBDE265=OFF/ON`

Off by default, so a static libheif decodes AVIF (AV1) but not HEIC (HEVC).  HEVC is covered by
actively licensed patents, so this is only for people building for their own use: **never enable it
for a build that is distributed.**  It has no effect on a system libheif, whose codec support is
whatever the system package provides.

### `DEPS_FORCE_SUBMODULE=ON`

This flag forces all `sessiondep_or_submodule` calls to take the submodule route, bypassing the
detection of system libraries.  Note that this behaviour is also enabled by `BUILD_STATIC_DEPS=ON`.

### `DEPS_FORCE_${pkg}_SUBMODULE=ON`

This flag overrides `sessiondep_or_submodule` for just a single package to force that package to
ignore system libs and use a submodule.

### `LOCAL_MIRROR`

This can be set to a mirror to check first for downloads, with fallback to the upstream download
URL, when download static sources.  For instance, CI jobs for Session projects typically set this to
https://builds.session.codes/deps/.  (Note that source files are hashed and verified, so use of a local mirror
does not allow modified source packages).

### `SUBMODULE_CHECK`

Can be set to `OFF` to turn submodule check failures performed by the check_submodule() into
non-fatal warnings instead of errors.

## Duplicate dependency handling

This code can safely be used by multiple callers with different requirements without worrying about
getting mixed versions.  For example, if project A requires xyz>=1.1 and also uses a submodule B
that uses this code and requires xyz>=1.2, then the system library will only be used if it can
satisfy both requirements.  If the system version found was 1.1.5 then this will build and link to
the static library for both dependencies.

## `session_dep(...)`

This function is used to look for a system dependency, and if not found, build the dependency as a
static library using one of the available static dep build scripts in this repository.  Typical
usage specifies the pkg-config library name and the minimum required version such as:

    session_dep(libngtcp2 1.5.0)

This will make available a sessiondep::libngtcp2 target that is either a system library >= 1.5.0, or
alternatively the local static build of libngtcp2.

Optional arguments that can be added after the version are as follows:

    WITH pkgspec [pkgspec2 ...]

If the dependency is a library that produces requires multiple separate library targets then WITH
allows you to ensure that all of them are available, and falls back to a static build if any are
missing.  For example:

    session_dep(libngtcp2 1.5.0 WITH libngtcp2_crypto_gnutls)

will create sessiondep::libngtcp2 and sessiondep::libngtcp2_crypto_gnutls targets, either both
loaded from the system, or both coming from a static dep build.

## `sessiondep_or_submodule(...)`

This is similar to `session_dep` in that it first attempts to load a system library, but if it fails
then instead of using a repo build scripts it instead adds a given submodule path (relative to where
the function is called) via `add_subdirectory(dir)`.  This is intended for builds where the
dependency builds easily via existing cmake build scripts (without needing the heavier external
project dep building infrastructure used by the static builds in this repository).

This function takes 4 arguments:

- pkgconfig library name
- minimum required version
- path to fallback submodule to add via `add_subdirectory` if the library was not found
- cmake alias target to create.  This target must be the same as one created by the subdirectory.

If the target to create *already* exists when this function is called then this function produces a
fatal error: loading the same target from different places requires care and if desiged, the caller
should pre-check whether the target already exists.

## `check_submodule(...)`

This function checks that a submodule (and nested submodules within it) is checked out up to date
with the current git commit, producing a fatal error if not (to ensure that submodules get updated).
The checks can be bypassed using `-DSUBMODULE_CHECK=OFF` on the command line (e.g. when doing dev
work that is updating submodules).

This takes the relative path to the submodule as the first argument, and optional remaining
arguments of relative paths *within* that submodule to also check nested submodules.  For example:

    check_submodule(oxen-encoding)
    check_submodule(oxen-logging fmt spdlog)

ensures that each of oxen-encoding, oxen-logging, oxen-logging/fmt, and oxen-logging/spdlog are up
to date.

## Adding new builds

Static package builds go into deps/PKG.cmake, where PKG is the pkg-config name, and generally should
make use of deps/StaticBuild.cmake as much as possible for compiler flags and settings, by calling
the `sessiondep_build_external()` and `sessiondep_static_target()` functions.

The individual `deps/PKG.cmake` should never be included directly, but only through the
`session_dep()` function.  Various deps themselves make use of `session_dep()` for sub-dependencies
and require it to exist when they are invoked.

Important: remember to bump the `session_deps_version` in Deps.cmake when committing a new package
or fix: when session-deps is loaded from multiple projects in the same build, deps are loaded from
the instance with the highest version!

More advanced builds may need to do things differently than what the StaticBuild functions allow: if
so the build is expected to create a `sessiondep_ext_PKG` cmake target carrying the library
dependencies, include directories, and so on.  This target will be aliased to the sessiondep::PKG
target when doing a static build.  It is acceptable for that target to be an interface library (e.g.
to link to multiple sub-targets).

## Rejecting unsuitable system packages

Sometimes a system package is present and new enough and still cannot be used, for reasons its
version does not express: typically something about what it was built against.  A `check/PKG.cmake`
file, if one exists, is included immediately after `session_dep()` finds a system PKG and gets a
say.  Setting `sessiondep_reject_system` to a short reason rejects it, which falls back to the
static build exactly as not having found it would:

    # check/libfoo.cmake
    if(<some test that says the system libfoo won't do>)
        set(sessiondep_reject_system "was built without widget support")
    endif()

producing, at configure time:

    -- Found libfoo 1.2.3 but it was built without widget support; falling back to static build

Note that this is for packages that are genuinely unusable, not merely not preferred: rejecting one
means building it instead, so a check that is too eager costs everyone build time.  The reason
string is shown to whoever is building, so it should say what is wrong in a way that suggests what
to install instead.

`check/libcurl.cmake` is the worked example: a system libcurl that brings in an ngtcp2 crypto
backend other than the gnutls one cannot coexist with liboxenquic in the same process, because
ngtcp2's backends all export the same symbols, so whichever the loader reaches first is used by
both.  A libcurl built against a different TLS library but with no HTTP/3 at all is fine, which is
why that check tests for the ngtcp2 backend rather than for the TLS library.
