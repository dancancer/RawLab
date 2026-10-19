#!/usr/bin/env python3
"""Build pinned Lensfun/GLib dependencies for one target, without host libraries."""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import zipfile


def run(command, env, cwd=None):
    print("+ " + subprocess.list2cmdline([str(item) for item in command]), flush=True)
    subprocess.run(command, env=env, cwd=cwd, check=True)


def fetch(spec, sources, cache):
    sources.mkdir(parents=True, exist_ok=True)
    archive = sources / spec["file"]
    if not archive.exists():
        cached = next((p for p in (cache / spec["file"], cache / "sources" / spec["file"])
                       if p.is_file()), None) if cache else None
        if cached:
            shutil.copy2(cached, archive)
        else:
            temporary = archive.with_name(archive.name + ".part-" + str(os.getpid()))
            try:
                with urllib.request.urlopen(spec["url"], timeout=120) as response, temporary.open("wb") as output:
                    shutil.copyfileobj(response, output)
                if hashlib.sha256(temporary.read_bytes()).hexdigest() != spec["sha256"]:
                    raise RuntimeError("Dependency checksum mismatch: " + archive.name)
                temporary.replace(archive)
            finally:
                temporary.unlink(missing_ok=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != spec["sha256"]:
        raise RuntimeError("Dependency checksum mismatch: " + archive.name)
    return archive


def extract(archive, destination):
    if destination.is_dir():
        return
    stage = destination.parent / (destination.name + ".extract")
    stage.mkdir(parents=True, exist_ok=True)
    try:
        with tarfile.open(archive) as package:
            package.extractall(stage, filter="data")
        directories = list(stage.iterdir())
        if len(directories) != 1 or not directories[0].is_dir():
            raise RuntimeError("Unexpected dependency archive layout: " + archive.name)
        directories[0].rename(destination)
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def patch_meson(archive, subprojects):
    with zipfile.ZipFile(archive) as package:
        package.extractall(subprojects)


def install_tools(tools, sources):
    for name, version in (("meson", "1.12.1"), ("ninja", "1.13.2")):
        with urllib.request.urlopen(f"https://pypi.org/pypi/{name}/{version}/json", timeout=60) as response:
            release = json.load(response)
        if name == "meson":
            suffix = "-py3-none-any.whl"
        elif os.name == "nt":
            suffix = "-win_amd64.whl"
        elif sys.platform == "darwin":
            suffix = "-macosx_10_9_universal2.whl"
        else:
            suffix = "_" + platform.machine() + ".whl"
        wheel = next(item for item in release["urls"] if item["filename"].endswith(suffix))
        archive = fetch({"url": wheel["url"], "file": wheel["filename"], "sha256": wheel["digests"]["sha256"]}, sources, None)
        with zipfile.ZipFile(archive) as package:
            package.extractall(tools)
            if name == "ninja":
                binary = next(info for info in package.infolist() if info.filename.endswith(("/scripts/ninja", "/scripts/ninja.exe")))
                target = tools / "bin" / Path(binary.filename).name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(package.read(binary))
                target.chmod(0o755)


def cross_file(args):
    binaries = {"c": args.cc, "cpp": args.cxx, "ar": args.ar}
    flags = []
    link_flags = []
    system = args.platform
    if system == "ios":
        system = "darwin"
        binaries["objc"] = args.cc
        minimum = "-mios-simulator-version-min=" if "Simulator" in args.sysroot else "-miphoneos-version-min="
        flags = ["-arch", args.arch, "-isysroot", args.sysroot, minimum + args.minimum, "-Werror=unguarded-availability-new"]
        link_flags = flags
    elif system == "macos":
        system = "darwin"
        binaries["objc"] = args.cc
        flags = ["-arch", args.arch]
        if args.sysroot:
            flags += ["-isysroot", args.sysroot]
        flags += ["-mmacosx-version-min=" + args.minimum]
        link_flags = flags
    elif system == "android":
        triple = "aarch64-linux-android" if args.arch == "arm64-v8a" else "x86_64-linux-android"
        toolchain = Path(args.cc).parent
        suffix = ".cmd" if os.name == "nt" else ""
        binaries["c"] = str(toolchain / (triple + args.minimum + "-clang" + suffix))
        binaries["cpp"] = str(toolchain / (triple + args.minimum + "-clang++" + suffix))
        prefix = args.build.resolve() / "install"
        flags = ["-I" + str(prefix / "include")]
        link_flags = ["-L" + str(prefix / "lib")]
    cpu = "aarch64" if args.arch in ("arm64", "arm64-v8a") else "x86_64"
    lines = ["[host_machine]", "system = " + repr(system), "cpu_family = " + repr(cpu),
             "cpu = " + repr(cpu), "endian = 'little'", "", "[binaries]"]
    lines += [key + " = " + repr(value.replace("\\", "/")) for key, value in binaries.items()]
    lines += ["", "[properties]", "needs_exe_wrapper = true", "growing_stack = true", "", "[built-in options]"]
    for language in ("c", "cpp", "objc"):
        if language in binaries:
            lines += [language + "_args = " + repr(flags), language + "_link_args = " + repr(link_flags)]
    if system == "windows":
        lines += ["b_vscrt = 'md'"]
    return "\n".join(lines) + "\n"


def glib_options(target):
    """Return the GLib Meson options shared by the target builders."""
    library = "shared" if target == "macos" else "static"
    options = [
        "--libdir", "lib", "--buildtype=release", "--wrap-mode=forcefallback",
        "-Ddefault_library=" + library,
        "-Dtests=false", "-Dinstalled_tests=false", "-Dintrospection=disabled",
        "-Ddocumentation=false", "-Dman-pages=disabled", "-Dsysprof=disabled",
        "-Dlibmount=disabled", "-Dselinux=disabled", "-Dxattr=false", "-Dnls=disabled",
        "-Dglib_debug=disabled", "-Dlibelf=disabled", "-Dpcre2:jit=disabled",
    ]
    if target == "macos":
        options += [
            "-Dpcre2:default_library=shared", "-Dlibffi:default_library=shared",
            "-Dintl:default_library=shared", "-Dzlib:default_library=shared",
        ]
    return options


def archive_sources(target, sources, cache):
    """Use the shared archive directory directly for macOS builds."""
    return cache if target == "macos" and cache else sources


def cmake_fresh_args(target):
    return ["--fresh"] if target == "macos" else []


def find_library(prefix, stem):
    """Find an installed dynamic library, preferring its unversioned symlink."""
    directory = Path(prefix) / "lib"
    candidates = [directory / ("lib" + stem + ".dylib")]
    candidates.extend(sorted(directory.glob("lib" + stem + "*.dylib")))
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise RuntimeError("Installed library not found: " + str(directory / ("lib" + stem + ".dylib")))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--platform", choices=("ios", "android", "windows", "macos"), required=True)
    parser.add_argument("--arch", required=True)
    parser.add_argument("--cc", required=True)
    parser.add_argument("--cxx", required=True)
    parser.add_argument("--ar", required=True)
    parser.add_argument("--cmake", required=True)
    parser.add_argument("--sysroot", default="")
    parser.add_argument("--minimum", default="18.0")
    parser.add_argument("--toolchain", default="")
    parser.add_argument("--source-cache", type=Path)
    parser.add_argument("--prefix", type=Path)
    parser.add_argument("--glib-build", type=Path)
    parser.add_argument("--glib-prefix", type=Path)
    parser.add_argument("--jobs", default="4")
    args = parser.parse_args()
    if args.platform == "android" and os.name == "nt":
        parser.error("Android Lensfun dependencies require a macOS/Linux build host with POSIX shell and make")
    if args.platform == "android" and (not shutil.which("sh") or not shutil.which("make")):
        parser.error("Android Lensfun dependencies require POSIX shell and make")
    base = args.build.resolve()
    sources = base / "sources"
    prefix = (args.prefix or base / "install").resolve()
    glib_build = (args.glib_build or base / "glib").resolve()
    glib_prefix = (args.glib_prefix or prefix).resolve()
    tools = base / "tools"
    sources.mkdir(parents=True, exist_ok=True)
    glib_build.parent.mkdir(parents=True, exist_ok=True)
    glib_prefix.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["PYTHONPATH"] = str(tools)
    ninja = tools / "bin" / ("ninja.exe" if os.name == "nt" else "ninja")
    if not ninja.is_file() or not (tools / "mesonbuild").is_dir():
        install_tools(tools, sources)
    env["NINJA"] = str(ninja)
    env["PATH"] = str(ninja.parent) + os.pathsep + env.get("PATH", "")
    specs = json.loads(Path(__file__).with_name("lens-dependencies.json").read_text())
    archive_directory = archive_sources(args.platform, sources, args.source_cache)
    archive_cache = None if archive_directory != sources else args.source_cache
    archives = {name: fetch(spec, archive_directory, archive_cache) for name, spec in specs.items()
                if name != "iconv" or args.platform == "android"}
    if args.platform == "android":
        iconv = sources / specs["iconv"]["directory"]
        extract(archives["iconv"], iconv)
        iconv_build = base / "iconv"
        iconv_build.mkdir(exist_ok=True)
        triple = "aarch64-linux-android" if args.arch == "arm64-v8a" else "x86_64-linux-android"
        toolchain = Path(args.cc).parent
        iconv_env = env.copy()
        iconv_env.update(CC=str(toolchain / (triple + args.minimum + "-clang")), AR=args.ar,
                         RANLIB=str(toolchain / "llvm-ranlib"), STRIP=str(toolchain / "llvm-strip"), CFLAGS="-O2 -fPIC")
        run(["sh", iconv / "configure", "--host=" + triple, "--prefix=" + str(prefix),
             "--disable-shared", "--enable-static", "--disable-nls"], iconv_env, cwd=iconv_build)
        run(["make", "-j" + args.jobs], iconv_env, cwd=iconv_build)
        run(["make", "install"], iconv_env, cwd=iconv_build)
        env["CPPFLAGS"] = "-I" + str(prefix / "include")
        env["LDFLAGS"] = "-L" + str(prefix / "lib")
    glib = sources / specs["glib"]["directory"]
    extract(archives["glib"], glib)
    if args.platform == "ios":
        # Headerless probes otherwise enable the SDK 27 pipe2 symbol on iOS 18.
        configuration = glib / "meson.build"
        original = "  if cc.has_function(f)\n"
        corrected = "  if cc.has_function(f, prefix: f == 'pipe2' ? '#include <unistd.h>' : '')\n"
        text = configuration.read_text()
        if corrected not in text:
            if text.count(original) != 1:
                raise RuntimeError("Unexpected GLib function-probe configuration")
            configuration.write_text(text.replace(original, corrected))
    for name in ("pcre2", "libffi", "intl", "zlib"):
        extract(archives[name], glib / "subprojects" / specs[name]["directory"])
    patch_meson(archives["pcre2_patch"], glib / "subprojects")
    patch_meson(archives["zlib_patch"], glib / "subprojects")
    machine = glib_build.parent / "cross.ini"
    cross = cross_file(args)
    cross_changed = machine.exists() and machine.read_text() != cross
    machine.write_text(cross)
    entry = glib_build.parent / "meson.py"
    entry.write_text("import sys\nsys.path.insert(0, " + repr(str(tools)) + ")\n"
                     "from mesonbuild.mesonmain import main\nraise SystemExit(main())\n")
    meson = [sys.executable, str(entry)]
    glib_install_prefix = glib_prefix if args.platform == "macos" else prefix
    configure = [*meson, "setup", glib_build, glib, "--cross-file", machine, "--prefix", glib_install_prefix,
                 *glib_options(args.platform)]
    if (glib_build / "meson-private/coredata.dat").is_file():
        configure.append("--wipe" if cross_changed else "--reconfigure")
    run(configure, env)
    run([*meson, "compile", "-C", glib_build, "-j", args.jobs, "glib-2.0", "pcre2-8", "intl"], env)
    if args.platform == "macos":
        run([*meson, "install", "-C", glib_build], env)
        libraries = {name: str(find_library(glib_prefix, name))
                     for name in ("glib-2.0", "pcre2-8", "intl")}
    else:
        installed = json.loads(subprocess.check_output([*meson, "introspect", "--installed", glib_build], env=env))
        for source, destination in installed.items():
            if str(destination).endswith(".h") and Path(source).is_file():
                target = Path(destination)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
        targets = json.loads(subprocess.check_output([*meson, "introspect", "--targets", glib_build], env=env))
        libraries = {}
        for name in ("glib-2.0", "pcre2-8", "intl"):
            item = next(t for t in targets if t["name"] == name and t["type"] == "static library")
            source = Path(item["filename"][0])
            target = prefix / "lib" / source.name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            libraries[name] = str(target)
    lens = sources / specs["lensfun"]["directory"]
    extract(archives["lensfun"], lens)
    lens_build = base / "lensfun"
    configure = [args.cmake, *cmake_fresh_args(args.platform), "-S", lens, "-B", lens_build, "-G", "Ninja",
        "-DCMAKE_MAKE_PROGRAM=" + str(ninja), "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
        "-DCMAKE_INSTALL_PREFIX=" + str(prefix), "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
        "-DCMAKE_C_COMPILER=" + args.cc, "-DCMAKE_CXX_COMPILER=" + args.cxx,
        "-DPKG_CONFIG_EXECUTABLE=" + str(base / "no-host-pkg-config"), "-DGLIB2_BASE_DIR=" + str(glib_prefix),
        "-DGLIB2_INCLUDE_DIRS=" + str(glib_prefix / "include/glib-2.0"),
        "-DGLIB2_GLIB2CONFIG_INCLUDE_PATH=" + str(glib_prefix / "lib/glib-2.0/include"),
        "-DGLIB2_LIBRARIES=" + libraries["glib-2.0"], "-DBUILD_WITH_MSVC_STATIC_RUNTIME=OFF",
        "-DBUILD_TESTS=OFF", "-DBUILD_LENSTOOL=OFF", "-DBUILD_DOC=OFF", "-DBUILD_FOR_SSE=OFF",
        "-DBUILD_FOR_SSE2=OFF", "-DPYTHON=OFF", "-DINSTALL_PYTHON_MODULE=OFF", "-DINSTALL_HELPER_SCRIPTS=OFF"]
    if args.platform == "macos":
        configure += [
            "-DCMAKE_OSX_ARCHITECTURES=" + args.arch,
            "-DCMAKE_OSX_SYSROOT=" + args.sysroot,
            "-DCMAKE_OSX_DEPLOYMENT_TARGET=" + args.minimum,
            "-DCMAKE_INSTALL_NAME_DIR=" + str(prefix / "lib"),
            "-DCMAKE_INSTALL_RPATH=" + ";".join((str(glib_prefix / "lib"), str(prefix / "lib"))),
            "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON", "-DCMAKE_MACOSX_RPATH=ON",
            "-DGLIB2_LIBRARY_DIRS=" + str(glib_prefix / "lib"), "-DBUILD_STATIC=OFF",
        ]
    else:
        configure += ["-DBUILD_STATIC=ON"]
    if args.platform == "ios":
        configure += ["-DCMAKE_SYSTEM_NAME=iOS", "-DCMAKE_OSX_SYSROOT=" + args.sysroot,
                      "-DCMAKE_OSX_ARCHITECTURES=" + args.arch, "-DCMAKE_OSX_DEPLOYMENT_TARGET=" + args.minimum]
    elif args.platform == "android":
        configure += ["-DCMAKE_TOOLCHAIN_FILE=" + args.toolchain, "-DANDROID_ABI=" + args.arch,
                      "-DANDROID_PLATFORM=android-" + args.minimum, "-DANDROID_STL=c++_shared"]
    elif args.platform == "windows":
        configure += ["-DPLATFORM_WINDOWS=ON",
                      "-DCMAKE_INSTALL_DATAROOTDIR=" + str(prefix / "share")]
    run(configure, env)
    run([args.cmake, "--build", lens_build, "--parallel", args.jobs], env)
    run([args.cmake, "--install", lens_build], env)
    notices = prefix / "licenses/lensfun"
    notices.mkdir(parents=True, exist_ok=True)
    for path in Path(__file__).parents[1].joinpath("third_party/lensfun").glob("*.*"):
        if path.is_file():
            shutil.copy2(path, notices / path.name)
    for name, path in {"GLib-COPYING": glib / "LICENSES/LGPL-2.1-or-later.txt", "PCRE2-LICENCE": glib / "subprojects/pcre2-10.44/LICENCE",
                       "proxy-libintl-COPYING": glib / "subprojects/proxy-libintl/COPYING"}.items():
        shutil.copy2(path, notices / name)
    if args.platform == "macos":
        shutil.copy2(glib / "subprojects/zlib-1.3.1/LICENSE", notices / "zlib-LICENSE")
    if args.platform == "macos":
        libraries["lensfun"] = str(find_library(prefix, "lensfun"))
    else:
        libraries["lensfun"] = str(prefix / "lib" / ("lensfun.lib" if args.platform == "windows" else "liblensfun.a"))
    if args.platform == "windows":
        libraries["regex"] = str(prefix / "lib/tre_regex.lib")
        shutil.copy2(lens / "libs/regex/README", notices / "TRE-README")
    if args.platform == "android":
        libraries["iconv"] = str(prefix / "lib/libiconv.a")
        libraries["charset"] = str(prefix / "lib/libcharset.a")
        shutil.copy2(iconv / "COPYING.LIB", notices / "libiconv-COPYING.LIB")
    (prefix / "libraries.json").write_text(json.dumps(libraries, indent=2))


if __name__ == "__main__":
    main()
