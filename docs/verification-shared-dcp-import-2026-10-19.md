# Shared DCP Import Verification

## Source And Scope

- Branch: `feature/shared-dcp-import`.
- Starts from Mac DCP import and its CI repair, `f59d7f9` (PR #82).
- Integrates `origin/development` at `6780222` through local merge `af939a3`.
- This report covers the shared compiler and four client adapters in this change,
  not an arbitrary later checkout or a published release.
- The cross-platform branch has not been pushed. Hosted CI for this change has
  **not run**; local results below must not be presented as hosted CI results.

## Implementation

`lutools/src/core/dcp_compiler.cpp` is the only application DCP parser/converter.
It owns bounded TIFF parsing, D65 adaptation, table normalization, numerical-rank
validation, tone interpolation and RLOOK v1/v2 serialization. The additive
`sony2fuji_compile_dcp` / `sony2fuji_release_blob` C ABI owns native allocations
and returns stable rejection reasons. Existing renderer/request layouts remain
unchanged. Python/NumPy/OCIO are test-oracle dependencies only.

Mac and iOS share `Shared/DCPCompiler.swift` and `Shared/LookLibrary.swift`.
Android uses JNI and its existing managed look-library transaction. Windows uses
P/Invoke and durable DCP-derived RLOOK storage; its existing external CUBE/RLOOK
references remain unchanged. All clients reject missing tone, automatic black,
unsupported stages and invalid calibration/tables with localized explanations.

The import policy remains stricter than the legacy preparation CLI: an embedded
tone curve and explicit `DefaultBlackRender=None` are required. There is no
silent Adobe-default inference and no claim of Lightroom rendering parity.

## Local Results

| Area | Actual result |
| --- | --- |
| Mac application | `RAWLAB_RUM=0 bash RawLabMac/build.sh` passed; macOS 14 deployment target, arm64, bundled/signed dependencies |
| Shared compiler / Swift adapter, arm64 | 23 assertions passed; six synthetic Python differential methods and the optional privately owned Canon profile method passed |
| Shared compiler / Swift adapter, x86_64 | 23 assertions and six synthetic differential methods passed under Rosetta; private-profile method skipped |
| Core suite | `ctest --test-dir lutools/build-macos --output-on-failure`: 37/37 passed, including native DCP and Metal regressions |
| Mac persistent library | `RawLabMac/tests/look-library.sh`: 54 assertions passed |
| Mac import model / real RAW | `RawLabMac/tests/look-import-model.sh`: 39 assertions passed with local Sony RAW and Canon profile; CPU/Force Metal maximum difference 1 DN; JPEG and 16-bit PNG export passed |
| Mac package | `RawLabMac/tests/bundle.sh` passed, including exact nlohmann MIT notice comparison |
| iOS native framework | Device arm64 and simulator arm64/x86_64 built; `verify-framework.sh` passed architecture, runtime dependency, compiler-symbol and license checks |
| iOS application | Simulator `xcodebuild ... build-for-testing` passed with Xcode 27; app and UI-test targets compiled |
| iOS import runtime | `RawLab/tests/look-import.sh` passed on a task-owned iOS simulator; actual shared compile/validate/persist, mixed batch, typed rejection, source preservation, restart and selection decisions covered |
| Android JVM | `:app:testDebugUnitTest` passed, including injected compiler, bounds, rollback and failure-state cases |
| Android native / packaging | `:app:assembleDebug :app:assembleDebugAndroidTest` passed for arm64-v8a and x86_64; APK contains nlohmann MIT notice and attribution |
| Android runtime | Three DCP instrumentation tests passed on a new Android 35 ARM64 emulator: malformed reason, non-BMP UTF-8 filename and actual managed-library compile/validate/install/restart |
| Windows managed storage | `tests/looks/LookGrouping.Tests.csproj` passed: validation, rollback, durable identity, corrupt registry preservation and immutable snapshots |
| Windows interop on macOS | Real P/Invoke calls into a compiler-only arm64 dylib passed: output/header, non-BMP filename, missing-tone reason and repeated blob release; both Swift-generated and Python-generated synthetic fixtures used |
| Windows compilation | App and WPF test projects cross-compiled with .NET 8.0.425, `EnableWindowsTargeting=true`, `RawLabRumSdk=false`; zero warnings/errors |
| Localization | 27 tests passed; all 30 generated catalogs byte-identical, no unowned resources |
| CI policy | 23 tests, one optional Android cache/toolchain test skipped; final workflow-specific 12 tests and actionlint passed |

The synthetic differential suite covers both TIFF byte orders, D65 slots,
non-diagonal matrices, profile exposure, HSV encodings, dual HSM selection,
omitted saturation planes, absent look tables and tone endpoints. Content
rejections preserve existing output. Focused C++ checks also cover overlapping
Rational budgets, near-singular matrices, blob ownership and legal UTF-8 names.
ASan/UBSan and warning-enabled standalone compiler checks passed.

## CI Coverage

- Both Mac matrix jobs execute compiler, library and import-model scripts, with
  synthetic Python parity explicitly enabled. Private fixtures remain optional.
- Windows runs the shared `dcp_compiler` CTest and required Python parity. It
  generates public synthetic fixtures, enables real P/Invoke look tests and runs
  `ui-details`, including the no-RAW file-menu import regression.
- iOS runs the import harness after framework/app compilation. The harness creates
  and removes its own simulator when no device is supplied.
- Android builds both native ABIs, JVM regressions and the instrumentation APK.
  Hosted Android device execution is not configured; the three runtime results
  above are local emulator results.

## Review And Limits

Independent review prompted fixes for filename over-restriction and Windows
RAW-dependent import, hidden no-photo UI entry, startup failure on corrupt
registry and concurrent mutable-list access. Re-review cleared those findings.
The iOS all-failed path does not reapply the prior look or clear a master recipe.

Windows desktop/native packaging, WPF UI runtime and GPU behavior were not run on
a Windows machine. Cross-compilation and macOS CLR interop are not substitutes
for those checks. The newly wired Windows CI gates must run before integration.
Mac x86_64 execution used Rosetta, not an Intel Mac. Physical minimum-OS Mac/iOS
devices and Android hardware were not tested. Renderer/backend support is
unchanged: Android/Windows native DCP looks retain CPU Auto fallback and reject
unsupported Force GPU execution.

No private DCP tables or personal RAW files are checked in. Original input files
remain unchanged. Test-owned iOS and Android devices were shut down and removed; the
private Android ADB server was stopped without touching other devices. One-time
logs, build intermediates and generated fixtures are cleaned after recording
these results; the Mac app, iOS framework and Android debug APK are retained as
local artifacts.
