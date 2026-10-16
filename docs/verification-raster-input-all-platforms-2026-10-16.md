# All-Platform Raster Input Verification

Status (updated 2026-10-17): local implementation and targeted native acceptance
completed. Final-head hosted CI and integration status are tracked on
[PR #62](https://github.com/dancancer/RawLab/pull/62), not inferred from baseline CI.
This is not a release or physical-device compatibility claim.

## Scope

Base: `development` `9066bf782bcdd98117320e5e39dabf28aa1c450b`.
Branch: `feature/all-platform-raster-input`.
Reviewed implementation: `b661a6b`, followed by acceptance/review fixes in
`41bf21c`. Documentation-only follow-ups do not change the tested source.

| Client | Accepted input family | Adapter |
| --- | --- | --- |
| macOS | JPEG, PNG, TIFF, HEIF | Existing shared ImageIO adapter |
| Windows | JPEG, PNG, classic single-page TIFF | Existing WIC adapter; HEIF/BigTIFF not enabled |
| iOS | JPEG, PNG, TIFF, HEIF | Same ImageIO adapter as macOS, now enabled and linked on iOS |
| Android | JPEG, PNG | Platform decoder with format validation; TIFF/HEIF not enabled |

Inputs must be single-frame opaque RGB8 SDR. Supported RGB color profiles are
converted to sRGB, untagged RGB assumes sRGB, and orientation is applied once.
HDR/gain maps, high-bit-depth/float, transparent and unsupported non-RGB inputs
must fail instead of being silently flattened or quantized. This does not add
HDR output, mobile Agent or MCP.

Android's ICC support is deliberately limited to bounded RGB/XYZ matrix/TRC
profiles representable by its platform decoder, including ordinary sRGB,
Display P3 and AdobeRGB. It validates ICC header/class/version, D50, matrix,
transfer curves and PNG/JPEG profile packaging before decoding. Unsupported
Lab/A2B-only or malformed profiles are rejected rather than relying on the
platform's silent sRGB fallback. This is not a general-purpose ICC engine.

Raster requests use `SONY2FUJI_INPUT_DISPLAY_BUFFER=2`, bypass RAW baseline and
the scene sigmoid, and retain the common look, tone/HSL, denoise, effects and
geometry stages. Camera-only settings are resolved for each input, without
overwriting the saved/frozen source settings. FINAL exports use full source
pixels, not interactive previews.

## Evidence

### Shared Apple Adapter

- Before enabling iOS, the existing `display_image_tests.cpp` compiled for the
  arm64 simulator failed JPEG/PNG/TIFF/HEIF/P3 decode and empty-path assertions:
  the native adapter returned `UNSUPPORTED`.
- After enabling it, the same source-backed simulator check passed orientation,
  tightly packed opaque pixels, TIFF/HEIF, independent Display P3 to sRGB,
  untagged RGB and rejection of transparent/16-bit/multipage/CMYK/corrupt input.
  This early test linked the old framework only for buffer release; it is not
  the final rebuilt-framework or app acceptance result.
- ISO gain-map access now checks runtime availability, preserving the macOS
  14 deployment target while using iOS 18's existing ImageIO API.
- Final packaged-framework runner: `bash lutools/tests/display-image-ios.sh
  /path/to/sony2fuji.framework SIMULATOR_UDID`.
- Fresh full-feature device arm64 and simulator arm64/x86_64 builds, followed by
  an incremental rebuild of the final decoder source, passed the framework's
  architecture, patched LibRaw, license and system-runtime-dependency checks.
- Packaged-framework decoder execution on the dedicated iPhone simulator
  (iOS 27, arm64, minimum target 18) passed **62 assertions**, including all eight
  EXIF orientations and rejection of a real ISO gain-map JPEG. The simulator
  encoder could not generate that JPEG, so the host generated and verified its
  actual auxiliary gain map first; the same bytes were supplied using
  `RAWLAB_TEST_GAIN_MAP`. The runner forwards this to the simulator environment.
  The synthetic fixture SHA-256 is
  `2d31b068d099e9299f2dbd1f06d6f7296e8d796ac2483786a364adb55e9412f8`.
- Host CTest passed **30/30** in a fresh, consistently configured Xcode build,
  including display input/render, Agent/recipe, geometry, RAW WB, GPU photo and
  DNG regressions. The expanded decoder test was rebuilt and passed afterward.
  This default test configuration is not a new full desktop app/package or
  Windows physical-device acceptance.
- Decoder metadata inspection releases its temporary image before creating the
  oriented image. Drawing context/image ownership ends before the alpha scan or
  backing-buffer release. This reduces avoidable overlap; no measured mobile
  peak-memory guarantee is claimed.
- Delivery review found that a profiled grayscale PNG bypassed the non-RGB
  guard. The new fixture first verifies its embedded profile and monochrome
  source model; the old packaged framework then failed rejection and cleared
  output assertions. Requiring RGB before and after orientation fixes both.
  Fresh full-feature three-slice framework build/verification passed, and the
  packaged decoder passed **66 assertions** on the private iOS 26.4 iPhone,
  including the grayscale regression and external verified gain-map fixture.
- The delivery core build passed **36/36 CTest** with wavelet/chroma denoise,
  GPU, Lensfun and DNG SDK enabled and a macOS 14 compilation target. Its LibRaw
  0.22.2/DNG SDK were freshly compiled through this checkout's wrapper. An
  initial experiment with an older prebuilt dependency prefix failed the SDK
  OOM injection test; that configuration was replaced, not accepted or skipped.
  Logs: `/tmp/rawlab-raster-delivery-core-ctest.log` and
  `/tmp/rawlab-raster-delivery-ios-decoder-green26.log`.

### iOS App and Model

- Fresh unsigned simulator `build-for-testing` passed against the rebuilt
  framework. Legacy scene-buffer defaults remain unchanged; the raster loader
  opts into explicit display-buffer semantics.
- `batch-export.sh` passed, including the added regression proving that
  dismissing a DNG journal preserves the actual exported image bytes;
  `import-state.sh`: 167 passed;
  `geometry-processing.sh`: 60 passed. The optional actual-RAW perspective
  section was not enabled in that geometry run.
- `processor-export.sh`: 36 passed. Its optional calibrated-lens RAW section
  was skipped: the DJI DNG fixture does not supply the required distortion
  calibration and is not a substitute for that test's matching lens fixture.
- `batch-publication.sh` exercised the actual `BatchExportModel` and processor
  with mixed raster plus the repository DNG fixture, JPEG publication through
  an injected test writer and persistent rendered-DNG publication. Both formats
  passed output readability checks; the real Photos writer remains the default.
- Independent review confirmed the file-import toolbar and method-level
  dirty/busy guards, background copy/hash work and source/target settings
  resolution. The iPhone native busy-lock test passed (1/1).
- The earlier iOS 27 run did not reach assertions because XCTest AX startup
  timed out. Native acceptance was completed instead on dedicated iOS 26.4
  simulators; the failed startup is not counted as a product-test pass.
- iPhone 16 Pro: busy-lock **1/1**, Files cancellation/committed-export and
  dirty-geometry guards **1/1**, actual Files selection **1/1**. The final
  selection rerun used the fresh framework/app and passed in 22.078 seconds:
  `/tmp/rawlab-raster-iphone-files-final.xcresult`.
- iPad Pro 11-inch (M4): **3/3**, no skips, 153.134 seconds of test execution:
  Files selection, busy-lock and cancellation/dirty-draft/export guards.
  `/tmp/rawlab-raster-ipad-files-final.xcresult`. An initial iPad test reached
  assertions but failed because its Files sidebar has no Browse button; the
  helper now detects the visible local-storage sidebar before using Browse.
  The same helper was rerun successfully on iPhone.
- Selection tests actually navigate the system picker through On My iPhone /
  On My iPad, Downloads and `RawLabFilesFixture, png`, then verify a visible
  editor image, enabled comparison and disabled RAW-only lens correction.
  Setup uses an opaque RGB8 PNG seeded only into the private simulator's local
  FileProvider group container (`File Provider Storage/Downloads`), resolved
  through `simctl listapps` rather than a product import backdoor. Provider URL
  identity is not an additional automated assertion. Screenshots were inspected.

### Android App and Device

- Full current-source JVM results: **153 tests, 0 failures/errors/skips**.
  Native request tests, `lintDebug`, both ARM64/x86_64 native builds, app and
  instrumentation APK builds passed. `check-native.sh` confirmed 16 KiB
  alignment for both ABIs.
- Lenovo TB320FC, Android 15/API 35: direct `RasterNativeInstrumentedTest`
  execution passed **11/11**. It covers neutral JPEG/PNG, orientation, real
  master-recipe parameters and strength 0/1/2, combined adjustments/geometry/
  denoise preview versus FINAL PNG, full-size export after a reduced preview,
  rendered-DNG float pixels versus inverse-sRGB PNG appearance, progressive
  JPEG, P3/AdobeRGB to sRGB pixels, malformed/semantically incomplete ICC
  rejection, Force rejection and RAW/raster/RAW session switching.
- Delivery review added valid SDR cICP PNG acceptance (`1/13/0/1`), retaining
  PQ/unsupported cICP rejection, strict sRGB intent/length checks and empty
  IEND/EOF checks. Three focused JVM tests failed before the fix and passed
  afterward; ICC conflict coverage also passed. The added real PNG device test
  verifies both known neutral pixels and FINAL PNG equality, not just metadata.
- The early instrumentation run exposed two test-fixture/sizing assumptions;
  those were corrected before the final run. A stricter ICC pass then rejected
  Android's valid seven-parameter `para` type 4 profiles. The actual synthetic
  platform-produced ICC bytes were inspected, valid type 4 support was added,
  and all ten original tests were rerun successfully. No permissive sRGB fallback was
  restored. Temporary diagnostic code and device-cache copies were removed.
- Installed and local APK SHA-256 values match:
  - app: `8b0aa4f05b32d512e57d642ef4cd3de12ac082a31e8fc7eedef9824213ed1180`
  - test: `51eed77d4ac9bf028b42324de1f9cdbf4c0c042edf327da414dbf640d5ef8f60`
- Build command: `RAWLAB_TEST_RAW=/path/to/DJI_20250602164503_0444_D.DNG
  ./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
  :app:assembleDebugAndroidTest --no-daemon --no-parallel --max-workers=2`.
  Final device acceptance is the direct runner with private ADB port 5047 and
  serial `HA1ZKK0Q`:
  `/tmp/rawlab-android-raster-native-direct-private5047-full-20261017.log`.
  The earlier default-port UTP run also passed 11 tests, but private-port UTP
  initialization reported zero tests; it is not counted as a pass. No formal
  application data was cleared. The delivery test APK uses the shared Sony RAW
  fixture supplied through `-PrawlabTestRaw`.

### Build Environment Notes

- The initial unconfigured host run stopped at LibRaw 0.21.5. A subsequent
  mixed-CLT/Xcode cache also failed to compile; its outputs were discarded.
  The passing fresh host build uses pinned 0.22.2 and one Xcode SDK, not a
  weakened minimum version or a product workaround.

Hosted CI was started on `b661a6b` in
[run 38929965841](https://github.com/dancancer/RawLab/actions/runs/38929965841).
Its Windows job exposed a real compile failure in the renderer-independent
editing test project: `BatchExport.cs` now referenced `RenderEngine`, which that
project intentionally does not link. The pure input-family/settings logic was
moved to `PhotoInput.cs`; existing renderer/library APIs delegate to it, while
the batch model and its tests link the pure helper directly. A final-head run
is required after this fix. PR checks are the authority for final CI status;
neither this first run nor older `9066bf7` development CI accepts a later head.

### Desktop Mixed-Batch Isolation

The mobile review exposed the same reverse-direction boundary on desktop:
camera-only values dormant in a raster source's saved edits must not become
active on a RAW batch target. macOS now resolves a temporary source/target-aware
copy in the actual batch runner and target preview. Its regressions were RED
before the fixes and the complete batch model suite passed afterward, preserving
recipe identity/strength/common style, the active recipe's relative tint offset
and the immutable snapshot. An independent raster style without a recipe loses
its dormant camera tint. RAW targets use the client's default RAW exposure mode,
not the sensor-only baseline used by display input. Full Mac Swift
source type-check at deployment target 14 passed. These are model/compiler
results, not a new desktop package or macOS 14 physical-runtime acceptance.

Windows restored-job isolation is implemented at final render, target preflight
and target preview, with active recipe tint and RAW-default exposure preserved.
The current-source WPF app/test build passed with 0 warnings/errors, and **91
raster checks** passed on Windows. Remote/local hashes of the four modified
Windows source files were verified. A forward-slash/default-working-directory
rerun exposed a test dictionary lookup that did not canonicalize the input path;
the test was fixed and the same invocation then passed 91/91. Its final log is
`C:/RawLabBuild/all-platform-raster-input/build/windows-raster-final.log`.

Windows native acceptance is now **42/42** across the same source/configuration:
the original 1-35 passed; 37-42 passed in 123.23 seconds; test 36 passed in
471.86 seconds with an unchanged real 25 MB RAW, assertions and thresholds.
The earlier 300-second timeout was replaced by an 1800-second execution window,
not a skipped or weakened test. Final log:
`C:/RawLabBuild/all-platform-raster-input/build/windows-native/windows-remaining-36-long.log`.
The later delivery edits do not change Windows native code.

After the pure-helper extraction, remote hashes of all six changed Windows
files matched. Editing net8, WPF app and WPF test builds passed with **0 warnings
and 0 errors**; the editing runner, about **40/40** and raster **91/91** passed.
The real batch-model regression also verifies raster-to-RAW normalization and
unchanged stored snapshots without depending on a renderer. Logs:
`C:/RawLabBuild/all-platform-raster-input/build/windows-hostedci-validation/`.
No new Windows package compression or distribution was performed.

## Retained Limits

- Actual macOS 14 runtime, iOS physical-device installation/color/memory, Android
  API 26 and other OEM behavior remain separate from current-host/simulator or
  API 35 checks.
- Require final-head hosted CI and independent review before integration. Local
  iPhone/iPad Files interaction acceptance is complete; it does not close the
  minimum-OS, physical-device or distribution gates for a release candidate.
- A 64-million-pixel validation ceiling is not a mobile peak-memory guarantee.
- iOS's old raster scene-buffer path previously applied the RAW neutral curve
  to an already developed image. Moving it to display-buffer semantics
  intentionally corrects that appearance and disables camera-only WB; it does
  not promise pixel compatibility with that old raster behavior. RAW processing
  and stored adjustment values retain their existing contracts.
- Existing published downloads remain v0.7.0. No tag, official release, distribution signing,
  store upload or deployment is authorized by this implementation.
