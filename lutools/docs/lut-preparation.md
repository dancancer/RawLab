# LUT Preparation

`lutools.lutprep` adapts explicitly described LUTs to the existing RawLab photo
pipeline. Preparation happens once on a desktop. Generic LUTs produce an ordinary
F-Gamut/F-Log2 to display-sRGB CUBE. Supported DCPs can instead compile to `.rlook`,
preserving their stages for native CPU/Metal evaluation without RGB-CUBE approximation.
Both consume RAWs supported by the installed LibRaw. No source-camera calibration or white balance replaces the target RAW's
own development. DCP matrices are used only to reconstruct the profile's expected
input after RAW development. Native applications do not need Python or OCIO.

This does not identify an unknown LUT's intended colors, reproduce a camera's
JPEG engine, or establish cross-camera calibration. An sRGB creative LUT also
depends on its author's starting image; RawLab explicitly uses its own neutral
rendering, which need not match that author's tone mapping.

The newer macOS AI recipe compiler uses a separate, explicitly declared
display-sRGB CUBE path after precise neutral rendering. It does not use this
tool's F-Log2 canonical bake or its Python/OCIO dependencies. See the
[photo color contract](color-contract.md) for the required declarations and
CPU/Metal support. The preparation commands below retain their existing meaning.

## Setup

Run from the repository root with Python 3.10 or newer:

```bash
python3 -m venv lutools/.venv-lutprep
lutools/.venv-lutprep/bin/python -m pip install -r lutools/requirements-lutprep.txt
lutools/.venv-lutprep/bin/python -m lutools.lutprep spaces
```

On Windows, the interpreter is `lutools\.venv-lutprep\Scripts\python.exe`.
Dependencies are optional, isolated from native builds, and listed in
`requirements-lutprep.txt`. The CLI accepts OCIO-readable LUT formats, including
3D/1D CUBE, SPI1D and CLF. A source format may contain its own shaper or domain;
OCIO interprets those, not a second handwritten format parser.

## Batch Audit

```bash
lutools/.venv-lutprep/bin/python -m lutools.lutprep audit /path/to/presets
lutools/.venv-lutprep/bin/python -m lutools.lutprep audit /path/to/presets --verify-compile
```

The read-only inventory visits known formats in deterministic order without
following directory symlinks. Each entry records its input root, relative path,
metadata, diagnostics, and separate `read`, `compile` and `appearance` states.
One malformed file does not hide the rest. `--verify-compile` actually compiles
supported DCPs to temporary RLOOK files and reads them back; normal inspection
leaves compilation `not_run`. Compatible CUBE/RLOOK files are already prepared,
not newly compiled. Generic LUTs still need an explicit color contract.

`native_photo_compatible` is independent of `canonical`. Declared F-Log/F-Log2
with F-Gamut, or F-Log2C with F-Gamut C, can be imported directly when output is
BT.709. Explicit Log output receives native decoding and display rendering.
These contracts have native CPU and GPU implementations (`cpu_only=false`).
Auto falls back on backend failure; Force requires successful GPU execution.
`canonical` continues to mean F-Log2/F-Gamut to display-sRGB, so preparation
cannot silently pass through technical Log output as a canonical display LUT.
Use direct import for the supplied Fuji files; no resampling is needed.

XMP inspection records CRS fields, profile dependencies and table identifiers;
embedded payload bodies are omitted. It does not execute XMP or infer unknown
namespace semantics. XMP compilation remains blocked.

`summary.status=completed` means the inventory finished, not that every file
passed. Inspect the separate read/compile counters. An incomplete directory scan
sets `complete=false`, reports diagnostics and exits 2. A complete scan exits 0
even when individual presets fail. Appearance remains `unverified` until a
separate, appropriate reference check exists.

The [named-sample reference protocol](look-reference.md) distinguishes native
runtime agreement from source-renderer and controlled cross-camera evidence.

## Explicit Contracts

Use the LUT author's documentation, not the filename, to choose a contract.
Examples are in [examples/lut-contracts](../examples/lut-contracts/):

| Example | Required source meaning | Rendering location |
| --- | --- | --- |
| `srgb-creative.json` | display sRGB to display sRGB | RawLab neutral before LUT |
| `slog3-to-rec709.json` | S-Log3/S-Gamut3.Cine to Rec.709 gamma 2.4 | LUT already renders; no extra neutral curve |
| `slog3-look.json` | S-Log3/S-Gamut3.Cine to the same scene encoding | RawLab neutral after LUT |

