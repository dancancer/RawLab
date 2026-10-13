# Fuji GPU and Batch Import Verification

## Delivered Behavior

- F-Log, F-Log2 and F-Log2C CUBEs now run through the full photo GPU pipeline.
  Host code supplies the CPU adapter's input matrix. Shaders select F-Log versus
  F-Log2 encoding independently from output decoding; explicit Log outputs receive
  decoding and neutral display rendering before the strength blend.
- Metal, GLES and D3D11 implementations are updated. Auto still falls back on
  backend failure; Force still returns an error instead of pretending CPU work
  was GPU work. GLES sharpening/denoise limitations and DCP platform routing are
  unchanged. The C ABI, RAW development and source LUTs are unchanged.
- macOS and Android look pickers accept multiple files. One sequential task
  processes the full selection, keeps successful imports when another file fails,
  selects the last successful item and reports every failed filename. Cancelled
  or all-failed batches preserve selection. The separate, scrollable import
  report survives preview completion. Managed copies still persist across restart.
- Windows also selects and adds multiple look paths, retaining its existing
  session-only references, duplicate handling and render-time validation. It does
  not gain the macOS/Android managed-library or per-file validation workflow.

## GPU Evidence

- New Metal regressions failed against the old shader/CPU-only gate, then passed:
  **12 input/output contracts x 4 strengths**, with low/high exposure and tone
  adjustments, compared both directly and through C API Force. Every Force request
  reports the actual Metal backend. Synthetic comparisons had **0 DN** difference.
- Two user packs, **36 CUBEs x 2 real RAWs**: managed import/readback plus CPU,
  Auto and forced Metal preview all passed. Maximum difference was **1 DN** on
  Sony `DSC06251.ARW` and DJI `DJI_20250602164503_0444_D.DNG`.
- Five representative new contract types on both RAWs: **10/10** extended GPU
  regressions passed, including three white balances, controls, proxy/exact cache
  transitions, FINAL output and PNG export independent of interactive state.
- Native GLES smoke on API 35 arm64 emulator: **130 CPU/GLES comparisons**,
  maximum **1 DN**, including 12 Fuji contracts, strength 0/0.5/1/2, non-unit LUT
  domains and PREVIEW/FINAL ordering. Unsupported detail and oversized-band cases
  still fell back in Auto and failed in Force.
- Android real-RAW Fuji instrumentation failed before the GLES change (F-Log
  mismatch was 9 DN), then passed all 12 contracts x 4 strengths in Auto/Force,
  requiring backend GLES and at most 2 DN error.
- Core CTest: **10/10 passed**, including original LUT/Metal and DCP regressions.
- Python: **97 tests, 96 passed, 1 optional external Canon DCP fixture skipped**.
  The built native DCP probe was enabled. Native Fuji metadata now reports
  `cpu_only=false`; canonical display preparation remains a separate concept.

## Batch and Client Evidence

- Mac model regressions passed partial success, multiple failures, last-success
  selection, cancelled selection, unchanged sources, duplicate-name isolation
  and restart recovery. Initial tests demonstrated the missing batch entry point.
- Android ViewModel regressions passed the same mixed/all-failed cases, with a
  real RAW preview. Reports remain after rendering; selection/export availability
  stay intact on all-failed batches.
- Android unit/lint/debug APK checks and **38 full instrumentation tests passed**.
  One additional long-report UI test subsequently passed on both phone and tablet.
- Mac native report sheet tested at 950x620 and 1320x850 editor sizes. Android
  dialog tested on a 1080x2400 phone in light mode and a 1600x1000 tablet in dark
  mode with font scale 1.3. All used 18 long failure filenames; scrolling and
  dismissal worked, with no overlapping controls. Screenshots were inspected.
- Final Mac app build passed dependency, architecture and signing checks.
  The dedicated Android emulator's display/theme/font overrides were restored
  and it was stopped. Tests used temporary Mac libraries, not the user's library.

## Reproduction and Artifacts

Core and external-file tests:

```bash
ctest --test-dir lutools/build-macos --output-on-failure
bash RawLabMac/tests/fuji-compatibility.sh /path/to/RAW \
  /path/to/gfx-eterna-55-3d-lut-v110/33Grid/*/*.cube \
  /path/to/gfx100sii-3d-lut-v100/*/*.cube
MACOSX_DEPLOYMENT_TARGET=26.0 bash RawLabMac/tests/look-import-model.sh
bash RawLabMac/tests/batch-import-presentation.sh /path/to/screenshot-directory
```

Local logs and screenshots: `output/flog2-import-diagnosis/`, specifically
`gpu-contracts-metal.log`, `gpu-contracts-gles.log`, `gpu-ctest.log`,
`fuji-gpu-{sony,dji}.log`, `gpu-accel-*.log`, `batch-mac-green.log`,
`batch-mac-ui.log`, `batch-android-green.log`, `android-gpu-batch-full.log`,
`batch-android-{phone,tablet}-ui.log`, `mac-batch-{compact,wide}.png` and
`android-batch-{phone,tablet}.png`.

Final local app: `build/RawLab Fuji GPU.app` (Apple Silicon, macOS 26 target,
ad-hoc signed). Android debug APK:
`RawLabAndroid/app/build/outputs/apk/debug/app-debug.apk`.

## Verification Limits

D3D11 shader/constant-buffer changes received an independent static review;
the C++ and HLSL parameter layouts both use 224 bytes. No Windows compiler,
Windows SDK or D3D11 hardware runtime was available here. Windows GPU and
multi-picker changes therefore remain **uncompiled and runtime-unverified**.
Android GLES was exercised on an emulator, not a physical handset performance
benchmark. No iOS binary rebuild, commit, push or publication was performed.
