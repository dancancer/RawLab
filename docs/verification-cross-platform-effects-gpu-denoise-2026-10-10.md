# Cross-Platform Effects and GPU Denoising Verification

Date: 2026-10-10. Local worktree branch: `feature/cross-platform-effects-gpu-denoise`,
based on `development` at `86ddfe9`. These results were recorded during
implementation before Gitflow delivery. They are local build/runtime evidence,
not remote-commit CI or final versioned-release verification.

## Implemented Contract

All four clients use the existing shared rendering formulas and additive session
setters; request v2 has not changed. Every preview/export sets the complete effects,
wavelet and display-chroma state. Effects participate in edit memory, batch
snapshots, reset and preview invalidation. Older saved records default to effects
and display-chroma off.

| Parameter | Range | Default |
| --- | --- | --- |
| Vignette Amount | -100..100 | 0 |
| Vignette Midpoint | 0..100 | 50 |
| Vignette Roundness | -100..100 | 0 |
| Vignette Feather | 0..100 | 50 |
| Vignette Highlights | 0..100 | 0 |
| Grain Amount | 0..100 | 0 |
| Grain Size | 0..100 | 25 |
| Grain Roughness | 0..100 | 50 |

Controls round half steps away from zero. Amount zero preserves auxiliary values
but bypasses its effect. Highlights protection applies only to negative vignette.
Display-chroma mode 0/1/2 is independent of wavelet chroma, defaults to 0, and is
carried internally without adding a second denoise selector.

Wavelet filtering precedes exposure/LUT. Display-chroma follows tone/LUT; detail,
vignette and fixed-seed grain precede final resizing. Metal serves Mac/iOS, GLES
3.1 compute serves Android, and D3D11 compute serves Windows. CPU retains noise
estimation/calibration, OpenCV Lab conversion and outer filters, RAW development
and file encoding. This is not an all-GPU pipeline. Native DCP remains CPU/Metal
only. Auto retains CPU fallback; Force reports required GPU failures.

## Confirmed Gates

| Platform | Result |
| --- | --- |
| macOS shared core | Release rebuild and all 19 CTest cases passed, including Sony/DJI RAW fixtures, individual filters, complete denoisers, photo effects and GPU photo contracts. |
| iOS framework | Device arm64 and simulator arm64/x86_64 XCFramework build passed with wavelet and display-chroma dependencies enabled. |
| iOS client | Simulator app and unsigned arm64 device app builds passed. Presentation, edit-memory and batch-export suites passed. No physical iPhone runtime or signed installation was tested. |
| iOS rendering | `processor-export.sh` passed synthetic and real Sony RAW processing/export checks. Forced Metal with simultaneous effects, wavelet, display-chroma and sharpening matched CPU within 2 code values; repeated GPU grain was identical. |
| iOS UI | Targeted `testPhotoEffectsControls` passed on iPhone 17e, including access to all five vignette and three grain controls, negative-only highlights protection and group reset. Portrait screenshots were inspected. Landscape, accessibility-size effects controls and physical iPhone performance were not verified. |
| Android build | ARM64 and x86_64 debug app/test APK builds and `lintDebug` passed. All 55 JVM tests passed. |
| Android GLES filters | Standalone native `gpu_filter_tests` passed on Lenovo TB320FC, Android 15, Adreno GPU. The executable completed with exit 0, including EGL teardown. |
| Android photo pipeline | Standalone `rawlab_gpu_tests` passed synthetic neutral/Fuji tone/detail, resize, session/thread reuse, oversized-halo Auto fallback/Force failure and combined effects/wavelet/chroma/detail checks. Actual backend was GLES; repeated grain was identical. |
| Android RAW rendering | Seven native instrumented cases passed with the DJI DNG, including combined CPU/Force-GLES preview parity and native PNG export. The metadata case required LensModel, absent from that DNG; rerunning that case with the Sony ARW passed native JPEG/16-bit PNG, dimensions and metadata checks. This is not a claim that the full suite passed in one fixture run. |
| Android controls | Both `PhotoEffectsControlsTest` cases passed on the unlocked tablet. ActivityScenario helpers are included only in the debug APK so the device vendor's cross-APK activity restrictions do not block the harness. JVM tests and lint were rerun successfully after that test setup change. The final screenshot harness uses the actual `RawLabTheme` and direct Compose component capture; its test APK rebuilt and both cases passed again. Inspected 360 dp vignette and 600 dp grain images show all labels, values and reset controls without clipping or overlap, including negative-vignette highlights and disabled grain auxiliaries at zero amount. These are isolated controls on the tablet, not full-editor screenshots or a physical phone run. |
| Windows managed code | .NET 8 WPF application and full Windows test project cross-compiled with `EnableWindowsTargeting=true`: 0 warnings, 0 errors. Portable denoise/effects and edit-workflow suites passed. |
| Windows native build | Release C++ and HLSL build passed on the Windows build host. All 14 native CTest cases passed; no D3D11 filter test was skipped. The shared compute entry was also independently compiled as `cs_5_0`. |
| Windows RAW rendering | All 126 default managed/native/WPF checks passed, including actual Direct3D 11 rendering, native-resolution JPEG/16-bit PNG, dimensions, metadata and source protection. The additional denoise suite passed combined effects/wavelet/display-chroma/detail CPU parity within 2 code values, actual Auto/Force D3D11 backend assertions, deterministic grain and disable-backend fallback/failure checks. Exact denoise export matched an independent render within one code value. |
| Windows effects UI | All 44 additional photo-feature checks passed. Narrow-editor screenshots exposed clipped vignette labels; a failing allocated-width regression reproduced the defect. Effects now reflow by available width and remain scrollable within the adjustment dock. All five labels passed width checks, lower controls passed a reachability check, highlights enablement/reset worked, and grain/vignette/scrolled screenshots were inspected after the fix. |
| Static integration review | Read-only review found no confirmed must-fix defect in ABI layouts, full-state setters, persistence/reset, cache keys, render order or Auto/Force paths. |

