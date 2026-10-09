# RawLab iOS Native Framework

OpenCV 4.12.0 (core/imgproc) and wavelib are statically linked for linear-light
wavelet denoising. OpenCV uses Apache 2.0; wavelib uses BSD 3-Clause. See the
included `OpenCV-LICENSE` and `wavelib-COPYRIGHT`.
Sources: https://github.com/opencv/opencv/tree/4.12.0 and
https://github.com/rafat/wavelib. Exact revisions and archive hashes are pinned
in `lutools/cmake/denoise-dependencies.cmake`. Local stationary-wavelet column
and inverse-transform optimizations are in `lutools/cmake/wavelib-swt-columns.c.inc`
and `wavelib-iswt2.c.inc`.

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

The white-balance temperature model includes Adobe DNG SDK-derived code;
see Adobe-DNG-SDK-LICENSE.txt. Embedded stb image decoding/encoding uses its
MIT license option; see stb-MIT-LICENSE.txt. System zlib,
Metal and Foundation are supplied by iOS. No OpenMP, LCMS, JPEG/JasPer or
commercial Nikon/TicoRAW SDK is linked into LibRaw in this build.
