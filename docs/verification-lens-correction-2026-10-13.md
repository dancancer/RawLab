# Lensfun Lens Correction Verification

This is the historical core/macOS verification on the original feature baseline.
For the development forward-port and iOS/Android/Windows results, see
[the cross-platform verification](verification-lens-correction-platforms-2026-10-13.md).

## Scope

Implemented in the shared C++ core and macOS client on `feat/lens-correction`,
in an independent worktree based on `b31827cf9c4a3237eaebf3c3d4f8f6fa58422f13`.
The original checkout's uncommitted viewport/denoise changes were not included
or reverted. No release or original RAW modification was performed. Commit/push
are a separate delivery phase following the review below.

- Profile-based distortion and lateral chromatic aberration (TCA), independently enabled and default off.
- Per-input automatic matching, explicit ambiguity/no-calibration states and searchable manual selection.
- Automatic inscribed cropping by zoom, retaining output dimensions and aspect ratio.
- Versioned C session configuration/catalog/report APIs, unchanged request v2 layout and optional Lensfun builds.
- Optional persisted macOS settings, lens-group reset and frozen batch settings.
- Offline DB1 snapshot and recursive dependency/license packaging.

Defringe, axial CA, profile vignetting and perspective correction are not included.
Lensfun profiles do not establish pixel equivalence with Lightroom.

## Environment

Apple Silicon, macOS 27.0 build 26A428; arm64 application targeting macOS 26.0,
using the Command Line Tools macOS 26.5 SDK. Existing LibRaw/OpenCV/wavelib/DNG
SDK dependencies were reused via `RAWLAB_DEPENDENCY_PREFIX`; Lensfun was built
in the worktree's own prefix. Lensfun 0.3.4 uses the pinned source archive and
the unmodified 2026-10-12 DB1 snapshot recorded in
`lutools/third_party/lensfun/README.md`.

## Automated Results

| Check | Result |
| --- | --- |
| `bash RawLabMac/build.sh` with the dependency prefix above | PASS: Swift/C++ build, JXL smoke checks, ad-hoc signing and bundle closure |
| `ctest --test-dir lutools/build-macos --output-on-failure` | PASS: 22/22, including real RAW, DNG/JXL, color, CPU/GPU and denoise regressions |
| Lensfun-off CPU build; `ctest --test-dir lutools/build-lens-off -R '^lens_api$' --output-on-failure` | PASS: retained C symbols, disabled settings, enabled-feature rejection and buffer isolation |
| `bash RawLabMac/tests/lens-settings.sh` | PASS: optional/legacy JSON, reset, automatic/manual settings and manual-no-selection sentinel |
| `bash RawLabMac/tests/lens-render.sh /path/to/DSC06251.ARW` | PASS: matching, cache isolation, preview/native CPU/Metal comparison, JPEG and 16-bit PNG |
| `bash RawLabMac/tests/edit-memory.sh` | PASS: manual profile settings persist through edit storage |
| `bash RawLabMac/tests/batch-export.sh` | PASS: lens settings remain frozen when live settings change |
| `bash RawLabMac/tests/presentation.sh` | PASS: existing bottom-dock/presentation regressions |
| Owned source/docs staged diff check | PASS; verbatim upstream README/license files retain their original trailing whitespace |

Synthetic profiles cover exact matching, ambiguity, unknown-camera full catalog,
manual selection with valid crop metadata, rejection without sensor information,
missing requested calibration, combined channel coordinates, all-pixel border
coverage, invalid sampling coordinates, four-channel distortion without TCA,
embedded Stage3 skipping and exact disabled identity. Review regressions first
failed for the unknown-camera catalog and disabled inspection status, then
passed after the fixes. The two findings received a narrow read-only re-review.

## Real RAW Results

Read-only fixture: Sony ILCE-7CM2, `DSC06251.ARW`, portrait orientation,
Tamron `E 28-200mm F2.8-5.6 A071` at 76 mm. The compatible catalog contains
181 profiles and one automatic match with both distortion and TCA calibration.

