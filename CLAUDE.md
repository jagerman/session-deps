# session-deps

Builds the Session projects' C/C++ dependencies from source, statically, for Linux, Apple platforms
(macOS and, via `SDK_NAME`, iOS), Windows (mingw-w64 cross) and Android.  Consumed as a submodule: a
project includes `Deps.cmake` and asks for what it needs with `session_dep()`, which finds a suitable
system package or falls back to building one here.

CI builds Android and iOS but cannot run what it builds for them, so code guarded by `ANDROID` or an
Apple SDK check that compiles and links can still be broken at runtime without anyone noticing.

`README.md` documents the user-facing side — the cmake options, `session_dep()`, how to add a
package, and `check/PKG.cmake` system-package rejection.  Read it first; this file is what it does
not say.

## Layout

| path | what |
| --- | --- |
| `Deps.cmake` | entry point; `session_dep()`, the system-vs-static decision, version handshake |
| `deps/StaticBuild.cmake` | shared machinery: toolchain flags, the `sessiondep_*` functions |
| `deps/PKG.cmake` | one recipe per package, named for its pkg-config module |
| `deps/patches/` | patches applied to upstream sources |
| `deps/extra/` | other files a recipe uses: helper scripts, vendored files; outside the recipe glob |
| `check/PKG.cmake` | optional veto on an otherwise acceptable system package |
| `test/` | a project that builds every recipe and uses each one; what CI runs |
| `.woodpecker/build.star` | CI workflows |

## Recipes

