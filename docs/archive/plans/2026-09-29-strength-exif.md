# Strength and EXIF Implementation Plan

**Goal:** Match the Mac 0-200% film-strength range in the other existing app client, retaining 100% defaults, and preserve shooting metadata in Mac and iOS photo exports.

**Architecture:** Keep rendering unchanged. Give the iOS settings model one strength range used by the slider and both processor entry points. Use a shared Swift ImageIO export helper for iOS JPEG encoding, metadata-only copying for Mac JPEG, and lossless PNG encoding with standard eXIf. Retain shooting EXIF, camera/lens and GPS; replace dimensions, orientation and color-space declarations to match output pixels. Do not copy RAW-specific metadata, MakerNotes or old thumbnails.

**Scope:** Existing Mac and iOS app exports. Android has no app implementation in this repository. The CLI has no adjustable-strength UI and stays at its existing 100% default; adding CLI options and portable CLI metadata is not part of this app change. Preserve the dirty iOS worktree; do not publish or commit.

## Execution

- [x] Reproduce iOS range failure in `RawLab/tests/EditorPresentationTests.swift` and missing EXIF through a real `RenderEngine` JPEG export.
- [x] Add `RawSettings.lutStrengthRange` and `clampedLUTStrength`; use them in `AdjustmentKind` and both `Sony2FujiProcessor` paths.
- [x] Implement `Shared/ExportMetadata.swift`: capture properties from the source URL, normalize rendered geometry, encode JPEG and preserve output pixels when adding metadata. Pass source URLs through all iOS export callers. Add the shared source to both builds and relevant test runners.
- [x] Test timestamp, camera/lens, exposure, ISO, GPS, orientation, dimensions, source immutability, missing metadata, JPEG pixels and 16-bit PNG pixels. Exercise the actual Mac export and iOS encoder, not only dictionary helpers.
- [x] Run model/export tests, Mac build, and available iOS simulator/device builds. Record checks and platform limitations without claiming CLI/Android metadata support.