`rec709-gamma24` means ideal black-zero BT.1886 / gamma 2.4, not the Rec.709
camera OETF and not sRGB. ACES spaces here describe encoding/primaries, not an
automatic ACES RRT/ODT. A scene-output LUT uses RawLab neutral unless the source
transform itself contains a display rendering and is declared display-output.

```json
{
  "version": 1,
  "input": {"space": "srgb", "reference": "display", "range": "full"},
  "output": {"space": "srgb", "reference": "display", "range": "full"},
  "interpolation": "linear"
}
```

Every signal declares all three fields. `reference` is `scene` or `display`;
display-to-scene is deliberately rejected. `range` is `full` (normalized 0..1)
or `legal10` (normalized 10-bit 64..940). `legal10` scales the actual signal;
it does not replace CUBE `DOMAIN_MIN/MAX`. This tool does not guess 8-bit legal,
12-bit legal, HDR peak luminance, camera-native primaries or an unknown transfer.

Source interpolation is explicitly `linear` or `tetrahedral`; the prepared CUBE
always uses the native trilinear path. Final display values are clipped to 0..1.
This is not perceptual gamut compression. The native F-Log2 input has the existing
0..1 clamp, so values already lost at that boundary cannot be recovered by baking.

## Inspect And Prepare

The bundled identity example is intentionally untagged. This command composes a
neutral starting image with a no-op sRGB creative LUT:

```bash
mkdir -p output/lutprep
lutools/.venv-lutprep/bin/python -m lutools.lutprep inspect \
  lutools/examples/lut-contracts/identity.cube
lutools/.venv-lutprep/bin/python -m lutools.lutprep prepare \
  lutools/examples/lut-contracts/identity.cube output/lutprep/neutral.cube \
  --contract lutools/examples/lut-contracts/srgb-creative.json --size 65
```

If the error gate fails, the CLI prints its measurement report and exits with
status 2; no destination is created or replaced. Try `--size 129`
for a denser grid. To inspect an explicitly approximate result, re-run with
`--allow-approximation`; inspect the returned report before accepting the look.
Do not blindly increase `--max-error` just to suppress a failure.

Grid sizes are 2..129, default 65. `--max-error` defaults to 0.02 in absolute
display-sRGB channel units (roughly 5.1 eight-bit codes), not Delta E. The report
contains max, mean and p99 channel errors for full-domain, gray and scene samples.
The identity example itself can fail this conservative full-domain gate: a
uniform F-Log2 grid poorly resolves some extreme colors near sRGB clipping. That
is a limitation of baking this transform, not an unidentified source contract.
Validation reads the serialized output with trilinear interpolation and compares
it against the direct composition. Samples are deterministic, not an exhaustive
or mathematical error bound. A larger grid is not guaranteed to reduce the
maximum at every sample, especially near clipping boundaries.

Legacy compatible Fuji-style 3D CUBEs with `Gamma`/`Gamut` declarations pass
through byte-for-byte when no manifest is supplied. An explicit conflicting
`OutputTransfer` disables passthrough. Untagged files, 1D/shaper files and
Log-output files need an explicit contract instead. Existing native restrictions
remain in force; the preparer does not simply rename an incompatible source LUT.

Source files are never written. Destinations require `--force` to replace. Source
and destination aliases, including hard links, are rejected. Validation happens
before atomic installation; failed runs remove temporary output. Baked files
embed `#RawLab:` JSON metadata with source basename, contract and error report.

## Custom OCIO Spaces

Name custom spaces with the `ocio:` prefix and declare which config space is
scene-linear sRGB, D65. The reference is an author-supplied assertion; its physical
meaning cannot be inferred from an arbitrary OCIO name. It must not be ACEScg,
camera-native RGB, a data space, or display-linear RGB after tone mapping.

```json
{
  "version": 1,
  "input": {"space": "ocio:My Camera Log", "reference": "scene", "range": "full"},
  "output": {"space": "srgb", "reference": "display", "range": "full"},
  "interpolation": "tetrahedral",
  "ocio": {"config": "config.ocio", "reference_space": "Linear sRGB"}
}
```

The config path is relative to the manifest. Built-in names retain their fixed
meaning. Custom OCIO transforms may use config search paths/resources, which must
be available during preparation; native rendering only needs the finished CUBE.
Only the config basename is embedded, so archive the original manifest/config
separately when reproducibility across machines matters.

## DCP Appearance Adaptation

```bash
lutools/.venv-lutprep/bin/python -m lutools.lutprep inspect /path/to/profile.dcp
lutools/.venv-lutprep/bin/python -m lutools.lutprep compile-dcp \
  /path/to/profile.dcp output/lutprep/profile-look.rlook
```

