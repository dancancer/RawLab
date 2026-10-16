# All-Platform Raster Input Implementation Plan

> **For agentic workers:** Use the existing platform implementations and focused red/green regressions. Keep platform ownership separate; the coordinator owns the core contract and final integration.

**Goal:** Extend ordinary-image input from desktop to iOS and Android, including import, editing, native-size export and mixed RAW/raster batch export.

**Architecture:** Decode validated, opaque RGB8 SDR files into oriented display-sRGB. Every raster render uses `SONY2FUJI_INPUT_DISPLAY_BUFFER`, not the legacy scene buffer. Reuse the shared CPU rendering stages and keep RAW processing unchanged. Resolve camera-only settings independently for each input without rewriting the stored source recipe.

**Tech Stack:** Existing C++ C ABI, Apple ImageIO, SwiftUI, Kotlin/Compose and Android platform image decoding. No mobile Agent or MCP.

## Constraints

- Preserve the dirty primary checkout; work from `development` `9066bf782bcdd98117320e5e39dabf28aa1c450b` in the dedicated worktree.
- Common minimum format support is JPEG/PNG. Apple additionally reuses its existing TIFF/HEIF adapter. Do not claim formats absent from a platform's validated decoder.
- Accept only single-frame, opaque, RGB8 SDR, bounded by 64 million pixels. Convert supported ICC-tagged RGB to sRGB; untagged RGB assumes sRGB. Reject unsupported color/HDR, bit depth, transparency and animation/multipage rather than silently flattening or quantizing.
- Apply source orientation once, before user geometry. FINAL/native-size exports must not use a reduced preview.
- Raster effective settings have no RAW baseline, camera white balance, FBDD or lens correction. Keep wavelet/chroma denoise, looks, HSL, tone, geometry and effects.
- Preserve existing RAW behavior, recipe identity, persisted edits, cancellation and per-source batch snapshots.
- No tags, official releases, version bump, distribution signing, deployment or source-photo uploads.

## Review Focus

- Neutral raster RGB8 must round-trip without applying the RAW sigmoid.
- Switching RAW/raster and mixed batch targets must not leak camera WB/lens/session settings.
- EXIF rotations and mirrored orientations must not be applied twice on preview/export.
- Platform decoders must not silently discard HDR gain maps, high bit depth, animation or transparency.
- Native exports must reload/use full source pixels after interactive preview or resize.

## Tasks

### 1. Apple Decoder and Shared Contract

Owner: coordinator. Files: `lutools/src/platform/display_image.cpp`, `lutools/CMakeLists.txt`, C header, `lutools/tests/display_image_tests.cpp`, focused simulator runner.

- [x] Run existing decoder behavior tests as an iOS simulator binary and observe the unsupported-adapter failures.
- [x] Enable the existing ImageIO implementation and framework links for iOS, retaining the same validation and orientation rules.
- [x] Guard ISO gain-map API by runtime OS availability, retaining macOS 14 support.
- [x] Re-run the decoder tests against the rebuilt iOS framework, then host CTest and desktop decoder/render regressions.

### 2. iOS App Integration

Owner: iOS implementer. Files: `RawLab/` processor, import/view-model, batch, UI and tests only.

- [x] Add focused neutral, orientation, invalid-format, settings-isolation and mixed-batch regressions; observe the old behavior fail.
- [x] Use the shared decoder and explicit display request without changing legacy RAW buffer semantics.
- [x] Add file import, enable ordinary/mixed batch, normalize camera-only controls per input and disable inapplicable controls.
- [ ] Run model/import/batch tests, rebuilt-framework simulator pixel/export tests and targeted native UI acceptance.

### 3. Android App Integration

Owner: Android implementer. Files: `RawLabAndroid/` image discovery/storage, decoder, JNI/request, editor/batch, strings and tests only.

- [x] Add format/request/neutral/orientation/isolation/batch regressions and record expected failures.
- [x] Decode supported files into validated sRGB RGB8 with Android API 26 compatibility; reject unsupported encodings before lossy normalization.
- [x] Integrate ordinary images in albums/files, preview, native export and mixed batch with per-input effective settings.
- [x] Run JVM, native request, lint, both-ABI app/test build and focused connected-device input/export tests.

### 4. Integration and Evidence

Owner: coordinator. Files: shared color/API docs, platform README and verification report.

- [x] Independently review platform diffs for color, memory, lifecycle, RAW compatibility and test gaps.
- [x] Close the same raster-source to RAW-target dormant-camera-settings boundary in desktop batch runners and target previews, without changing saved snapshots or journal formats.
- [x] Repair actionable findings and rerun affected tests; record exact source/config/device and unsupported-format limits.
- [x] Check whitespace and final owned paths, retain useful deliverables and remove only known disposable build/test outputs.

## Execution Record

- Initial iOS native decoder test: expected RED, JPEG/PNG/TIFF/HEIF/P3 and empty-path behavior failed because the iOS adapter was disabled.
- Apple adapter enabled: same simulator test GREEN, including orientation, P3 conversion, untagged RGB and transparency/16-bit/multipage/CMYK rejection. This early check compiled the current adapter with the old framework used only for buffer release; final packaging verification must use the newly built framework.
- Initial unconfigured `lutools/test.sh` stopped during configuration: host Homebrew LibRaw is 0.21.5, below 0.22.2. Reconfigure with the pinned source dependency rather than weakening the required version.
- Fresh full-feature three-slice framework and final incremental rebuild/verification passed. Packaged iPhone-simulator decoder: 62 assertions passed, all eight orientations and a host-generated verified ISO gain-map JPEG included. Host CTest: 30/30; expanded decoder test rebuilt and passed afterward.
- Apple scoped independent review: no remaining must-fix after releasing the temporary decoded image early and destroying the drawing context before releasing its backing store. The pixel ceiling is not a measured mobile memory limit.
- Desktop audit found the reverse mixed-batch boundary also reachable on macOS and structurally unguarded in restored Windows jobs. The coordinator added a macOS source/target helper at batch render and preview; its runner regression failed before the fix and the complete model suite passed afterward. Full Mac Swift source type-check at target 14 passed; no new desktop app/package or physical-runtime pass is inferred from this.
- Final mixed-source resolution preserves active master-recipe tint as a relative style offset, while resetting dormant camera WB/lens and using RAW's preview exposure default. Mac recipe-tint and Windows path-normalization regressions each failed before their fixes and passed afterward.
- Android: 149 JVM tests, lint, both ABIs/alignment, APK builds and 10/10 API35 device tests passed. ICC is restricted to validated RGB matrix/TRC profiles; real Android `para` type 4 profiles are covered rather than silently falling back to sRGB.
- iOS: model/import/processor/build and actual mixed JPEG/DNG model-chain tests passed. Native busy-lock passed on iPhone. Expanded Files-picker/dirty-draft UI sign-off remains unchecked because XCTest failed to initialize after a bounded simulator retry; it is not reported as passed.
- Windows: current-source managed build 0 warnings/errors and 91 raster checks passed. Native 35/42 reached; the long-running wavelet exposure-cache test was stopped, so the full native suite remains unaccepted.
- Final cleanup retained the rebuilt XCFramework, simulator app/xcresults, Android APKs/reports and reusable shared fixtures. Removed owned native compiler intermediates, redundant harnesses, remote-upload staging and temporary diagnostic copies; the dirty primary checkout and original photographs were not cleaned or rewritten.
