# Third-Party Notices for RawLab Mac 0.1

The application bundles the following dynamically linked libraries from the
installed Homebrew packages, or rebuilt from the pinned upstream sources in
`RawLabMac/build-dependencies.sh` for macOS 15 arm64/x86_64. Their original license and copyright notices are
included alongside this document. Packaging changes only Mach-O install names
and ad-hoc code signatures; it does not modify these libraries' source code.

| Component | Version | Source | Notices |
| --- | --- | --- | --- |
| LibRaw | 0.21.5 | https://github.com/LibRaw/LibRaw/tree/0.21.5 | LibRaw-LICENSE.CDDL, LibRaw-LICENSE.LGPL, LibRaw-COPYRIGHT |
| LLVM OpenMP runtime | 21.1.8 | https://github.com/llvm/llvm-project/tree/llvmorg-21.1.8/openmp | libomp-LICENSE.TXT |
| libjpeg-turbo | 3.1.3 | https://github.com/libjpeg-turbo/libjpeg-turbo/tree/3.1.3 | libjpeg-turbo-LICENSE.md, libjpeg-turbo-README.ijg |
| JasPer | 4.2.8 | https://github.com/jasper-software/jasper/tree/version-4.2.8 | JasPer-LICENSE.txt, JasPer-COPYRIGHT.txt |
| Little CMS | 2.17 | https://github.com/mm2/Little-CMS/tree/lcms2.17 | Little-CMS-LICENSE |

This software is based in part on the work of the Independent JPEG Group.

LibRaw is distributed here under its CDDL 1.0 option. The v0.1 GitHub Release
provides the official LibRaw 0.21.5 source tag archive as
`LibRaw-0.21.5-source.tar.gz`. The Homebrew build recipe is included as
`LibRaw-Homebrew.rb`. Other installed recipes are available from Homebrew Core:
https://github.com/Homebrew/homebrew-core/tree/master/Formula

The macOS 15 dependency build uses the official release source archive at
https://www.libraw.org/data/LibRaw-0.21.5.tar.gz with the upstream LibRaw-cmake
build scripts at https://github.com/LibRaw/LibRaw-cmake/tree/eb98e4325aef2ce85d2eb031c2ff18640ca616d3.
Its exact archive checksums and build options are recorded in
`RawLabMac/build-dependencies.sh` in the RawLab source repository.

RawLab's white-balance implementation incorporates the Adobe DNG SDK's
temperature conversion model; see Adobe-DNG-SDK-LICENSE.txt. The embedded stb
image decoder/writer use their MIT option; see stb-MIT-LICENSE.txt. Their original
dual-license notices remain in the source headers under lutools/src/core.

Fujifilm LUT data and film simulation names are attributed to their respective
rights holders; no ownership of these assets or official affiliation is claimed.
The film-label artwork and application icon are generated assets, not official
product artwork. See their generation records in the RawLab source repository.

RawLab source and releases: https://github.com/dancancer/RawLab
