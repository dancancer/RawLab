# Lens Correction on Native Clients

## Scope

All four native clients share the Lensfun C API. Distortion and lateral chromatic
aberration and profile vignetting are independent corrections, initially off.
The mobile workspace exposes all three switches; desktop adapters preserve and
render imported vignetting settings. Auto crop initially on only
takes effect when a requested calibration is applied; it preserves output size
and aspect ratio by narrowing the field of view. Purple/green defringe,
longitudinal chromatic aberration and additional embedded manufacturer lens
models are not implemented.

Automatic mode resolves each RAW from its camera, lens and focal length. It never
persists an automatically resolved profile, and never guesses between multiple
matches. Manual mode uses the searchable metadata catalog; an empty selection
uses an explicit invalid-profile sentinel rather than accidentally enabling auto.
Missing camera/focal/calibration information is displayed as a skipped correction.
Vignetting additionally requires aperture metadata and matching Lensfun calibration.
Unknown focus distance uses the Lensfun far-distance convention (1000 meters).
iOS and Android also support opt-in JPEG/display-input correction through
structured EXIF and per-photo focal-length/crop-factor overrides. Manual selection
cannot bypass missing focal/crop metadata. The native adapter sets the versioned
`sony2fuji_lens_metadata` before rendering and clears it between sources; the
[rendering contract](../../../lutools/docs/color-contract.md#display-referred-raster-input)
defines orientation and preview/export parity. Mac and Windows raster adapters
retain their previous unsupported-input behavior.

Each client saves the lens configuration with per-photo edits. Old records lacking
the field remain off. Lens reset is isolated; all reset also clears it. Batch jobs
freeze the requested configuration, so auto is re-matched per target. Neutral
comparison retains the same lens configuration and geometry. HSL, effects, recipes, exposure modes and existing
batch recovery behavior remain independent. Mobile focal/crop overrides belong to
the source photo and are not copied as another photo's metadata. Cross-kind
RAW/raster batch adaptation clears lens correction; same-kind rendering uses the
target's metadata and explicit settings.

The additive v2 configuration, profile and report APIs carry vignetting without
changing the original v1 C struct sizes or function signatures. A v1 setter clears
the vignetting extension. SDR edit records and recipes use optional `vignetting`;
HDR camera-development records use optional `lens_vignetting` and native flag 8.
Absent values default off. Adjustment transfer carries `geometry.lens.vignetting`.
RAW decode and white-balance-anchor cache identities include the new switch.

## Native Dependencies

macOS uses the existing target-prefix/pkg-config workflow plus a pinned Lensfun
source build. iOS, Android and Windows source-build static Lensfun 0.3.4,
GLib 2.84.4, PCRE2 10.44 and proxy-libintl for each target. Windows also links the
upstream bundled TRE regular-expression library. Android API 26 uses GNU libiconv
1.18 and libcharset; iOS uses its system iconv. JIT is disabled.

`lutools/cmake/lens-dependencies.json` contains source URLs and SHA256 pins.
`build-lens-dependencies.py` uses Python 3.11+, isolated Meson/Ninja tools, target
compilers and only the GLib libraries used by Lensfun. The GLib pipe2 declaration
probe is adjusted to respect iOS 18 availability when building with SDK 27.
`RAWLAB_LENS_SOURCE_CACHE` optionally supplies checksum-verified archives. Nothing
is downloaded by the application at runtime. Android builds additionally require
a POSIX shell and make on the build host for GNU libiconv.

iOS framework resources contain `Lensfun` and `Licenses/lensfun`; the application
opens the resource in `Bundle.main/Frameworks/sony2fuji.framework`. Android packages
the XML assets and copies them into a versioned private directory. Windows copies
them into the application output `Lensfun` directory. Mac uses bundle resources.

## Licenses and Validation

The offline, unmodified DB1 snapshot is dated 2026-10-12. Lensfun code is
LGPL-3.0-or-later and the database is CC BY-SA 3.0. GLib, proxy-libintl and libiconv
license texts accompany each relevant client; PCRE2 and TRE attribution is retained.
See `docs/reference/licensing.md` and the source manifest for the corresponding sources and
rebuild instructions. Generated dependencies, binaries and personal RAW fixtures
are excluded from commits and distribution source archives.

Focused regressions cover native ABI layout, missing-field migration, delimiter
and Unicode profile IDs, reset isolation, immutable batch settings, real RAW
automatic/manual matching, crop dimensions, neutral comparison, export and
CPU/platform-GPU parity. Native/UI gates are separate from managed compilation.
The dated verification record lists actual results and platform limitations.
