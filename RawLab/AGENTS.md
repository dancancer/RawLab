# RawLab iOS

These instructions apply to `RawLab/`. Follow the root [AGENTS.md](../AGENTS.md)
for Gitflow, authorization, shared resources and cleanup. Commands below run from
the repository root, not from the `RawLab/` subdirectory.

## Project Structure

- SwiftUI entry: `RawLab/RawLab/App/RawLabApp.swift`; editor UI:
  `RawLab/RawLab/UI/Editor/ContentView.swift`.
- Processing integration: `RawLab/RawLab/Core/RawProcessing/`. The shared C ABI
  and native rendering rules live in [lutools](../lutools/AGENTS.md) and the
  [color contract](../lutools/docs/color-contract.md).
- App resources: `RawLab/RawLab/Resources/`, including `Assets.xcassets`,
  `Info.plist` and localized strings. Shared looks and recipes live in
  `Shared/BundledLooks/` and `Shared/master-recipes.json`.
- Xcode project: `RawLab/RawLab.xcodeproj`; the shared `RawLab` scheme includes
  the `RawLabUITests` target. UI test sources are in `RawLab/RawLabUITests/`.
- `RawLab/tests/` contains standalone Swift/C harnesses and their shell runners.
  They are not all executed by the Xcode scheme.

## Build And Test

Inspect schemes with `xcodebuild -list -project RawLab/RawLab.xcodeproj`.
The app links `lutools/build-ios/sony2fuji.xcframework`; use the existing
[iOS integration instructions](../lutools/platform/ios/README.md) when native
inputs changed or the framework is missing:

```bash
bash lutools/platform/ios/build-framework.sh
bash lutools/platform/ios/verify-framework.sh lutools/build-ios/sony2fuji.xcframework
```

The CI compilation command does not assume an installed simulator device:

```bash
xcodebuild -project RawLab/RawLab.xcodeproj -scheme RawLab -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/ci-ios ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

`build-for-testing` compiles the app and tests; it does not execute UI tests.
Choose affected checks from `RawLab/tests/` and read each runner's prerequisites.
Some run with the macOS SDK; others require a simulator app, an `.xctestrun`
file or explicit environment variables.

For Editor UI workflows, `bash RawLab/tests/editor-ui.sh` requires
`IOS_SIMULATOR_UDID` to identify a fresh dedicated simulator whose Photos library
has the named fixture required by that script. Do not point it at a daily-use
simulator or invent an available device. Specialized UI harnesses can be skipped
by the shared scheme unless their runner configures the harness.
Report compilation, executed tests, skipped coverage and missing fixtures separately.

## Coding And Safety

- Follow existing Swift/SwiftUI conventions: four-space indentation, UpperCamelCase
  types and lowerCamelCase members. Keep view responsibilities clear without
  imposing arbitrary line-count or folder-size limits.
- Preserve cross-platform parameters, persistence and rendering behavior; check
  affected clients when changing the shared C ABI.
- RAW fixtures are external inputs. Use `RAWLAB_TEST_RAW` where supported; do not
  commit personal photos, credentials, screenshots or generated build outputs.
- Photo usage descriptions are in `RawLab/RawLab/Resources/Info.plist` and localized
  `InfoPlist.strings`; keep them aligned with import/export behavior.
- Keep bundled assets intentional and document size or compatibility changes.
- Use the root Gitflow and per-action authorization rules. PRs should describe
  the change, checks actually run, risks and unverified platforms; include relevant
  UI evidence without committing temporary screenshots.
