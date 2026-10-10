# macOS Effects and Metal Denoising Verification

## Scope

- Base: `origin/development` at `c3a2e4c`.
- Branch: `codex/macos-effects-gpu-denoise`.
- Migrated the vignette/grain implementation, Metal stage, Mac controls and tests.
- Added Metal acceleration for wavelet SWT/threshold/inverse and display-chroma guided filtering.
- Kept CPU noise estimation/calibration, normalization, OpenCV Lab conversion, outer filtering and coarse resizing. RAW decoding and legacy FBDD remain CPU work.
- Kept request v2 unchanged and preserved development's separate denoise build flags.

## Verification

All commands below completed successfully on the local Apple Silicon Mac.

```sh
bash RawLabMac/build.sh
bash RawLabMac/tests/presentation.sh
ctest --test-dir lutools/build-macos --output-on-failure
```

The first CTest run passed all 15 then-registered tests. After configuring
`SONY2FUJI_TEST_RAW` with the local Sony fixture, the four additional RAW tests
and `color_contracts` were built and passed using:

```sh
ctest --test-dir lutools/build-macos \
  -R '^(color_contracts|raw_noise|raw_reuse|raw_white_balance|raw_input)$' \
  --output-on-failure
```

This covers all 19 tests now registered, including CPU-reference Metal filter
tests, full denoisers, photo effects, CUBE/DCP rendering and Sony/DJI RAW checks.
The Metal tests assert actual GPU filtering, not only the reported backend.
Wavelet tile differences were approximately `1.9e-6` or less; guided-filter
differences were approximately `9.5e-5` or less in Lab units. The tested complete
denoisers differed by less than `4e-7` per RGB channel.

Real RAW combined rendering was checked separately with the local Sony
`DSC06251.ARW` and bundled PROVIA 65-grid LUT:

```sh
bash RawLabMac/tests/photo-effects-render.sh "$RAWLAB_TEST_RAW" "$RAWLAB_TEST_LUT" wavelet
bash RawLabMac/tests/photo-effects-render.sh "$RAWLAB_TEST_RAW" "$RAWLAB_TEST_LUT" chroma
```

Both passed preview/native CPU-Metal comparisons (maximum difference `1/255`),
deterministic interactive grain, actual Metal backend assertions, native JPEG
and 16-bit PNG export, and native Metal buffer/PNG comparison (`0/255` after
conversion to the test's 8-bit comparison representation).

## Timing Observations

Single-fixture measurements, with RAW decode warmed and vignette/grain enabled:

| Case | CPU | Metal |
| --- | ---: | ---: |
| First wavelet-denoised preview | 8.868 s | 3.210 s |
| First display-chroma-denoised preview | 4.392 s | 2.535 s |
| Warm display-chroma preview | 4.873 s | 2.209 s |

The warm wavelet preview measured 2.983 s versus 0.150 s, but reused the wavelet
result cache and is not a fresh denoising benchmark. These are individual local
observations, not general performance guarantees or isolated kernel timings.

## Migration and Limits

Only the migrated effects files/hunks were removed from the original checkout.
Its AI-color-match, batch-export, RAW and other unrelated work was retained.
The original checkout's presentation and edit-memory tests were rerun after
cleanup. A local scoped archive was retained before removing those hunks.

Independent read-only review found no actionable defect in GPU buffer layout,
filter dispatch, failure handling, cache integration or feature-flag guards.
No Intel Mac, iOS, Android or Windows runtime validation was performed for the
new Metal denoise implementation.

## Delivery Revalidation

Before publication, the complete configured CTest suite passed in one run:
19/19 tests, zero failures. The branch was then rebased onto `development` at
`24f717e`, incorporating its newly merged edit-memory and batch-export feature;
the core rendering code was unchanged by this base update.

The Mac app build/signing, presentation, edit-memory and batch-export checks
passed on the updated base. The real Sony RAW batch-render test also passed
with wavelet denoising, vignette and grain enabled: single and batch JPEG/16-bit
PNG pixels matched at 4672x7008, and the original RAW identity was unchanged.
The edit-memory regression now explicitly saves/restores vignette and grain
parameters. An initial edit-memory compile overlapped a library rebuild and
was rerun successfully after that build completed.
