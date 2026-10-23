"""Exact, toolchain-specific caches of third-party native build outputs."""
import argparse
import glob
import hashlib
import json
import os
from pathlib import Path
import platform as host_platform
import shutil
import subprocess
import sys

import yaml
from affected_platforms import macos_matrix


ROOT = Path(__file__).resolve().parents[2]
COMMON_INPUTS = (
    "scripts/ci/native_cache.py", "scripts/ci/requirements.txt", "lutools/CMakeLists.txt",
    "lutools/cmake/**/*.cmake", "lutools/cmake/**/CMakeLists.txt",
    "lutools/cmake/**/*.py", "lutools/cmake/**/*.json", "lutools/cmake/**/*.in",
    "lutools/cmake/**/*.inc", "lutools/third_party/rawspeed-camera-calibration.inc",
    "lutools/third_party/lensfun/*.*",
    "lutools/third_party/nikon_he/*",
    "lutools/third_party/libraw/*",
)
PLATFORM_INPUTS = {
    "macos": ("RawLabMac/build*.sh",),
    "windows": ("RawLabWindows/build.ps1", "RawLabWindows/native/CMakeLists.txt"),
    "android": ("RawLabAndroid/app/src/main/cpp/CMakeLists.txt",
                "RawLabAndroid/*.gradle.kts", "RawLabAndroid/app/build.gradle.kts",
                "RawLabAndroid/gradle.properties", "RawLabAndroid/gradle/wrapper/gradle-wrapper.properties"),
    "ios": ("lutools/platform/ios/build-framework.sh",),
}
# OpenCV emits these outside its own subdirectory. Preserve their timestamps too.
OPENCV_HEADERS = ("opencv2", "carotene", "cvconfig.h", "cv_cpu_config.h",
                  "custom_hal.hpp", "opencv_data_config.hpp")


def hash_inputs(root, paths):
    return {path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(set(paths))}


def dependency_inputs(root, platform, arch=None):
    paths = set()
    for pattern in (*COMMON_INPUTS, *PLATFORM_INPUTS[platform]):
        matches = {path for path in root.glob(pattern) if path.is_file()}
        if not matches:
            raise ValueError(f"Native cache input is missing: {pattern}")
        paths.update(matches)
    return {**hash_inputs(root, paths),
            f".github/workflows/ci.yml#{platform}": workflow_identity(root, platform, arch)}


def workflow_identity(root, platform, arch=None):
    workflow = yaml.load((root / ".github/workflows/ci.yml").read_text(), Loader=yaml.BaseLoader)
    job = workflow.get("jobs", {}).get(platform)
    if not isinstance(job, dict):
        raise ValueError(f"Native cache job is missing: {platform}")
    if platform == "macos" and arch is not None:
        matrix = job.get("strategy", {}).get("matrix", {})
        rows = matrix.get("include", [])
        if rows == "${{ fromJSON(needs.changes.outputs.macos_matrix) }}":
            rows = macos_matrix("full")
        if not isinstance(rows, list):
            raise ValueError("Unknown native cache matrix source")
        # Test shards of one architecture build the same dependencies and share one key.
        selected = {json.dumps({name: value for name, value in row.items() if name != "suite"}, sort_keys=True)
                    for row in rows if row.get("arch") == arch}
        if len(selected) != 1:
            raise ValueError(f"Native cache matrix row is missing or ambiguous: {platform}/{arch}")
        matrix["include"] = [json.loads(row) for row in selected]
    # Keep the complete consumer job and shared build defaults, not unrelated jobs.
    inputs = {"job": job, "env": workflow.get("env", {}), "defaults": workflow.get("defaults", {})}
    return hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()


def cache_key(platform, arch, inputs, environment):
    identity = {"platform": platform, "arch": arch, "inputs": inputs, "environment": environment}
    digest = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    return f"native-deps-v1-{platform}-{arch}-{digest}"


def cache_paths(platform, arch):
    if platform == "macos":
        if arch not in ("arm64", "x86_64"):
            raise ValueError(f"Unsupported Mac architecture: {arch}")
        return [f"build/macos-deps/14.0/{arch}/install", f"build/lensfun/14.0/{arch}/install"]
    if platform == "windows":
        return [f"build/windows-native/{path}" for path in (
            "_deps", "dng-sdk", "raw-jpeg", "core/wavelib", "lens-dependencies/install", *OPENCV_HEADERS)]
    if platform == "android":
        base = "RawLabAndroid/app/.cxx/Debug/*"
        return [f"{base}/{abi}/{path}" for abi in ("arm64-v8a", "x86_64")
                for path in ("_deps", "dng-sdk", "raw-jpeg", "core/wavelib", "lens-dependencies/install",
                             ".ninja_deps", ".ninja_log", "configure_fingerprint.bin",
                             "metadata_generation_command.txt", *OPENCV_HEADERS)]
    if platform == "ios":
        base = "lutools/build-ios-libraw/0.22.2"
        paths = [f"{base}/sources"]
        for config in ("iphoneos-arm64", "iphonesimulator-arm64", "iphonesimulator-x86_64"):
            core = f"{base}/core-{config}"
            paths += [f"{core}/{path}" for path in (
                "_deps", "raw-dependencies", "raw-jpeg", "wavelib", "lens-dependencies/install", "build/XCBuildData",
                *OPENCV_HEADERS)]
            # Xcode puts object files in a shared directory, not each dependency's build tree.
            paths += [f"{core}/build/{target}.build" for target in (
                "raw", "raw_r", "rawlab_dng_sdk", "jxl*", "brotli*", "hwy*", "skcms*",
                "opencv_*", "wavelib", "tiff")]
        return paths
    raise ValueError(f"Unsupported platform: {platform}")


