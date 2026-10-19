# RawLab iOS Native Framework

The shared DCP compiler uses JSON for Modern C++ (Niels Lohmann), under MIT.
Its original notice is included as `Licenses/nlohmann-JSON-MIT.txt`.

OpenCV 4.12.0 (core/imgproc) and wavelib are statically linked for linear-light
wavelet denoising. OpenCV uses Apache 2.0; wavelib uses BSD 3-Clause. See the
included `OpenCV-LICENSE` and `wavelib-COPYRIGHT`.
Sources: https://github.com/opencv/opencv/tree/4.12.0 and
https://github.com/rafat/wavelib. Exact revisions and archive hashes are pinned
in `lutools/cmake/denoise-dependencies.cmake`. Local stationary-wavelet column
and inverse-transform optimizations are in `lutools/cmake/wavelib-swt-columns.c.inc`
and `wavelib-iswt2.c.inc`.

libtiff 4.7.1 is statically linked for the structured rendered-DNG writer. The
writer stores baked display-sRGB output as float32 LinearRaw and does not embed
original sensor data or claim reversible RAW edits. See `libtiff-LICENSE.md`.
Source: https://download.osgeo.org/libtiff/tiff-4.7.1.tar.gz

LibRaw 0.22.2 is statically linked into sony2fuji.framework under its CDDL 1.0
option. Copyright and both upstream license texts accompany the framework.
Base source: https://www.libraw.org/data/LibRaw-0.22.2.tar.gz

The corresponding local modifications and build instructions are in the RawLab
source repository: https://github.com/dancancer/RawLab
See `lutools/cmake/patch-libraw.cmake` and `lutools/platform/ios/build-framework.sh`.
Changes cover X2D II crop, X-Trans tile concurrency, Nikon HE recognition and
R6 III ColorData v12. R6 III layout/matrix evidence comes from ErikCJohansson's
contribution: https://github.com/LibRaw/LibRaw/issues/821

Four camera matrices are adapted from RawSpeed contributors' cameras.xml:
https://github.com/darktable-org/rawspeed/blob/c835b05aecfacb7343f7c424abd620aa12116c3f/data/cameras.xml
The extracted data remains under CC BY-SA 3.0:
https://creativecommons.org/licenses/by-sa/3.0/
See `rawspeed-camera-calibration.inc`. Changes are extraction into LibRaw table
syntax while retaining metadata-derived black/white levels. No RawSpeed decoder
code is linked.

Lens correction statically links Lensfun 0.3.4, GLib 2.84.4, PCRE2 10.44 and
proxy-libintl. Their license texts and the offline DB1 (2026-10-12) database
attribution are in `Licenses/lensfun`. Lensfun is LGPL-3.0-or-later; GLib is
LGPL-2.1-or-later; PCRE2 uses its BSD license; proxy-libintl uses LGPL-2.0-or-later.
The database is CC BY-SA 3.0, not the library license. Pinned source URLs/hashes
are in `lutools/cmake/lens-dependencies.json`. The source-build script adjusts
GLib's pipe2 declaration probe for the iOS 18 deployment target; the lens library
and database are unmodified. PCRE2 JIT is disabled. No extra runtime dylibs ship.

Adobe DNG SDK 1.7.1 Build 2724 is statically linked through the shared DNG decoder wrapper to
support DNG 1.7 JPEG XL-compressed images. Its source archive and checksum are
pinned by `lutools/cmake/dng-sdk.cmake`; the SDK license and upstream notices are
copied into the framework's `Licenses/dng-sdk/` directory, including JPEG XL,
Brotli, Highway and skcms notices. A local extracted SDK
source may be supplied with
`-DFETCHCONTENT_SOURCE_DIR_RAWLAB_DNG_SOURCE=/path/to/dng_sdk_1_7_1` when
building, without changing the production script's source pin.
The SDK validator and XMP editing are disabled. The local adapter adds missing
`qDNGUseXMP` guards to `dng_jxl.cpp`; image decoding is unchanged.
This product includes DNG technology under license by Adobe.

The white-balance temperature model includes Adobe DNG SDK-derived code;
see Adobe-DNG-SDK-LICENSE.txt. Embedded stb image decoding/encoding uses its
MIT license option; see stb-MIT-LICENSE.txt. System zlib,
Metal and Foundation are supplied by iOS. No OpenMP, LCMS, JPEG/JasPer or
commercial Nikon/TicoRAW SDK is linked into LibRaw in this build.
