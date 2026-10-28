# Third-Party Notices for RawLab Mac

The application bundles libraries rebuilt from pinned upstream sources in
`RawLabMac/build-dependencies.sh` and `RawLabMac/build-lens-dependency.sh`,
targeting macOS 14 arm64/x86_64. Their original license and copyright notices are
included alongside this document. Packaging changes only Mach-O install names
and code signatures. LibRaw also includes the source patches described below.

| Component | Version | Source | Notices |
| --- | --- | --- | --- |
| Sparkle | 2.10.0 | https://github.com/sparkle-project/Sparkle/tree/2.10.0 | Sparkle-LICENSE.txt (MIT) |
| Restormer real denoising | Upstream pretrained checkpoint | https://github.com/swz30/Restormer | DualDn/Restormer-LICENSE.txt (Academic Public License, noncommercial) |
| JSON for Modern C++ | Vendored header | https://github.com/nlohmann/json | nlohmann-JSON-MIT.txt |
| DualDn Big | 7ec5f6a21c04321beb0d3297d6e9ac5f50635555 | https://github.com/OpenImagingLab/DualDn | DualDn/LICENSE (CC BY-NC 4.0, OpenImagingLab 2024) |
| ONNX Runtime | 1.23.2 | https://github.com/microsoft/onnxruntime/tree/v1.23.2 | DualDn/ONNX-Runtime-LICENSE, DualDn/ONNX-Runtime-ThirdPartyNotices.txt |
| LibRaw | 0.22.2 | https://github.com/LibRaw/LibRaw/tree/0.22.2 | LibRaw-LICENSE.CDDL, LibRaw-LICENSE.LGPL, LibRaw-COPYRIGHT |
| Nikon HE decoder | Local C++ adaptation of dnglab 0f044c2c and LibRaw PR 826 | https://github.com/dnglab/dnglab/pull/835 | nikon-he/README.md, nikon-he/LICENSE.LGPL-2.1 |
| LLVM OpenMP runtime | 21.1.8 | https://github.com/llvm/llvm-project/tree/llvmorg-21.1.8/openmp | libomp-LICENSE.TXT |
| libjpeg-turbo | 3.1.3 | https://github.com/libjpeg-turbo/libjpeg-turbo/tree/3.1.3 | libjpeg-turbo-LICENSE.md, libjpeg-turbo-README.ijg |
| Little CMS | 2.17 | https://github.com/mm2/Little-CMS/tree/lcms2.17 | Little-CMS-LICENSE |
| Adobe DNG SDK | 1.7.1 Build 2724 | https://www.adobe.com/go/dng_sdk | dng-sdk/Adobe-DNG-SDK-LICENSE.txt |
| JPEG XL, Brotli, Highway, skcms | Sources bundled with the pinned DNG SDK | https://download.adobe.com/pub/adobe/dng/dng_sdk_1_7_1_2724_20260908.zip | dng-sdk/ directory |
| OpenCV / opencv_contrib | 4.12.0 | https://github.com/opencv/opencv/tree/4.12.0 and https://github.com/opencv/opencv_contrib/tree/4.12.0 | OpenCV/ directory |
| libtiff | 4.7.1 | https://download.osgeo.org/libtiff/tiff-4.7.1.tar.gz | libtiff-LICENSE.md |
| Lensfun library | 0.3.4 | https://github.com/lensfun/lensfun/tree/v0.3.4 | Lensfun/lgpl-3.0.txt, Lensfun/UPSTREAM-README.md |
| Lensfun database | DB1 snapshot, 2026-10-12 | https://lensfun.github.io/ | Lensfun/database-CC-BY-SA-3.0.txt, Lensfun/README.md |
| GLib | 2.84.4 | https://github.com/GNOME/glib/tree/2.84.4 | Lensfun/GLib-COPYING |
| proxy-libintl | 33934de09af6a6627eb44e310a8079df009abdbb | https://github.com/frida/proxy-libintl/tree/33934de09af6a6627eb44e310a8079df009abdbb | Lensfun/proxy-libintl-COPYING |
| PCRE2 | 10.44 | https://github.com/PCRE2Project/pcre2/tree/pcre2-10.44 | Lensfun/PCRE2-LICENCE |
| zlib | 1.3.1 | https://zlib.net/fossils/zlib-1.3.1.tar.gz | Lensfun/zlib-LICENSE |
| Alibaba Cloud RUM PC SDK (`libalibabacloud_rum.dylib`) | 0.4.4 | https://help.aliyun.com/zh/cms/cloudmonitor-2-0/access-pc-platform-application, archive `AlibabaCloud_RUM_macOS_0.4.4.zip` SHA-256 `b837d135b16eb1ec087cfba8796be2425765cb39e16b161d663364135e59085e` | Vendor binary shipped without license text; redistribution terms pending vendor confirmation. RawLab links it under RawLab-Aliyun-RUM-Exception.txt |
| libcurl (bundled inside the RUM PC SDK) | 7.68.0-DEV | https://curl.se/ | libcurl-COPYING.txt |

The Alibaba Cloud RUM SDK and its libcurl are unmodified vendor binaries; packaging changes
only their Mach-O install names and code signatures. They are present only in builds with
usage analytics (the default release build); `RAWLAB_RUM=0` builds omit both.

