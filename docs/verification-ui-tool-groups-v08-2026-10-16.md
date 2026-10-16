# v0.8 White Balance and Vignette UI Follow-up

Date: 2026-10-16. UI worktree started from the CI/macOS-14 preparation
revision `1949b6d`. These changes are separate from that CI PR and from the
new bundled-LUT work. Initial verification preceded delivery; consult the UI
PR for the current push, CI and merge state. No formal release is authorized.
The final local branch is rebased onto CI preparation revision `8b1b841`;
only its release-evidence document differs from the tested pre-rebase tree.
All production sources, tests and workflow hooks are byte-identical.

## Scope

- macOS, iOS/iPadOS, Android and Windows expose one **White Balance** tool,
  while preserving separate temperature/tint parameters, saved edits,
  recipe identities and desktop Agent contracts.
- Vignette starts collapsed. Its collapsed panel retains the intensity
  control/value and expansion action, with neither group nor intensity reset.
  Expanded panels retain group/individual resets. Grain behavior is unchanged.
- Complete model-parameter lists remain distinct from visible tool lists.
  In particular, iOS batch summaries and per-parameter tests still include tint.

## macOS Evidence

The complete default Apple Silicon app build and bundle checks passed with a
14.0 deployment target. The host runs macOS 27: this is not macOS 14 runtime
acceptance or Intel runtime evidence.

`RawLabMac/tests/presentation.sh` passed 95 assertions, including a failing
pre-fix single-WB-tool regression, tint-only changed state, camera-pair reset
and recipe-preserving zero-tint-offset reset. `control-groups.sh` passed 22
assertions; `test_tool_group_ui.py` passed four source-contract checks. The
source checks supplement, rather than replace, native interaction.

Native acceptance used the actual production editor views in a private test
app, with isolated look/edit/batch directories and a copy of the tracked DJI
DNG. Input SHA-256 before/after:
`0ecdc8087d566c5ba39f9bd40eef4dfc5f3884ccb016f311a606508751c79eaf`.

- The full window AX tree contains one `tool.temperature` named White Balance
  and no `tool.tint`; both numeric controls remain present.
- Editing tint to 24 preserves 4928 K; editing temperature to 6000 K preserves
  tint 24. The White Balance context action restores 4928 K / tint 13 and
  as-shot mode through native keyboard menu activation.
- A collapsed vignette at -40 exposes its slider/value and expansion action,
  with zero `effects.reset*` elements.
- Expansion exposes five parameter/value pairs, five individual resets and
  one uniquely identified `effects.resetGroup.vignetteAmount`.
- Midpoint 24 survives collapse/re-expansion; native group reset restores
  intensity 0 and midpoint 50. Wide-window screenshots were inspected for
  overlap; minimum-size and physical macOS-14 interaction remain unverified.

An initial in-process SwiftUI accessibility probe returned an empty tree and
was discarded; it is not counted as successful runtime coverage. CUA's full
window AX tree and actual control actions supplied the native evidence above.

Local logs: `/tmp/rawlab-v08-ui-final-build.log`,
`/tmp/rawlab-v08-ui-presentation-target14.log`,
`/tmp/rawlab-v08-ui-control-groups-target14.log`. Screenshots/AX action traces are in the
coordinating chat, not shipped photo resources.

## Other Platforms

| Platform | Current evidence | Remaining gate |
| --- | --- | --- |
| Android | JVM tests, lint, debug/test APK builds and five targeted connected-device Compose tests passed on Lenovo TB320FC / Android 15 / API 35; root independently reran the five tests with `OK (5 tests)` | The device's pre-existing language-resource test assumption failed and is not a pass. Real RAW export was not rerun for this UI-only change. Android still accepts RAW only. |
| iOS/iPadOS | Current-source three-slice framework build/verification and unsigned simulator `build-for-testing` passed. Both targeted native tests passed on iPhone 18 Pro and iPad simulators, iOS 27. Presentation/model regressions passed, including complete parameter enumeration and recipe-preserving reset. | Simulator evidence does not close physical-device, minimum-iOS-18, signing or installation acceptance. The raster export test validates its confirmation/cancel flow, not an actual saved JPEG or RAW processing parity. |
| Windows | Default native/CMake and WPF package build passed in an isolated remote workspace; `BuildScriptChecks.ps1` and the independent `tool-groups` WPF suite passed, 28 checks including recipe-preserving reset and transform navigation | The full `photo-features` suite passed the new assertions, then timed out at its existing folder-apply confirmation under SSH Session 0. It remains failed, not an all-green suite. Physical desktop/native-input confirmation was not performed. |

