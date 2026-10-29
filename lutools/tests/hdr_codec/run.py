#!/usr/bin/env python3
"""Build an isolated, pinned Apple HDR codec probe; never manage shared devices."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET


HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "cmake"))
from hdr_sources import MANIFEST, digest, prepare
from public_fixtures import inspect as inspect_public_fixture
TARGETS = {
    "macos-arm64": ("MacOSX", "arm64", "14.0"),
    "macos-x86_64": ("MacOSX", "x86_64", "14.0"),
    "ios-arm64": ("iPhoneOS", "arm64", "18.0"),
    "ios-simulator-arm64": ("iPhoneSimulator", "arm64", "18.0"),
    "ios-simulator-x86_64": ("iPhoneSimulator", "x86_64", "18.0"),
}



def command(args, log):
    print(f"Running {args[0]} -> {log.name}", flush=True)
    with log.open("w") as output:
        result = subprocess.run([str(x) for x in args], stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        print("\n".join(log.read_text(errors="replace").splitlines()[-35:]), flush=True)
        raise subprocess.CalledProcessError(result.returncode, args)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=TARGETS, required=True)
    parser.add_argument("--cache-root", type=Path, required=True, help="Primary workspace .cache/shared")
    parser.add_argument("--build-root", type=Path, required=True, help="Task-owned temporary build directory")
    parser.add_argument("--fixture-dir", type=Path, help="Read-only, explicitly authorized phone photos")
    parser.add_argument("--public-fixture-dir", type=Path, help="Pinned public Android originals, verified against public-fixtures.json")
    parser.add_argument("--final-fixture", type=Path, help="Explicit read-only original for full-resolution production verification")
    parser.add_argument("--run-tests", action="store_true")
    parser.add_argument("--device-udid", help="Explicit task-owned, already booted simulator")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if platform.system() != "Darwin" or args.jobs < 1:
        parser.error("This probe needs macOS and a positive job count")
    if args.run_tests and args.target == "ios-arm64":
        parser.error("Device binary is build-only; physical execution needs a separately signed private harness")
    if args.run_tests and "simulator" in args.target and not args.device_udid:
        parser.error("Simulator execution requires an explicit task-owned UDID")
    public=[]
    if args.public_fixture_dir:
        if args.fixture_dir:
            parser.error("Choose either personal or pinned public fixture directory")
        args.fixture_dir=args.public_fixture_dir
        public=json.loads((HERE/"public-fixtures.json").read_text())["fixtures"]
        for fixture in public:
            inspect_public_fixture(args.fixture_dir/fixture["filename"],fixture)
    inputs=set(args.fixture_dir.resolve().glob("*")) if args.fixture_dir else set()
    inputs={p for p in inputs if p.suffix.lower() in {".heic",".heif",".jpg",".jpeg"}}
    if public and {p.name for p in inputs}!={f["filename"] for f in public}:
        parser.error("Public fixture directory contains unlisted image files")
    if args.final_fixture:
        inputs.add(args.final_fixture.resolve())
    def input_stamps():
        return {str(p):{"sha256":digest(p),"bytes":p.stat().st_size,"mtime_ns":p.stat().st_mtime_ns} for p in sorted(inputs)}
    original_stamps=input_stamps()
    pin = json.loads(MANIFEST.read_text())
    cache = args.cache_root.resolve()
    build = args.build_root.resolve() / args.target
    build.mkdir(parents=True, exist_ok=True)
    uhdr, jpeg = prepare(cache)
    sdk_name, arch, minimum = TARGETS[args.target]
    sdk = subprocess.check_output(["xcrun", "--sdk", sdk_name.lower(), "--show-sdk-path"], text=True).strip()
    common = [f"-DCMAKE_OSX_SYSROOT={sdk}", f"-DCMAKE_OSX_ARCHITECTURES={arch}", f"-DCMAKE_SYSTEM_PROCESSOR={arch}",
              f"-DCMAKE_OSX_DEPLOYMENT_TARGET={minimum}", "-DCMAKE_BUILD_TYPE=Release"]
    if sdk_name != "MacOSX":
        common += ["-DCMAKE_SYSTEM_NAME=iOS", "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY"]
    jpeg_build, jpeg_prefix, probe = build / "jpeg", build / "jpeg-install", build / "probe"
    command(["cmake", "-S", jpeg, "-B", jpeg_build, *common, "-DENABLE_SHARED=OFF", "-DENABLE_STATIC=ON",
             "-DWITH_TURBOJPEG=OFF", "-DWITH_TOOLS=OFF", "-DWITH_TESTS=OFF", "-DWITH_SIMD=OFF"], build / "jpeg-configure.log")
    command(["cmake", "--build", jpeg_build, "--target", "jpeg-static", "--parallel", args.jobs], build / "jpeg-build.log")
    command(["cmake", "--install", jpeg_build, "--prefix", jpeg_prefix], build / "jpeg-install.log")
    probe_options = [f"-DHDR_ULTRAHDR_SOURCE={uhdr}", f"-DHDR_JPEG_PREFIX={jpeg_prefix}"]
    probe_options.append(f"-DHDR_EXTERNAL_FIXTURE_ROOT={args.fixture_dir.resolve() if args.fixture_dir else ''}")
    probe_options.append(f"-DHDR_FINAL_FIXTURE={args.final_fixture.resolve() if args.final_fixture else ''}")
    if args.run_tests and "simulator" in args.target:
        probe_options.append(f"-DCMAKE_CROSSCOMPILING_EMULATOR=xcrun;simctl;spawn;{args.device_udid}")
    command(["cmake", "-S", HERE, "-B", probe, *common, *probe_options], build / "probe-configure.log")
    command(["cmake", "--build", probe, "--target", "hdr_codec_probe", "--parallel", args.jobs], build / "probe-build.log")
    architectures = subprocess.check_output(["lipo", "-archs", str(probe / "hdr_codec_probe")], text=True).strip()
    if architectures != arch:
        raise RuntimeError(f"Unexpected built architecture: {architectures}")
    dependencies = subprocess.check_output(["otool", "-L", str(probe / "hdr_codec_probe")], text=True)
    for line in dependencies.splitlines()[1:]:
        if not line.strip().startswith(("/System/Library/", "/usr/lib/")):
            raise RuntimeError(f"Unexpected non-system dynamic dependency: {line.strip()}")
    licenses = build / "licenses"
    for name, source in [("libultrahdr", uhdr), ("libjpeg_turbo", jpeg)]:
        output = licenses / name
        output.mkdir(parents=True, exist_ok=True)
        for filename in pin[name]["license_files"]:
            shutil.copyfile(source / filename, output / filename)
    if args.run_tests:
        try:
            command(["ctest", "--test-dir", probe, "--output-on-failure", "--output-junit", build / "tests.xml"], build / "ctest.log")
        finally:
            if input_stamps()!=original_stamps:
                raise RuntimeError("Read-only fixture changed during verification")
        print((build / "ctest.log").read_text(), flush=True)
        tests = ET.parse(build / "tests.xml").getroot().findall(".//testcase")
        if not tests or any(test.find("skipped") is not None for test in tests):
            raise RuntimeError("A feasibility run must execute its cases; skips are not acceptance")
    report = {"target": args.target, "host_arch": platform.machine(), "host_os": platform.mac_ver()[0],
              "sdk": sdk, "deployment_target": minimum, "architecture": architectures,
              "tests_executed": args.run_tests, "physical_device_acceptance": False,
              "source_sha256": {str(p.relative_to(HERE.parents[1])):digest(p) for p in sorted({
                  *HERE.glob("*.mm"),*HERE.glob("*.cpp"),*HERE.glob("*.py"),HERE/"CMakeLists.txt",HERE/"DeviceInfo.plist.in",
                  *HERE.parents[1].glob("src/core/hdr_*"),HERE.parents[1]/"src/core/photo_geometry.cpp",
                  HERE.parents[1]/"src/platform/hdr_image_apple.mm",HERE.parents[1]/"src/platform/hdr_image.h",
                  HERE.parents[1]/"include/sony2fuji/ffi/sony2fuji_hdr.h"}) if p.is_file()},
              "fixtures":original_stamps,"public_fixture_attribution":public,"originals_unchanged":input_stamps()==original_stamps,
              "dependency_manifest_sha256": digest(MANIFEST)}
    (build / "provenance.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Built {args.target}; tests_executed={args.run_tests}; physical_device_acceptance=false", flush=True)


if __name__ == "__main__":
    main()