Lensfun is built unmodified from a checksum-pinned source archive using
`RawLabMac/build-lens-dependency.sh`, without Python tools, lenstool or libpng.
The library is LGPL-3.0; the unmodified offline database is CC BY-SA 3.0 and
remains separate from RawLab code. Lensfun database authors/contributors retain
their rights; the project and calibration contribution service are at
https://lensfun.github.io/. Database provenance is retained in Lensfun/README.md.
GLib and proxy-libintl retain their original LGPL terms; PCRE2 retains its original BSD
license and PCRE2 exception. Their source releases are available at
https://download.gnome.org/sources/glib/2.84/,
https://github.com/frida/proxy-libintl, and
https://github.com/PCRE2Project/pcre2/releases/tag/pcre2-10.44.

Rendered DNG serialization uses libtiff with a virtual output-referred linear-sRGB
profile. It does not embed original sensor data or claim reversible RAW edits.
This product includes DNG technology under license by Adobe.

The optional display-chroma filter uses OpenCV core, imgproc and ximgproc,
with their transitive modules. Pinned source archives and build options are in
`RawLabMac/build-chroma-dependency.sh`. OpenCV's Apache 2.0 notices, the guided
filter's BSD notice and the installed third-party notices are included in
`OpenCV/`. No darktable denoising implementation or executable is bundled.

This software is based in part on the work of the Independent JPEG Group.

The optional DualDn package retains the original trained weights. Local changes
split the model into fixed-size RAW, ISP and RGB ONNX graphs and add tiled execution
and a scene-linear bridge in RawLab. The model manifest records source and weight
checksums. DualDn and its converted model retain their upstream license; they are
not relicensed under RawLab's license. Apple Silicon release builds bundle these
components; development and Intel release builds do not.

This product includes DNG technology under license by Adobe.
JPEG XL DNG decoding uses the DNG SDK only for the JPEG XL decoder path.
The SDK is built without its command-line validator, XMP metadata editing or
XMP toolkit. The local CMake adapter adds missing `qDNGUseXMP` guards to
`dng_jxl.cpp`; image decoding is unchanged. JPEG XL and its bundled dependencies
are statically linked into the DNG SDK dependency. Their full original licenses
are retained under `dng-sdk/`.

LibRaw is distributed here under its LGPL 2.1 option. Its base source is
available from the official release archive below. `LibRaw-Homebrew.rb` records
the older 0.21.5 build used by previous releases, not the current source build.
Other installed recipes are available from Homebrew Core:
https://github.com/Homebrew/homebrew-core/tree/master/Formula

The macOS dependency build uses the official release source archive at
https://www.libraw.org/data/LibRaw-0.22.2.tar.gz with the upstream LibRaw-cmake
build scripts at https://github.com/LibRaw/LibRaw-cmake/tree/eb98e4325aef2ce85d2eb031c2ff18640ca616d3.
Its exact archive checksums and build options are recorded in
`RawLabMac/build-dependencies.sh` in the RawLab source repository.

The pinned source build applies the changes below; a custom Homebrew/system
library build does not necessarily contain them. Local LibRaw changes are
reproducible with `lutools/cmake/patch-libraw.cmake`:
X2D II crop backport (upstream bcb267e), immutable X-Trans tile input, Nikon
HE model recognition and decoding, R6 III ColorData v12 parsing, and camera calibration matrices.
The Nikon HE decoder is LGPL 2.1, not CDDL; see `nikon-he/README.md` and
`nikon-he/LICENSE.LGPL-2.1` for attribution, source links and modifications.
R6 III layout/matrix evidence is from ErikCJohansson's contribution at
https://github.com/LibRaw/LibRaw/issues/821; the parser reuses LibRaw's existing
v12 offsets. This is a local sample-verified correction, not upstream support.
The matrix data in `lutools/third_party/rawspeed-camera-calibration.inc` is
adapted from RawSpeed contributors' `data/cameras.xml` at commit
c835b05aecfacb7343f7c424abd620aa12116c3f:
https://github.com/darktable-org/rawspeed/blob/c835b05aecfacb7343f7c424abd620aa12116c3f/data/cameras.xml
That extracted/adapted data remains licensed under CC BY-SA 3.0:
https://creativecommons.org/licenses/by-sa/3.0/
Changes are extraction into LibRaw table syntax; black/white levels remain
metadata-driven. No RawSpeed decoder code is included.

RawLab's white-balance implementation incorporates the Adobe DNG SDK's
temperature conversion model; see Adobe-DNG-SDK-LICENSE.txt. The embedded stb
image decoder/writer use their MIT option; see stb-MIT-LICENSE.txt. Their original
dual-license notices remain in the source headers under lutools/src/core.

Fujifilm LUT data and film simulation names are attributed to their respective
rights holders; no ownership of these assets or official affiliation is claimed.
The film-label artwork and application icon are generated assets, not official
product artwork. See their generation records in the RawLab source repository.

RawLab source and releases: https://github.com/dancancer/RawLab

Linear wavelet denoising uses wavelib (BSD 3-Clause), pinned to
7f61bf592f3c470b2a7d8199431fde821d7253ac, with a local SWT2 inverse phase
correction validated against PyWavelets. The DWT/IDWT filter kernels are unchanged.
See wavelib-COPYRIGHT and lutools/cmake/wavelib-iswt2.c.inc in the source.
Source: https://github.com/rafat/wavelib
No darktable denoising code or noise-profile database is included.

Sony ARW6 decoding and A7 V metadata are backported from LibRaw e419de0;
A1 II, EOS R50 V and PowerShot V1 metadata come from upstream PRs 775/846,
784 and 856. The original LGPL/CDDL terms apply. Sigma X3F tools are enabled;
Roland Karlsson's BSD-style notice is retained in LibRaw-X3F-BSD.txt.
Pinned sources and scope: docs/reference/raw-format-support.md.
