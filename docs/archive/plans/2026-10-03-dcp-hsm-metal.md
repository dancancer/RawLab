# DCP HSM And Metal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve and execute HSM calibration stages and accelerate native DCP looks on Metal.

**Architecture:** Extend DCP parsing and `.rlook` with optional HSM and look stages; expose immutable stage data to CPU/Metal. Keep unsupported platforms on existing CPU behavior.

**Tech Stack:** Existing Python/NumPy, C++17, Metal compute, CMake/CTest.

**Spec:** `docs/superpowers/specs/2026-10-03-dcp-hsm-metal-design.md`

## Global Constraints

- No new dependencies, camera-specific corrections, C ABI layout changes or redistribution of private profile data.
- v1 remains readable; v2 adds HSM metadata and data, with <=4M combined cells and <=64 MiB file size.
- HSM before profile EV before LookTable; no implicit tone/black defaults.
- CPU/Python max error <=2e-6 on identical float32 inputs; real Metal/CPU photo difference <=2 DN.
- No Windows/GLES native-DCP GPU claim. No commits or publication requested.

### Task 1: DCP Stages And Explicit Policies

**Files:** `lutools/lutprep/dcp.py`, `__main__.py`, `native.py`, `tests/test_lutprep_dcp.py`, `tests/test_native_dcp.py`.

- [x] Add and run red tests:
  ```python
  expected = apply_look_table(apply_look_table(rgb, hsm, 0), look, 0)
  # Use two noncommuting color operations and a value-dependent HSM with EV.
  self.assertRaises(ValueError, DCPProfile.read, missing_tone_source)
  ```
- [x] Parse optional HSM/Look with one validated table helper. Select shared Data1 or the D65 dual slot, reject triple HSM. Add explicit `tone_curve` and `no_auto_black` keyword policies and metadata.
- [x] Add v2 writer/reader tests and implement HSM payload preservation while retaining v1 output for old profiles. Run Python suites.

### Task 2: Native CPU V2

**Files:** `include/sony2fuji/dcp_look.h`, `src/core/dcp_look.cpp`, `tests/dcp_look_tests.cpp`.

- [x] Add red v2/read/order/corruption tests and cross-language synthetic HSM cases.
- [x] Introduce immutable `DcpStages`/`DcpTable` data returned by `stages()`, preserve validated parsing and cache ownership. Factor HSV math once for both stages.
- [x] Verify v1 results unchanged and v2 matches Python including absent look, encoding 1, shared table and profile exposure.

### Task 3: Native Metal

**Files:** `src/gpu/metal_photo.mm`, new `src/gpu/metal_dcp_shader.h`, `src/gpu/photo_gpu.h`, `src/ffi/sony2fuji_c.cpp`, `tests/dcp_look_tests.cpp`, `tests/acceleration_tests.cpp`, `tests/gpu_photo_tests.cpp`.

- [x] Add failing tests requiring actual Metal for native v1/v2, CPU/Metal parity, cache invalidation and nonfinite fallback.
- [x] Add a dedicated DCP kernel, immutable resource cache, stage validity flag and typed parameters; dispatch it between matrix/WB/exposure and normal adjustments.
- [x] Route `.rlook` to Metal on Apple, preserve CPU fallback and truthfully fail Force on errors or unsupported backends. Retain existing CUBE shader.
- [x] Run synthetic Metal tests and real RAW regressions with v1 and v2 profiles.

### Task 4: Verification And Delivery

**Files:** Update usage/color contract and this verification record. Keep local profile outputs in ignored `output/`.

- [x] Compile old CameraMatching profiles and three Adobe Standard stage-validation packages with explicit external tone/no-auto-black. Compare Python, CPU and Metal without RGB baking.
- [x] Run complete Python suite, `bash lutools/test.sh`, Mac build and native-look progressive rendering.
- [x] Obtain a scoped read-only review, fix demonstrated issues and repeat affected gates.
- [x] Check diff/format scope and record actual supported stages, platform checks and remaining limits.

