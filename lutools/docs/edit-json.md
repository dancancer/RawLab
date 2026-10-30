# Edit JSON

The CLI accepts a versioned edit recipe through the existing C API:

Schemas 1–4 retain legacy processing. New RAW/SDR desktop recipes use schema 5 with an
explicit [processing identity](#v5-processing-identity); the v1 example below
remains valid and does not silently opt into newer algorithms.

```sh
sony2fuji --recipe edit.json --print-recipe  # validate and emit explicit defaults
sony2fuji --recipe edit.json                 # exact FINAL file export
```

Recipe mode accepts no legacy rendering flags or positional arguments. Relative
input, look and output paths are relative to the JSON file's directory, regardless
of the working directory. `--print-recipe` preserves those paths, requires no RAW
or look file, and writes only JSON to stdout. Keep the printed recipe in the same
directory, or update its paths when moving it.

```json
{
  "schema_version": 1,
  "input": { "path": "photo.ARW" },
  "edits": {
    "exposure": { "mode": "preview", "ev": 0, "brightness": 1 },
    "white_balance": { "mode": "camera" },
    "look": { "path": null, "strength": 1 }
  },
  "output": {
    "path": "edited.jpg",
    "format": "jpeg",
    "jpeg_quality": 95,
    "size": { "mode": "native" }
  }
}
```

## Fields and defaults

`schema_version`, `input.path`, `edits.exposure.mode`, `output.path` and
`output.format` are required. Other supported fields have the defaults below.
Unknown fields, unsupported versions, duplicate keys, wrong types, nonfinite or
out-of-range numbers and NUL-containing/empty paths fail before processing.
JSON is UTF-8, at most 1 MiB and at most 16 nesting levels.
Integer fields require integer JSON tokens (for example `95`, rather than `95.0`).

| Field | Values / units | Default when omitted |
| --- | --- | --- |
| `schema_version` | Integer `1`; independent of binary request v2 | Required |
| `input.path` | RAW/DNG file path | Required |
| `edits.exposure.mode` | `scene`, `preview`, `sensor` | Required |
| `edits.exposure.ev` | Relative EV, [-20,20]; +1 doubles linear input | 0 |
| `edits.exposure.brightness` | Positive finite float32 multiplier (at least the smallest normal float32) | 1 |
| `edits.white_balance.mode` | `camera`, `auto`, `temperature` | `camera` when the whole group is omitted |
| `edits.white_balance.temperature_kelvin` | 2000–50000 K, required only in `temperature` mode | Required in temperature mode |
| `edits.white_balance.tint` | [-150,150]; positive adds magenta; only in `temperature` mode | 0 |
| `edits.look.path` | Compatible `.cube` / `.rlook`, or `null` for neutral output; required if group present | `null` when the whole group is omitted |
| `edits.look.strength` | Factor [0,1]; 0 bypasses look loading | 1 |
| `output.format` | `jpeg`, `png` (16-bit), `dng` (rendered float32 SDR) | Required; never inferred from extension |
| `output.jpeg_quality` | Integer 1–100; used only for JPEG | 95 |
| `output.size.mode` | `native`, `limit_long_edge` | `native` when group omitted |
| `output.size.long_edge` | Positive uint32 pixels, required only for `limit_long_edge`; preserves aspect, never enlarges | Required in limit mode |

The [JSON Schema](edit-json-v1.schema.json) describes the accepted structure.
The native parser additionally checks duplicate keys, UTF-8, limits and NULs.

## Exposure compatibility

The mode is always explicit. `scene` uses the existing +0.7 EV workflow baseline
plus valid DNG BaselineExposure. `preview` replaces that baseline with embedded
preview matching, falling back to scene if unavailable. `sensor` uses neither
workflow nor metadata baseline. User EV is applied relative to the chosen mode.
See the [color contract](color-contract.md) for exact RAW processing semantics.

Legacy CLI invocations and C sessions keep their `scene` default. Native clients
keep `preview` for new edits, while saved records missing an exposure mode keep
their original `scene` interpretation. V1 does not migrate native persistence
or change client defaults. A future UI exporter must serialize the effective
mode rather than omit it or infer it from a slider value.

## C++ and C API mapping

`sony2fuji/edit_recipe.h` provides parsing, serialization and `toRequest()`.
The returned request borrows the recipe's strings. Keep the recipe alive and
unchanged until processing completes. The adapter sets every identity control
explicitly and builds a FINAL RAW-to-file request without altering the v2 ABI.
Set the recipe's exposure mode on a fresh session before calling `process`:

```cpp
const auto request = recipe.toRequest();
auto status = sony2fuji_session_set_raw_exposure_mode(session, recipe.exposureMode);
if (status == SONY2FUJI_STATUS_OK)
    status = sony2fuji_process(session, &request, nullptr);
```

The opt-in `rawlab_edit_protocol` static library is separate from the rendering
core. It uses pinned [nlohmann JSON 3.12.0](https://github.com/nlohmann/json/tree/v3.12.0)
under its retained [MIT license](../third_party/nlohmann/LICENSE.MIT). Native app
builds and the C header acquire no new dependency. Reusing a session requires
resetting any other session-level effects; this first CLI path creates a fresh
session per recipe.

## Agent command results

```sh
sony2fuji --capabilities --json
sony2fuji --recipe edit.json --print-recipe --json
sony2fuji --recipe edit.json --json
```

`--json` emits one UTF-8 JSON document to stdout. Diagnostics use stderr.
The result protocol has its own version, separate from the edit schema:

```json
{"protocol_version":1,"command":"export","ok":true,"result":{"output_path":"/photos/edited.jpg","format":"jpeg"},"error":null}
```

Failures return nonzero and `ok:false`, `result:null`, and an `error` object
containing `code`, `message` and `status`. Native status values 1–6 map to
`invalid_argument`, `unsupported`, `io_error`, `processing_error`, `out_of_memory`
and `output_io_error`. `invalid_recipe` identifies a JSON schema/parser failure.
Argument/parser failures have `status:null`; backend failures retain the actual
native status. A backend error is never relabeled as success or another status.
The existing DNG writer reports output storage failures as status 6; legacy
JPEG/PNG encoding can report status 4 for such a failure. Results preserve that
distinction. Paths in successful exports are absolute, without requiring symlink
canonicalization.

Capability results list only currently supported commands, recipe versions,
input types, file formats and exposure modes. Querying requires no photo or
configured service. Validation returns the normalized recipe without opening
its source. Legacy rendering flags remain separate from recipe commands.

## Image information

```sh
sony2fuji --info photo.ARW --json
```

This reads LibRaw identification metadata without unpacking or developing RAW
pixels. The result includes camera/lens, capture ISO/aperture/shutter, an absolute
input path, DNG baseline exposure when the tag exists, and `identified_size`.
Its `orientation` is LibRaw's flip code (0–7), not the EXIF Orientation number.
These dimensions precede decoding, SDK Stage3 and user geometry;
`rendered_size` remains `null`. An info success does not certify compressed
pixel data or predict final output dimensions. Unavailable values use `null`;
EXIF exposure bias and calibrated as-shot Kelvin/tint are currently unavailable.
The input path is relative to the working directory. No recipe or output file
is needed; mixing info with recipe/capability commands fails explicitly.

## Exact preview

```sh
sony2fuji --recipe edit.json --preview preview.png --long-edge 1280 --json
sony2fuji --recipe edit.json --json
```

The first command writes a 16-bit PNG capped to the requested long edge, without
upscaling (default 1280 pixels). It uses the exact FINAL processing path with a
temporary output-size override. No interactive/viewport approximation is used.
The JSON result includes actual `width`/`height`, `quality:"exact"`, format and
absolute output path. The preview path is relative to the working directory;
paths stored in the recipe keep their recipe-relative meaning.

The recipe file and its FINAL settings are preserved. Running the second command
uses the original output path, format and size. `--long-edge` requires a positive
uint32 and is accepted only with `--preview`. Preview cannot be combined with
info, capability query or recipe normalization. Original RAWs remain protected
by the existing C API input/output identity check.

Geometry follows in dependent PRs.
Unsupported adjustment fields fail explicitly; they never become silent
no-ops. New edit fields will require an updated supported schema version.

## Geometry in recipe v2

Version 1 remains supported and rejects geometry fields. Set `schema_version: 2`
to use the optional `edits.geometry` object. Omitted fields mean identity, and
normalization preserves the recipe version. See [schema v2](edit-json-v2.schema.json)
and the [reusable example](../examples/edit-recipes/geometry-v2.json).

```json
"geometry": {
  "quarter_turns": 1,
  "flip_horizontal": false,
  "flip_vertical": false,
  "straighten_degrees": 2,
  "crop": {"x": 0.1, "y": 0.1, "width": 0.8, "height": 0.8}
}
```

`quarter_turns` is an integer from 0 to 3, clockwise. Flips operate in the rotated
canvas. Straightening is clockwise in degrees, from -45 to 45; it keeps a centered
rectangle inside the rotated image. Crop coordinates are fractions of that
straightened canvas, with top-left origin, positive width/height, and both end
coordinates at most 1. The native float boundary allows 1e-6 rounding tolerance
and clamps it to 1. Crop starts round down and ends round up to retain all covered
pixels. Output resizing happens afterward and never upscales.

The common order is source orientation and lens processing → color/photo effects
(including existing grain/vignette) → quarter turns → flips → straightening → crop
→ requested output size. Vignette retains its source-centered semantics; rotated
or straightened grain is sampled with the image. Integer turns/flips/crop copy
pixels exactly. Straightening uses one bilinear sample and extends edge pixels at
the half-pixel boundary; it preserves linear negative/highlight values for DNG.
Identity bypasses geometry without changing existing pixels.

Native clients use the additive 40-byte `sony2fuji_geometry_config` v1 and
`sony2fuji_session_set_geometry`; the existing request v2 layout is unchanged.
Set the complete configuration before each render, including identity to reset.
`sony2fuji_session_get_geometry_size` reports the full edited canvas before output
resizing only after a successful process; successful setters and newly failed
processes clear it. Invalid setters preserve the last configuration and result.
Active geometry uses the full source even for interactive previews, so crop and
aspect agree with FINAL. GPU Auto may use GPU color plus CPU geometry and reports
CPU for the mixed result; GPU Force with active geometry returns `unsupported`.

## Perspective in recipe v3

Use `schema_version: 3` to add the optional
`edits.geometry.perspective: {"horizontal": 0.3, "vertical": -0.2}`.
Both fields are unitless numbers from -1 to 1, defaulting to 0; native UIs show
-100% to 100%. Versions 1/2 remain supported and keep zero perspective. Version 2
rejects perspective fields, so existing recipes retain their contract. See
[schema v3](edit-json-v3.schema.json) and [example](../examples/edit-recipes/perspective-v3.json).

Perspective follows turns/flips and precedes straightening/crop. The transform is
centered: for original rotated canvas width W and height H, let u=2dx/W, v=2dy/H,
a=0.25·horizontal and b=0.25·vertical. The inverse source offset is
(dx,dy)/(1+a·u+b·v). Positive horizontal expands the right side, and positive
vertical expands the bottom side. A centered rectangle scaled by
1/(1+|a|+|b|) keeps sampling inside the source; dimensions round down, at least
one pixel. Straightening uses this reduced canvas, then crop and final size apply.
Perspective and straightening share one bilinear sampling pass, without black
borders or linear highlight clipping. Both perspective values at zero preserve
basic geometry exactly. This is horizontal/vertical keystone editing; four-corner
handles and automatic line detection are outside this increment.

The additive 16-byte `sony2fuji_perspective_config` v1 and
`sony2fuji_session_set_perspective` keep the basic 40-byte geometry config and
binary request v2 unchanged. The two setters preserve each other's settings.
Set both complete configs, including zero values to reset, before every render.
They share the same native-canvas query lifecycle and CPU geometry policy.

## Complete edits in recipe v4

Use `schema_version: 4` for the complete edit record. Versions 1, 2 and 3
remain unchanged and reject these fields. The [v4 schema](edit-json-v4.schema.json)
and [complete example](../examples/edit-recipes/complete-v4.json) show the v4
control shape; normalized CLI output also includes explicit `input.type`.

`input.type` is optional in v4 and defaults to `raw`; the v4 serializer always
emits the explicit value (`raw` or `raster`). Versions 1, 2 and 3 keep their
existing input object and reject `input.type`, so legacy recipes do not acquire
new behavior during normalization.

All v4 groups are optional in the input. Validation treats omitted controls as
identity values, while normalization emits every group and every default. The
recipe stores the final values consumed by the shared core; it does not store a
master-recipe ID, UI percentage conversion, or another multiplication by look
strength.

`--lens-database /path/to/offline-db` selects an offline Lensfun file/directory
for rendering. A v4 render that requests lens correction returns
`result.lens_correction` with `state`, `applied_distortion`, `applied_tca`,
`crop_scale` and `profile_id`. For example, `no_database`, `no_calibration` or
`embedded_geometry` reports that the requested correction was not applied;
successful file encoding alone is not evidence of applied lens correction.

### Raster input boundary

`input.type: "raster"` is a macOS capability for one opaque 8-bit SDR JPEG,
PNG, TIFF or HEIF frame. The supported input is single-frame, sRGB display
data; 16-bit, alpha, floating-point, HDR, CMYK and other image variants are
rejected before processing. Other platforms must advertise raster only when
their capability response provides the same contract.

Raster recipes use `edits.exposure.mode: "sensor"` and
`edits.white_balance.mode: "none"`; omitting white balance has the same
default. `raw_level` must be zero, and lens `distortion`, `tca` and
`profile_id` must be disabled/null. Tone, look, HSL, effects, display chroma
denoise, wavelet denoise and geometry remain available. Raw-only camera white
balance, RAW exposure baselines, lens correction and FBDD are not applied.
Mixed batches resolve these RAW-only settings per input instead of carrying
camera state from a neighboring RAW photo.

| Capability | `raw` | `raster` |
| --- | --- | --- |
| Camera white balance and RAW exposure baseline | Yes | No |
| FBDD and catalog lens correction | Optional | No |
| Tone, look, HSL, effects and geometry | Yes | Yes |
| Display chroma and wavelet denoise | Optional | Optional |

| Group / field | Values / units | Default |
| --- | --- | --- |
| `input.type` | `raw` or macOS `raster` | `raw` when omitted |
| `edits.look.strength` | Factor [0,2]; 0 bypasses look loading | 1 |
| `edits.tone.contrast`, `saturation` | Core multipliers [0,2] | 1 |
| `edits.tone.highlights`, `shadows`, `s_curve` | Signed core controls [-1,1] | 0 |
| `edits.detail.sharpening` | Core sharpening amount [0,2] | 0 |
| `edits.hsl.hue`, `saturation`, `lightness` | Three arrays of eight channel values, each [-100,100] | Eight zeroes per array |
| `edits.effects.vignette_amount`, `vignette_roundness` | [-100,100] | 0 |
| `edits.effects.vignette_midpoint`, `vignette_feather`, `vignette_highlights` | [0,100] | 50, 50, 0 |
| `edits.effects.grain_amount`, `grain_size`, `grain_roughness` | [0,100] | 0, 25, 50 |
| `edits.denoise.raw_level`, `chroma_mode` | Integer 0, 1 or 2 | 0 |
| `edits.denoise.wavelet.enabled` | Boolean | `false` |
| `edits.denoise.wavelet.luma`, `chroma`, `coarse` | [0,100] | 0, 46, 50 |
| `edits.lens_correction.distortion`, `tca` | Boolean | `false` |
| `edits.lens_correction.auto_crop` | Boolean | `true` |
| `edits.lens_correction.profile_id` | Nonempty catalog ID or `null`; `null` selects automatic matching | `null` |

For raster input, the effective defaults are `sensor` exposure, `none` white
balance, `raw_level: 0`, and disabled/null lens correction. A raw recipe may
use `camera`, `auto` or `temperature` white balance, but not `none`.

The v4 adapter maps tone and detail to the existing request v2 controls. The
remaining groups use the additive session setters for HSL, photo effects, raw
and display denoise, wavelet denoise, and lens correction. These setters must
be available in the linked shared core before a recipe is rendered; unavailable
optional capabilities return their existing structured `unsupported` status.
The macOS path reuses the shared `apply`/HSL stages and preserves the current
RAW camera white-balance result rather than applying a second UI conversion.
For raster input the display-linear path performs the explicit sRGB decode and
re-encode without adding a RAW scene baseline or neutral-scene sigmoid. GPU
Auto may fall back to CPU; GPU Force rejects unsupported raster paths rather
than claiming GPU success.

The result protocol remains `protocol_version: 1`; v4 changes only the edit
schema. `--print-recipe` still validates without opening the RAW and preserves
recipe-relative paths. The CLI capabilities response must advertise v4 only
when the v4 parser and serializer are available.

## v5: Processing Identity and Additive Color Controls

[Schema v5](edit-json-v5.schema.json) retains all v4 input, edit and output
groups, and requires one additional root object:

```json
"processing": { "family": "rawlab", "version": 2, "quality": "standard" }
```

The supported versions are `1` (released v0.8.2 RAW/SWT behavior) and `2`
(Bayer VNG and C5 EAW denoising). Both use quality `standard`.
Unknown members, families, versions or quality values are rejected before
rendering or creating output. The processing version is independent of
`schema_version`, the result protocol and request v2.

Schemas 1–4 implicitly select processing version 1, continue rejecting the
`processing` field, and normalize without adding it. An in-memory recipe with
processing version 2 cannot be serialized as schema 1–4: the serializer throws
instead of discarding its identity. A schema 5 recipe can explicitly select
version 1 without changing any edit values.

Schema 5 also accepts optional `edits.tone.black_point`,
`edits.tone.white_point`, and `edits.color.vibrance`, each a finite number in
`[-1,1]`, default zero. These are resolved core values, independent of legacy
contrast/saturation and master-recipe strength. The
[tone controls v1 contract](tone-controls-v1.md) defines their stage and numerical
behavior. Existing v5 recipes without them remain valid and retain the same
normalized form; zero-valued additive keys are omitted during normalization.
Schemas 1–4 reject the new fields, and serialization refuses to discard nonzero
controls into an older schema. CLI capabilities advertises their algorithm
version, minimum recipe version, stable field names and range in `tone_controls`.

Schema 5 also accepts an optional `edits.color_grading` object with
`shadows`, `midtones` and `highlights`. Each present zone must contain both
`hue` (degrees in `[0,360)`) and `saturation` (`[0,100]`). Missing zones default
to `{ "hue": 0, "saturation": 0 }`. These values are independent of legacy
recipe strength. A valid JSON hue just below 360 may round to 360 in float;
that rounded value is stored as equivalent canonical 0.

Normalization emits all three zones when any hue or saturation is nonzero,
including dormant hue with zero saturation. An entirely default configuration
omits `color_grading`, preserving the previous normalized form. Schemas 1–4
reject the field; serialization never silently discards grading into an older
schema. Native processing uses the independent 32-byte color-grading config
v1, after HSL and before chroma denoising. See the
[grading numerical contract](color-grading-v1.md) for the candidate formulas,
quality admission and exact zero-saturation bypass. CLI capabilities reports
the actual config version, minimum recipe version, zone names and ranges.

Schema 5 accepts `edits.tone.curve`, with exactly `mode` and `points`:

```json
"curve": { "mode": "custom", "points": [[0, 0], [0.25, 0.4], [0.75, 0.9], [1, 1]] }
```

`legacy` requires an empty point array and uses the existing `s_curve` scalar.
`custom` requires 2–33 finite binary64 coordinate pairs in `[0,1]`, fixed
endpoints `[0,0]` and `[1,1]`, strictly increasing x and nondecreasing y.
Custom mode rejects nonzero `s_curve`; desktop adapters preserve the inactive
legacy value in the photo record but emit scalar zero for rendering. Missing
`curve` means legacy. Schema 5 normalization emits the complete mode and point
array, including `{ "mode": "legacy", "points": [] }` for old v5 input.
Schemas 1–4 reject this field and cannot serialize an active custom curve.

The [tone curve v1 contract](tone-curve-v1.md) defines monotone PCHIP, exact
identity bypass, fixed endpoints and precision admission. The independent
544-byte native config leaves request v2 unchanged. The native sampler used by
all four curve canvases shares the render evaluator. CLI capabilities exposes
`tone_curve.version`, `recipe_min_version`, modes, point limit and interpolation.

The macOS and Windows Agent adapters emit schema 5 and preserve the photo's
selected identity, including old records restored as version 1. Ordinary
parameter changes, resets and batch snapshots do not implicitly upgrade it.
See the [processing-version contract](processing-version.md) for the compatibility
baseline, cache isolation, platform boundaries and explicit conversion policy.

## V6 phone HDR

[Schema 6](edit-json-v6.schema.json) adds a separate display-referred HDR recipe.
The [example](../examples/edit-recipes/hdr-v6.json) uses `input.type="hdr_raster"`,
`processing={"family":"rawlab_hdr","version":1,"quality":"standard"}` and
`output.format="hdr_jpeg"`. The input container must independently pass the HDR
probe and decoder. Schema 1–5 input, rejection and output rules are unchanged.
Schema 6 never enters binary request v2; it builds `sony2fuji_hdr_request_v1`.

`edits.exposure` accepts only `ev` in [-4,4], default 0. `white_balance` is
required and uses `mode="relative"`, `relative_temperature` in [2000,50000]
(default 6500), and `relative_tint` in [-150,150] (default 0). These coordinates
are independent of camera WB and follow the [HDR color contract](hdr-color-contract.md).
There is no RAW exposure mode or brightness multiplier.

The common tone fields keep their canonical transfer units: contrast/saturation
are factors [0,2], default 1; highlights/shadows are [-1,1], default 0. The HDR
request mapping is `(contrast-1)*100`, `(saturation-1)*100`, `-highlights*100`
and `shadows*100`. Geometry has the same shape and order as schema 3–5. Looks,
HSL, detail, denoise, lens correction, curves, black/white points, vibrance,
color grading and atmospheric effects are rejected by field, even when neutral.

HDR JPEG output requires explicit `base_color="srgb"|"display_p3"`, writes ISO
and XMP gain-map descriptions, and defaults to quality 95. Optional long edge is
1–65535, with no upscale. Source files and existing destinations survive failure.
Metadata is copied from the SHA-256-verified original and the gain map is generated
from the edited HDR/SDR pair.

CLI capabilities advertises v6, `hdr_raster` and `hdr_jpeg` only on the supported
Apple runtime (macOS15+/iOS18+). Windows/Android and macOS14 keep the old capability
set. CLI `--preview` renders the same FINAL HDR request at the requested size,
then publishes the edited **SDR rendition** as PNG with `rendition="sdr"`.
This is separate from HDR display; the headroom values in results describe
source/edited content and never the current screen. MCP negotiates v6 with its
configured CLI and preserves its HDR context without downgrading to schema 5.


## V7 X3F rendering identity

[Schema 7](edit-json-v7.schema.json) extends the v5 RAW recipe with required
`x3f_mode: "legacy" | "normal-v1"`. The [example](../examples/edit-recipes/x3f-v7.json)
selects the normal renderer. `input.type` must be `raw`, and execution independently
checks the `FOVb` file signature. Schema validation does not decode the source.
V1–5 preserve legacy X3F pixels; v6 remains the separate HDR format. A normal
X3F record cannot be serialized into an older schema that would drop its identity.

In normal mode, the source's saved rendering provides the exposure and WB
baseline. Exposure mode is retained in the record for switching back to legacy,
but adds no scene offset or embedded-preview matching. User EV and WB are relative
to this rendered baseline; neutral WB coordinates are 6500/0, not measured camera
Kelvin. Automatic RAW WB, raw denoise, AI replacement and extra lens correction
are unsupported. Ordinary display adjustments and compatible looks remain available.

`--capabilities --json` exposes `result.x3f.normal_available`, the minimum recipe version
and mode names. Recipe syntax can be normalized without the renderer, while
normal rendering returns an explicit error in builds without X3F support. Camera
and saved-parameter admission are described in the [X3F contract](x3f-rendering.md).
