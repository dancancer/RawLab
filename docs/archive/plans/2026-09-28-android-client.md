# Android Client Implementation Plan

> Execute in this worktree using test-driven development and bounded independent verification.

**Goal:** Deliver the approved RAW editor with an in-app album browser and file fallback.
**Architecture:** Compose/ViewModel owns UI, a serialized worker owns native sessions, JNI calls the shared C ABI. Android-specific native dependency wiring builds LibRaw from source.
**Tech Stack:** Kotlin 2.1.20, AGP 8.9.2, Gradle 8.11.1, SDK 35/min 26, NDK 27.2, Compose Material 3.
**Spec:** `docs/superpowers/specs/2026-09-28-android-client-design.md`.

## Constraints

- Never write the original RAW or expand into desktop feature parity.
- Preserve C ABI/color math. CPU first; export FINAL + NATIVE.
- Permission denial leaves file import usable; API 34 partial access is distinct from full.
- All native calls and teardown serialized. Publish only current exact preview revisions.
- No push, release, or store publication.

## Tasks

- [x] Build foundation: Gradle wrapper, manifest/assets, pinned LibRaw CMake and JNI. Native request test failed before implementation, then passed; both ABIs compile.
- [x] Domain and worker: settings, permission policy, RAW filtering and serialized queue. JVM compilation demonstrated missing behavior before implementation; 8 unit tests now pass through Gradle.
- [x] Storage and editor: real RAW rendering, import failure preservation, complete output publication and pending-row cleanup covered by Android instrumentation.
- [x] Compose UI: albums, permission/reselection, document fallback, adjustments, comparison, export and adaptive portrait/landscape layouts.
- [x] Delivery: C++ 6/6, JVM 8/8, Android instrumentation 6/6, lint without errors, dual-ABI APK and all native libraries aligned to 16 KB. Independent JNI feedback addressed. See `RawLabAndroid/verification.md` for evidence and remaining device coverage.

## Verification Commands

```sh
bash lutools/test.sh
cd RawLabAndroid
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
./gradlew :app:connectedDebugAndroidTest
```

Native test example: default request must use camera WB, identity color factors,
preview edge 1600; file output must switch to FINAL/NATIVE regardless of the
interactive preview setting. JVM permission examples: API 32 requests only
READ_EXTERNAL_STORAGE; API 33 requests only READ_MEDIA_IMAGES; API 34 requests
READ_MEDIA_IMAGES plus READ_MEDIA_VISUAL_USER_SELECTED. A blocked first render,
followed by revisions 2 and 3, must run 1 and 3 and publish only 3. Closing a
blocked render must destroy its engine after completion, not during it.

SDK license acceptance, missing devices, or tool download failures are reported
separately from implementation/test results; no unrun device coverage is claimed.
