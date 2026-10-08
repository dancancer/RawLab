# iOS Design Alignment Verification

## Scope

Branch: `codex/ios-macos-design`, based on `main` at `9de1885`.

- Native dark editor with a yellow selected-tool accent, Chinese controls, and a photo-led canvas.
- One bottom tool strip for film, strength, and existing adjustments; signed progress rings and individual reset.
- Collapsible adjustment panel and floating luminance histogram. The existing before/after semantics are unchanged.
- ETERNA and ETERNA BB reuse the current Mac artwork directly through Xcode resource references. WDR keeps a generic icon. No LUT files were added or replaced.
- Portrait, compact-height landscape, and Dynamic Type layouts. The target remains iPhone-only.
- No shared rendering source or numeric processing contract changes. No RGB histogram, desktop file tree, exposure-baseline selector, or as-shot white-balance migration.

## Checks

Passed:

- 21 model assertions for signed/asymmetric progress, strength baseline, isolated reset, and film name/artwork mapping.
- Debug simulator build and unsigned Release device build.
- Three XCUITest cases on iPhone 17e, iOS 26.4: empty state/panel visibility, accessibility XXXL text, and the photo editing workflow.
- The workflow covers Photos import, exposure edit/reset, ETERNA selection, actual artwork pixels, histogram expansion, before/after state, collapse/restore, landscape home-indicator clearance, and successful saving to Photos.
- `git diff --check` and project plist validation.

The editor deliberately uses a dark appearance even when the system is light, as on Mac. Visual checks used native simulator captures, not browser mockups. The workflow imported a simulator-library raster photo; this is not new RAW/color-calibration coverage or physical-device verification. XXXL controls remain available through the scrollable dock.

Existing build diagnostics: the asset catalog has no `AccentColor` entry; Xcode also emitted a debugger-version lookup diagnostic during UI tests. Neither failed the builds or tests. The UI explicitly sets its yellow tint.

## Reproduction

Model checks (Command Line Tools can run these independently of Xcode):

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools bash RawLab/tests/presentation.sh
```

UI checks require a bootable iPhone simulator, an available photo in its Photos library, the current iOS core framework, and Photos add permission. Substitute an available device ID:

```sh
xcrun simctl addmedia "$DEVICE" /path/to/photo.jpg
xcrun simctl privacy "$DEVICE" grant photos-add com.example.RawLab
xcodebuild -project RawLab/RawLab.xcodeproj -scheme RawLab \
  -destination "platform=iOS Simulator,id=$DEVICE" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

Final local results: `/tmp/rawlab-ios-current-core-tests.xcresult` (3 passed, 0 failed), `/tmp/rawlab-ios-device-build.log` (Release device build, exit 0). Screenshots are in ignored `output/ios-design/`, including `photo-film-portrait.png`, `photo-film-landscape.png`, `photo-adjustment-portrait.png`, and `large-text-portrait.png`.

## Resolved Verification Failures

1. SwiftUI named-image lookup did not find the loose PNG resources despite successful bundling. A screenshot-pixel assertion reproduced the blank ETERNA artwork before the fix. Loading the bundled file as `UIImage` fixes it; the pixel assertion now passes.
2. Compact landscape film items extended too close to the home indicator. Smaller compact artwork and reduced dock spacing keep the full item inside the safe area; the UI test asserts its frame.
3. The existing local `sony2fuji.xcframework` was stale. A direct 2x2-buffer C API probe returned `NATIVE: unsupported (2)` and `EXACT: ok (0)` with that binary. Rebuilding unchanged current-main core sources returned `ok (0)` for both, and the unchanged native-size export then passed the UI test. No lower-resolution fallback was introduced.

The framework was rebuilt for device arm64 and simulator arm64/x86_64 using existing platform-specific LibRaw dependencies, then repackaged locally. The previous framework is preserved at `lutools/build-ios/sony2fuji.xcframework.pre-ios-design-20260928`. Generated frameworks remain ignored. See `lutools/platform/ios/README.md` for build prerequisites; a fresh checkout must build its own current framework.

## Follow-up: Complete Built-in LUT Set

The user's follow-up expands the original UI-only scope to include the full photo LUT set. The iOS bundle now references the repository's 65-grid ACROS, ASTIA, CLASSIC CHROME, CLASSIC Neg., ETERNA, ETERNA BB, PRO Neg.Std, PROVIA, REALA ACE, Velvia, and WDR files. Ten corresponding film artwork resources are shared with Mac. Mac's packager excludes WDR; iOS retains it as an additional display transform.

The old 33-grid resources are no longer part of the application target, avoiding duplicate names. The FLog2-to-FLog2-709 intermediate transform is not offered as a photo effect. Original source resources and shared processing code are unchanged.

- Model coverage increases to 32 assertions, including every 65-grid film name/artwork mapping. The new ACROS fixture failed before the parser change and passes afterward.
- `RawLab/tests/bundled-luts.sh <simulator-app-path> <device-id>` executes the packaged C API against every actual bundled LUT. All 11 produce valid native-size RGBA output from a synthetic RGB fixture. The previous bundle fails the inventory check.
- The local uncompressed Debug app increases from approximately 13 MiB to 109 MiB, primarily the 65-grid CUBE files and additional artwork. This is not an IPA download-size measurement.
- The simulator test suite adds inventory coverage and scrolls the longer chooser before selecting ETERNA. Final result: `/tmp/rawlab-ios-all-luts-final.xcresult`, 4 passed and 0 failed, including import/edit/film selection/export. The scrolling helper uses bounded drags rather than querying hittability of offscreen elements, which raised an XCTest automation error in the first run.
- Updated simulator Debug and unsigned device Release builds passed. The device build log is `/tmp/rawlab-ios-all-luts-device.log`; final screenshots use the `all-luts-` prefix under `output/ios-design/`.
