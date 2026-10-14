# Android geometry editor verification — 2026-10-14

Scope: uncommitted Android geometry UX changes in the shared `build/phase-one-basic-geometry` worktree. The parent task owns the final source revision and integration record. No Git operations, dependency additions, JNI/core changes, or RAW-original modifications were performed in this task. `GeometrySettings` continues to write record version 2 and read versions 1 and 2.

The geometry tool opens a separate draft, renders rotation/flips/perspective/straightening on an uncropped canvas, and shows normalized crop bounds with a mask, thirds grid, four corner handles and interior movement. Crop-only changes never submit native rendering or persist edits. Native crop/correction modes offer Free, Original, 1:1, 3:2, 4:3 and 16:9 presets, orientation swapping, rotation/flips, optional precise percentages, and three correction sliders. Grid and Reset geometry remain pinned below the scrolling controls. Apply persists once and always queues a final cropped preview, including unchanged drafts. Cancel restores the previous exact preview without writing. Queue revision guards discard late draft previews after Apply, Cancel and photo replacement. Pending drafts block single/batch export and existing batch-task navigation.

The implementation preserves Material 3, 48 dp action targets, full 48 dp corner hit areas, safe system-bar insets, geometry keyboard insets, system Back cancellation, dynamic text scaling and six-language resource/accessibility labels. Geometry editing uses one fit canvas; normal pan, pinch and comparison gestures resume after the draft ends.

## Build and focused checks

Final offline incremental command, using installed SDK/Gradle dependencies and the repository DJI DNG:

```sh
JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home \
ANDROID_HOME=/Users/xupeng/Library/Android/sdk \
./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleDebugAndroidTest :app:lintDebug \
-PrawlabTestRaw=/Users/xupeng/mycode/rawtools/build/phase-one-basic-geometry/lutools/examples/DJI_20250602164503_0444_D.DNG \
--offline --console=plain
```

PASS: 96 JVM tests, including 14 new physical-ratio/drag regressions and 7 new draft-transaction regressions; dual arm64-v8a/x86_64 debug APK; instrumentation APK; Android lint. Kotlin reports icon deprecation warnings; they do not prevent compilation. Relevant generated results remain under `app/build/test-results/testDebugUnitTest`, `app/build/reports`, and `app/build/outputs/apk` and are not source deliverables.

Device checks use an owned API 35 Google APIs arm64 Pixel 5 emulator with SwiftShader, private ADB port 5047 and explicit serial `emulator-5588`. The final phone configuration was 393 dp wide, dark mode, font scale 1.3; all 3 `GeometryControlsTest`/`GeometryEditorInstrumentedTest` cases passed. The final tablet configuration used a 1600×2560 display override at 240 dpi, 1067 dp wide, light mode, font scale 1.0; the real-RAW editor transaction test passed. The earlier light/normal-font phone pass also passed 3 cases. A test-only `performScrollTo` failure after pinning Reset was corrected to click the fixed footer; the final confirmation passed.

The real DJI DNG device test verifies physical handle resizing, no rerender or store change from crop drag, uncropped quarter rotation and straightening, draft export/batch guards, Cancel restoration, crop-only Apply producing a smaller native cropped result, Reset leaving committed edits intact, cancelled late transform results, and unchanged Apply returning to the cropped result.

Final emulator screenshots, inspected from native captures:

- `/tmp/rawlab-geometry-android/geometry-ui/geometry-crop-393dp-dark-font1.3.png`
- `/tmp/rawlab-geometry-android/geometry-ui/geometry-correct-393dp-dark-font1.3.png`
- `/tmp/rawlab-geometry-android/geometry-ui/geometry-crop-1067dp-light-font1.0.png`
- `/tmp/rawlab-geometry-android/geometry-ui/geometry-correct-1067dp-light-font1.0.png`

The emulator display size, density, font scale and theme were restored to its original phone configuration after verification. The installed app remains open for the parent UI review; a fixture copy is available at `/sdcard/Download/Geometry-DJI.dng`. Owned process identities: private ADB PID 51027, emulator PID 51037 (exec session 74589). Cleanup must target only that owned emulator/port; shared ADB and other devices were untouched.

## Reviewer fixes and current validation

The review found that the UI effect maximized a manually resized ratio-locked crop again after a transform and that Apply could commit bounds against an outdated canvas. Ratio lock now belongs to editor state: explicit preset selection alone maximizes the crop, while a matching transform preview refits the existing normalized area and center (scaling down only when required by canvas bounds) before atomically marking the preview ready. Transform requests clear readiness, and both the model and reducer reject Apply until the matching preview/refit completes. Crop gestures and presets wait for that preview; correction controls remain available for continued adjustment. Icons now inherit native disabled-state colors.

The revised source passes the same offline build/lint/APK command with 103 JVM tests: 18 crop-math tests and 10 transaction tests. Added assertions cover a manually resized square on a 3:2 canvas rotating to a 2:3 canvas, unchanged area/center after aspect refits, no maximization from canvas changes, and pending-preview Apply rejection. Revised device tests compile and are packaged but have not run successfully on this revised source.

The original emulator exited before the revised device run. Its console port had no listener, while the owned private ADB server remained PID 51027. Relaunching its existing AVD returned emulator PID 66458 and session 89342, but no device subsequently appeared at `emulator-5588`. A read-only boot check hit an automatic approval-review deadline; the single permitted retry executed and returned `device not found`. Attempting to inspect the owned emulator session then failed with `exec-server transport disconnected` and recovery timeout. Revised APK installs and instrumentation runs did not execute; the earlier screenshots/device passes above remain evidence for the pre-review source only.

After the host reconnected, the parent confirmed PID 66458 had exited and authorized one recovery attempt. The same existing AVD was started with `nohup`/`disown`, headless, on the same private ADB port; new owned PID 71417 was recorded. Its persistent log `/tmp/rawlab-geometry-android/review-fix-emulator.log` reported boot completion in 19974 ms. Nevertheless, the expected device never appeared, and a direct private-ADB connection to the owned emulator's port 5589 was refused. An exact `ps -p 71417` check confirmed that this process also exited. Its log contains no fatal/error or exit reason. No further launch attempts were made. Both recovery emulator PIDs are confirmed exited; private ADB PID 51027 remains the only owned process from these checks. The revised device tests remain unexecuted.

## Limits

These are local emulator and build results, not hosted CI or hardware GPU/performance evidence. Six-language keys compile and are present; the native visual pass used English. Tablet evidence uses an emulator display override, not a physical tablet. The shared rendering core was unchanged, so this UX task did not repeat unrelated CPU/GPU numerical comparisons. Polarr supplied a function reference; no claim of matching Polarr gestures or visual details is made. Revised-device verification is blocked because the owned emulator repeatedly exits before it can be reached through ADB; its last persistent log does not establish the exit reason.
