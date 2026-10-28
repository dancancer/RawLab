# LibRaw backports and local patches

## Parallel VNG

`vng_parallel.inc` preserves the active-channel integer arithmetic from the
pinned LibRaw 0.22.2 `src/demosaic/misc_demosaic.cpp`. The companion
`cmake/libraw-vng.cmake` inserts it after bilinear interpolation and the VNG
lookup-table construction. It is a local optimization, not an upstream change
or a different demosaic algorithm.

For Bayer filters with OpenMP and more than one available worker, each batch reads an immutable
snapshot of at most 256 output rows plus a two-row halo on each side. The last
four source rows survive into the next batch before any overwritten image
data can be read. Additional storage is bounded by `260 * width * 8` bytes,
not a second full image. The original scalar path remains available without
OpenMP, with one worker, or for non-Bayer filters. Progress and cancellation run on the calling thread
at the original 256-row boundaries, outside parallel regions.

`vng_parallel_tests.cpp` compares every active channel against fingerprints
captured from the unmodified implementation, including borders, partial batches,
three/four-color Bayer patterns and flat inputs. Separate CTest invocations
select one and four OpenMP workers and check callback order and cancellation.
`raw_decode_benchmark` is an opt-in Release diagnostic: it separates open/unpack,
LibRaw processing, demosaic/mix-green and complete core processing with/without
embedded-preview matching. Differences between separate timing runs are not
reported as exact isolated conversion or preview costs.

The original LibRaw LGPL 2.1 / CDDL 1.0 licensing also applies to the derived
pixel arithmetic. Licenses are supplied and packaged with the pinned dependency.

## Sony ARW6

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
