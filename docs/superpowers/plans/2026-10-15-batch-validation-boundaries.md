# Batch Validation Boundaries Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the remaining local batch-validation gaps without changing the 240-second export budget or touching the user's installed RawLab data.

**Architecture:** Keep the existing test-process isolation and extend its evidence to a real 90-second Compose timeout and earlier process-death windows. Give look imports an exact transaction identity and serialize library operations across instances/processes so recovery never guesses ownership from a new filename or deletes an active import. Reuse the repository's isolated-application-ID init-script pattern for physical-device tests.

**Tech Stack:** Kotlin/JUnit/Compose, Gradle init scripts, Java NIO file locking, Android instrumentation/ADB, atomic JNI backend output and unchanged shared rendering core.

**Spec:** User request in this chat; prior findings and boundaries in `reviews/self-android-v08-editor-20261015-1644.md` and `RawLabAndroid/batch-gpu-preference-verification.md`.

## Global Constraints

- Preserve the existing WIP and review reports; no commit, push, PR, release or remote CI write.
- Keep both `240_000` export waits and the original `90_000` preview wait unchanged.
- Never clear/uninstall/overwrite `com.rawlab.android` on the physical device or delete personal photos/looks.
- Use explicit serials and private ADB servers; only stop task-owned app/server/emulator processes.
- Keep Java namespace/JNI symbols and shared C ABI unchanged; no rendering-quality reduction or emulator-specific CPU pinning.
- Report expected crashes separately from normal passes and leave unreached hardware/CI cases explicit.

## Review Focus

- A committed look survives importer death; only transaction-owned uncommitted files are removed.
- A corrupt registry or an unmarked legacy orphan is preserved, not guessed away.
- Recovery cannot race a live importer in another instance/process.
- A 90-second timeout must actually expire; a short injected exception is not equivalent evidence.
- Device package isolation and selector normalization must not force-stop the original app.

### Task 1: Recover Interrupted Look Imports and Partial Fixtures

**Files:** `LookLibrary.kt`, `LookLibraryTest.kt`, `LookLibraryInstrumentedTest.kt`, `BatchTestCleanup.kt`, `BatchTestCleanupInstrumentedTest.kt`, `BatchWorkflowInstrumentedTest.kt`.

- [x] Add failing filesystem tests for transaction-owned stage/orphan cleanup, committed-look preservation, corrupt-registry preservation and concurrent instances.
- [x] Run focused JVM tests and record RED, including single-point monitor/file-lock mutations and real child JVMs.
- [x] Use a persistent per-root file lock plus a shared in-process monitor. Create `.import-<UUID>.pending` before the first staged file; recover only its exact uncommitted destination and strictly internal temporary names, preserving registered files.
- [x] Record the exact managed look ID in the validator callback before commit; preserve both pre-existing and independently added same-named looks. Also clean exact-ID orphans if a prior cleanup died after registry removal.
- [x] Move the partial-recovery fixture under its owned job directory and give its pending URI the unique fixture prefix/path before any checkpoint.
- [x] Add mid-import and insert-before-checkpoint process-death probes; require preserved resources and dead owner before fresh-process recovery.
- [x] Run JVM, normal cleanup/look tests and real process recovery probes.

### Task 2: Isolated Physical-Device Build and Accurate Backend Evidence

**Files:** new `tests/batch-validation.gradle`, `tests/batch-gpu.sh`, debug manifest, `NativeProcessor.kt`, JNI bridge, affected native/batch instrumentation tests.

- [x] Reuse the existing Sony-memory init-script pattern with `com.rawlab.android.batchprobe56c3`; keep namespace unchanged.
- [x] Parameterize only runtime application/test IDs in the wrapper. Verify APK IDs before installation; retain the original app's installed APK hash.
- [x] Pin file-export backend reporting with a failing real-native test, then return the existing session's actual backend through JNI without changing shared C ABI. Pin actual batch reporting with its own RED, not only a reference processor.
- [x] Add original-size Clean AUTO batch cases for new/resumed jobs, real GPU controls and CPU-only fallback; record backend evidence, dimensions, pixels and elapsed time rather than inferring hardware execution from speed. Run the expensive full AUTO case by explicit selector, in addition to the unchanged default normal six.
- [x] Build/lint/JVM/alignment gates, install only the isolated app/test package and run the initial physical-device matrix without concurrent builds/emulator workloads. Record its CPU UI timeout as failure, not a green matrix.

### Task 3: Real 90-Second Timeout and Simulator Comparison

**Files:** `BatchWorkflowInstrumentedTest.kt`, `tests/batch-gpu.sh`, recovery tests.

