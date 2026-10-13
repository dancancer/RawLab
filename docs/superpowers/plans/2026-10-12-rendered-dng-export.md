# Rendered DNG Export Implementation Plan

**Goal:** Add baked rendered DNG export to Mac single and batch workflows, verify
the actual files in Lightroom, then reuse the encoder in the other native clients.

**Approved design:** Shared native encoder consumes FINAL display-sRGB RGB after
all adjustments and resizing. DNG 1.4 stores inverse-sRGB float32 RGB as
output-referred LinearRaw, with a virtual D50 profile and neutral Adobe settings.
Existing JPEG/PNG behavior, original RAWs and C request layouts remain unchanged.
The experiment and Lightroom validation establish the initial encoding contract.

**Workspace:** Independent `feature/rendered-dng-export` worktree based on
refreshed `origin/development`. The approved delivery is a focused commit, push
and PR to `development`, without merge, release or unrelated changes.

## Task 1: Shared Encoder

- [x] Add failing synthetic encoder tests, independently reading TIFF tags and
  linear RGB pixels; test nonfinite/invalid input and write failures.
- [x] Implement `saveRenderedDNG(const ImageData&, const std::string&)` in
  `lutools/src/core/rendered_dng.h` and `.cpp`, using libtiff for structured TIFF
  serialization rather than implementing a new TIFF container.
- [x] Add a pinned portable TIFF dependency in CMake, preserving platform builds.
- [x] Append `SONY2FUJI_OUTPUT_DNG = 4`; leave existing enum values and request
  layout unchanged. Wire FILE validation and ImageEncoder dispatch only.
- [x] Verify synthetic DNG with Adobe SDK validator and roundtrip tests.

## Task 2: Mac Single And Batch

- [x] Add failing format/extension and legacy JPEG/PNG journal tests.
- [x] Add an explicit JPEG/PNG/rendered-DNG format model; NSSavePanel and both
  export menus expose DNG. Engine maps `.dng` to the native format, never JPEG.
- [x] Keep final settings/LUT snapshots and native/final long-edge processing.
  DNG bypasses ImageIO raster metadata rewriting.
- [x] Add batch format persistence while decoding legacy `png` journals as before;
  DNG temporary/published filenames and recovery use the correct suffix.
- [x] Run `bash RawLabMac/tests/batch-export.sh`, affected Swift checks,
  `bash RawLabMac/build.sh`, and `ctest --test-dir lutools/build-macos
  --output-on-failure` with available real RAW fixtures.
- [x] Export real RAW with nonzero adjustments to PNG and DNG through the native
  Mac engine and exercise single/batch UI. Lightroom Develop plus unresized,
  unsharpened 16-bit sRGB TIFF export must match the PNG within one RGB8 step.

## Task 3: Other Clients

- [x] After Mac acceptance, add equivalent format/filename dispatch to Windows
  and Android single/batch flows; retain backward-compatible batch persistence.
- [x] Add iOS rendered DNG file export, retaining JPEG photo-library behavior;
  use FINAL native file rendering for RAW and equivalent raster processing.
- [x] Avoid JPEG/PNG metadata rewriters on DNG; use correct DNG MIME/UTType.
- [x] Build and run affected platform checks where tooling exists; record missing
  devices/toolchains and do not claim those platforms runtime-verified.

## Verification Boundaries

The output preserves appearance, not sensor RAW latitude or separately reversible
RawLab controls. Lightroom import presets or subsequent edits can change it.
Photos, generated DNG/TIFF/PNG, screenshots and build products remain ignored.

Current evidence and platform limitations are recorded in
`docs/verification-rendered-dng-export.md`. Storage regressions additionally
verify atomic replacement, temporary-file cleanup and distinct output IO status;
the C ABI rejects DNG preview requests. The CLI also maps DNG extensions to the
shared FINAL encoder.