- Automatic and manually selected profile produce identical corrected pixels.
- Correction changes the baseline pixels; disabling it restores exact baseline pixels with no stale cache/session state.
- Auto crop retains dimensions/aspect ratio and the profile reports applied distortion and TCA.
- Preview and native CPU/Metal output have maximum channel difference `1/255`; the configured regression tolerance is `2/255`.
- Interactive rendering can reuse the exact corrected cache.
- JPEG and actual 16-bit PNG export use native corrected geometry.

## Pre-Commit Review Regressions

The 2026-10-13 Dual review and main-thread reconciliation found two cache defects
and verified their fixes before delivery. See
`reviews/self-lens-correction-20261013-1018.md` for the review scope.

- RAW -> BUFFER -> identical RAW: the new C API regression first failed because the RAW cache hit retained the BUFFER report. The RAW report now lives with its cache and is restored on both hit and miss; the regression passes with Lensfun enabled and disabled.
- Preview-matched exposure + temperature WB after lens-setting changes: before the fix, the real fixture returned history EV `2.08996319770813` versus fresh-session EV `2.1591854095458984`, a difference of about 0.069 EV. The exposure anchor now includes the lens configuration/database identity. History and fresh sessions have identical EV and pixels, both without crop (`2.1591854095458984`) and with crop (`2.0920565128326416`).
- The two fixes received a focused independent counter-review. A proposed mirror-coordinate issue was disproved; correct orientation handling was left unchanged.

## Native UI

The first native inspection used an isolated copy under ignored `build/`, not
the original RAW. Automatic mode, both correction switches and crop reporting
were exercised; the panel reported both corrections and about 3% cropping.
Manual mode with no selection correctly avoided an automatic fallback.

The inspection found an unavailable SF Symbol, a wrapped segmented-picker label
and a list-row selection problem. The symbol was replaced with `viewfinder`,
the picker label hidden, and the final chooser uses full-width native buttons in
a lazy scroll stack. The native List wrapper exposed rows rather than actionable
buttons and did not apply the selection on click; changing only the row hit shape
did not resolve it. Keyboard selection through the intermediate List was
confirmed, but that intermediate implementation is not retained.

After manual unlock, the final application was rebuilt and native inspection
completed on 2026-10-13:

- Searching `28-200` exposes the matching Tamron as an actionable button. Clicking it closes the chooser, sets manual mode and reports both applied corrections with about 3% cropping.
- Disabling TCA alone leaves distortion applied; disabling distortion as well reports correction off and disables the crop control.
- Lens-group reset clears manual selection, restores automatic mode and disables both corrections without changing the selected film or exposure.
- Re-enabling both corrections in automatic mode reports a unique match and the same approximately 3% crop.
- The lens symbol, segmented labels, profile name and status fit in the inspected wide and 1320-by-850-point layouts without overlapping.

The final UI check used a generated `RawLab Lens Check.app` copy with a unique
bundle identifier because the user's original RawLab instance remained running.
Its executable/resources are from the final build; only generated bundle
name/identifier metadata differs. The original application and original RAW
were not modified. The generated app and fixture remain under ignored `build/`.

## Limits

- Only one real camera/lens pairing has been checked for correction; subjective calibration quality and other lenses remain unverified.
- Intel/macOS 15 builds and runtime are not verified for this feature. GLib and its dependency closure must support the requested architecture/minimum OS.
- iOS, Android and Windows interfaces were not changed or built. Their existing requests remain compatible; Lensfun is optional in the core.
- Automatic crop checks the complete perimeter for every RGB channel, not a mathematical interior proof for arbitrary nonmonotonic profiles.
- JXL DNG correction is conservatively skipped only when successful unpack reports actual SDK Stage3 processing. Other manufacturer-specific embedded lens models are not implemented.
- The application is locally ad-hoc signed, not notarized or published.
