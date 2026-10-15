# Android 0.8 Implementation

## Authority and Isolation

- Current user approval supersedes the historical pending-approval notices in the design package.
- Base: `440b9788ff4cfd8a3f5dfa781b16a33997ccd801` (`origin/development`, PR #51).
- Worktree: `/Users/xupeng/.codex/worktrees/56c3/rawtools`.
- Branch: `feature/android-v08-editor`.
- Approved design source: `17b012361d2a4e470a7bba41cd7cf0c1bc7997a3`, read-only design worktree.
- Android implementation only. No Shared/C++ ABI changes, release, push, PR, or Library writes.

## Stages

1. Establish Gradle baseline and preserve RAW, recipe, persistence, export, and batch contracts.
2. Implement continuous gray/yellow editor, ordered circular tools, signed arcs, moving rulers,
   exact-value drafts, film labels and recipe badges, and phone/tablet portrait structure.
3. Implement geometry/lens group drafts with preview-only rendering, apply/cancel/exit protection,
   constrained crops and on-canvas controls. Ordinary adjustments remain immediate.
4. Replace single/batch format chips with full-width radio rows; preserve SAF/MediaStore,
   size validation, frozen snapshots, stop/recovery and complete bundled licenses.
5. Integrate approved adaptive launcher layers and settings. Validate using Gradle, native
   package checks, focused instrumentation, then independent read-only review.

## Review Focus

- Draft renders must not persist, alter ordinary settings, or become exportable.
- Stale render results must not overwrite newer draft or committed settings.
- Numeric drafts reject invalid/non-finite/out-of-range values without changing the live value.
- Portrait tablets stay stacked; font scaling must not hide format titles or fixed draft actions.
- DNG remains file-only; batch requires a directory. Cancelled pickers do not report success.
- 100% refers to bounded comparison-preview pixels, never full RAW pixels.
- Launcher resource validation is not installed-launcher or OEM-mask acceptance.

## Verification

Application source: `f598c74db28983c393b5560646cd01a77374a1b1`.
Final UI test source: `5a86dace146f878085403793d0d58dbc2f40905e` (test-only Cancel/reopen coverage).
Native integration was installed from `c531173a774dc30a71f0f56f1b6d127b3722b40f`;
the later application change affects only the numeric dialog's keyboard/sign action and translations.
The verification-record commit does not change application or test sources.

### Implemented Scope

- Material gray/yellow roles, circular ordered tools, signed scalar arcs, persistent tool selection,
  all-tools sheet, full film labels and shared recipe names with Layers badges.
- Fixed-cursor moving rulers, reciprocal Kelvin, quarter-sensitivity mode, selection haptics with
  a shared 125 ms budget, system-animation-scale handling, accessibility progress actions,
  exact-value local drafts and strict finite/range/locale-decimal validation. Signed fields retain
  the system decimal keyboard and offer a local sign action; only Apply changes the actual value.
- Ordinary adjustments still render and save immediately. Global reset retains ordinary film and
  clears recipes. Effects, HSL, denoise, camera WB, bounded comparison zoom and RAW semantics remain.
- Independent geometry/lens group drafts, preview-only rendering, constrained crop rectangles,
  canvas handles/grid, ratios, Apply/Cancel, changed-draft exit decisions and export/library guards.
- Full-width single-column JPEG/PNG/DNG radio rows shared by single and batch output; natural text
  height, existing size limits, file-only DNG, SAF-cancel return to settings and explicit unknown counts.
- Settings, language, about/update links and complete bundled license entry points remain available.
  Package version remains the real `0.7.0` debug package identity, not an asserted 0.8 release.
- Approved 108 dp adaptive layers and monochrome resource; no macOS tile/transparent margin is used
  for launcher icons. The earlier PNG had transparent outer margins but no painted white border;
  the exact cause of the user's original white-line screenshot remains unconfirmed.

### Host Gates

JDK: Temurin 21.0.8. SDK 35, NDK 27.2.12479018, CMake 3.22.1.
The initial clean-base command prepared and built both native ABIs. Subsequent implementation
started while that long dependency build was running; final-source results below are authoritative.

```sh
cd RawLabAndroid
export JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home
export ANDROID_HOME=/Users/xupeng/Library/Android/sdk
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug :app:assembleDebugAndroidTest \
  -PrawlabTestRaw=/Users/xupeng/mycode/rawtools/lutools/test-assets/DSC00316.ARW --console=plain
bash scripts/check-native.sh
```

- Gradle: PASS. JVM XML totals: 82 tests, 0 failures, 0 errors, 0 skipped.
- Lint: PASS with 0 errors and 32 warnings, including dependency-update suggestions, existing locale
  bundle/backup rules, resource/KT extensions, and count/plural suggestions. No baseline suppression added.
- Debug app and instrumentation APK: PASS, both ARM64 and x86_64 native libraries packaged.
- `check-native.sh`: PASS, APK zip alignment and all 8 packaged native-library LOAD alignments.
- Host request contract: PASS, compiled with `c++ -std=c++17 -I RawLabAndroid/app/src/main/cpp
  -I lutools/include RawLabAndroid/tests/request_test.cpp -o /tmp/rawlab-android-v08-56c3/request-test`.

File-backed gate evidence: `final-host-gates.txt`, `final-host-report-counts.json`,
`final-native-alignment.txt`, and `final-request-contract.txt` in the evidence directory below.
The Gradle rerun uses valid up-to-date outputs where sources did not change; it is not a clean build.

App APK: `app/build/outputs/apk/debug/app-debug.apk`.
SHA-256: `450e37714f5ae1980b5cdfdb53b4364ce43d8505ad07f285ce3bbc995c7c9b5a`.
RAW is copied into the instrumentation APK only, not the application APK or Git.

### Isolated Device Evidence

- Task-created AVD: `/tmp/rawlab-android-v08-56c3/device`, API 35 ARM64, 6144 MB,
  headless SwiftShader GLES. Private ADB port `5063`, serial `emulator-5762`, ports `5762/5763`.
- Owned emulator PID `43438`; owned ADB PID `18693`. Both were stopped after verification;
  ports `5063/5762/5763` have no listener. Shared ADB servers `5037/5047` remain running with
  their original PIDs `23749/51027`. No shared ADB server, AVD, or desktop CUA was operated.
- All instrumentation uses explicit `adb -P 5063 -s emulator-5762 shell am instrument -w -e class ...
  com.rawlab.android.test/androidx.test.runner.AndroidJUnitRunner`, never `connected` enumeration.
- Phase matrix: `EditorV08ControlsTest`, `EditorV08DraftTest`, `GeometryControlsTest`,
  `LensControlsTest`, `PhotoEffectsControlsTest`: 9/9 PASS on 800x1280 dp / system font 1.6.
- Pre-keyboard-fix phone matrix: 360x800 dp / system font 1.6, 4/4 PASS. Includes exact drafts,
  bundled label decoding, six-language 280 dp format rows with text-layout overflow assertions,
  real RAW, exposure layout, on-canvas geometry, fixed draft actions and DNG file-only sheet.
- 1280x800 dp / font 1.0 real-RAW layout case: PASS, photo left and dock right. That two-test run
  was NOT a suite pass: the other text-overflow assertion failed against merged semantics. The
  assertion was corrected to inspect unmerged text and passed in the later phone matrix.
  Tablet structural runs preceded the final Kelvin-current preservation, Material container color
  corrections and later numeric keyboard fix; the layout implementation was unchanged. The four-test
  phone matrix includes the Kelvin/color corrections but not the later keyboard fix.
- Actual Google launcher circular icon inspected after installation: full opaque dark background,
  intact yellow/cyan frames, no visible extra top white stripe. This is one launcher/mask only.
- Final application UI matrix: 360x800 dp / system font 1.6, 10/10 PASS in 253.402 seconds.
  Includes the sign action, exact-dialog Cancel/reopen, six-language narrow format text, actual film
  bitmap decoding, real RAW layout, geometry/lens draft persistence/recreation/stale-result isolation,
  export/library/batch draft guards, geometry numeric controls, lens controls and effects controls.
- Native integration on `c531173`: 4 tests, 3 PASS and 1 timeout failure, 948.013 seconds total.
  Geometry exact/interactive preview, FINAL export and reset: PASS. Rendered DNG/PNG with all
  adjustments on CPU and forced GLES (asserted backends 0/2), plus source-RAW hash preservation:
  PASS. CPU preview+exports took 150519 ms; forced SwiftShader GLES took 485579 ms.
  Known-partial MediaStore output removal, recovery and discard: PASS.
- `BatchWorkflowInstrumentedTest.remembersEditsAndExportsFrozenBatchWithoutChangingTargetRecords`
  FAILED at line 74 after waiting 240000 ms for the original-size, high-denoise export. The journal
  still said `PROCESSING`, with no output URI/global error; the worker stack was inside
  `NativeProcessor.nativeProcess` via `BatchExport.kt:377`. The test process then exited.
  This does not establish either successful completion or a specific renderer root cause. The
  native renderer/export path was not changed for this UI work. No timeout increase or success
  reclassification was made; full batch/single pixel parity remains unverified in this run.

Native invocation used the following explicit class selection:

```sh
adb -P 5063 -s emulator-5762 shell am instrument -w -e class \
  'com.rawlab.android.NativeProcessorTest#geometryReachesExactInteractivePreviewFinalExportAndSessionReset,com.rawlab.android.RenderedDngInstrumentedTest#nativeDngBakesAllAdjustmentsOnCpuAndForcedGles,com.rawlab.android.BatchWorkflowInstrumentedTest' \
  com.rawlab.android.test/androidx.test.runner.AndroidJUnitRunner
```

Native evidence: `final-native-tests.txt`, `batch-timeout-journal.properties`,
`native-batch-timeout-logcat.txt`, and `c531173-native-artifacts/`.

Final UI invocation (same private device, after installing the final application/test APKs):

```sh
adb -P 5063 -s emulator-5762 shell am instrument -w -e class \
  'com.rawlab.android.EditorV08ControlsTest,com.rawlab.android.EditorV08DraftTest,com.rawlab.android.GeometryControlsTest,com.rawlab.android.LensControlsTest,com.rawlab.android.PhotoEffectsControlsTest' \
  com.rawlab.android.test/androidx.test.runner.AndroidJUnitRunner
```

Final UI log: `final-ui-phone-160-tests.txt`. Final application captures:
`final-f598c74-phone160/{film,exposure,geometry,dng}.png`. The geometry capture includes a
render-in-progress state; it is not evidence of a completed rotated frame. Native geometry assertions
and the completed draft test provide the separate behavior evidence.

Local screenshots and logs remain outside Git in `/tmp/rawlab-android-v08-56c3/evidence`.
They are Android emulator captures, not HTML/prototype screenshots.

### Review and Remaining Gates

Two independent in-chat read-only audits checked call chains, draft persistence/revision safety
and the UI. These were static reviews, not additional device-test passes.
Findings fixed: library operations and recovered batches cannot bypass drafts; locale commas parse;
unknown output counts are explicit and excluded from completion; empty import buttons lock correctly.
Reviewer rechecked those fixes with no new concrete finding. About keeps the actual running version;
backgrounding retains in-memory drafts without saving them, rather than silently discarding user work.
The last review's signed-keyboard finding was fixed with a Decimal IME plus a localized sign icon;
the reviewer rechecked the narrow change with no new concrete finding.

NOT REACHED: physical-device GPU/performance/thermal behavior, hardware haptic feel, TalkBack spoken
navigation, predictive-Back animation/edge gesture, complete physical IME/cutout matrix, foldable hinge
posture, OEM round/squircle/theme-icon masks and splash acceptance. No hinge-specific layout API was
added. Large-text and responsive evidence is from the emulator, not physical tablet hardware.

NOT RUN: hosted CI, full connected instrumentation suite, newly granted SAF directory DNG workflow,
original-size three-format camera matrix and all-camera parity. Existing contracts were retained;
design prototype checks are reference evidence only and are not Android product verification.

This report supplies Android implementation/evidence for coordination entries V08-007/V08-014/
V08-020/V08-021. The global 0.8 checklist, Shared/core ABI and other platforms were not edited.

## Batch Timeout Follow-Up

The [local fixed-budget investigation](batch-timeout-diagnosis.md) reproduced the same timeout on
the exact pre-v0.8 baseline and localized it to SwiftShader's full-resolution Clean wavelet path.
Fresh-session CPU Clean and FORCE-with-denoise-disabled controls pass within the unchanged 240 s
budget. The evidence points to a pre-existing emulator software-GLES slow path rather than v0.8
introducing this timeout. Both original runs remain censored at 240 s: this does not prove equal
uncensored GPU throughput or exclude every smaller regression, change the original test result,
or replace physical GPU acceptance.

## Batch GPU Preference Follow-Up

Batch target validation, effect preview and export now inherit the editor's GPU switch, including
new and resumed batch entry points. GPU off selects CPU; GPU on retains AUTO with CPU fallback.
The [local red/green verification](batch-gpu-preference-verification.md) first reproduced the ignored
switch and unchanged 240000 ms timeout, then passed the entire existing batch workflow class:
2/2 tests, 289.022 s total. Original-size Clean export completed in 133402 ms within the original
240 s wait, with 4672x7008 output and identical CPU single/batch decoded pixels. The class total
includes the independent single-export reference. No timeout or quality parameter was changed.
The prior AUTO/SwiftShader failures remain historical failures, not reclassified passes; physical
GPU acceptance and GPU-on full-resolution Clean completion remain unverified.