- [x] On the task-owned AVD, use a real original-size CPU Clean export to hold the JNI session mutex while the UI stays SELECTING and its preview waits at nativeCreate.
- [x] Confirm blocker nativeProcess and the preview's JNI wait separately, then let the unchanged 90-second wait expire. Rethrow the real ComposeTimeoutException; do not inject the short assertion or sleep in native.
- [x] Require elapsed-time, stack/state, deferred-cleanup, process-death and preserved-input recovery markers. Actual timeout 90096 ms, owner 5226 to recovery 5364; wrapper remains failed.
- [x] Re-run the original-size GPU-on case on the same AVD with the unchanged 240-second wait. Record genuine software-GPU timeout, driver evidence, dead-owner recovery and downstream NOT REACHED cases separately from physical Adreno success.

### Task 4: Final Verification and Re-review

**Files:** batch verification record and a new local review report.

- [x] Freeze implementation; run affected normal CPU/AUTO/GLES/RLOOK, partial-recovery, look-storage and process-death cases. Keep earlier batch snapshots separate from the final incremental missing-Look branch, which has its own targeted backend/UI reruns and hashes.
- [x] Verify task-owned gallery/files/looks are clean and the original physical app is untouched; shut down task-owned simulator/server resources and return USB transport ownership.
- [x] Run independent read-only review, reconcile concrete findings, preserve legacy/unverified limits explicitly and record source/APK/fixture hashes.
- [x] No staging, commit, push or PR. Hosted CI remains NOT REACHED under the local-only constraint.

### Task 5: Stable Save Feedback (Added User Scope)

The user requested one-round closure of additional confirmed issues after the iOS owner forwarded the Android save-notice layout defect. Keep this UI change and its APK evidence separate from the already-running frozen batch matrix.

**Files:** `EditorScreen.kt`, a focused Compose regression test, local verification record.

- [x] Confirm that flow-layout save notices shift the tool strip and shrink the adjustment area; add geometry assertions and run RED without changing save behavior.
- [x] Move SAVED/RESTORED and retryable FAILED feedback to the photo workspace overlay, clear of photo-info and comparison labels. Do not alter dock measurements, persistence, rendering, saved edits or failure retry behavior.
- [x] Preserve localized text and polite live-region semantics; keep draft suppression and an accessible retry action.
- [x] Assert dock, tool, slider and preview bounds across insertion/content change/removal, expanded/collapsed, narrow/wide, six languages and large font. Inspect representative device screenshots in one batched pass. Extend with touch retry, capture-info scrolling, null preview and geometry/lens drafts.
- [x] Build/JVM/lint/alignment and targeted UI/recovery smoke on the final incremental APK: 88 JVM tests, lint zero errors, 8 aligned native libraries, six-language layout plus five existing canvas tests and six recoveries. Do not attribute earlier frozen batch timings to this later APK.

### Task 6: Root-cause Follow-ups Found During Verification

- [x] Reproduce completed-export backend getter contention with a real second CPU preview; return backend within the original JNI lock, without a second getter lock. Verify RED/GREEN and retain a -1 no-write sentinel.
- [x] Capture app locale before the language rule and restore it only after the old owner dies; prove the old cleanup leaves zh-Hans instead of de.
- [x] Trace physical locale failures into the actual Lenovo framework DEX. Preserve literal-language guards; do not work around OEM region/test-mode policy in production or claim six physical languages passed.
- [x] Identify secure-keyguard/doze as a separate physical-test precondition. Use test-window KEEP_SCREEN_ON across Activity recreation, not global screen-off settings. Use ExternalResource.before so failed unlock preconditions stop the body.
- [x] After the user's secure unlock, run foreground-controlled baseline/current CPU comparison. Both genuinely time out at 240071/240063 ms with screen on, keyguard absent and test-window wake lock; fresh recovery passes. These are timeout observations, not equal completed-render times or an immutable hardware limit. Physical Chinese UI and preview-crash locale recovery also pass their assertions. Task-owned packages/resources are removed again.
- [x] Record final review and exact source/APK evidence, including expected failure versus normal pass and remaining hardware/security boundaries.

### Task 7: Restored Missing-Look Import Mode

- [x] Confirm restored missing-Look import bypasses ordinary Work.Preview's mode setter; reproduce actual validation backend 2 with GPU off, preserving AUTO-on control 2.
- [x] Apply work.gpuMode before that validation preview. Observe the actual NativeFrame backend only in debuggable builds; do not substitute a later session probe.
- [x] Put the test Application's edit store and random working cache inside the already-owned journal fixture, covering native timeout/process death without relying on finally.
- [x] Run refined RED and physical/AVD GREEN, host gates, final UI regression and independent incremental review. Keep both 240-second waits and the original 90-second wait unchanged.
