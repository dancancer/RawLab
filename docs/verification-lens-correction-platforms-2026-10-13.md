# Cross-Platform Lens Correction Verification

## Scope and Baseline

Branch `feat/lens-correction-development` is based on development commit
`12d6cc17b2b92233657d3eb548ee146dbdcb8530`, in an independent managed worktree.
The Lens-only core/macOS change was forward-ported from `d6cc5a9`; earlier
AI/JXL work on that branch was not imported. Development's HSL, photo effects,
master recipes, exposure modes, iPad layout and batch behavior were retained.
The original checkout and the older feature worktree were left intact.

iOS, Android and Windows now use the same additive Lens C API and unmodified
offline DB1 snapshot. Independent distortion/TCA, automatic/manual matching,
search, auto crop, per-photo memory, reset and frozen batch settings are included.
Purple/green defringe is not included. No original RAW was modified.

## Automated Gates

Logs and generated artifacts are in the worktree's ignored `build/` directory.
These are local/native checks, not hosted CI or optical certification.

| Gate | Result and evidence |
| --- | --- |
| Shared core CTest on Apple Silicon | PASS, 22/22; `lens-core-tests.log` |
| Final Lens C API using the external Sony fixture | PASS; `lens-core-api-final.log` |
| Lensfun-disabled C API | PASS, 1/1; `lens-off-tests.log` |
| macOS application, signing and bundled dependency closure | PASS; `lens-macos-build-final.log` |
| macOS settings, real RAW CPU/Metal/export and batch checks | PASS; `lens-macos-settings.log`, `lens-macos-render.log`, `lens-macos-batch.log` |
| iOS XCFramework device arm64 and simulator arm64/x86_64 | PASS, exported Lens API/resources/licenses/runtime closure verified; `lens-ios-framework.log` |
| iOS Debug application | PASS; `lens-ios-app.log` |
| iOS legacy/Unicode edit memory and frozen batch settings | PASS; `lens-ios-memory.log`, `lens-ios-batch.log` |
| iOS native real RAW, CPU/Force Metal and export harness | PASS; `lens-ios-native-final.log` |
| iPhone and iPad Lens UI tests | PASS; `lens-ios-ui-final.xcresult`, `lens-ipad-ui.xcresult` |
| Android arm64-v8a/x86_64 native builds, application/test APK, unit tests and lint | PASS, 59 unit tests; `lens-android-green.log` |
| Android real RAW Lens processing, compact Lens UI and nested license dialog | PASS, 3 instrumented tests; `lens-android-instrumentation.log` |
| Android manual-empty-selection regression | PASS, 1 instrumented test; `lens-android-sentinel-final.log` |
| Windows managed build, ABI/edit persistence and source-packaging checks | PASS; `lens-wpf-build.log`, `lens-windows-editing.log`, `lens-remote-tool-tests.log` |
| Windows native build, CTest and WPF real RAW integration | PASS, CTest 20/20 and 143 WPF checks; `windows-remote/20261013-123403/build.log` |
| Windows forced-rebuild Lens-specific integration | PASS, 11 checks including the latest manual-empty-selection assertion; `lens-windows-focused-final.log` |

Windows verification uses its dedicated build host and an isolated
`C:/RawLabBuild/lens-correction-development` workspace. The command is
`python3 RawLabWindows/build-remote.py --host <host> --identity <key> --known-hosts <file> --workspace C:/RawLabBuild/lens-correction-development --test --raw <external ARW>`.
The remote packaging excludes photos from the source archive; the explicit test
fixture is copied only into the private generated build area.

The final manual-empty-selection assertion is additionally checked by rebuilding
the WPF tests with `dotnet build --no-incremental -p:Platform=x64` and running
`RawLabWindows.Tests.dll --lens <repo> <RAW>`. The normal build script now also
forces a test rebuild, because preserved source-archive timestamps allowed an
incremental build to reuse the previous test assembly. This does not change
application rendering or the production binary's behavior.

Android instrumentation was run with explicit `adb -s emulator-5584` commands,
not a connected Gradle task. This feature's owned API 35 arm64 AVD is isolated
from other emulators and physical devices. iOS UI checks used owned iPhone 17 Pro
and iPad Pro 13-inch simulators on iOS 26.4. Portrait/landscape screenshots were
inspected; the landscape phone controls remain reachable by scrolling.

## Behavioral Evidence

The external Sony ILCE-7CM2/Tamron A071 RAW has a unique match and real distortion
and TCA calibration. Native checks confirm manual/automatic agreement, actual
pixel changes, crop retaining dimensions, CPU/platform-GPU parity, exact reset
to the disabled baseline and 16-bit PNG export. Manual mode without a selection
reports a skipped correction and never falls back to automatic matching.

Persistence regressions include missing Lens fields in old records, profile IDs
containing Unicode and delimiters, reset isolation and immutable batch snapshots.
Automatic batch settings retain the request, not a source image's resolved ID.
The C request v2 layout is unchanged. Optional Lensfun builds keep the exported
Lens API and reject enabled correction cleanly.

## Review and Regressions

Two independent read-only reviewers covered reachable rendering/configuration
paths, client state, persistence, ABI, caches, dependency packaging and licenses.
The confirmed findings were fixed and re-reviewed:

- iOS recipe preparation temporarily disabled Lens correction before automatic
  exposure. The final Lens configuration now follows recipe preparation. The
  real RAW automatic-exposure regression passes.
- Android's license dialog tried to open the new `licenses/lensfun` directory as
  a file. The focused test reproduced `FileNotFoundException: licenses/lensfun`
  before the fix; recursive leaf-file enumeration passes afterward.
- Static dependency license texts and notices were completed for the affected
  clients. GLib, PCRE2, proxy-libintl, Android libiconv and Windows TRE are covered
  alongside Lensfun and the database attribution.

No confirmed Must-fix or Should-fix remains in the reviewed code scope. The
original core/macOS cache fixes are retained. No GitHub approval or hosted CI
status is inferred from these local reviews.

## Limits

- Real calibration quality has been exercised with one Sony/Tamron pairing.
  Other profiles and subjective Lightroom equivalence are not certified.
- Mobile runtime checks used simulators/emulators, not physical hardware.
  iOS 18 runtime and Android x86_64 runtime were not exercised; their respective
  deployment build and ABI build checks do not imply runtime coverage.
- Android source dependency builds require a macOS/Linux POSIX build host.
  Windows-host Android dependency building is explicitly unsupported by the
  builder; this does not affect the native Windows application.
- Intel/macOS 15 runtime was not exercised. macOS uses the existing dependency
  prefix, while mobile/Windows source-build pinned static dependencies.
- Auto crop checks every RGB coordinate on the complete perimeter, not an
  interior proof for arbitrary nonmonotonic profiles.
- No release, notarization, merge or hosted exact-head CI was performed.
