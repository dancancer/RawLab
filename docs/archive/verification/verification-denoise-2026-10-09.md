# Cross-platform denoise verification

Scope: the development-source wavelet denoise feature, based on main
`5ff3a65f8882d83c0933ce36822461b1e995e9d8`. This is not a release certification.
Pending AI color matching, batch export and persistent edits are excluded.

## Contract

- Off by default; Detail is 0/46/50 and Clean is 10/72/100 (luma/chroma/coarse).
- All three controls accept finite values from 0 to 100. Disabling retains values;
  reset restores disabled defaults.
- Original comparison pixels do not follow exposure, white balance, LUT or denoise.
- Frame-size changes preserve the source viewport, zoom and pan.
- Interactive approximation never supplies exact preview or export pixels.
- CPU execution is explicit: Auto falls back; Force rejects unsupported denoise.
- OpenCV 4.12.0 and wavelib are source-pinned, hash-verified and carry licenses.

## Completed checks

| Platform | Build | Runtime and regression evidence |
| --- | --- | --- |
| macOS arm64 | Native core and app build | CTest 11/11; settings, viewport and editor-model tests; real Sony RAW with all three controls, repeated exact rendering, exposure/WB invalidation, proxy isolation, native-size 16-bit PNG and exact/export parity within one 8-bit code value |
| iOS | XCFramework: device arm64, simulator arm64/x86_64; simulator Debug and unsigned device Release apps | Model tests; 13 simulator processor/export checks, including native denoise, Off restoration, proxy isolation, zoom/pan preservation, RAW/raster processing and export metadata |
| Android | arm64-v8a/x86_64 JNI, Debug APK, unit tests and lint | API 35 arm64 emulator: 5 native/viewport tests and 1 controls test; independent full-resolution PNG parity, fixed comparison dimensions, zoom/pan, preset selection and disable/re-enable; compact 360dp control screenshot inspected |
| Windows x64 | MSVC native libraries and self-contained WPF app, built on Windows | Native CPU CTest 5/5; model tests; WPF comparison/geometry plus denoise checks on Windows: unchanged original, independent exact render after proxy, CPU/Force handling, native-size 16-bit PNG and exact/export parity; packaged dependency licenses verified |

The Android and Windows denoise integration fixture is a deterministic synthetic
Bayer DNG produced by `lutools/tests/make_denoise_fixture.py` using NumPy and
tifffile. It is generated outside source control and is not a camera-quality claim.
Mac RAW/export coverage uses an external Sony sample; source photos are not added
to the repository or uploaded as build artifacts.

## Reproduction entry points

- Shared core: enable `SONY2FUJI_ENABLE_WAVELET_DENOISE`, build, then run CTest.
- Mac: `RawLabMac/build.sh`, `tests/wavelet-settings.sh`, `tests/presentation.sh`,
  `tests/denoise-model.sh <RAW>` and `tests/wavelet-render.sh <RAW>`.
- iOS: `lutools/platform/ios/build-framework.sh`, Xcode app builds,
  `RawLab/tests/presentation.sh` and `RawLab/tests/processor-export.sh
  <absolute simulator app path> <simulator UUID>`.
- Android: Gradle `testDebugUnitTest`, `lintDebug`, `assembleDebug` and
  `connectedDebugAndroidTest` with `-PrawlabTestRaw=<generated DNG>`; select
  `NativeProcessorTest#waveletDenoisePreviewAndExportShareTheSameSettings`,
  `PhotoCanvasTest` and `DenoiseControlsTest` for the targeted device suite.
- Windows: `RawLabWindows/build.ps1 -SelfContained`; build the test project and
  run `RawLabWindows.Tests.dll --denoise <repository> <generated DNG>` with the
  freshly built native DLLs, compiler runtime and ExifTool on the test path.

## Boundaries

No release, signing submission or App Store/TestFlight upload was performed.
iOS and Android physical-device runtime/peak-memory validation remains pending.
Windows testing used a VM's CPU path, not a hardware Direct3D denoise backend.
Mac Intel and older macOS hardware were not revalidated in this change.
