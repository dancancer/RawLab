# Fuji LUT Compatibility Verification

This records the initial CPU compatibility checkpoint. The subsequent
[GPU and batch-import verification](verification-fuji-gpu-batch-import-2026-10-07.md)
supersedes the CPU-only limitation below; these historical results are retained.

## Scope and Result

The shared PHOTO renderer now accepts the 36 user-supplied 33-grid CUBEs:

| Pack | F-Log | F-Log2 | F-Log2C | Total |
| --- | ---: | ---: | ---: | ---: |
| GFX ETERNA 55 v1.10, 33Grid | 4 | 12 | 12 | 28 |
| GFX100S II v1.00 | 4 | 4 | 0 | 8 |

F-Log uses its published curve; F-Log2C uses the F-Log2 curve with a separate
F-Gamut C matrix. Technical Log output is decoded and passed through the existing
neutral display transform in BT.709/sRGB, before strength blending. Display LUT
outputs do not receive an extra curve. RAW calibration, WB and exposure are unchanged.

The 22 newly accepted contracts use CPU, including Auto fallback. Force fails
explicitly instead of claiming GPU success. The 14 previously supported F-Log2
display contracts retain their existing GPU path. No C ABI change or source-LUT
rewriting is required. Built-in film lists are unchanged.

## Checks Completed

- Red/green native tests: the old core rejected F-Log, F-Log2C and technical
  Log output; the same acceptance cases pass after implementation.
- Core CTest: **10/10 passed**, including CPU/Metal parity, Sony/DJI real RAWs,
  DCP, highlight, white-balance and image-statistics regressions.
- New core tests cover independent F-Log curve anchors, negative/low branch and
  super-white round trips, independently derived F-Gamut C red coordinates,
  C API input-adapter values, nine input/output Log combinations, output decode,
  display-space strength blending, CPU/Auto equality and Force rejection.
  The color-contract target passed again after adding the input-adapter values.
- Real Mac library and renderer: **36/36 imports and managed reloads**, separately
  on Sony `DSC06251.ARW` and DJI `DJI_20250602164503_0444_D.DNG`.
  All 72 CPU/Auto preview comparisons passed: new CPU-only contracts were exact;
  existing GPU contracts differed by at most **1 DN**. Original CUBE bytes were
  unchanged. The test library was temporary, not the user's Application Support.
- Mac managed-library tests and editor-model import/rename/remove/error tests passed.
- Five real CPU-only LUT contracts (F-Log/F-Log2C display and all three Log
  outputs) passed the extended acceleration/export regression on both Sony and
  DJI: **10/10 cases**. Each checked actual CPU backend, Force rejection,
  three WB settings, all adjustments, interactive/exact cache transitions,
  FINAL behavior and PNG export. CPU/Auto pixels were identical; export with
  interactive enabled was byte-identical to exact export.
- Mac adjustment regression passed on **7 RAWs**, including full-resolution
  preview/export equality and 16-bit output. Bundled-app smoke passed on Sony and
  DJI; the missing-RAW case correctly failed.
- Python: **97 tests, 96 passed, 1 skipped** (optional external Canon DCP fixture).
  The built native DCP probe was enabled. `native_photo_compatible` is separate
  from canonical display passthrough; technical CUBEs are never silently relabeled.
- Actual-pack Python audit: **36 read, 36 native compatible, 0 blocked/failed**.
  Compilation is correctly `not_run`: these CUBEs import directly. Its separate
  source-renderer appearance status remains `unverified`.
- Android: unit/lint/debug APK/test APK builds passed for arm64-v8a and x86_64.
  **6 native instrumentation tests passed** on API 35 arm64 emulator, including
  all three input families, display/Log output, CPU/Auto equality, backend reporting
  and Force failure. The dedicated emulator was stopped after the test.
- Scoped independent static review found no confirmed implementation defect.

## Reproduction

From the repository root, after building the shared core:

```bash
ctest --test-dir lutools/build-macos --output-on-failure
RAWLAB_DCP_PROBE="$PWD/lutools/build-macos/dcp_look_tests" \
  lutools/.venv-lutprep/bin/python -m unittest discover -s lutools/tests -p 'test_*.py' -q
bash RawLabMac/tests/look-library.sh
bash RawLabMac/tests/look-import-model.sh
bash RawLabMac/tests/fuji-compatibility.sh /path/to/Sony.ARW \
  /path/to/gfx-eterna-55-3d-lut-v110/33Grid/*/*.cube \
  /path/to/gfx100sii-3d-lut-v100/*/*.cube
lutools/build-macos/acceleration_tests /path/to/RAW /path/to/compatible.cube
```

Local evidence is under `output/flog2-import-diagnosis/`, including the two
`fuji-compatibility-*.log` files, `native-audit.json`, `mac-build.log`,
`mac-adjustments.log`, `mac-smoke.log` and `accel-*.log`.

## Deliverables and Boundaries

- Local Apple Silicon app: `build/RawLab Fuji Compatible.app`, macOS 26 build,
  ad-hoc signed with bundled dependencies. Existing running app was not replaced.
- Android debug APK: `RawLabAndroid/app/build/outputs/apk/debug/app-debug.apk`.
- Mac misleading import-error headings now say `操作失败`, not `无法导出`.
- No publishing, commits, physical Android deployment, iOS binary rebuild or
  Windows runtime verification in this change. Existing iOS bundled-only picker
  was not expanded into a new file importer.
- This verifies declared color transforms and rendering compatibility, not
  camera-specific Fuji JPEG emulation or controlled cross-camera color accuracy.

Formula sources: [F-Log v1.2](https://dl.fujifilm-x.com/technical-data/F-Log_DataSheet_E_Ver.1.2.pdf)
and [F-Log2C v1.0](https://dl.fujifilm-x.com/technical-data/F-Log2C_DataSheet_E_Ver.1.0.pdf).
