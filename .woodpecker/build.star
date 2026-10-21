# CI for session-deps itself.  There is nothing here to build but the dependency recipes, so every
# workflow builds test/, which pulls in every recipe in deps/ and links against all of them.  The
# point is that a recipe which has rotted -- an upstream that moved its tarball, a configure option
# that went away, a platform it never actually built on -- is found here rather than by whichever
# project next needs it.
#
# The dependency list is not written down anywhere: test/CMakeLists.txt globs deps/, so a recipe
# added without touching this file is still covered.
#
# Linux builds, and the Android and mingw cross builds, run in our images on the docker agents; macOS
# and iOS builds run directly on the Mac agents.

registry = "registry.session.codes/"

events = ["push", "pull_request", "tag", "manual"]

apt_get = "apt-get -o=Dpkg::Use-Pty=0 -q"

# Everything needed to build the recipes themselves; the deps' own dependencies get built, not
# installed, which is the whole point.
build_tools = [
    "build-essential",
    "cmake",
    "git",
    "pkg-config",
    "ccache",
    "ca-certificates",
    "automake",
    "autoconf",
    "libtool",
    "patch",
    "file",
    "xz-utils",
    "unzip",
    "python3",
    "ninja-build",
]

default_cmake = {
    "CMAKE_BUILD_TYPE": "Release",
    "CMAKE_COLOR_DIAGNOSTICS": True,
    # Dep sources come from our own mirror first so that CI does not hammer (or depend on the
    # availability of) a dozen upstream download sites.
    "LOCAL_MIRROR": "https://builds.session.codes/deps",
}

# OpenSSL has to be told its target when cross-compiling, and only mingw is mapped.
cross_skip = {"SKIP_DEPS": "libssl"}

def cmake_args(opts):
    return " ".join([
        "-D%s=%s" % (k, ("ON" if v else "OFF") if type(v) == "bool" else v)
        for k, v in opts.items()
    ])

# Running deps-test is the point of it: building only proves the recipes compiled, while the run
# calls into every library and is what catches one that links but does not work.  A cross build
# that the CI machine cannot execute passes run_test = None and gets the build only.
#
# check-pic links each archive into a shared object, which is where they all end up and which
# deps-test, an executable, cannot show.  It exists only where the target is ELF.
#
# uname_audit builds under strace and fails on any build script that asks what the build machine is
# without having been reviewed: a cross build that decides its target from the build machine works
# from Linux and breaks from a mac, which no mac workflow here would catch.  See test/uname-audit.py.
def build_commands(cmake, jobs, run_test, pic_check, uname_audit = False):
    opts = dict(default_cmake)
    opts.update(cmake)
    build = "ninja -j%d -v" % jobs
    if uname_audit:
        build = "../test/uname-audit.py " + build
    cmds = [
        "mkdir build",
        "cd build",
        "cmake ../test -G Ninja " + cmake_args(opts),
        build,
    ]
    if pic_check:
        cmds.append("ninja -j%d -v check-pic" % jobs)
    if run_test:
        cmds.append(run_test)
    return cmds

def workflow(name, platform, image, commands):
    step = {"name": "build", "image": image, "commands": ['echo "Building on $${CI_MACHINE}"'] + commands}
    if image != "sh":
        step["pull"] = True
    return {
        "name": name,
        "labels": {"platform": platform, "backend": "local" if platform.startswith("darwin/") else "docker"},
        "when": [{"event": events}],
        "steps": [step],
    }

# glib needs meson >= 1.4.  A release whose own is too old takes it from `backports` (a Debian
# codename) or, where nothing packaged will do, installs version `meson_pip` with pip.
def linux(
        name,
        image,
        arch = "amd64",
        jobs = 6,
        pkgs = [],
        backports = None,
        meson_pip = None,
        cmake = {},
        run_test = "./deps-test",
        pic_check = True,
        uname_audit = False):
    meson = "meson"
    if uname_audit:
        pkgs = pkgs + ["strace"]
    if backports:
        meson = "meson/%s-backports" % backports
    elif meson_pip:
        meson = "python3-pip"

    cmds = ['echo "man-db man-db/auto-update boolean false" | debconf-set-selections']
    if backports:
        cmds.append('echo "deb http://deb.debian.org/debian %s-backports main" >> /etc/apt/sources.list.d/extra.list' % backports)
    cmds += [
        apt_get + " update",
        apt_get + " install -y eatmydata",
        "eatmydata " + apt_get + " install --no-install-recommends -y " + " ".join([meson] + build_tools + pkgs),
    ]
    if meson_pip:
        cmds.append("pip3 install --no-cache-dir meson==" + meson_pip)
    return workflow(name, "linux/" + arch, registry + image, cmds + build_commands(cmake, jobs, run_test, pic_check, uname_audit))

def macos(name, arch, cmake = {}, run_test = "./deps-test"):
    return workflow(name, "darwin/" + arch, "sh", [
        # Without this the C compiler has no include path containing basic system headers.
        'export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"',
    ] + build_commands(cmake, 6, run_test, pic_check = False))

# The image has the NDK, which ships the toolchain file, at this path.
android_ndk = "/usr/lib/android-ndk"

def android(abi):
    return linux("Android (%s)" % abi, "android", run_test = None, cmake = dict(
        cross_skip,
        CMAKE_TOOLCHAIN_FILE = android_ndk + "/build/cmake/android.toolchain.cmake",
        ANDROID_ABI = abi,
        ANDROID_ARM_MODE = "arm",
        ANDROID_PLATFORM = "android-23",
        ANDROID_STL = "c++_static",
    ))

def ios(name, platform):
    return macos(name, "arm64", run_test = None, cmake = dict(
        cross_skip,
        CMAKE_TOOLCHAIN_FILE = "../external/ios-cmake/ios.toolchain.cmake",
        PLATFORM = platform,
        DEPLOYMENT_TARGET = 13,
        ENABLE_BITCODE = False,
    ))

def main(ctx):
    return [
        linux("Debian sid (amd64)", "debian-sid"),
        # The arm builders run out of memory above 4 concurrent compiles.
        linux("Debian bookworm (arm64)", "debian-bookworm", arch = "arm64", jobs = 4, backports = "bookworm"),
        # Nothing packaged for jammy is new enough, not even in backports, and meson is pure Python.
        linux("Ubuntu jammy (amd64)", "ubuntu-jammy", meson_pip = "1.7.0"),
        # armhf is built on an arm64 machine, as the 32-bit runners are.
        linux("Debian trixie (armhf)", "debian-trixie/arm32v7", arch = "arm64", jobs = 4),

        # The test binary is built static, so wine can run it without the cross toolchain's DLLs.  The
        # uname audit needs a cross build, and this is the one that builds every recipe.
        linux(
            "Windows x64 (mingw)",
            "debian-sid",
            pkgs = ["g++-mingw-w64-x86-64-posix", "wine"],
            cmake = {"CMAKE_TOOLCHAIN_FILE": "../test/cross/mingw-x64.cmake"},
            run_test = "WINEDEBUG=-all wine ./deps-test.exe",
            pic_check = False,
            uname_audit = True,
        ),

        macos("macOS (ARM)", "arm64"),
        macos("macOS (Intel)", "amd64"),

        # The two ABIs Session ships, plus x86_64 for the emulator most Android development runs on.
        # x86 can be added here if it is ever worth the build time.
        android("arm64-v8a"),
        android("armeabi-v7a"),
        android("x86_64"),

        ios("iOS (device)", "OS64"),
        ios("iOS (simulator)", "SIMULATORARM64"),
    ]
