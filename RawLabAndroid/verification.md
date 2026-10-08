# Android Verification

## Strength and EXIF Update (2026-09-29)

- Film strength is 0-200% in the UI, Kotlin settings, and JNI adapter;
  default and reset remain 100%. Slider completion retains the latest value.
- JPEG and PNG exports copy readable capture EXIF through AndroidX
  ExifInterface 1.4.2 before either MediaStore or document publication.
  Orientation, dimensions, and sRGB metadata describe the rendered output;
  RAW layout, MakerNotes, and source thumbnails are not copied.
- FNumber is rounded to one decimal. Standard reciprocal exposure times use
  rational values such as 1/60; other exposures retain their duration.
  External viewers control their own textual presentation.
- JVM tests: 12/12. Host C++ request contract: passed. Android 15/API 35 ARM64
  emulator `rawlab-exif-test`: 10/10 instrumentation tests, none skipped.
- Real Sony RAW exports remain 7008x4672; PNG remains 16-bit. Tests verify
  capture tags, GPS, missing tags, corrected orientation/dimensions, unchanged
  source bytes and decoded pixels, and unchanged PNG IHDR/IDAT payloads.
- Debug APKs build for arm64-v8a and x86_64. Lint: 0 errors, 12 advisory
  warnings. APK/ELF 16 KB alignment: passed for all eight packaged libraries.
- Regression evidence before fixes: 200% rejected by Kotlin/JNI; RAW PNG
  export missing `Make`; slider 200% selection reverted to 100%.
- No physical device was modified or tested for this update. No all-camera
  metadata compatibility claim: only tags the source provider supplies and
  ExifInterface can read are retained; stripped GPS cannot be recovered.

## Initial Client Verification

This records the initial CPU-only client. Current hardware acceleration and
portrait-first UI evidence is in [gpu-verification.md](gpu-verification.md).

Date: 2026-09-28. Local development evidence, not a store release or a claim
of compatibility with every Android device.

## Build and Host Checks

- macOS host, OpenJDK 21, Gradle wrapper 8.11.1, AGP 8.9.2, Kotlin 2.1.20.
- SDK 35, NDK 27.2.12479018, CMake 3.22.1.
- `:app:assembleDebug` and `:app:assembleDebugAndroidTest`: passed.
- Both `arm64-v8a` and `x86_64` compile from LibRaw source; no host binary links.
- `:app:testDebugUnitTest`: 8 tests passed. Covers settings/reset/ranges,
  API-specific permission requests/full-partial-denied classification, RAW
  filtering, latest-pending rendering, close ordering, and working-file copies.
- Host `tests/request_test.cpp`: passed. Covers native identity defaults,
  camera/temperature WB, PREVIEW vs FINAL/NATIVE, invalid values, native OOM
  classification, and truncated/padded RGBA buffers.
- `:app:lintDebug`: 0 errors, 10 warnings. Seven dependency-update notices,
  two optional KTX suggestions, and one legacy backup-configuration suggestion.
  Backup is disabled; current-platform extraction rules exclude app data.
- `scripts/check-native.sh`: APK zip alignment and ELF LOAD alignment passed
  for all eight packaged libraries across both ABIs, including libc++ and the
  transitive AndroidX graphics library. This is not a 16 KB device runtime test.
- Shared C++ suite: 6/6 passed after the CMake integration change. Optional
  local DJI/extra Sony fixtures are absent in this worktree; those additional
  tests were not run. The repository Sony fixture is present.

## Device Checks

Android 15/API 35 Google APIs ARM64 emulator, AVD `rawlab-api35-arm64`, device
`emulator-5554`. The image reports about 2.4 GiB RAM plus swap.

Final `:app:connectedDebugAndroidTest`: 6/6 passed, 0 skipped, on the tree with
the JNI status/buffer validation fixes and landscape layout adjustment.

Instrumentation covers:

- Empty editor import actions and disabled export.
- Sony RAW import through the ViewModel, a changed film/exposure, Activity
  recreation with retained edits, and a failed import preserving the previous
  usable photo.
- Native Sony 7008x4672 RAW: bounded RGBA preview, differing film/exposure/WB
  output, full-resolution 16-bit PNG and JPEG, missing-file failure, and
  idempotent close/rejected use after close.
- MediaStore publication after a complete copy, removal of a failed pending
  row, and rejection of an output URI equal to the input URI.

Manual Android 15 checks exercised the real system permission dialog:
selected Limited Access, selected the Sony RAW, confirmed the app displayed
the partial-access label and that RAW, and reopened/cancelled the
reselection permission dialog. System document import from Downloads also
opened the RAW without broad album access.
The editor's JPEG -> Save to Album action then completed end to end with
Velvia selected. MediaStore reported the resulting JPEG as 7008x4672 with
`is_pending=0`; the source RAW remained a separate unchanged media item.

Visual inspection used actual emulator screenshots in portrait/light and
landscape/dark with font scale 1.3. The first landscape inspection found that
the bottom controls left too little image height; controls now sit beside
the canvas in wide landscape. A confirmation screenshot shows both images
and controls without overlap. Font scale/theme/rotation were restored after
checking. Evidence includes `album-partial-access.png` and
`landscape-dark-large-text.png` under `app/build/verification/`.

One preview/edit sample from `dumpsys meminfo` reported approximately 742 MiB
total PSS (not a peak measurement). Native memory dominates. No low-memory
device performance or failure-recovery claim is made from this sample.

## Evidence Locations

Generated evidence is intentionally not committed:

- `app/build/reports/tests/testDebugUnitTest/`
- `app/build/reports/androidTests/connected/debug/`
- `app/build/reports/lint-results-debug.html`
- `app/build/verification/` for emulator screenshots.
- `app/build/outputs/apk/debug/app-debug.apk` for the installable debug build.

## Remaining Coverage

No physical-device run, API 26-34 runtime matrix, x86_64 runtime run, 16 KB
page-size device run, process-death export recovery, or all-camera format
matrix. Album permission classification for older API levels has JVM coverage,
not runtime coverage on those versions. GPU acceleration is intentionally off.
