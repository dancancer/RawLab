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

Local changes only affect malformed streams:

- Coefficient magnitudes above INT32_MAX are rejected before narrowing, and
  signs use conditional negation instead of an overflowing doubled coefficient.
- Inverse-wavelet, edge-detail and final-green reconstruction compute in 64-bit
  and reject any intermediate value outside int32. Upstream overflows int32 for
  encodable coefficients such as 1073758208 (`hp + hc + 2`, `2 * x`). Final
  sample composition widens before clamping to the 12-bit code range.
- Tiles shorter than 16 rows have no low-frequency row and are rejected before
  reconstruction; upstream reads rows 0 and -1 of an empty plane.

`sony_arw6_bounds_tests.cpp` compiles this file with UBSan on Clang/GCC desktop
builds and drives synthetic containers through `sony_arw6_load_raw()`, from packet
decoding to pixel output. It sweeps large coefficients over every subband, record
and component, plus seeded multi-coefficient combinations, for aligned and
guarded tile heights. CMake registers it when `SONY2FUJI_TEST_LIBRAW_SOURCE`
points at a patched LibRaw source tree, which supplies the internal headers.

`sony_arw6_tests.cpp` uses the linked LibRaw to check dispatch, corrected levels,
well-formed synthetic tiles and refusal of short or out-of-range streams. Both
tests need a RawLab-patched LibRaw (built in this tree, or a prefix carrying
`share/rawlab/libraw-patch.sha256`); a stock system LibRaw skips them. Full pixel
development is tested with an external, unbundled `DSC06333.ARW` via
`SONY2FUJI_TEST_SONY_ARW6`. Sample checks prove decoding and rendering, not a
colorimetric calibration of all Sony cameras.
