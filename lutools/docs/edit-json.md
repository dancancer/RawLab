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
| `output.format` | `jpeg`, `png` (16-bit), `dng` (rendered 16-bit LinearRaw SDR) | Required; never inferred from extension |
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
JPEG, PNG and DNG encoding all publish through staged writes, so an output
storage failure reports status 6 (`output_io_error`) for every format. Paths in
successful exports are absolute, without requiring symlink canonicalization.

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

`input.type: "raster"` accepts one opaque 8-bit SDR JPEG, PNG, TIFF or HEIF
frame on macOS, plus opaque 16-bit integer RGB PNG/TIFF on macOS and Windows.
The capability response advertises `bits_per_component: [8,16]` and
`tiff_bits_per_component: [8,16]`; JPEG and HEIF remain 8-bit inputs. The adapter
converts tagged RGB to sRGB and preserves PNG/TIFF precision through processing.
Nonopaque alpha, floating-point, HDR, CMYK and high-bit-depth formats other than
integer RGB PNG/TIFF are rejected.
Check the capability response for other platforms' supported inputs.

The Android client additionally accepts opaque integer RGB/RGBA16 PNG through
its client-side raster decoder and the existing RGBA16 display-buffer API.
It retains 16-bit samples, applies orientation once, converts supported tagged
RGB to sRGB and treats untagged RGB as sRGB, matching its 8-bit color handling.
This client-side support does not enable the Android native file-loader or
change the macOS CLI capability response.

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
| `input.type` | `raw` or macOS/Windows `raster` | `raw` when omitted |
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
| `edits.lens_correction.profile_id` | Nonempty catalog ID (at most 1024 UTF-8 bytes) or `null`; `null` selects automatic matching. Catalog IDs join maker, model, mount and crop factor with newlines; no other control characters are accepted | `null` |

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
"processing": { "family": "rawlab", "version": 3, "quality": "standard" }
```

The supported versions are `1` (released v0.8.2 RAW/SWT behavior), `2`
(Bayer VNG and C5 EAW denoising), and `3` (v2 RAW/denoise with
[basic controls v3](basic-controls-v3.md)). All use quality `standard`.
Unknown members, families, versions or quality values are rejected before
rendering or creating output. The processing version is independent of
`schema_version`, the result protocol and request v2.

Schemas 1–4 implicitly select processing version 1, continue rejecting the
`processing` field, and normalize without adding it. An in-memory recipe with
processing version 2 or 3 cannot be serialized as schema 1–4: the serializer throws
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

Schema 5 also accepts optional `edits.effects.clarity` and `edits.effects.dehaze`,
each a finite number in `[-1,1]`, default zero. They drive the atmosphere stage
documented in [atmosphere v1](atmosphere-v1.md); schemas 1–4 reject both keys, and
serialization never discards a nonzero value into an older schema.

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

CLI capabilities advertises v6, `hdr_raster` and `hdr_jpeg` when the runtime
supports HDR. Apple builds require macOS 15 or iOS 18. CLI `--preview` renders
the same FINAL HDR request at the requested size,
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

## V8 HDR tone

[Schema 8](edit-json-v8.schema.json) uses `rawlab_hdr` processing version 2
and the source, geometry and output contracts from schema 6. The optional
`edits.tone.black_point`, `white_point` and `s_curve` use [-1,1], default
to zero, and map to percentages in the native request. Custom `curve` mode
requires zero `s_curve`. Its normalized coordinates represent [-8,+8] EV
around SDR reference white. See the [color contract](hdr-color-contract.md) and
the [schema 8 example](../examples/edit-recipes/hdr-v8.json).

An HDR-capable CLI lists 8 in `recipe_versions` and exposes
`hdr.processing_versions` and `hdr.tone_recipe_version`. Schema 6 still
uses the version 1 request and renders its original pixels.

## V9 HDR color

[Schema 9](edit-json-v9.schema.json) selects `rawlab_hdr` processing version
3. It keeps the HDR source, tone, geometry and output fields of schema 8.
Optional `edits.color.vibrance` uses [-1,1]. The `edits.hsl` arrays contain
eight values in [-100,100] per axis. `edits.color_grading` accepts shadows,
midtones and highlights with hue in [0,360) and saturation in [0,100].
Omitted controls are neutral. See the [example](../examples/edit-recipes/hdr-v9.json)
and the [HDR color contract](hdr-color-contract.md).

The CLI advertises schema 9 through `recipe_versions` and
`hdr.color_recipe_version`. Schemas 6 and 8 continue to select their
original processing versions.

## V10 HDR peak and SDR base

[Schema 10](edit-json-v10.schema.json) selects `rawlab_hdr` processing
version 4. It adds the optional `edits.rendition` group. `peak_limit_ev`
accepts [0,6] with zero selecting an unlimited peak. `sdr_exposure_ev`
accepts [-4,4] and `sdr_contrast` and `sdr_saturation` accept [-1,1].
These controls affect the edited HDR master and its SDR base as described in
the [HDR color contract](hdr-color-contract.md). Omitted values are neutral.
See the [example](../examples/edit-recipes/hdr-v10.json).

The CLI advertises schema 10 through `recipe_versions` and
`hdr.rendition_recipe_version`. Schemas 6, 8 and 9 continue to select their
original processing versions.

## V11 HDR vignette and grain

[Schema 11](edit-json-v11.schema.json) selects `rawlab_hdr` processing
version 5. The optional `edits.effects` group accepts vignette amount and
roundness in [-100,100]. Vignette midpoint, feather, highlight protection,
grain amount, size and roughness use [0,100]. Omitted values keep their
defaults. See the [example](../examples/edit-recipes/hdr-v11.json) and the
[HDR color contract](hdr-color-contract.md).

The CLI advertises schema 11 through `recipe_versions` and
`hdr.effects_recipe_version`. Earlier HDR schemas retain their own processing.

## V12 HDR detail

[Schema 12](edit-json-v12.schema.json) selects `rawlab_hdr` processing version 6.
The optional `edits.detail` group accepts sharpening in [0,2], clarity and
dehaze in [-1,1], and rendered RGB denoise in [0,1]. Omitted controls are zero.
See the [example](../examples/edit-recipes/hdr-v12.json) and the
[HDR color contract](hdr-color-contract.md).

The CLI advertises schema 12 through `recipe_versions` and
`hdr.detail_recipe_version`.

## V13 declared HDR look

[Schema 13](edit-json-v13.schema.json) selects `rawlab_hdr` processing version 7.
An optional `edits.look` group contains a CUBE `path` relative to the recipe
or absolute, its lowercase SHA-256 `sha256`, and `strength` in [0,2]. Strength
defaults to 1. The asset must declare the HDR profile in the
[HDR color contract](hdr-color-contract.md). The CLI verifies the fingerprint
before publishing preview or export output. The capabilities response
advertises `hdr.look_recipe_version` and `hdr.look_profile`.

## V14 HDR sources and SDR exports

[Schema 14](edit-json-v14.schema.json) retains the v13 HDR edits and
`rawlab_hdr` processing version 7. It adds `input.type="raw"` for ordinary
camera RAW and `input.type="proraw"` for Apple ProRAW DNG, alongside
`hdr_raster` for gain-map JPEG/HEIF. The explicitly selected decoder validates
the actual source; changing a suffix does not convert between these types.
V6 and v8–v13 keep their `hdr_raster` / `hdr_jpeg` restrictions.

Only `raw` accepts an optional `input.camera_development` object. Its fields
follow the Mac camera HDR development settings, before the separate relative
`edits.white_balance` stage:

| Field | Values and default |
| --- | --- |
| `version` | `1` |
| `white_balance_mode` | `as_shot` (default) or `temperature` |
| `temperature`, `tint` | Both `0` for as-shot; temperature mode uses 2000–50000 K (default 6500), tint -150–150 (default 0) |
| `exposure_reference` | `metadata` (default) or `sensor`; no ordinary RAW scene/preview boost |
| `fbdd_level` | Integer 0–2, default 0 |
| `lens_distortion`, `lens_tca`, `lens_vignetting` | Booleans, default false; vignetting is omitted when false |
| `lens_auto_crop` | Boolean, default true; active only with lens correction |
| `lens_profile` | Optional nonempty profile id (newline-joined catalog segments; no other control characters), at most 1024 UTF-8 bytes, requiring active lens correction |
| `camera_profile` | Optional `{ "path": "camera.dcp", "sha256": "<64 lowercase hex digits>" }` for a D65 camera-matrix DCP or RLOOKHDR |

Camera profile paths resolve relative to the recipe, like look paths. The
decoder checks the profile fingerprint before export. `--lens-database`
selects the session's Lensfun file/directory for both ordinary and HDR camera
RAW recipes; missing calibration remains an explicit failure. Omitted camera
development normalizes to the Mac defaults. These fields do not request AI
denoising.

`output.format` accepts `hdr_jpeg`, `jpeg`, `png` and `dng`. HDR JPEG still
requires `base_color="srgb"|"display_p3"`. For the other formats `base_color`
is optional and has no effect: the core exports the edited SDR rendition in
sRGB, including rendered RGB DNG rather than a RAW sensor copy. JPEG quality,
geometry and the no-upscale long-edge limit retain their existing semantics.
Preview always renders the same FINAL request to SDR PNG. ProRAW HDR JPEG
export uses the core's streaming path with the system temporary directory;
SDR exports use the common HDR SDR writer.

The CLI advertises 14 in `recipe_versions`, adds `proraw` to `input_types`, and
publishes `hdr.source_recipe_version=14`, `hdr.input_types` and
`hdr.output_formats`. This changes the JSON schema only; the result protocol,
HDR processing version and shared C ABI remain unchanged.
`proraw` is advertised only in builds with the DNG SDK enabled; other builds
return `unsupported` for that explicitly selected source type.

For `--info`, an unrecognized extension triggers content-based HDR probing,
then SDR image loading, then LibRaw inspection. Recognized invalid HDR
containers are rejected instead of silently opening their SDR base.

## v15: HDR channel curves

[Schema 15](edit-json-v15.schema.json) selects `rawlab_hdr` processing version
8 and retains the v14 source and export formats. `edits.tone.curve.channels`
optionally holds `red`, `green` and `blue` curves, each with its own `mode`
and `points` under the same fixed-endpoint, monotone PCHIP rules as the
master curve. Missing channels are legacy identity curves. Channel objects
cannot contain further channels. The master luminance curve runs first;
independent RGB curves then use the normalized log-EV domain. Older HDR
schemas reject active channel curves and keep their original processing.

The CLI publishes `hdr.channel_curve_recipe_version=15` and processing
version 8. SDR schemas 5 and 7 also accept `tone.curve.channels` without
changing their existing processing identity; the channels use display RGB
there. Identity channels are omitted during normalization, preserving old
recipes. `tone_curve.channels` lists the available channel names.

SDR schemas 4, 5 and 7 accept optional `edits.lens_correction.vignetting`,
default false and omitted from normalized output when disabled. Agent CLI
raster recipes still reject active lens corrections: the native display
lens API requires explicit camera metadata that this recipe does not carry.
Camera HDR schemas 14 and 15 accept `input.camera_development.lens_vignetting`;
a vignetting-only correction can select a `lens_profile`.
