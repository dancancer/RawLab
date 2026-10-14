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

Image inspection, previews and geometry follow in dependent PRs.
Unsupported adjustment fields fail explicitly; they never become silent
no-ops. New edit fields will require an updated supported schema version.