A recipe is included only via `session_dep()`, never directly, and ends up providing
`sessiondep::PKG`.  Most of one looks like:

    set(LIBFOO_VERSION 1.2.3)
    set(LIBFOO_MIRROR https://example.com/download)
    set(LIBFOO_SOURCE libfoo-${LIBFOO_VERSION}.tar.xz)
    set(LIBFOO_HASH SHA512=...)

    session_dep(zlib 1.2)             # sub-dependencies, same mechanism

    sessiondep_build_external(libfoo
        PATCHES libfoo-something.patch
        CONFIGURE_COMMAND ...          # omit to get the standard ./configure
        DEPENDS sessiondep::zlib
    )
    sessiondep_static_simple(libfoo sessiondep::zlib)

Functions, all in `deps/StaticBuild.cmake` unless noted:

- `session_dep(PKG minver [WITH ...])` — *`Deps.cmake`*; the only way to pull in a dependency.
- `sessiondep_build_external(name ...)` — wraps `ExternalProject_Add` with the right compiler,
  flags, prefix and cross settings.  Takes `PATCHES`, `DEPENDS`, `CONFIGURE_COMMAND`,
  `BUILD_COMMAND`, `INSTALL_COMMAND`, `BUILD_BYPRODUCTS`, `PATCH_COMMAND`.
- `sessiondep_static_target(target ext libfoo.a [deps...])` — one imported archive.
- `sessiondep_static_simple(name [deps...])` — the common case: one archive named after the recipe.
- `sessiondep_bundle(name targets...)` — an interface target over several archives (see `icu-io`).
- `sessiondep_link_flags(out targets...)` — flattens cmake targets to a linker argument list, for
  handing to a foreign build system's `LIBS=`.
- `sessiondep_expand_urls(out file mirrors...)` — applies `LOCAL_MIRROR`.

Build settings come from promoted cache variables, not from computing your own: `sessiondeps_cc`,
`sessiondeps_cxx`, `sessiondeps_CFLAGS`, `sessiondeps_CXXFLAGS`, `sessiondeps_ldflags`,
`sessiondeps_make`, `sessiondeps_patch`, `sessiondeps_cross_host`, `sessiondeps_cross_rc`.  Anything
set as `deps_foo` near the end of `StaticBuild.cmake` is promoted to `sessiondeps_foo`; add to the
`foreach` promotion list when introducing one.

`CONFIGURE_COMMAND` takes one of three forms: a literal command (the default is `./configure`),
`DEFAULT_CMAKE` followed by `-D` options, or `DEFAULT_MESON` followed by `-D` options.  The latter
two also supply the build and install commands, and build out-of-source.

`DEFAULT_MESON` pins `--libdir=lib`, because meson otherwise honours the distro's multiarch layout
and installs to `lib/x86_64-linux-gnu`, where `sessiondep_static_target()` does not look.  It also
passes `--wrap-mode=nodownload`: left alone, meson resolves a missing dependency by fetching it from
WrapDB at configure time, which would bring in code that never went through our hash-pinned
tarballs.  Subprojects already vendored in the tarball (glib ships gvdb that way) still resolve.

meson has no `--host`, so a cross build is described by a cross file, generated once in
`StaticBuild.cmake` as `sessiondeps_meson_cross`.  Its `cpu_family` has to come from meson's own
fixed vocabulary, which is neither cmake's spelling nor the triplet's, so `ARCH_TRIPLET` is
translated rather than passed through; an unrecognised architecture is a fatal error rather than a
guess.

**OpenSSL does not take `--host`.**  It picks its target from `POSIX::uname()` with no environment
override, so a cross build must name the target (`./Configure mingw64`) and pass the cross `AR` and
`RANLIB`; `SYSTEM=MINGW64` was an OpenSSL 1.x thing and has been inert since 3.0.  Its archives are
also rewritten after installation (`deps/extra/libssl-hide-internals.cmake`) so that only the public API is
global: its assembly shares global names with gnutls's copy of the same code, and a static archive
has no version script to hide them.

**Bump `session_deps_version` in `Deps.cmake` with any recipe change.**  When several projects in one
build tree carry this submodule, the highest version wins and the others are ignored, so a fix in a
copy with a stale version silently does nothing.

## Patches

Recipes name patches with `PATCHES`, bare filenames relative to `deps/patches/`.  Every patch is
applied with `-p1`; a patch from elsewhere that strips differently gets `a/` and `b/` prefixes added
to its headers rather than its own strip level.

`patch` runs as `patch -N -f` so it can never stop for input.  On a terminal an unapplyable patch
otherwise waits for an answer forever instead of failing.  Do not "fix" that with `--batch`: despite
the name it answers *yes, it looks reversed*, reverse-applies and exits **0**, which for a patch
upstream has since adopted means silently deleting the fix.

Generating one:

- **Produce it with `diff -u`, never by hand.**  Hand-written hunk headers get the line counts wrong
  and apply with fuzz or silently wrong.  Copy the file to a scratch directory, edit the copy, and
  `diff -u --label a/path --label b/path`.
- Verify with `patch -p1 -F0 --dry-run` against a *pristine* extracted tarball.  Fuzz means the
  context does not really match.
- Prefer a patch from MSYS2, MXE, Debian or the distro that already solved it over writing one;
  note the provenance at the top of the file.
- Explain *why* upstream needs it at the top of the patch file, above the diff.
- Re-check patches on a version bump.  A patch upstream has adopted now fails the build (good), but
  one whose context merely drifted can apply in the wrong place.

## Things that have bitten us

**A static archive nothing references contributes nothing.**  Linking against a `.a` proves the
target and its flags are coherent, not that its symbols exist or its headers are installed.  This is
why `test/main.cpp` calls into every library.

**libtool absorbs a `.a` named on a link line.**  Passing archive *paths* in an autotools `LIBS=`
gets their members copied into the library being built — a `libcurl.a` with `libgnutls.a` inside it.
Pass `-L`/`-l` instead; `sessiondep_link_flags()` does.

**Link order matters and cmake only knows what you tell it.**  A single-pass linker takes each
archive once, in order, so an archive that references a symbol must come *before* the one defining
it.  Declare the dependency between `sessiondep_static_target()`s rather than relying on the order
they happen to appear in; `icuuc` referencing `icudata` is the worked example.

**A Windows static library usually needs a define saying so.**  Headers that support both DLL and
static builds default to `__declspec(dllimport)`, so callers look for `__imp_foo` and the plain
symbol in the archive does not match.  The target must carry the library's own opt-out as an
`INTERFACE` definition — `UTF8PROC_STATIC`, `CURL_STATICLIB`, `ZMQ_STATIC`, `NGTCP2_STATICLIB`.
Windows also wants system libraries named explicitly (`ws2_32` for anything doing sockets,
`iphlpapi`, `crypt32`, `bcrypt`).

**Cross builds run host-compiled tools against target config.**  The worst bugs here come from a
tool built for the build machine making decisions with `#if` on *its* platform while reading the
target's settings — ICU's `pkgdata` names the data library that way and silently produces one nobody
installs.  When a cross build misbehaves, ask which machine the deciding code was compiled for.

**A build script that asks `uname` is describing the build machine, whatever it meant to ask.**
zlib's configure took its platform from `uname -s` instead of `--host`; from Linux the answer
happened to pick a branch that worked for Android and mingw, and from a mac it archived Android
objects with Apple's libtool.  Darwin is the build machine scripts single out, so these bugs pass
every Linux-hosted cross build and fail on a developer's mac.  The mingw workflow catches the
question instead of the failure; see CI.

**An optional dependency left at its default is a system library waiting to leak in.**  On a native
build the pkg-config search path is our destdir *followed by the system's*, so that a static
libvips can sit on a system glib.  The cost is that any recipe which leaves an optional dependency
to autodetection can find a system copy, record it in its own `.a`, and fail the *final* link on
symbols from a library that was never in the destdir — libtiff picked up the system `libdeflate`
this way and the error named only `libdeflate_*`, several steps from the cause.  Set every optional
dependency explicitly, including the ones you are turning off, and including the ones that are not
codecs.

**`--default-library=static` does not make meson link its dependencies statically.**  It governs
what the project builds; dependency resolution still runs a plain `pkg-config --libs`, which omits
`Requires.private` and `Libs.private` — where a static library records what it needs.  That is what
`-Dprefer_static=true` in `DEFAULT_MESON` is for; without it libheif linked without libde265 and
dav1d.  It also picks up `Cflags.private`, which is where a library tends to hide its Windows
"I am static" define.

**`prefer_static` hides the destdir from meson's library search.**  Dependencies with no pkg-config
method — `intl` and `iconv` among them — end in `find_library()`, which normally runs a `-lname`
link test that sees the `-L` in `c_link_args`.  With `prefer_static` on it runs a filesystem scan of
the compiler's built-in directories instead, and a library installed here is simply not found.  glib
turns it back off for this reason; a recipe whose dependencies include such a library needs the
same.

**Autotools flags can be silently inert.**  `AC_ARG_WITH` names are collected at generation time, so
a flag whose handling sits inside a conditional is accepted and ignored with no warning
(`--without-ssl` does nothing for unbound once `--with-nettle` is given).  Check that a flag reaches
`config.h`/`configdata.pm` rather than assuming.

**`deps/sqlite3.cmake` is an alias** that bundles `sqlite3mc`; there is no separate stock sqlite3
build.

## Testing

`test/` builds every recipe — globbed, so a new recipe is covered without being listed — and links
`main.cpp`, which calls something from each and prints its version.  `HAVE_DEP_*` is defined per
recipe built, so the calls follow `SKIP_DEPS`.

The glob covers building, but the calls in `main.cpp` are written by hand, so **a new recipe gets
built and linked with nothing exercising it until someone adds one**.  Add the call with the recipe.

    cmake -S test -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DLOCAL_MIRROR=https://builds.session.codes/deps
    ninja -C build

`-DSKIP_DEPS='libfoo;libbar'` drops recipes; it lives in the CI job rather than in the cmake so a
skip is visible where it applies instead of switching off coverage everywhere.

A full run builds everything and is slow.  To iterate on one dep, build just its target
(`ninja sessiondep_libfoo_external`), or work in a scratch copy of the extracted source with the
recipe's own configure line — `make -k` there finds every compile error in one pass instead of one
per CI round trip.

## CI

Woodpecker, configured by `.woodpecker/build.star` (Starlark, evaluated by our
session-woodpecker-config extension).  One workflow per platform: Debian sid, bookworm (arm64) and
trixie (armhf), Ubuntu jammy, mingw cross, macOS arm and intel, Android (arm64-v8a, armeabi-v7a,
x86_64) and iOS (device, simulator).  Each builds `test/` and runs `deps-test` where the agent can
execute it: natively, or under wine for mingw.  The Android and iOS workflows only build.  The ELF
ones, Linux and Android, also build `check-pic`, which links each archive whole into a shared object
of its own: everything here ends up inside one, and `deps-test` is an executable.

The mingw workflow builds under `test/uname-audit.py`, which traces the build with strace and fails
on any script that asks about the build machine — `uname`, `arch`, Perl's `POSIX::uname`, Python's
`platform` — other than the expected ones (autoconf's `config.log` header, `config.guess`, cmake and
meson).  It sees that a script asked, not what it did with the answer, so a new finding means
reading the script.  Fix the recipe if the answer decides anything about the target (`--uname` for
zlib; a preset cache variable where configure caches the check; a patch).  If it only matters on a
build machine nobody uses, add it to `KNOWN` in the script with the reason.  A known entry that is
no longer asked fails the audit too, so drop it after a version bump removes the question.  Run it
locally with `../test/uname-audit.py ninja` in a mingw build directory, or `--log` to re-read a
trace.

The arm builders run out of memory above 4 concurrent compiles, so those workflows pass `jobs = 4`.
