# Edit JSON v1

The CLI accepts a versioned edit recipe through the existing C API:

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
