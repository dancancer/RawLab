# LibRaw decoder backports

`sony_arw6.cpp` is backported from LibRaw commit
[`e419de08001de28ae6988ecb22df47e52b9c5eaa`](https://github.com/LibRaw/LibRaw/tree/e419de08001de28ae6988ecb22df47e52b9c5eaa).
It decodes Sony ARW6 / Compressed RAW 2, including tiled streams and partial final rows.
The companion `cmake/libraw-sony-arw6.cmake` backports TIFF dispatch, decoder flags,
ILCE-7M5 identification/crop/color matrix, and the final upstream black/white/linear
maximum correction without changing the released LibRaw 0.22.2 data layout.

The upstream copyright and LGPL 2.1 / CDDL 1.0 dual-license header is retained.
The complete licenses are supplied by the pinned LibRaw source distribution and
packaged alongside the application.

Original upstream SHA-256: `e7dc103273a6680e95ec5f423ac745635b20da9e38c1f49dc18bca1f60de5946`.

Local changes reject coefficient magnitudes above INT32_MAX before narrowing,
and apply signs with conditional negation instead of an overflowing doubled
coefficient. These guards affect malformed streams. The exact upstream sign
expression overflows for a validly encoded magnitude 1073758208 and sign bit 1;
`sony_arw6_bounds_tests.cpp` exercises the decoder helpers directly, with UBSan
enabled on Clang/GCC desktop builds.

The synthetic regression checks dispatch, corrected levels and damaged-stream
refusal. Full pixel development is tested with an external, unbundled
`DSC06333.ARW` via `SONY2FUJI_TEST_SONY_ARW6`. Sample checks prove decoding and
rendering, not a colorimetric calibration of all Sony cameras.
