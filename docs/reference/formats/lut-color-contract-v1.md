# Native CUBE/VLT color contracts

RawLab converts its input to the LUT author's documented input, evaluates the
original table, and converts the documented output to display-sRGB. It never
infers colors from a filename, camera name, `TITLE` or `#LUMIXPHOTOSTYLE`. XMP
execution is outside this format. Existing legacy Fuji/sRGB files retain their
released interpretation; that compatibility does not certify camera appearance.

## Contract and evidence

One UTF-8 `#RawLabColorContract:` comment contains a single-line JSON object:

```json
{
  "version": 1,
  "input": {"space": "vlog-vgamut", "reference": "scene", "range": "full"},
  "output": {"space": "rec709-gamma24", "reference": "display", "range": "full"},
  "interpolation": "tetrahedral",
  "base_rendering": "none",
  "evidence": {
    "source": "Actual author document or reference project identifier",
    "conditions": "Author-specified input, output, range, base and interpolation conditions"
  }
}
```

This illustrates the schema; it is **not a declaration for a Panasonic LUT pack**.
The source and conditions must refer to the actual author's documentation or
controlled reference. These are user-supplied assertions, not authenticated proof.
Accepted contracts remain **Appearance unverified** in the application. Importing
does not certify a visual match or upgrade that status.

Strict import distinguishes missing input/output information, missing evidence,
unsupported colors/base rendering and invalid/conflicting declarations.
Missing information or evidence can enter the explicit compatibility flow below;
unsupported or conflicting declarations remain blocked. Unknown keys, duplicate JSON/color
declarations and a simultaneous legacy `#Gamma`/`#Gamut` contract fail closed.

| Space | Reference | Meaning |
| --- | --- | --- |
| `srgb` | `display` | sRGB transfer, BT.709/D65 primaries |
| `rec709-gamma24` | `display` | Ideal black-zero gamma 2.4; not the camera OETF |
| `linear-srgb` | `scene` or `display` | Linear BT.709/D65 with the declared reference |
| `vlog-vgamut` | `scene` | Panasonic V-Log and V-Gamut |
| `slog3-sgamut3` | `scene` | Sony S-Log3 and S-Gamut3 |
| `slog3-sgamut3-cine` | `scene` | Sony S-Log3 and S-Gamut3.Cine |

Both signals declare `full` or `legal10`; the latter maps normalized values
to/from `(64 + 876*x)/1023`. Input range mapping precedes CUBE domain normalization;
output range removal precedes decoding. Tables retain finite negative/superwhite
values. Only the final SDR display result is clipped. Nonfinite processing fails.
Interpolation is `linear` (trilinear) or `tetrahedral`. No table is resampled.

## Base rendering

Target-camera RAW calibration and white balance remain unchanged. Log input is
derived from scene-linear data before RawLab's neutral view curve.

- `none`: scene input. Apply the LUT before neutral rendering. Display output
  already contains its rendering; scene output receives the neutral curve once.
- `rawlab-neutral-v1`: a display-to-display LUT receiving RawLab's neutral
  rendering of scene input. The author/reference must justify this base. It is
  not a Panasonic Standard emulation and cannot be applied to an already-rendered
  display input as though it were scene radiance.
- `source-display`: a display-to-display LUT receiving an already-rendered image.
  It cannot manufacture a camera base style from RAW. The source image must
  actually have the documented base; the application cannot authenticate that.

Display-to-scene recovery is unsupported. A display image cannot enter a scene
Log LUT. `#LUMIXPHOTOSTYLE VLOG` must agree with `vlog-vgamut`; `STD` requires an
explicit display contract with `source-display`. Other base styles, including a
requested `panasonic-standard` renderer, remain unsupported. A Gamma and gamut
alone do not specify a manufacturer's skin/contrast/highlight rendering.

New contracts use the shared CPU implementation on all platforms. GPU Auto
falls back to CPU; Force rejects them. Existing legacy GPU paths are unchanged.
Generic `LUTApplicator` remains a mathematical sampler for already-encoded RGB;
it is not a photo renderer and does not establish or validate input color meaning.
Applications must use the PHOTO API's contract validation and rendering path.

## User-confirmed compatibility

All clients retain one import action. A normal, supported look imports directly.
A structurally valid CUBE/VLT with missing colors or reference evidence opens a
compatibility configuration prompt before installation. Cancel skips that file
without changing the selected look; other files in a multi-file import continue.
An external file already carrying a compatibility record also requires confirmation.
Reopening the managed library restores the confirmed asset without another prompt.

Input/output color spaces, references, ranges, interpolation and base rendering
must form a complete supported execution configuration. Unknown color spaces
remain unselected until the user selects a candidate or configures advanced fields.
LUTCalc input/range comments, Panasonic Photo Style and Export
LUT profile comments provide visible suggestions; they do not certify appearance.
Existing complete explicit parameters with missing evidence are retained unchanged.
No author evidence is fabricated from a user's choice.

