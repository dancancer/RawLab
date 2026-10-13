# iPad and Cross-Platform Color Controls Verification

## Scope and Branch

Implementation is on `feature/ipad-hsl-auto-exposure`, based on
`origin/development` at `ffadcd4ee765e72fa20cfea9461767e6b3507cc7`.
This report records local implementation verification. On 2026-10-11 the owner
authorized a commit, push, PR to `development` and merge; remote delivery and
exact-head check status are recorded in the PR. Release and deployment remain
outside scope. The original checkout and its unrelated untracked files were
preserved.

The three color changes are implemented in iOS, macOS, Android and Windows.
iOS additionally targets iPad, includes iPad icons/orientations, and uses
window-size-driven layouts. New settings use embedded-preview exposure matching;
legacy records without a mode retain the scene baseline. Explicit saved modes,
HSL and the chosen EV survive edit-memory and frozen batch snapshots.

## Completed Checks

Commands below are run from the repository root; `rtk` is the shell wrapper.
Apple commands use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
External Sony RAW coverage uses `RAWLAB_TEST_RAW`; the DJI DNG fixture is in
`lutools/examples`.

| Area | Command or check | Result |
| --- | --- | --- |
| Shared core | `ctest --test-dir lutools/build-macos --output-on-failure` | 14/14 passed, including HSL/Auto, Metal, denoise, effects and DJI RAW |
| Sony RAW color controls | `lutools/build-macos/photo_color_tests /path/to/DSC06251.ARW` | Passed |
| macOS app | `MACOSX_DEPLOYMENT_TARGET=15.0 bash RawLabMac/build.sh` | Built; dependency bundling/signature checks passed |
| macOS actual RAW | `bash RawLabMac/tests/adjustments.sh` with Sony RAW enabled | Two RAW fixtures passed, including actual-pixel preview/export and 16-bit export checks |
| macOS edit workflow | `edit-memory.sh`, `edit-model.sh`, `batch-export.sh` under `RawLabMac/tests` | Passed, including HSL/mode restart and frozen batches |
| iOS core | `bash lutools/build.sh ios` | Device and simulator slices built; license/runtime-dependency checks passed |
| iOS models | `presentation.sh`, `edit-memory.sh`, `batch-export.sh` under `RawLab/tests` | Passed, including defaults, migration, narrow-window/accessibility layout policy and frozen HSL/mode |
| iOS actual render/export | `bash RawLab/tests/processor-export.sh /absolute/path/to/RawLab.app DEVICE_ID` | Passed with Sony RAW, Force Metal HSL buffer/final RAW parity and bounded/idempotent RAW/raster Auto |
| iPhone UI | `EditorUITests/testHSLAndAutoExposureAdaptiveLayout` on iPhone 17 Pro, iOS 27 simulator | Passed, including repeated Auto, HSL and selected-tool visibility after rotation |
| iPad UI | Same focused UI test on iPad Pro 11 M5, iOS 27 simulator | Passed, including portrait/landscape layout and selected-tool visibility after rotation |
| Android unit/build/lint | `./gradlew :app:testDebugUnitTest :app:assembleDebug :app:lintDebug` | 56 tests passed; APK built; lint has 0 errors and 38 existing warnings |
| Android native processing | `NativeProcessorTest#hslAndAutomaticExposureReachTheSharedCore` on a dedicated read-only emulator | Passed: actual RAW pixels, Auto/Force HSL on GLES, CPU parity, identity/cache restoration, Auto bounds/idempotence and all baselines |
| Windows managed tests | `dotnet run` for `tests/editing/EditWorkflow.Tests.csproj` and `tests/denoise/DenoiseSettingsTests.csproj` | Passed |
| Windows WPF compile | `dotnet build RawLabWindows/RawLabWindows.csproj -p:EnableWindowsTargeting=true -p:RuntimeIdentifier=win-x64 --no-self-contained` | Passed with 0 warnings and 0 errors |
| Windows native HSL follow-up | Isolated MSVC core build and CTest `photo_color`, `d3d11_shader` | 2/2 passed; D3D11 host code and cs_5_0 HSL shader compiled; reflection verifies 320-byte constants and HSL offsets |
| Patch hygiene | `git diff --check` | Passed |