The final Windows-only change after the full native/default suite was the effects
control layout. Its complete targeted 44-check suite was rerun against that change;
shared rendering code did not change.
The final sources were rebuilt and packaged as a self-contained Windows ZIP
successfully. This local artifact is not a published release.

Android numerical filter maxima against the existing CPU references:

- Complete wavelet denoiser: `1.49012e-7` RGB float.
- Complete display-chroma denoiser: `2.68221e-7` RGB float.
- Individual guided filter: `1.71542e-4` Lab units.
- Source-pixel vignette/grain: `6.58035e-5` RGB float.
- Combined synthetic FINAL output: `0` code values; the pixel tolerance gate is 2.

Windows D3D11 numerical filter maxima against the same CPU references:

- Complete wavelet denoiser: `1.78814e-7` RGB float.
- Complete display-chroma denoiser: `2.98023e-7` RGB float.
- Individual guided filter: `1.46866e-4` Lab units.
- Source-pixel vignette/grain: `1.3113e-5` RGB float.

The Windows result is an actual D3D11 backend assertion, not a WARP or CPU
fallback result. A display adapter's WMI name alone does not establish compute
availability; no physical GPU model or comparative filter performance is inferred.

Floating-point GPU output is tolerance-tested, not promised bit-identical across
drivers. The same grain hash and full-image coordinates are used on every backend.
GLES division may use reciprocal multiplication, as permitted by the
[GLSL ES 3.10 specification](https://registry.khronos.org/OpenGL/specs/es/3.1/GLSL_ES_Specification_3.10.pdf).
Shader periodic indexing avoids negative remainder operands.

## Unverified Gates

- Windows Explorer desktop integration was **NOT REACHED** by the additional
  photo-features runner because its SSH session had no Explorer desktop. Native
  WPF controls and rendered-window tests are covered separately.
- Low-memory devices, every camera model and comparative denoise performance were
  not evaluated in this run. Source-resolution RAW processing remains memory-intensive.

## Reproduction

Core:

```sh
cmake --build lutools/build-macos -j 8
ctest --test-dir lutools/build-macos --output-on-failure
```

iOS uses the existing `RawLab/tests/presentation.sh`, `edit-memory.sh`,
`batch-export.sh`, and `processor-export.sh` scripts. Pass an absolute built
simulator app path and an explicit simulator UDID to `processor-export.sh`.
The targeted UI gate is `RawLabUITests/EditorUITests/testPhotoEffectsControls`.

Android, from `RawLabAndroid` with the local Android SDK configured:

```sh
./gradlew testDebugUnitTest assembleDebug assembleDebugAndroidTest lintDebug
RAWLAB_TEST_RAW=/path/to/fixture.ARW ./gradlew connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.rawlab.android.NativeProcessorTest
./gradlew connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.rawlab.android.PhotoEffectsControlsTest
```

Use an unlocked, awake device for UI checks. RAW fixtures are external and only
enter the test APK. Native `gpu_filter_tests` and `rawlab_gpu_tests` are explicit
CMake targets, not production app assets.

To retain the controls images, install the app and test APKs manually, run the
same instrumentation class with `adb shell am instrument`, and pull
`/sdcard/Android/data/com.rawlab.android/files/effects-screenshots` before APK
cleanup. The final images capture the tagged Compose surface, not a full-screen
image obscured by the vendor's application-list permission prompt. No unrelated
application-list permission was granted and no lock-screen authentication was bypassed.

Windows portable suites are `RawLabWindows/tests/denoise/DenoiseSettingsTests.csproj`
and `RawLabWindows/tests/editing/EditWorkflow.Tests.csproj`. Use the existing
`RawLabWindows/build-remote.py --test --raw /path/to/fixture.ARW` with a configured
SSH account, or `build.ps1 -Test -RawPath /path/to/fixture.ARW` on Windows.
The full Windows test runner additionally supports `--denoise` and
`--photo-features` with the repository root and an external RAW fixture.

Local evidence is in ignored `build/cross-platform-*.log`, the iOS test result
bundle and platform test report directories. Personal RAW files, screenshots,
credentials and binaries are not added to the source diff.