For a display LUT, the user chooses either `source-display` for a matching rendered
image, or `rawlab-neutral-v1` for an explicitly approximate RAW base. The latter
is labeled **Approximate base · Unverified**, including for Panasonic STD files;
it does not emulate Panasonic Standard. A VLOG tag cannot be changed into sRGB,
and STD cannot be silently treated as a scene Log LUT. Output magnitudes above 16
require a separate acknowledgement; VLT integer values are normalized before this
check. The original values are not repaired, clipped or resampled.

The managed copy preserves every original byte and appends one final-line
`#RawLabCompatibility:` JSON record. Version 1 records `source_bytes`, the SHA-256
of those original bytes, `confirmed: true`, `confirmed_extreme_values`, and a
complete `contract` without an `evidence` field. Original author metadata remains
separate. A changed hash, duplicate record/JSON field, unconfirmed parameters,
unsupported colors or conflicting source declaration rejects the record.
The confirmation field records the workflow, not cryptographic proof of a human
or author. It never promotes appearance to verified.

`sony2fuji_inspect_lut_compatibility` returns a bounded JSON draft and current
source hash. `sony2fuji_prepare_lut_compatibility` requires that hash and explicit
confirmation, then returns prepared bytes without writing the source. Clients
install those bytes through the existing managed-library transaction. Both use
`sony2fuji_blob` ownership and `sony2fuji_release_blob`.

Compatibility and approximate-base states are additive C enum values 7 and 8;
the existing unreadable value 6 is unchanged. Both use the same CPU color evaluator,
Auto fallback and Force rejection as explicit author contracts. A warning badge
on the look icon, a localized notice and an accessible name persist with the
managed record. Frozen export copies retain the embedded interpretation.

User looks can be renamed from their context/more menu. Renaming changes only
the displayed library name; asset IDs, bytes, source names, compatibility status
and saved photo associations stay unchanged. Windows also stores display-name
aliases for historical external-path looks without renaming or relocating those
files. Built-in look names remain fixed.

## Guided preview and reference comparison

Compatibility inspection includes bounded candidate contracts with stable IDs,
their basis (`file-parameters`, `partial-metadata` or `assumed`) and remaining
assumptions. Fixed explicit parameters yield one unchanged candidate. Partial
metadata constrains candidates; STD yields the four combinations of common
sRGB/Gamma 2.4 display encodings, while a known Log input only varies an unknown
output. With no input clues, the common display and supported Log inputs yield
at most ten candidates. This is a limited trial set, not exhaustive inference,
a calibrated probability, or evidence that the first option is most accurate.

Clients show candidate thumbnails before the collapsed advanced fields. Selecting
a thumbnail supplies its complete execution configuration but does not install
the LUT; confirmation remains explicit. A separate source-photo picker can be
used without changing the editor's photo or adjustments. On Mac and Windows,
the source picker browses folders already registered in RawLab's photo library,
with independent selection and browsing state; it does not open an external-file
picker. The current editor photo remains the initial preview even if it was opened
outside the library. An empty library directs the user to add a folder in the main
window. Android reuses RawLab's album grid and permission handling with a separate
single selection and an explicit use-photo action. iOS reuses RawLab's PhotosPicker
entry and RAW-aware acquisition. Cancelling either mobile picker preserves the
existing preview; acquired temporary files survive until the preview has copied
them, and cancelled or superseded acquisitions cannot replace the current source.
Reference images retain their separate file-selection entry. Raster inputs require
`source-display`; scene/Log candidates cannot recover scene radiance from JPEGs.
The original formal contract is never rewritten to accommodate another source.

The independent preview session uses C5 processing, as-shot white balance, scene
exposure normalization, EV 0, LUT strength 100%, no additional adjustments or
geometry, and a 512-pixel-long-edge sRGB buffer. Raster inputs use their existing
rendering. On Mac/iOS, an HDR original used as a source photo is decoded with
PREVIEW and a 512-pixel long-edge limit. The canonical SDR rendition is converted
to opaque display-sRGB RGBA8; the temporary HDR float pair is then released.
It remains a display input, with scene/Log candidates excluded. These conditions
are displayed so they are not confused with the
editor's current edits. Source/LUT copies belong to the preview worker; changing
sources or closing the dialog discards stale results and releases them after
native work finishes. Previewing does not modify the managed library.

`sony2fuji_preview_lut_compatibility` accepts a separate serial session, a PHOTO
request whose `lut_path` points to the original file, and JSON containing only
`source_sha256` and `contract`. It checks the same source/metadata constraints as
import, creates an in-memory LUT override, and uses the normal PHOTO evaluator.
It requires BUFFER/PREVIEW output and a long edge of 1–1024. It does not generate
a `confirmed` record or permit file export through this preview entrypoint.

