# Fixed Style / Manual Tone Region Experiment

Date: 2026-10-10

## Delivered Scope

The macOS AI candidate sheet now separates the existing 40 style parameters
from four manually editable tone-region boundaries. Local region edits never
request AI, never change the frozen style, exposure or white balance, and
retain a default-region comparison rendered at the same strength.

- Default boundaries: `0.2, 0.6, 0.4, 0.8`.
- Coordinate: Oklab L after the style curve and hue-band lightness lift.
- Native compile v1/40 is unchanged. Native compile v2 takes 44 floats.
- The AI response JSON remains v1/40; refinement includes the previous actual
  region values as context and resets a newly generated style to defaults.
- Pending or failed adaptation cannot apply/export a stale candidate. Stop
  restores the last successfully rendered values. Both comparison frames are
  committed together only after successful rendering.
- Private CUBE metadata stores style, boundaries, model and bake report.
  Public CUBE export strips private metadata and keeps the resolved table.
- No KNN, automatic exposure/WB, spatial masks, new service or photo upload
  was added. Existing Hamada v1/v2/v3 artifacts were not modified.

## Reproduction

```sh
bash RawLabMac/build.sh
bash experiments/ai-color-match/tone-regions.sh \
  experiments/ai-color-match/tone_regions.json \
  output/adaptive-tone-regions-new
```

The driver requires a new output directory, reads the authorized NAS RAWs,
and checks source file identity before/after each render. The checked-in JSON
contains local sample paths and hand-set boundaries. The driver fixes one
synthetic style for every image: identity tone/hue stages, chroma 0.85,
shadow tint `(-0.006, -0.009)`, midtone `(0.002, 0.003)`, highlight
`(0.001, 0.007)`. Strength is 1.0 and all other settings are identical between
the two arms. This is not the HLS Hamada v3 transform or a newly inferred AI
style. Boundaries are trial settings, not learned or human-approved labels.

Outputs: `output/adaptive-tone-regions/overview.jpg`, plus per-scene neutral,
fixed, manual and side-by-side JPEGs, `manual.cube`, and `record.json` with
the complete recipe, boundaries, settings and bake reports.

## Numerical Results

All five scenes use 65-grid CUBEs. The fixed look's maximum sampled channel
error is `0.0024627042`. The unchanged acceptance gate is `0.02`.

| Scene | Manual boundaries | Manual max error |
| --- | --- | ---: |
| Foliage / DSC08882 | 0.08, 0.40, 0.65, 0.95 | 0.00057916436 |
| White building / _DSC9078 | 0.10, 0.45, 0.65, 0.95 | 0.0023716271 |
| Sea / _DSC9094 | 0.12, 0.45, 0.60, 0.90 | 0.0030229115 |
| Portrait / _DSC9334 | 0.08, 0.40, 0.65, 0.95 | 0.00057916436 |
| Snow / DJI_20250220115702_0068_D | 0.08, 0.40, 0.75, 1.00 | 0.00057916436 |

These are approximation errors for the resolved transform, not style-match
scores. Identical reports for some scenes are expected: this gate samples
the transform's RGB domain, not the scene's pixels.

## Visual Assessment

The overview was inspected with neutral, fixed and manual arms side by side.
Manual boundaries visibly change where cool-shadow and warm-highlight tints
appear without changing overall style parameters. Some pale building/snow
areas look less tinted; changes in the portrait and sea scene are subtle,
and there is no consistent, obvious improvement across all five images.
This is a preliminary subjective assessment, not a blinded preference test.

The experiment establishes an editable, reproducible adaptation mechanism,
not the superiority of these particular settings. Do not train KNN on this
configuration as ground truth. A next training stage requires manually
confirmed per-scene choices and an independent scene-level evaluation.
Zero toning, or identical tints in all three regions, cannot benefit from
moving these boundaries. The existing Hamada v3 CUBE is not adapted by them.

## Verification

- Red: new native v2 acceptance test failed against the old compiler. New
  Swift region/model tests failed to compile before those interfaces existed.
- Green: `ctest --test-dir lutools/build-macos --output-on-failure`: 19/19.
- After adding dense actual-transform weight checks, the `color_recipe`
  target was rebuilt and rerun successfully. Coverage includes v1/default-v2
  agreement, changed nonzero toning, unchanged zero-toning identity,
  nonnegative normalized weights, invalid boundaries and the original gate.
- `bash RawLabMac/tests/ai-data.sh`: passed, including separate region
  serialization/validation and accurate refinement context.
- `bash RawLabMac/tests/ai-workflow.sh <DSC08882.ARW>`: passed. Verified no
  additional HTTP calls for region/strength edits, immutable style,
  equal-strength fixed/adapted frames, cancellation, a real local render
  failure with preserved prior frames and blocked export/apply, retry,
  manual-region installation, persistence, restoration and stale-edit guards.
- `bash RawLabMac/tests/ai-render.sh <DSC08882.ARW> output/adaptive-tone-regions/foliage/manual.cube`:
  CPU/Metal max difference 1 DN at strengths 0, 1 and 2. Full-resolution
  4672x7008 JPEG and 16-bit PNG single/batch exports had identical pixels.
  Source RAW identity was unchanged.
- `bash RawLabMac/build.sh`: passed, including bundled dependency/signature
  check. Output: `build/RawLab Mac.app`.
- Native UI: local fixture with synthetic URLProtocol response, no network
  upload. Expanded four sliders, selected fixed comparison, changed shadow
  start from 0.10 to 0.15 and waited for successful preview, reset all four
  values, and inspected at 1000x740 and 820x660 content sizes. No text/control
  overlap was observed. The fixture was closed after inspection.
- `git diff --check`: passed. No commit or push was performed.

The GUI fixture is repeatable with:

```sh
RAWLAB_AI_UI=1 bash RawLabMac/tests/ai-workflow.sh \
  /Volumes/boom-data/Photo/2025/2025-06-30/DSC08882.ARW
```

The production app was rebuilt but an already running user editor was not
terminated or restarted. No real external AI request was made in this phase.

## Integration With Current Main

The AI branch was fast-forwarded to `origin/main` at
`4dc329c6a36f2e54d7b42e82575f99f977f8cd39` before restoring the scoped AI
changes. Main's GPU denoising, vignette/grain, photo information, export-size
and batch-export code remains in place. The AI workflow test now explicitly
checks that its baseline preserves photo effects and application preserves
the editor's export-size setting. Its build script includes the shared photo
information source required by the current editor.

Checks rerun against the integrated tree:

- Core CTest: 21/21 passed, including photo effects and Metal denoising.
- Mac application build and bundled dependency/signature check: passed.
- AI data and real-RAW workflow: passed.
- AI CUBE real-RAW CPU/Metal comparison: maximum 1 DN at strengths 0, 1 and 2;
  full-resolution JPEG/16-bit PNG single and batch outputs remain identical.
- Photo information tests: passed.
- Real-RAW vignette/grain tests: passed; native preview and 16-bit PNG matched,
  with CPU/Metal differences at most 1 DN.
- Staged diff whitespace check: passed. No generated photos, application
  bundles, credentials or unrelated platform changes are part of the commit.