`compile-dcp` is the preferred DCP path. It stores the input/output matrices,
normalized original HSV table, exposure multiplier and 4097 tone samples in a
bounded, versioned binary file. The core evaluates these stages with double
intermediates directly from common scene-linear sRGB. It never encodes F-Log2 or
samples an intermediate RGB CUBE. Typical tested profiles are about 310 KB.
See the [native format contract](../../docs/superpowers/specs/2026-10-03-native-dcp-look-design.md).

Native DCP runs on **CPU or Metal**. Metal acceleration uses float32 arithmetic
and requires macOS 15+/iOS 18+; CPU remains the double-precision reference. GPU
Auto falls back to CPU if Metal is unavailable or a stage produces nonfinite
values. Force reports failure rather than disguising CPU work as GPU work.
Windows/GLES native-DCP acceleration is not implemented, so those backends still
use CPU in Auto and fail in Force. Existing CUBEs keep their CPU/GPU paths. `--force` and
`--ignore-dcp-exposure` are available for compilation, with the same source-file
protection as baking. `inspect` can read the compiled package's metadata.

`prepare profile.dcp profile.cube --size 129` remains available for clients that
only accept CUBE, subject to the original approximation gate. Native `.rlook`
removes that RGB baking error for DCPs; it does not solve generic source-LUT baking,
or establish Lightroom/camera color equivalence. Version 1 packages remain readable.
Version 2 adds an optional calibration table and allows an absent LookTable,
with the [extended format contract](../../docs/superpowers/specs/2026-10-03-dcp-hsm-metal-design.md).

No generic RGB manifest is accepted for DCP. This path adapts the following stages:

- The explicit D65 `ColorMatrix` and corresponding `ForwardMatrix` reconstruct
  the input expected by the profile. The illuminant tag selects the pair, not
  its position in the file. A D65 pair in slots 1, 2 or 3 is supported.
- `ProfileHueSatMap`: an optional calibration stage before profile EV and
  LookTable. A shared Data1 is used when no Data2 exists; dual-table profiles
  select the table paired with the explicit D65 matrix. Triple-illuminant HSM
  requires interpolation not implemented here and is rejected.
- `ProfileLookTableDims/Data/Encoding`: HSV table in linear ProPhoto RGB, with
  hue wrapping and value/hue/saturation table order. Encoding 1 applies sRGB to
  the value coordinate and its value scaling, not to all RGB channels.
- `ProfileToneCurve`: natural cubic interpolation sampled to a 4096-interval
  table, then hue-preserving RGB application, not three independent RGB curves.
- `BaselineExposureOffset`: by default a linear EV adjustment after HSM and before the look;
  omit it with `--ignore-dcp-exposure`. This does not include the RAW file's
  baseline or RawLab's +0.7 EV and does not emulate Adobe's exposure-tone stage.

The input bridge is **not** a generic sRGB-to-ProPhoto conversion. Camera Matching
look tables can depend on their profile's matrix stages. With column vectors,
the adapter uses `P^-1 F diag(1 / (C W)) C M`, where `M` maps linear sRGB to XYZ
D65, `C` is the source D65 ColorMatrix, `F` maps source white-balanced camera
values to D50 XYZ, `P` is ProPhoto-to-XYZ D50 and `W` is the D65 reference white.
ForwardMatrix rows are normalized to the same D50 white used by `P`.

This explicitly defines a **white-relative virtual camera**, not a simulation of
the source sensor's absolute exposure. Virtual camera values are `C XYZ / max(C W)`;
the camera WB white is `C W / max(C W)`, so that maximum cancels. A global scaling
of ColorMatrix therefore does not introduce another exposure offset. No Bradford
adaptation is inserted before `C` or after `F`; `F` already outputs D50. The final
ProPhoto-to-sRGB output conversion includes D50-to-D65 adaptation as before.

After this bridge, the supported SDR domain is clipped, look/tone is applied,
then output is converted to display-sRGB. No second RawLab neutral curve is applied.
The target RAW's own calibration, WB and baseline are unchanged. Individual camera
calibration, AnalogBalance and automatic black rendering are not emulated. This
is not bit-exact SDK/Lightroom rendering or proof of cross-camera color accuracy.

The supported subset requires exactly one explicit D65 ColorMatrix/ForwardMatrix
pair with valid 3x3 matrices and an explicit tone curve. HSM and LookTable can be
absent, but partially declared/malformed tables are rejected. Missing/ambiguous
calibration, a singular ColorMatrix, nonpositive reference-white responses,
triple-illuminant HSM, spatial gain maps, HDR/dynamic-range tags, RGB tables,
unknown encodings and sRGB-encoded tables without a value axis are rejected rather
than silently skipping their required context. Both byte orders, two/three-dimensional table
declarations and omitted zero-saturation planes are handled. Safety limits are
128 MiB per profile, 4096 IFD entries, 4 million HSV cells and 8192 tone points.
Native packages limit both tables together to 4 million cells and 64 MiB total.

