# Denoise Cache Implementation Plan

**Goal:** Keep macOS post-denoise edits and window resizing responsive without changing denoise mathematics or exact exports.

**Architecture:** Retain one exact filtered image and two recent viewport entries with a 128 MiB preview-image budget. Each entry owns a small CPU noise-analysis cache, keyed by immutable RAW identity/quality and processing dimensions. macOS holds the current proxy resolution during continuous resizing and commits the latest requested size after 200 ms of quiet.

**Tech Stack:** Existing C++17/OpenCV/wavelib/Metal core and SwiftUI/AppKit editor.

**Spec:** User-approved discussion in this chat; `lutools/docs/color-contract.md` remains the numerical source of truth.

## Constraints

- Preserve all existing uncommitted work and original RAWs.
- Keep request v2 and the public C ABI layout unchanged.
- Exposure, LUT and tone controls are downstream of wavelet analysis and must not invalidate it.
- RAW identity, WB, exposure baseline, actual source quality and processing dimensions invalidate the corresponding entry.
- Strength changes invalidate filtered output, not source analysis; coarse calibration is prepared lazily.
- Auto retains CPU fallback; Force cannot reuse a CPU result as GPU success.
- No commit, push or release is requested.

## Tasks

1. Add red regressions for analysis reuse and filtered-cache slot retention. Internal `WaveletDenoiseAnalysisCache` is move-only; `applyWaveletDenoise` accepts optional cache/source identity. Diagnostics report analysis reuse. Verify independent CPU results remain identical.
2. Implement small analysis state in `wavelet_denoise.h/.cpp`: samples, fitted model and calibrated bands only, not full-image coefficients. Preserve validation, no-op and coarse on/off behavior.
3. Add `core/wavelet_cache.h`: exact slot, two preview slots, size budget, output options/backend matching and internal run/hit diagnostics. Integrate into `sony2fuji_c.cpp` without clearing unrelated entries on source/strength transitions.
4. Add the C API integration regression using the small existing DNG fixture. Assert real filter-call counts for exposure/tone edits, size A-B-A, exact-preview-exact, option/backend changes and source WB changes.
5. Add a red macOS regression for resize bursts with denoise enabled. Retain the currently rendered proxy edge during a burst; a main-queue work item applies the latest edge after 200 ms. Export/busy state covers pending resize work; photo/full-resolution changes cancel obsolete work.
6. Run analysis/cache unit tests, CTest, viewport/progressive/model integration and `RawLabMac/build.sh`. Measure cold/cache-hit and strength-change timings on the current photo. Update the verification report and contract with measured outcomes.
7. Verify saved current edits, restart the existing app, reopen the same photo and confirm restored settings and new preview behavior through the native UI.

## Completion

Tasks 1-7 are complete. The cache/analysis regressions, 23 CTests, macOS viewport
and progressive model checks, native build and current-photo benchmark passed.
The app was restarted with the current saved adjustments unchanged. Measurements,
native UI evidence and remaining limitations are recorded in
`docs/verification-viewport-preview-2026-10-12.md`. Changes remain uncommitted.
