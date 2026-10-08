# Look Reference Protocol

This protocol measures named, synthetic scene-linear samples. It does not
certify camera calibration, Lightroom parity, or a manufacturer's JPEG engine.
Keep these evidence levels separate:

1. Parsing and compilation: the source is understood and the prepared file is valid.
2. Runtime: a prepared look runs on a particular RAW and backend.
3. Named-sample agreement: the native look stage agrees with a declared independent evaluator.
4. Appearance and cross-camera quality: controlled source-software exports and paired RAWs agree under recorded conditions.

## Frozen Inputs

[`samples.json`](../examples/look-validation/samples.json) contains 20 named
scene-linear sRGB/D65 triples: gray, skin-like, sky, foliage, saturated,
negative and superwhite samples. These are not measured ColorChecker patches.
Inputs are rounded once to little-endian float32, matching the native probe.
The report retains those exact values, sample order and categories.

Freeze the source preset, compilation policy, prepared RLOOK and reference
conditions before changing rendering math. `preset.sha256` identifies the exact
prepared bytes; `preset.metadata` includes the source name, preparer version,
supported stages, tone/black choices and exposure policy. Keep the original
source and its identity privately alongside the report. Do not commit or
redistribute proprietary profiles or photographs.

## Native Evaluation

Build the existing `dcp_look_tests` target, then run from the repository root:

```bash
lutools/.venv-lutprep/bin/python -m lutools.lutprep.reference evaluate \
  /path/to/look.rlook --probe lutools/build-macos15-arm64/dcp_look_tests \
  > output/native-samples.json
```

An optional `--samples /path/to/samples.json` selects another explicitly frozen
sample document using the same schema. The tool invokes the real native CPU
`--evaluate` entrypoint, checks its exit status, exact byte count, finite values
and display-sRGB range, then emits JSON. It never changes source or look files.
The report labels its evaluator `internal`, reference `not_supplied`, and
appearance `unverified`. Successful execution is not a reference pass.

The tool currently evaluates RLOOK stages, not arbitrary CUBE/RAW files. Generic
LUT approximation uses the existing `prepare` report; full-image runtime checks
use the existing native acceleration/export tests.

## Independent Reference

Obtain outputs using an independent SDK or source-software path capable of
accepting the same scene-linear samples and explicit policy. A full Lightroom
RAW export is a different kind of evidence and cannot be inserted as these
look-stage samples without establishing an equivalent input boundary.

The external report uses `schema_version=1`, matching `input_space`,
`output_space`, `preset`, and ordered `samples`. Each sample contains `id`,
`category`, `input_rgb`, and independently produced `output_rgb`. Its evaluator
must contain:

```json
{
  "name": "Independent renderer name",
  "version": "Exact tested version",
  "kind": "independent",
  "provenance": "Reproduction command, source files and policy notes"
}
```

Record the source file/profile, input boundary, WB, exposure, base rendering,
look amount, tone curve, black treatment, automatic corrections, output transfer
and gamut in the provenance or its linked local evidence. Shared metadata means
conditions are intended to match, not that a program has authenticated them.
Do not relabel RawLab or the existing Python evaluator as an independent oracle.

```bash
lutools/.venv-lutprep/bin/python -m lutools.lutprep.reference compare \
  output/native-samples.json /path/to/independent-samples.json \
  --max-error 0.000002 > output/sample-comparison.json
```

Choose and document the tolerance from reference precision/repeatability before
comparing. The example is a strict numerical tolerance, not a universal visual
threshold. The tool rejects mismatched conditions, missing evaluator details,
nonfinite values, out-of-range output and self-reference. It reports maximum,
mean and p99 absolute display-sRGB channel error, plus per-category errors for
gray/highlights and the other groups. Exit 0 means named-sample agreement, 1
means its explicit error threshold failed, and 2 means invalid conditions/input.
No Delta E, perceptual certification or exhaustive error bound is implied.

## Controlled Camera Evidence

For cross-camera quality, photograph the same static scene with each target
camera under repeatable daylight, warm light and LED conditions. Include a
neutral gray card, a measured chart, skin/sky/foliage equivalents, saturated
colors and a highlight ramp. Retain original RAWs and source-renderer exports.
Record camera/lens/firmware, illuminant, exposure normalization, WB method,
base profile, look version/amount and output encoding; disable or record all
automatic/local/adaptive operations.

Compare target RAW calibration and look-stage behavior separately. Record gray
and exposure offsets, highlight clipping, representative color/hue differences,
and controlled side-by-side appearance. Freeze visual thresholds only after
reference repeatability is known. Unrelated Sony/DJI scenes prove runtime
coverage, not same-scene calibration. Missing references and paired RAWs remain
`not_supplied`/`unverified`; they are not zero-error passes.