No platform's pending native check is substituted by another platform's result.

Android reproduction:

```sh
cd RawLabAndroid
ANDROID_HOME="$HOME/Library/Android/sdk" ./gradlew :app:testDebugUnitTest :app:lintDebug
"$HOME/Library/Android/sdk/platform-tools/adb" shell am instrument -w -r \
  -e class com.rawlab.android.EditorToolsTest,com.rawlab.android.PhotoEffectsControlsTest \
  com.rawlab.android.test/androidx.test.runner.AndroidJUnitRunner
```

Android's five checks cover one selected accessible WB entry, both axes and
as-shot reset, vignette expansion/highlight availability and unchanged grain.
Root's device log is `/tmp/rawlab-v08-ui-compose-root.log`; the worker's JVM,
lint and device command ledger is `/tmp/rawlab-android-ui-groups-20261016.md`.

### iOS/iPadOS Native Matrix

The framework was freshly built from this source for device arm64 and simulator
arm64/x86_64, using the shared checksummed source archives. Framework verification
and the final simulator app/test build passed. `RawLab/tests/presentation.sh`
also passed locally; model/serialization tests are not substitutes for UI input.

| Private simulator | Targeted XCTest result | Result bundle |
| --- | --- | --- |
| RawLab iOS Editor V4 iPhone, iPhone 18 Pro, iOS 27 | 2 passed, 0 failed | `/tmp/rawlab-v08-ui-iphone-final2.xcresult` |
| RawLab iOS Editor V4 iPad, iOS 27 | 2 passed, 0 failed | `/tmp/rawlab-v08-ui-ipad-final.xcresult` |

The two tests are
`EditorV4UITests/testVignetteHighlightAvailabilityAndHSLChannelValues` and
`EditorV4UITests/testRasterJPEGExportConfirmationUsesCommittedValuesAndBlocksDirtyGeometry`.
They cover folded/expanded reset visibility, retained vignette values/highlight
availability, independent temperature/tint edits to 7000 K / +12, and the
existing geometry/export-confirmation cancellation path. The generated raster
fixture belongs to the private simulator library; no personal photo was added
to the repository. An iPad vignette screenshot was inspected for clipping and
overlap, including the two-line White Balance toolbar caption.

After adding explicit assertions that `tool.temperature` occurs exactly once,
is named White Balance and has no `tool.tint` peer, the app/tests were rebuilt
and the WB/raster test passed again on each simulator (one test each, not four
additional distinct cases). Results are
`/tmp/rawlab-v08-ui-iphone-wb-entry.xcresult` and
`/tmp/rawlab-v08-ui-ipad-wb-entry.xcresult`; the production app and vignette test
are unchanged from the preceding two-test runs.

Earlier failed runs remain failures: the picker AX label uses grouped `7,000 K`,
not `7000 K`; signed small values must retain their `+` prefix; numeric test
parsing must accept grouped values. The vignette test now performs its initial
group reset only after expansion makes that action available. These were test
assumption fixes, not reasons to weaken assertions or restore folded resets.

Windows reproduction from the isolated build workspace:

```powershell
./RawLabWindows/tests/run-v08.ps1 -RawPath <external-RAW> `
  -NativeArtifacts ./build/RawLab-Windows -Only tool-groups
```

The `tool-groups` command exits 0 independently; the original full photo suite
calls the same assertion block and retains its confirmation path. Local Windows
final managed-build/publish/test evidence is in
`build/windows-remote/20261016-170827/`, including `summary.json`,
`tool-groups.log` and `RawLab-Windows-tool-groups.zip`. The final source restores
the existing Saturation -> HSL -> White Balance -> Denoise -> Sharpening order;
the 28 checks were rerun after that correction. Package SHA-256:
`dd93f46f473f1c7b1550e783158b01ec44dbd951a08991d066cd516c3645a5e5`.

## Regression Hooks and Cleanup

The UI branch adds macOS presentation/control-group/source checks and the
Windows `tool-groups` suite to the hosted workflow. Six workflow policy tests
and actionlint passed. These UI hooks are separate from CI PR #59's baseline
and require their own current-head CI run. Android JVM tests use the existing
job, while iOS CI only compiles the UI tests and does not claim simulator
execution.

The private macOS acceptance profile/app and input copy were removed without
changing the original fixture or user edit records. Unneeded local native
dependency/build intermediates and the extracted iPad screenshot were removed.
The useful macOS app, Windows package, iOS framework and test-result evidence
remain available in their dedicated build or temporary directories.
