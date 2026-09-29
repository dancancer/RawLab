# App Strength and EXIF Verification

## Changes

- iOS uses `RawSettings.lutStrengthRange` (0...2) in its slider and clamps both RAW and raster processing to that same range. Defaults and reset remain 1 (100%). The Mac client already uses this range.
- `Shared/ExportMetadata.swift` is compiled into both app clients. All iOS JPEG export callers pass the source file URL. The Mac engine attaches metadata after the common CPU/Metal file-output path.
- Standard ImageIO-readable capture EXIF, camera/lens and GPS are retained. Output dimensions, orientation, software and sRGB color-space tags describe the rendered file. RAW pixels are already upright; unrotated iOS raster buffers retain their source orientation.
- Opaque MakerNotes, sensor CFA descriptions, stale image-coordinate tags and old thumbnails are not copied. Source files remain unchanged. Files without shooting EXIF still export normally.
- Scope is Mac JPEG/16-bit PNG and iOS JPEG app exports. No new Android application or CLI strength option was added; portable CLI/C API file encoding is unchanged.

## Regressions Caught

1. The new iOS range assertion failed at the old 100% upper bound. The actual iOS RAW and buffer paths now produce different output at 100% and 200%, proving the Swift bridge no longer clips the setting to 1.
2. A real Mac RAW-to-JPEG export initially failed to retain `DateTimeOriginal`.
3. Recreating ImageIO metadata from ordinary numeric properties truncated EXIF rationals: 0.008 became 0 and 2.8 became 2. JPEG attachment now copies the original typed tags before replacing geometry fields.
4. `CGImageDestinationCopyImageSource` added only XMP to the core encoder's PNG without an existing eXIf chunk. ImageIO's property reader synthesized EXIF from that XMP, so a second test checks the actual PNG chunk structure. PNG export now uses lossless ImageIO encoding with explicit EXIF properties, produces standard eXIf, and preserves 16-bit decoded samples.

## Passed Checks

- `bash RawLab/tests/presentation.sh`: range, default/reset, clamping and existing presentation assertions.
- `bash RawLabMac/tests/presentation.sh`: existing Mac strength and presentation assertions.
- `bash RawLabMac/tests/export-metadata.sh`: timestamp, rational exposure/aperture, ISO, camera/lens, GPS, orientation, dimensions, sRGB tags, missing shooting metadata, source immutability, JPEG/PNG pixel equality and 16-bit preservation. Includes actual Sony RAW JPEG/PNG exports and a standard PNG eXIf check.
- `bash RawLab/tests/processor-export.sh /tmp/rawlab-exif-build/Build/Products/Debug-iphonesimulator/RawLab.app`: compiled the actual iOS processor, settings and shared export helper against the app's embedded framework and executed on the iPhone 17e simulator (iOS 26.4). Both RAW and raster strength 200% paths and their JPEG EXIF were validated.
- `bash RawLabMac/tests/adjustments.sh`: all 8 RAW fixtures passed after the final PNG change, including full-resolution 16-bit export dimensions and preview/export sample parity.
- `bash RawLabMac/build.sh`: built and passed bundled-dependency/signature verification.
- iOS Debug simulator build and unsigned Release device build passed with the final shared source. Existing missing AccentColor notice was not changed.
- Project plist validation and `git diff --check` passed.

## Local Artifacts and Limits

- Mac metadata fixtures: `/tmp/rawlab-export-metadata.1785f7`.
- Mac final adjustment exports: `/tmp/rawlab-adjustments.rA5w0k`.
- iOS simulator build: `/tmp/rawlab-exif-build/Build/Products/Debug-iphonesimulator/RawLab.app`.
- Unsigned iOS device build: `/tmp/rawlab-exif-device/Build/Products/Release-iphoneos/RawLab.app`.
- Mac app: `build/RawLab Mac.app`.

No physical iOS device run, new UI screenshot audit, or unsupported-camera calibration claim is included. Photos providers can strip metadata before the app receives a file; the app preserves fields available in its cached original. The iOS project remains its existing iPhone-targeted client, not a new native iPad layout. No commit, distribution upload or replacement of `/Applications/RawLab Mac.app` was performed.
