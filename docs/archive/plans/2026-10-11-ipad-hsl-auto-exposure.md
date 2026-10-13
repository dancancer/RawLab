# iPad and Cross-Platform Color Controls Implementation Plan

> Use test-driven development and independently owned platform work. Integrate through a verified PR to `development`; do not release or deploy.

**Goal:** Deliver the four requested improvements in the existing native editors.

**Architecture:** Add versioned session configuration and a metering operation to
the shared core, preserving request v2. Wire each client's existing adjustment,
persistence and batch mechanisms to those interfaces. Adapt iOS by window size.

**Tech Stack:** C++17/LibRaw, SwiftUI, Kotlin/Compose/JNI, C#/WPF.

**Spec:** `docs/superpowers/specs/2026-10-11-ipad-hsl-auto-exposure.md`.

## Constraints

Worktree: `feature/ipad-hsl-auto-exposure`, based on `origin/development` at
`ffadcd4`. Preserve old saved exposure modes, request ABI, originals and unrelated
work. No new dependency. Rendering, persistence and batch parameters must agree
across clients. All HSL values are [-100,100], in the channel order specified in
the spec; auto exposure returns an absolute EV in [-4,4].

## Tasks

- [x] Core: add `lutools/tests/photo_color_tests.cpp`, demonstrate missing API
  failure, then implement `core/photo_color.{h,cpp}` and additive C interfaces
  in `ffi/sony2fuji_c.h`/`.cpp`. Register the focused test in CMake. Check output
  identity, edited pixels, fallback and metering with `lutools/test.sh`.
- [x] iOS/iPad: test settings default/migration, HSL snapshot round-trip and
  layout policy first. Update existing models/processor/view model and SwiftUI
  controls under `RawLab/`; update target device/orientation settings. Build the
  refreshed xcframework and simulator app; run platform/UI checks and capture
  iPhone and iPad layouts.
- [x] macOS: own `RawLabMac/` only. Extend adjustments/engine/dock/editor model
  and affected tests. Test HSL saved edits and frozen batches, then build/run
  model and actual-render checks against the new core.
- [x] Android: own `RawLabAndroid/` only. Extend settings/persistence, JNI session setup,
  editor controls and one-shot metering. Test default/legacy decode and HSL
  edits/batch freezing, then run unit tests, assemble and lint where available.
- [x] Windows: own `RawLabWindows/` only. Extend settings/clone, C interop,
  processor and WPF editor controls. Add managed regression checks. Run portable
  checks and cross-compile when available; leave Windows-only runtime unclaimed.
- [x] Integration: review each platform's native call paths and stale-result
  protection, run shared-core regressions and affected client checks, update
  the rendering contract/README and record actual verification results.

Completed checks and runtime limitations are recorded in
`docs/verification-ipad-hsl-auto-exposure-2026-10-11.md`. The named branch and
worktree retain the implementation. On 2026-10-11 the owner authorized a commit,
push, PR to `development` and merge after verification. Release and deployment
remain outside the delivery scope.

## GPU HSL Follow-Up

- [x] Replace fixed CPU-only HSL with Metal/GLES/D3D11 photo-shader stages while
  keeping the C ABI and persistence unchanged.
- [x] Change Force/Auto tests to require the actual backend; cover all 24 controls,
  wrap/grayscale, CUBE/tone, native-DCP Metal and denoise/detail/effects ordering.
- [x] Rebuild Apple core/app and Android artifacts, run native shader/RAW parity
  tests, and compile Windows HLSL with reflected constant-buffer validation.
- [x] Record Windows hardware limitations and update the rendering contract.
