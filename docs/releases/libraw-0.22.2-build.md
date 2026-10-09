# LibRaw Source for RawLab v0.4.1

`LibRaw-0.22.2-patched-source.tar.gz` contains the corresponding LibRaw source
used by RawLab v0.4.1, not the unmodified upstream archive:

- `LibRaw-0.22.2/`: upstream 0.22.2 with RawLab camera, metadata, crop and
  X-Trans fixes already applied. Upstream COPYRIGHT, LGPL and CDDL are retained.
- `LibRaw-cmake-eb98e4325aef2ce85d2eb031c2ff18640ca616d3/`: the pinned CMake
  wrapper used for Mac and iOS builds, with its upstream license.
- `rawlab-build/`: the patch, attributed calibration data and platform build
  files from this release. These files retain their repository-relative layout.

The original LibRaw archive is
`https://www.libraw.org/data/LibRaw-0.22.2.tar.gz`, SHA-256
`de86b035655accff8d4010f1a221fdf50d353cb7b1422ba26f14a0db92612cfa`.
The LibRaw-cmake archive SHA-256 is
`3cd218bf6d1254de86e27269541277fbfc5bae57a9002ce0b46fbe2a97088b43`.

The patch is idempotent and may be checked against the supplied source:

```sh
cmake -DLIBRAW_SOURCE_DIR="$PWD/LibRaw-0.22.2" \
  -P rawlab-build/lutools/cmake/patch-libraw.cmake
```

For complete client sources, use the `v0.4.1` tag at
<https://github.com/dancancer/RawLab>. Build from that checkout:

```sh
RAWLAB_ARCH=arm64 MACOSX_DEPLOYMENT_TARGET=15.0 bash RawLabMac/build-dependencies.sh
# Use RAWLAB_ARCH=x86_64 for Intel dependencies.
bash lutools/build.sh ios
# Android: follow RawLabAndroid/README.md; signing keys are not supplied.
# Windows: run RawLabWindows/build.ps1 -SelfContained on an x64 build host.
```

Mac enables OpenMP, LCMS, JPEG and DNG deflate. Windows enables OpenMP and zlib;
Android and iOS enable zlib without the optional LCMS/JPEG/JasPer integrations.
The iOS framework statically includes LibRaw; all client and framework sources
needed to rebuild it are available at the same tag. No signing keys, RAW photos,
proprietary profiles or build-machine credentials are included in this archive.
