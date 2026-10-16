# Android Geometry Integration Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans. Main owner implements; independent agents only inspect and review.

**Goal:** Port PR45 perspective, compatible v2 persistence and complete crop ratios onto the approved v0.8 Android editor.

**Architecture:** Keep the generic AdjustmentDraft and current preview queue, batch lifecycle, GPU reporting and RUM. Reuse the shared perspective setter and PR45 pure crop math; do not restore the legacy geometry editor/reducer.

**Tech Stack:** Kotlin, Compose Material3, JNI, shared C ABI, Gradle/JUnit/instrumentation.

**Spec:** Coordinator delegation dated 2026-10-16; approved Android design revision 17b0123; shared color contract and edit-json geometry contract.

## Global Constraints

- Base development 435feda; retain PR45 59d66da history through a normal merge. No force push, duplicate PR or merge to development by this owner.
- Own RawLabAndroid/** only. Preserve the old checkout and its two unknown Windows artifact deletions.
- Geometry order and quality budgets do not change. Keep CPU/Auto/Force semantics, 240-second export budget and read-only RAW.
- Only exact, current transform previews enable Apply. Crop-only edits stay in the overlay; native render on Apply includes final crop.
- Ratios are transient draft constraints; persisted geometry remains the actual crop plus both perspective axes.

## Review Focus

- Transform preview arriving after a newer crop drag must retain the newer crop and refit atomically before Apply.
- Original ratio uses full oriented source dimensions, never an edited or resized bitmap.
- Numeric width/height edits unlock ratio; reset clears the lock; selecting orientation is stable across preview completion.
- Both native setters run for every preview/export, including identity resets; actual backend reporting survives merge.
- Cancel/reopen/restart and frozen batch settings must preserve committed edits, current lifecycle and RUM.

### Task 1: Integrate Geometry Into v0.8

**Files:** GeometrySettings.kt, GeometryCropMath.kt, AdjustmentInteraction.kt, EditorViewModel.kt, GeometryControls.kt, GeometryCropCanvas.kt, EditorScreen.kt, MainActivity.kt, NativeProcessor.kt, rawlab_jni.cpp, six language resources, corresponding unit/instrumentation tests and Android verification docs.

**Interfaces:** Existing GeometrySettings plus perspectiveHorizontal/Vertical finite [-1,1]; v2 encodes 11 fields and reads v1 with zero axes. AdjustmentDraft owns geometryRatio/geometryPortrait and uses pure preset/refit math. PreviewPair carries originalAspect from native identity geometry dimensions.

- [x] Run clean development unit baseline: 102 tests pass.
- [x] Add v2 round-trip and v1-upgrade RED tests: two expected failures on development.
- [x] Resolve merge using current v0.8 UI/state as baseline, then port only domain/native/resource deltas.
- [x] Add draft ratio tests proving physical aspect, original orientation, area-preserving refit, reset/unlock and projection isolation; run RED before implementation.
- [x] Wire ratio choices, direction, perspective controls and corner resizing through the generic draft. Preserve stale revision filtering.
- [x] Run JVM suite; 129 tests pass. Build debug/test APKs, lint and check-native.
- [x] Use isolated ADB for geometry preview/FINAL/reset, draft Apply/Cancel/leave/process restart and batch snapshot/GPU/lifecycle regression. Record firmware and visual limits without claiming success.
- [x] Obtain independent read-only review and new-core incremental review, close coverage gaps, restore batch summary rows with RED/GREEN evidence, verify old checkout fingerprint.
- [x] Commit normal integration and target merges. Delivery uses the existing source branch/PR45, without force push or duplicate PR. Coordinator alone merges.

Detailed logs, source tree identities, runtime artifacts, failed diagnostics and remaining platform
limits are in [the integration verification record](geometry-v08-integration-verification-2026-10-16.md).

## Decisions

- Explicit execution authorization overrides writing-plans' generic review pause; no additional design approval required.
- The initial coherent merge is followed by normal merges of new development targets. The shared-core
  update receives an incremental NDK/native/batch check; later Mac/iOS-only targets reuse those results
  after verifying unchanged Android/core/configuration trees.
- Evidence is stored outside build output; historical PR45 verification is not exact-head evidence.