### Profiles Without ToneCurve

A missing `ProfileToneCurve` does **not** imply an identity curve. Adobe's SDK
renderer supplies its own default curve and, unless disabled by the profile,
default black processing. The preparer does not silently infer either.

To choose an external curve explicitly, pass a UTF-8 JSON array of linear
ProPhoto `[x,y]` pairs. The normal tone validation/interpolation applies. An
external curve cannot replace an existing profile curve. For new HSM/external-tone
profiles that request or default to Auto black, `--no-auto-black` is also required:

```bash
lutools/.venv-lutprep/bin/python -m lutools.lutprep compile-dcp \
  /path/to/Adobe-Standard.dcp output/lutprep/calibration-test.rlook \
  --tone-curve lutools/examples/lut-contracts/identity-tone-curve.json --no-auto-black
```

This example selects an identity tone and omits automatic black. It is a useful
calibration-stage test, **not** a reproduction of Adobe Standard rendering.
Metadata records `tone_source`, `black_render_policy` and the selected HSM tag.
Pre-existing no-HSM profiles retain their prior black-handling behavior, also
recorded in metadata. Original DCP files are never changed.

Adobe profile data is not bundled or redistributed by this implementation. Use
profiles you have access to and keep derived LUTs under ignored `output/`.
The result is an adapted appearance, not the camera's proprietary recipe or a full
Lightroom Develop implementation. FL2/FL3 require actual corresponding profiles;
they cannot be reconstructed merely by renaming FL.

**Regenerate DCP CUBEs produced by preparer 1.0 from their original DCPs.** Version
1.0 discarded the source input matrices and could turn blue sky purple. Version
1.1 adds the D65 adapter and records `input_adapter` and `input_calibration_tags`.
Copying an old CUBE byte-for-byte does not repair its already baked transform.

## Clients And Verification

macOS and Windows custom look pickers accept `.cube` and `.rlook`. Import the
**prepared or compiled** file, not the source DCP or JSON. iOS/Android share the
native core, but their current interfaces have no custom-LUT file picker. In-app
generic color selectors and mobile import are not part of this first delivery.

```bash
cmake --build lutools/build-macos -j 6
RAWLAB_DCP_PROBE=lutools/build-macos/dcp_look_tests \
  lutools/.venv-lutprep/bin/python -m unittest discover -s lutools/tests -p 'test_*.py' -v
ctest --test-dir lutools/build-macos --output-on-failure
lutools/build-macos/acceleration_tests lutools/examples/DSC06251.ARW output/lutprep/profile-look.rlook
lutools/build-macos/acceleration_tests lutools/examples/DJI_20250602164503_0444_D.DNG output/lutprep/profile-look.rlook
```

The last two commands require a configured Metal build and local RAW fixtures.
With `.rlook` on Mac they require actual Metal and CPU parity, plus cache/export
behavior. The native unit suite separately verifies Auto fallback and Force
failure for nonfinite GPU stages. With a compatible `.cube` they still require actual
CPU/GPU parity. Neither proves the adapted look is identical to Lightroom. Windows/GLES device checks remain
separate platform verification.

The optional real-profile regression uses `RAWLAB_TEST_CANON_DCP` pointing to
`Canon EOS R5 Camera Standard.dcp`. It checks the DJI sample's scene-linear blue-sky
color without storing or redistributing Adobe table data in the test suite.

## References

- [RawLab color contract](color-contract.md), especially F-Log2 and neutral rendering.
- [OpenColorIO Python API](https://opencolorio.readthedocs.io/en/latest/api/index.html).
- [Adobe DNG specification and SDK](https://helpx.adobe.com/camera-raw/digital-negative.html).
- Adobe reference algorithms in [dng_reference.cpp](https://github.com/LineageOS/android_external_dng_sdk/blob/lineage-23.2/source/dng_reference.cpp),
  [dng_spline.cpp](https://github.com/LineageOS/android_external_dng_sdk/blob/lineage-23.2/source/dng_spline.cpp)
  and [dng_camera_profile.cpp](https://github.com/LineageOS/android_external_dng_sdk/blob/lineage-23.2/source/dng_camera_profile.cpp).
  Their Adobe copyright/notice is retained in the extractor and the existing
  [DNG SDK license](../third_party/Adobe-DNG-SDK-LICENSE.txt).