An optional JPEG/PNG reference (also TIFF on Apple and Windows) is decoded with orientation and color
management into sRGB. Visual comparison is available without an assertion of
equivalent conditions. Numeric comparison additionally requires confirmation of
the same original, matching orientation/crop/composition, matching base rendering,
white balance/exposure/LUT strength, known sRGB output (or a correct conversion),
and a nonempty source/software/processing note. These are user assertions, not
authenticated metadata. Choosing another source/reference or changing relevant
processing parameters invalidates the comparison. Changing the source clears the
reference and cancels pending reference loads; changing any LUT execution parameter
requires the processing-condition assertion to be confirmed again.

`sony2fuji_compare_lut_previews` compares opaque RGB8/RGBA8 sRGB buffers at equal
dimensions up to 1024 per side. It validates strides, byte counts and the declared
conditions, then reports mean/max/p95 absolute channel differences and boundary
pixel fractions. It does not align/crop images, infer missing color profiles,
calculate Delta E, score naturalness, or decide an acceptance threshold. A black
and white, strongly tinted or clipped creative look is not automatically wrong.
Reference and preview dimensions that differ are limited to visual comparison.

The comparison describes reduced preview pixels under the recorded conditions,
not an exhaustive/full-resolution or author-appearance pass. Its `appearance`
field is always `unverified`, including for zero error. The dialog's reference
selection and comparison results are session-local; they do not become author
evidence in the managed LUT or upgrade its compatibility/approximate-base badge.
An independent controlled reference remains necessary for author-look acceptance.

## VLT 1.0

VLT requires its Panasonic version/source headers, `LUT_3D_SIZE 17` and 4913
R-fast triples of integers in 0..4095. Input knots are `0, 256, ..., 3840, 4095`;
the last interval has 255 codes. Output normalization preserves those knots.
VLT alone does not specify output Gamma/range. Append the contract after the
table to preserve the original header. CUBE supports 2..256 points and finite
`DOMAIN_MIN/MAX`. Readers are bounded to 256 MiB and 64 KiB per line.

## Preparation and persistence

Build `rawlab_lut_probe` with the desktop core. Create a JSON manifest containing
`source_sha256` (the exact original file hash) and `contract` (the complete object
above). Use `shasum -a 256 original.cube` to obtain the source hash.

```sh
python -m lutools.lutprep attach-contract original.cube documented.cube \
  --manifest documented.json --probe lutools/build-macos/rawlab_lut_probe
python -m lutools.lutprep inspect documented.cube
```

The command preserves source bytes, appends the contract/source digest, runs the
native validator and atomically installs a new file. It rejects source aliases,
existing destinations, conflicting metadata and hash mismatches. It never edits
the original. VLT uses the same procedure with `.vlt` source/destination. Import
the documented file through the client. Colors/evidence travel with the stored
asset and frozen batch copies; adjacent sidecars are never silently applied.

## Reference acceptance

`verify-reference` accepts a version-1 JSON report with `asset_sha256`, the exact
embedded `contract`, `input_kind` (`scene`/`display`, both linear-sRGB/D65), a
predeclared `max_error` in 0..0.02 absolute display-sRGB channel units, `evaluator`
and nonempty named `samples`. Each sample contains a unique `id`, `input_rgb`
and `output_rgb` (display-sRGB in 0..1). The evaluator requires `kind: independent`,
`name`, `version` and reproducible `provenance`. RawLab/lutprep self-reference and
mismatched asset/conditions are rejected.

```sh
python -m lutools.lutprep verify-reference documented.cube \
  --reference independent-samples.json --probe lutools/build-macos/rawlab_lut_probe
```

Exit 0 means agreement at the supplied samples/tolerance; 1 means mismatch; 2
means invalid evidence or unsupported processing. The report retains per-sample
errors and **appearance: unverified**. It never promotes a LUT's UI status.
Follow the [look reference protocol](../../../lutools/docs/look-reference.md) for
controlled author-software/camera exports with matched exposure, WB, base style,
skin/gray/sky/foliage and highlight ramps. Missing author outputs are an acceptance
gap, not a zero-error result. Internal numerical or CPU/GPU agreement is insufficient.

## Sources and compatibility notes

- [Panasonic V-Log/V-Gamut](https://pro-av.panasonic.net/en/cinema_camera_varicam_eva/support/pdf/VARICAM_V-Log_V-Gamut.pdf)
- [Panasonic VLT 1.0](https://pro-av.panasonic.net/en/cinema_camera_varicam_eva/support/pdf/VARICAM_3DLUT.pdf)
- [Sony S-Log3/S-Gamut3](https://pro.sony/s3/cms-static-content/uploadfile/06/1237494271406.pdf)
- [OCIO Sony transforms](https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/main/src/OpenColorIO/transforms/builtins/SonyCameras.cpp)

The offline Sony preparation bridge formerly combined CAT02 IDTs with a Bradford
return to D65. It now uses CAT02 consistently. Re-prepare earlier baked S-Log3
derivatives from the original sources; existing LUTs/edits are not silently changed.