## Verification Record (2026-10-03)

- Red tests demonstrated rejected HSM stages, missing CLI policies, rejected v2
  native files and the absent Metal DCP interface before implementation.
- Scoped review found that malformed unselected HSM data could be ignored. Four
  red subcases covered both selected slots and empty/truncated other tables.
  Parsing now validates every declared Data1/Data2 before retaining the D65 table.
  The review also identified missing Metal HSM encoding-1 coverage; a separate
  encoded-HSM/no-LookTable fixture now exercises value scaling on actual Metal.
- Full Python suite: 73/73 passed with `RAWLAB_TEST_CANON_DCP` pointing to the
  local Canon EOS R5 Camera Standard profile and `RAWLAB_DCP_PROBE` pointing to
  `lutools/build-macos/dcp_look_tests`; no optional fixture/probe skips.
- `bash lutools/test.sh`: 10/10 CTest cases passed, 51.47 seconds. This includes
  existing CUBE/RAW/WB/highlight tests. After the review-only parser correction
  and additional Metal test fixture, the full Python suite, native CPU suite
  and all five synthetic Metal fixtures were rerun successfully.
- Native CPU tests cover v1/v2 decoding, stage order, cache immutability, file
  corruption, PHOTO strength/exposure, FP32-overflow Auto fallback, truthful
  Force failure and recovery of actual Metal after a failed stage.
- Ten local profiles (seven CameraMatching, three Adobe Standard) were evaluated
  against the same float32 inputs: six existing RAW-derived linear images and
  three stress sets per profile, on both CPU and actual Metal. All 180 comparisons
  passed. Maximum error against Python was `2.9802319834e-8` for CPU and
  `7.8234005485e-6` for Metal; maximum quantized difference was 1 DN on either
  backend. Report: `output/dcp-hsm-metal/report.json`.
- Adobe Standard packages use an explicitly supplied identity tone and omit Auto
  black, so they validate stage execution, not Adobe Standard appearance. After
  the parser correction, the real Sony ILCE-7CM2, Nikon Z 6 and Fujifilm X-T5
  source profiles were read again successfully, validating both HSM tables.
- Fresh RAW `acceleration_tests` passed for DJI DNG with Canon Camera Standard
  v1 and Sony `DSC06251.ARW` with the Sony Adobe Standard stage-test v2 package.
  Force used actual Metal for camera WB, 4000 K and 8500 K; CPU/Metal differences
  were at most 1 DN, including all adjustments. Interactive-cache, exact final
  output and file-export assertions passed.
- `bash RawLabMac/build.sh` passed, including bundled dependency/signature checks.
  `RUN_PROGRESSIVE_RENDER=1 bash RawLabMac/tests/progressive-render.sh` with the
  Sony RAW and v2 package passed initial exact, 1000px interactive, latest-setting,
  release-exact and model/direct-render parity checks.
- CLI export of DJI DNG with the Canon native package passed. The actual exported
  `output/dcp-hsm-metal/dji-canon.jpg` was visually inspected: correct orientation,
  nonblank image and blue sky. Original RAW and DCP files were not modified.
- Diff and new-file whitespace checks passed. No new dependencies, ABI layout
  changes, commits or publication. Local generated profiles remain ignored.

## Remaining Limits

- Metal native-DCP requires macOS 15+/iOS 18+ for safe math. This phase was verified
  on macOS; no iOS/Android device or Windows build was run. Windows/GLES still use
  CPU for native looks in Auto and fail explicitly in Force. Mobile custom-look
  import remains outside this phase.
- Triple-illuminant HSM, spatial gain maps, HDR/RGB tables, implicit Adobe default
  tone and automatic black remain unsupported. No Lightroom equivalence or
  all-camera calibration is claimed. Generic LUT CUBE approximation limits are
  unchanged; native DCP bypasses that RGB baking step only for supported profiles.
