# Mac Adjustment Controls

## Delivered

- Six output controls: contrast, highlights, shadows, S-curve strength, saturation and sharpening. All default to identity; exposure/WB remain before the LUT.
- Collapsible film/input/tone/color/detail groups, numeric entry, bounded values, invalid-input rejection, individual/group/all-adjustment resets. Reset does not replace the RAW or selected LUT.
- Positive highlight/shadow UI values brighten. The highlight sign is translated at the Swift boundary rather than changing the shared C ABI convention.
- Sharpening runs at source resolution before preview downsampling, keeping the same filter footprint as export. Zero-sharpening retains the existing fast preview path.
- Updated local bundle: `build/RawLab Mac.app`. No commit or push. Original RAWs and the user's running app were not modified/reset by UI verification.

## Regression Evidence

- Before implementation, the Swift test failed because the six approved controls were absent. Core tests also reproduced mismatched preview/final sharpening.
- `RawLabMac/tests/adjustments.sh`: all 8 RAW fixtures passed. The script enumerates actual example files, including Git-ignored ARWs, rather than relying on tracked-file discovery.
- Each fixture checks all six controls change rendered pixels/histograms, preserve RAW base EV, and restore the original output when reset. Positive highlight/shadow direction is checked explicitly.
- A combined adjusted 100% display buffer was compared with the decoded original-size 16-bit PNG; sampled RGB errors were at most one 8-bit code value after quantization.
- Settings tests cover identity request values, numeric parsing, NaN/infinity/text rejection, clamping, percent conversion and reset isolation across groups.
- Core CTest with Metal: 3/3 passed. ASan/UBSan CTest: 3/3 passed. A synthetic edge fixture separately proves sharpening changes pixels and preview/final output agrees at the same requested dimensions.
- Native UI checks covered numeric entry, invalid input, individual reset, tone reset preserving saturation, full reset clearing edit errors, collapse/expand and the final panel layout. Validation ran in a separate temporary bundle and was closed afterward.
- App build, ad-hoc signature verification and `git diff --check` passed.

## RAW Fixtures

| File | Camera / ISO | Export |
| --- | --- | --- |
| DSC09067.ARW | Sony ILCE-7CM2 / 100 | 7008x4672 |
| DJI_20250602164503_0444_D.DNG | DJI PP-101 / 60 | 3072x3072 |
| DSC06251.ARW | Sony ILCE-7CM2 / 200 | 4672x7008 |
| DSC06271.ARW | Sony ILCE-7CM2 / 100 | 7008x4672 |
| DSC06377.ARW | Sony ILCE-7CM2 / 100 | 7008x4672 |
| DSC06395.ARW | Sony ILCE-7CM2 / 640 | 4672x7008 |
| DSC06667.ARW | Sony ILCE-7CM2 / 100 | 4672x7008 |
| DSC06765.ARW | Sony ILCE-7CM2 / 2000 | 7008x4672 |

Adjusted PNGs: `/tmp/rawlab-adjustments.FoCFys/<RAW filename>/adjusted.png`. Portrait output dimensions were also checked with ImageIO/sips, and a portrait plus the ISO-2000 night scene were visually inspected.

## Boundaries

These controls use the existing shared output algorithms, not darktable's complete modules. Highlights are a rendered-image adjustment, not RAW highlight reconstruction. S-curve strength is not a free-point curve editor. No denoise, masks or local tone-equalizer module was added. Matching parameter behavior and export pixels is not proof of calibrated cross-camera color equivalence.

Visual inspection found pink coloration in very bright car-body regions of DSC06251.ARW. A separate default PROVIA export with all six new controls neutral shows it too (`/tmp/rawlab-adjustments.FoCFys/DSC06251.ARW/default.jpg`). This is not attributed to the new control wiring; its rendering cause is not diagnosed or fixed in this bounded adjustment-panel change.
