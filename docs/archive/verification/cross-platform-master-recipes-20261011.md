# Cross-Platform Master Recipes Verification

Baseline: `development` commit `3c222c83467d4a559343ffe5e13869a27f6d9d1a`.
Changes are local on `feature/master-recipe-hsl`; no commit, push or release was performed.

## Behavior

- All four clients load the same fourteen calibrated definitions from `Shared/master-recipes.json`. Existing LUTs and artwork are reused, not regenerated or duplicated in source.
- Applying a recipe overwrites exposure, shadows, highlights, contrast, saturation, tint and all 24 HSL values, and resets strength to 100%.
- Strength scales the currently editable six controls, HSL and LUT together. Fractional HSL values are preserved and clamped to [-100,100]. Other controls remain independent.
- White-balance tint is relative to the actual target RAW's as-shot calibration. Cold processing and frozen batch replay resolve each target independently; a custom temperature is preserved.
- Recipe selection and ordinary film selection are mutually exclusive. Leaving a recipe preserves the visible controls and converts its tint offset to an absolute independent setting.
- Edit persistence and frozen jobs retain recipe identity, manually edited controls, HSL and strength; replay does not reinject catalog defaults.
- iOS keeps legacy native parameter storage. Only presentation converts to percentage controls and corrects highlight direction. Contrast/saturation/shadows/highlights/S-curve use [-100,100], sharpening [0,200], exposure steps 0.05 EV and temperature steps 10 K.
- Mobile film/recipe lists are directly draggable without arrow buttons. Desktop lists retain overflow buttons, endpoint disabling and hide-when-fitted behavior.

## Checks

| Platform | Check | Result |
| --- | --- | --- |
| macOS | Settings/catalog regressions; app build and bundle dependency checks | PASS |
| iOS | Presentation, edit-memory and batch-export shell suites | PASS |
| iOS | Actual Sony RAW, fourteen recipes x four strengths, explicit CPU reference, Force Metal, zero neutral and frozen final replay | PASS |
| iOS | Latest drag-only picker UI (1/1) and final unsigned device Release build | PASS |
| Android | Unit tests, lint, debug app and instrumentation APK builds | PASS |
| Android | Actual DNG, fourteen recipes x four strengths, explicit CPU reference, Auto/CPU and zero neutral | PASS |
| Android | Latest drag-only picker UI (1/1); all nine Sony native methods have passing evidence | PASS individually; class run interrupted |
| Windows | Portable editing tests and WPF cross-compilation | PASS |
| Windows | Native host build, CTest (18/18) and existing WPF/native regressions | PASS |
| Windows | Fourteen recipes x four strengths on actual RAW; final WPF checks (90), clean self-contained publish and ZIP | PASS |

Source RAWs were not modified. Reference photographs and generated build artifacts are not tracked.

## Evidence And Limits

- Initial model/catalog regressions failed before implementation, then passed after the corresponding changes.
- Android's first UI attempts ran behind a sleeping secure lock screen; they are not valid application UI results. After the user unlocked the device, the final Gradle and direct instrumentation UI runs passed; the actual Compose picker screenshot was captured, not the launcher.
- The initial Android existing-native-suite attempt used a DNG without the Sony-specific `LensModel` assertion fixture. It is not counted as passing; the final run uses the actual Sony RAW.
- The Android complete native class was interrupted around 6/9 by `ZuiMemoryCleaner_Recents` (confirmed in ActivityManager log), not a same-time native FATAL/OOM. Four methods had passed before interruption; the remaining five passed separately. This is nine passing method results, not an uninterrupted 9/9 class run.
- The iOS standalone simulator processor test initially used a relative framework rpath and failed to load the framework. The same test passed with the built app at an absolute path.
- Creative recipe LUT Auto checks exercise supported rendering/fallback; they do not claim forced GPU execution for every LUT. iOS separately exercised Force Metal as required by its renderer.
- iOS device output is an unsigned Release `.app`, not a signed installable IPA. Simulator UI verification does not establish physical iOS device, accessibility-size or iPad UI coverage.
- Recipe matrices use RAWs with valid camera WB calibration. Unsupported/uncalibrated RAW white balance is not established by this verification.
- iOS final bundle catalog, fourteen LUTs and fourteen artworks are byte-identical to source (29/29).
- Android final APK catalog, fourteen LUTs and fourteen artworks match source (29/29); fixture assets are packaged only in the instrumentation APK, not the client APK.
- Windows final ZIP catalog, fourteen LUTs and fourteen artworks are byte-identical to source (29/29), with native/runtime dependencies, ExifTool and licenses included. No repeated directory components remain in the clean package.
- Windows initial overflow UI regression used an unshown window (zero geometry); showing the window fixed that test precondition. The host then limited a requested 3000px window to 1044px, so hide-when-fitted coverage uses a temporarily shortened UI list rather than claiming unsupported wide-window coverage. Both film and recipe overflow/scroll/hide checks pass in a real WPF window.
- Evidence lives under ignored `build/master-optimization/`, `build/ios-parity-ui/`, `build/windows-remote/` and Android Gradle reports.

## Artifacts

- iOS unsigned device Release app: `build/ios-parity-device/Build/Products/Release-iphoneos/RawLab.app`.
- iOS latest UI result: `build/ios-parity-ui/RecipeMobileUITests.xcresult` (1 passed, 0 failed).
- iOS latest picker/HSL screenshots: `build/master-optimization/ios-parity-mobile-ui/`.
- Android debug APK: `RawLabAndroid/app/build/outputs/apk/debug/app-debug.apk`.
- Android final UI reports, original system-interruption log and isolated native regressions: `RawLabAndroid/app/build/verification/`.
- Android actual picker screenshot: `RawLabAndroid/app/build/verification/master-recipes-picker.png`.
- Windows final ZIP: `build/windows-remote/20261011-230934/RawLab-Windows-final.zip`.
- Windows final desktop UI evidence: `build/windows-remote/20261011-230934/ui-only-v5.log` (90 checks passed).
- Windows final publish/package evidence: `build/windows-remote/20261011-230934/final-publish-v3.log`.
