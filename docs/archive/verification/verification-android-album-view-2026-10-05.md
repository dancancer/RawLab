# Android Album View Verification

## Scope

- The in-app RAW album picker supports square thumbnails and original aspect ratios.
- Original ratios and three columns are the defaults; the view menu offers one through six columns.
- Square mode uses an aligned `LazyVerticalGrid`; original mode uses `LazyVerticalStaggeredGrid`.
- Column/mode changes retain the first visible photo rather than reusing a pixel offset that could exceed the smaller tile.
- Album filtering, editor navigation, activity recreation, refresh and permission behavior are preserved.
- No RAW rendering, LUT, export, permission or dependency changes are part of this task.

## Implementation Checks

MediaStore width/height and orientation define the initial display ratio; 90/270-degree rotations swap dimensions.
When dimensions are unavailable, the decoded thumbnail supplies the ratio. Original mode uses `ContentScale.Fit`;
square mode uses `ContentScale.Crop`. File labels retain two lines and ellipsis, including the six-column view.
Android 10+ requests thumbnails sized for the tile, capped at 1024 pixels. Android 8-9 retains `MINI_KIND`
and applies the recorded orientation; no full RAW decode is added to album browsing.

Observed red regressions before the fixes:

- A 2:1 photo was displayed in a 1:1 frame.
- The view/column menu did not exist.
- Using staggered layout for square mode assigned the seventh item to the third column because of pixel-rounded lane heights.
- Keeping a large old scroll offset while changing from one to six columns scrolled the partly visible anchor photo out of view.

## Automated Results

Run from `RawLabAndroid/` with JDK 21 and the installed Android SDK:

```sh
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug \
  :app:connectedDebugAndroidTest \
  '-Pandroid.testInstrumentationRunnerArguments.class=com.rawlab.android.AlbumScreenTest,com.rawlab.android.PhotoStorageTest,com.rawlab.android.AlbumThumbnailTest'
```

- JVM tests: 19 passed, zero failures/errors/skips.
- Instrumentation: 16 passed, zero failures/errors/skips on the API 35 arm64 emulator.
- APK build and lint succeeded. Lint retains existing dependency-update, backup, unused-resource and style notices; no new error was introduced.
- Coverage includes portrait/landscape ratios, EXIF rotation, missing-dimension fallback, mode switching, one/six-column geometry,
  partial-scroll anchoring, selected mode/columns after editor return/recreation, existing album scroll restoration and storage regressions.

## Native UI Inspection

Real Sony ARW and DJI DNG files were copied into a temporary album on a read-only emulator instance.
Source RAW files were not changed. Native screenshots were inspected in one batched pass:

- Phone: original three columns, square three columns, original one column, square six columns, view menu.
- Dark theme with font scale 1.3: phone six-column mode and menu.
- Tablet-sized display: 1600x2560 at 240 dpi, both modes at six columns with dark theme and font scale 1.3.

Screenshots and MediaStore dimension evidence are in ignored `output/android-album-view/`.
The menu controls remained accessible; filename text stayed inside its tiles, and square rows remained aligned.
Original-mode photos were not cropped by the UI. Preview detail remains limited by the thumbnail supplied by MediaStore.

This is emulator verification, not a physical-device or API 26-28 runtime claim. No release was published.
The debug APK is `RawLabAndroid/app/build/outputs/apk/debug/app-debug.apk`.
