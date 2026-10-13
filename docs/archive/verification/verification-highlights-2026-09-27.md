# Saturated Highlight Fix

## Change

The shared RAW processor now uses LibRaw `highlight=2` (blend) instead of `highlight=1` (unclip). Blending happens in camera channels after demosaic, before our float camera matrix and the Fuji LUT. Maximum-normalized WB and the existing float scale are unchanged. No change to baseline EV, user EV, LUT interpolation, output controls or public interfaces was needed.

This is LibRaw highlight blending, not a port of darktable's opposed-chroma reconstruction. It suppresses unreliable highlight chroma but cannot recover lost sensor detail. Bright colored regions may lose saturation. Scene RGB is not globally clipped to 1.

## Regression

`lutools/tests/highlight_regression.cpp` processes the real DSC06251 RAW through the production RAW processor, then tests neutral and PROVIA rendering. It uses an oriented embedded-JPEG near-white mask in the car-body ROI, covering 7,661 samples, and checks input gains of 0.5, 1 and 2. Pink is defined as `(R+B)/2-G > 0.08` in the rendered RGB values. The allowed rate is at most 1%, and absolute mean PROVIA magenta bias at most 0.02. A known saturated point must remain neutral while retaining linear values greater than 1.

The test failed before the production change and passed afterward:

| Relative input EV | PROVIA pink before | PROVIA pink after | Neutral pink after |
| --- | ---: | ---: | ---: |
| -1 | 4,797 | 4 | 4 |
| 0 | 4,759 | 2 | 1 |
| +1 | 4,710 | 2 | 0 |

At portrait coordinate (3984, 1544), default linear RGB changed from `(5.5014, 0.934914, 2.89717)` to `(2.74763, 2.74763, 2.74763)`. The Bayer neighborhood was already saturated before WB. At default EV the mean PROVIA magenta score changed from `0.116790` to `-0.002390`.

The sample is a local, Git-ignored RAW. CMake registers `sony_highlights` when `examples/DSC06251.ARW` exists and prints a fixture requirement otherwise; it does not silently substitute another image. No RAW was added to Git or modified.

## Verification

- `ctest --test-dir lutools/build-macos --output-on-failure`: 4/4 passed, including the new regression, color contracts, Sony and DJI RAW checks.
- `ctest --test-dir lutools/build-sanitize --output-on-failure`: 4/4 passed with ASan/UBSan.
- `bash RawLabMac/tests/adjustments.sh`: all 8 RAW fixtures passed. Six controls, reset, exposure-baseline stability, original-size 16-bit PNG and display/export pixel parity were verified through the desktop engine.
- `bash RawLabMac/build.sh`: rebuilt the local Mac bundle with the new static core.
- `codesign --verify --deep --strict --verbose=2 'build/RawLab Mac.app'`: passed.
- `git diff --check`: passed.

All eight fixtures were also exported with both the pre-fix and post-fix CLI using default PROVIA: DSC09067, DSC06251, DSC06271, DSC06377, DSC06395, DSC06667, DSC06765 and the DJI DNG. Contact-sheet inspection found the obvious magenta car bodies in DSC06251 and bright surfaces in DSC06395 removed, with no obvious new broad color or exposure problem at that viewing scale. The ISO-2000 night scene was included; this is not exhaustive validation of every saturated colored light or camera model.

## Local Artifacts

- Updated application: `build/RawLab Mac.app`. An already running process must be quit and reopened to load the new core and clear its old RAW cache; it was not force-quit or reset during verification.
- Before/after JPEGs: `/tmp/rawtools-highlight-fix/{before,after}/`.
- Car-body comparison: `/tmp/rawtools-highlight-fix/DSC06251-comparison.jpg`.
- Eight-sample contact sheets: `/tmp/rawtools-highlight-fix/samples-1.jpg` and `samples-2.jpg`.
- Desktop-engine adjusted PNGs: `/tmp/rawlab-adjustments.w2tJGG/`.
- Prior darktable reference and single-module-off comparison: `/tmp/rawtools-dsc06251-dt/`.

No commit or push was made. Existing unrelated changes were preserved. Mobile binaries were not rebuilt in this macOS-focused verification.