def selected_files(root, patterns):
    files = set()
    for pattern in patterns:
        for match in glob.glob(str(root / pattern)):
            path = Path(match)
            if path.is_file() or path.is_symlink():
                files.add(path)
            elif path.is_dir():
                files.update(child for child in path.rglob("*") if child.is_file() or child.is_symlink())
    return files


def command(*arguments):
    return subprocess.check_output(arguments, text=True, stderr=subprocess.STDOUT).strip()


def toolchain_identity(platform):
    identity = {
        "workspace": str(ROOT.resolve()), "host": host_platform.platform(),
        "runner_arch": os.environ.get("RUNNER_ARCH", host_platform.machine()),
        "image_os": os.environ.get("ImageOS", "local"),
        "image_version": os.environ.get("ImageVersion", "local"),
        "python": sys.version, "python_path": sys.executable,
        "cmake": command("cmake", "--version"), "cmake_path": shutil.which("cmake"),
    }
    if platform in ("macos", "ios"):
        identity["xcode"] = command("xcodebuild", "-version")
        identity["developer_dir"] = os.environ.get("DEVELOPER_DIR") or command("xcode-select", "-p")
        identity["compiler"] = command("xcrun", "clang", "--version")
        sdks = ("macosx",) if platform == "macos" else ("iphoneos", "iphonesimulator")
        for sdk in sdks:
            identity[sdk] = {field: command("xcrun", "--sdk", sdk, f"--show-sdk-{field}")
                             for field in ("path", "version", "build-version")}
        if platform == "macos":
            identity["minimum_os"] = os.environ.get("MACOSX_DEPLOYMENT_TARGET", "14.0")
            identity["homebrew"] = command("brew", "list", "--versions", "autoconf", "automake",
                                            "libtool", "m4", "pkgconf")
        else:
            identity["minimum_os"] = os.environ.get("IOS_DEPLOYMENT_TARGET", "18.0")
    elif platform == "windows":
        program_files = Path(os.environ["ProgramFiles(x86)"])
        vswhere = program_files / "Microsoft Visual Studio/Installer/vswhere.exe"
        installation = command(str(vswhere), "-latest", "-products", "*", "-requires",
                               "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath")
        vs = Path(installation)
        version = (vs / "VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt").read_text().strip()
        compiler = vs / "VC/Tools/MSVC" / version / "bin/Hostx64/x64"
        identity["msvc"] = {"path": str(compiler), "version": version,
                            **hash_inputs(compiler, [compiler / name for name in ("cl.exe", "link.exe", "lib.exe")])}
        identity["windows_sdks"] = sorted(path.name for path in (program_files / "Windows Kits/10/Include").iterdir())
    elif platform == "android":
        sdk = Path(os.environ["ANDROID_HOME"])
        ndk = sdk / "ndk/27.2.12479018"
        identity["ndk"] = (ndk / "source.properties").read_text()
        identity["compiler"] = command(str(ndk / "toolchains/llvm/prebuilt/linux-x86_64/bin/clang"), "--version")
        identity["android_cmake"] = command(str(sdk / "cmake/3.22.1/bin/cmake"), "--version")
        identity["android_home"] = str(sdk)
        identity["java"] = command("java", "-version")
    return identity


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("key", "inventory"))
    parser.add_argument("--platform", choices=tuple(PLATFORM_INPUTS), required=True)
    parser.add_argument("--arch", required=True)
    args = parser.parse_args()
    paths = cache_paths(args.platform, args.arch)
    if args.mode == "inventory":
        files = selected_files(ROOT, paths)
        report = {"files": len(files), "bytes": sum(path.lstat().st_size for path in files)}
        print(json.dumps(report, indent=2))
        (ROOT / "build/ci/native-cache-size.json").write_text(json.dumps(report, indent=2) + "\n")
        return
    inputs = dependency_inputs(ROOT, args.platform, args.arch)
    environment = toolchain_identity(args.platform)
    key = cache_key(args.platform, args.arch, inputs, environment)
    report = {"key": key, "inputs": inputs, "environment": environment, "paths": paths}
    print(json.dumps(report, indent=2))
    output = ROOT / "build/ci/native-cache.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write(f"key={key}\npaths<<RAWLAB_CACHE_PATHS\n" + "\n".join(paths) + "\nRAWLAB_CACHE_PATHS\n")


if __name__ == "__main__":
    main()