macOS was also exercised manually using an isolated copy of the DJI DNG: default
preview baseline, repeated Auto returning the same EV, blue-channel saturation,
saved HSL restoration and all three HSL sliders in the resizable dock. iPhone and
iPad portrait/landscape screenshots were visually inspected. Test logs, result
bundles and images remain local under the ignored `build/verification` directory.

## Review and Fixes

Platform/core read-only reviews checked native parameter mapping, persistence,
cache keys, batch snapshots and stale Auto protection. Metering now rejects
invalid WB/colorspace enums with regression coverage. Windows HSL drag handling
uses the editor's existing interactive preview path and submits an exact render
on release. iOS tool-strip automation uses controlled drags to avoid inertia and
invalid clipped AX activation points. Rotation recenters the selected tool.

## GPU HSL Follow-Up

The initial CPU-only HSL choice was replaced following the request to use GPU.
HSL now executes in the Metal/GLES/D3D11 photo shaders after tone/color and before
chroma/detail/effects. No request-v2 or client-persistence change was needed.
Identity HSL bypasses exactly, and Auto/Force keep the existing backend semantics.

- A failing HSL Force test first demonstrated the former CPU-only restriction.
- Metal tests cover each of the 24 axis/channel controls, red wrap, grayscale,
  mixed extremes, CUBE/tone, preview/final resize and chroma/detail/effects.
  Native DCP/HSL/effects also pass their float-stage and propagated-error gates.
- GLES native smoke tests cover the same channel mapping, wrap/grayscale,
  CUBE/tone, resizing and combined HSL/wavelet/chroma/detail/effects. Actual RAW
  instrumentation verifies Auto/Force GLES and fresh settings after cache reuse.
- GLES shader compilation exposed an incorrectly typed float-array constructor;
  explicit floating-point literals fixed it. Final native smoke and RAW tests
  passed after rebuilding and reinstalling the updated artifacts.
- iOS rebuilt device/simulator core slices and the simulator app; actual Sony
  RAW final export and raster HSL both succeed in Force Metal within two RGB8
  code values of CPU.
- Windows verification uses a dedicated temporary directory and read-only
  imported build dependencies. Native D3D11 C++ and GPU test binaries compile;
  HLSL compiles with the production flags and reflected constant offsets match
  the host. The isolated core build disables denoise features; it does not
  replace a full production build or hardware GPU test. Setup was corrected to
  inherit the normal Windows NOGDI definitions and UTF-8 compiler option.

Local follow-up logs are `build/verification/hsl-metal-gpu-final.log`,
`hsl-metal-dcp.log`, `hsl-gles-gpu-final.log`,
`hsl-android-instrumentation-final.log`, `hsl-ios-processor-export.log` and
`hsl-windows-native-verified.log`. No source or build output in the original
Windows workspace was changed, and no RAW fixture was uploaded there.

## Verification Boundaries

- GPU Auto may still fall back on an actual backend failure. Native DCP looks
  retain their pre-existing CPU-only path on GLES/D3D11; Metal supports them.
  GPU Force never reports a CPU replacement as GPU success.
- No physical iPad/iPhone or physical Android device was tested. iPad split-window
  and accessibility selection are covered by the layout-policy tests, not a full
  interactive multitasking/device matrix.
- The available Windows host has Microsoft Basic Display Adapter, not a usable
  hardware D3D11 adapter. Native compilation, HLSL reflection, portable tests and
  WPF cross-compilation do not establish hardware D3D11 parity/performance or
  real WPF interaction. No shared Windows build workspace was overwritten.
- Auto is a bounded luminance heuristic, not scene recognition or guaranteed
  highlight recovery. A matched embedded preview remains an approximation and
  falls back to scene mode when its reference is unusable.
- These are local verification results, not exact-head CI results. The PR records
  the remote check status. No release signing, notarization or IPA distribution
  was performed.
