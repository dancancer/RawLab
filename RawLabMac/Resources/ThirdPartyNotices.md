# Third-Party Notices for RawLab Mac

The application bundles the following dynamically linked libraries from the
installed Homebrew packages, or rebuilt from the pinned upstream sources in
`RawLabMac/build-dependencies.sh` for macOS 15 arm64/x86_64. Their original license and copyright notices are
included alongside this document. Packaging changes only Mach-O install names
and ad-hoc code signatures. LibRaw also includes the source patches described below.

| Component | Version | Source | Notices |
| --- | --- | --- | --- |
| LibRaw | 0.22.2 | https://github.com/LibRaw/LibRaw/tree/0.22.2 | LibRaw-LICENSE.CDDL, LibRaw-LICENSE.LGPL, LibRaw-COPYRIGHT |
| LLVM OpenMP runtime | 21.1.8 | https://github.com/llvm/llvm-project/tree/llvmorg-21.1.8/openmp | libomp-LICENSE.TXT |
| libjpeg-turbo | 3.1.3 | https://github.com/libjpeg-turbo/libjpeg-turbo/tree/3.1.3 | libjpeg-turbo-LICENSE.md, libjpeg-turbo-README.ijg |
| Little CMS | 2.17 | https://github.com/mm2/Little-CMS/tree/lcms2.17 | Little-CMS-LICENSE |

This software is based in part on the work of the Independent JPEG Group.

LibRaw is distributed here under its CDDL 1.0 option. Its base source is
available from the official release archive below. `LibRaw-Homebrew.rb` records
the older 0.21.5 build used by previous releases, not the current source build.
Other installed recipes are available from Homebrew Core:
https://github.com/Homebrew/homebrew-core/tree/master/Formula

The macOS 15 dependency build uses the official release source archive at
https://www.libraw.org/data/LibRaw-0.22.2.tar.gz with the upstream LibRaw-cmake
build scripts at https://github.com/LibRaw/LibRaw-cmake/tree/eb98e4325aef2ce85d2eb031c2ff18640ca616d3.
Its exact archive checksums and build options are recorded in
`RawLabMac/build-dependencies.sh` in the RawLab source repository.

The pinned source build applies the changes below; a custom Homebrew/system
library build does not necessarily contain them. Local LibRaw changes are
reproducible with `lutools/cmake/patch-libraw.cmake`:
X2D II crop backport (upstream bcb267e), immutable X-Trans tile input, Nikon
HE model recognition, R6 III ColorData v12 parsing, and camera calibration matrices.
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
