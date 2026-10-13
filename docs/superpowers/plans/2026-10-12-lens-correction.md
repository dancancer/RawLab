# Lensfun Lens Correction Implementation Plan

**Goal:** Add profile-based distortion and lateral chromatic aberration correction to the shared core and macOS, with automatic matching, manual selection and automatic edge cropping. Defringe is excluded.

**Architecture:** Lensfun owns profile matching and coordinate models. The core samples demosaiced camera channels before `rgb_cam`, combining distortion/TCA into one sampling pass. Corrected RAW results enter existing caches and CPU/GPU photo pipelines. Auto crop uses an inscribed zoom while retaining source dimensions/aspect ratio.

**Constraints:** Preserve request v2, default-off behavior, existing working-tree changes and RAW originals. Use versioned C session setters and optional Codable settings. Automatic mode resolves independently for each input; never persist an automatically resolved lens as a manual selection. Bundle an offline DB1 and license notices in macOS. Other builds may disable Lensfun without breaking the C ABI.

## Tasks

- [x] Add focused synthetic profile tests for matching, ambiguity, missing calibration, combined camera-channel mapping and safe automatic crop. Observe the missing implementation failure.
- [x] Add optional Lensfun dependency, public metadata/config/report types and a row/block coordinate mapper. Skip previously SDK-processed Stage3 geometry conservatively and report the reason. Verify tests with Lensfun enabled and disabled.
- [x] Integrate metadata capture and pre-matrix sampling in RAWProcessor, versioned C setters/catalog/report APIs and correction-sensitive cache keys. Verify disabled identity, reset, exact/preview/output and CPU/Metal behavior with real RAW.
- [x] Add optional persisted macOS settings and a dedicated bottom-dock lens tool. Complete asynchronous catalog loading through the existing render queue, searchable manual selection, per-feature toggles and visible matching/application states. Verify old JSON, persistence, reset and frozen batch settings.
- [x] Bundle Lensfun/GLib dependencies, database and notices; build macOS and run affected tests. Complete final native manual-selection, per-feature toggle, reset and layout confirmation after macOS unlock.
- [x] Update the rendering contract and macOS README with actual behavior and verification limits. No commit, push or release is part of this request.

## Interfaces

- C++ `LensMetadata`, `LensCorrectionOptions`, `LensProfile`, `LensCorrectionReport`, `LensCorrectionDatabase`, and `LensCorrectionTransform` in `include/sony2fuji/lens_correction.h`.
- C ABI `sony2fuji_session_set_lens_database`, `sony2fuji_session_set_lens_correction`, `sony2fuji_session_inspect_lens`, and `sony2fuji_session_get_lens_report`; fixed-size strings in catalog/report, copied configuration strings.
- Swift optional `Adjustments.lensCorrection`; transient report/catalog travels with the latest accepted render, not with saved photo edits.

## Verification

- `cmake --build lutools/build-macos -j 6` and focused `ctest --test-dir lutools/build-macos -R lens --output-on-failure` during development.
- `bash RawLabMac/build.sh`, affected scripts under `RawLabMac/tests/`, and `ctest --test-dir lutools/build-macos --output-on-failure` before completion.
- Real RAW checks include manual/automatic profile resolution, cache reset, off identity, border coverage, CPU/Metal parity, preview and JPEG/16-bit PNG. Record missing platform or fixture coverage explicitly.
