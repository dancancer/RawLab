# Master recipe settings

`Shared/master-recipes.json` is the catalog used by macOS, iOS, Android and
Windows. A recipe is an editable starting point: applying it writes its visible
controls once. Rendering, reopening a photo, restoring a preset and resuming a
batch must not look up and reapply catalog defaults.

## Settings versions

The recipe settings version is independent of the adjustment payload version,
preset registry version, processing version, batch journal version and Agent
JSON schema version.

| Version | Recipe strength applies to |
| --- | --- |
| 2 | LUT, exposure, shadows, highlights, contrast, saturation and relative tint; saved HSL remains independent |
| 3 | Version 2 controls plus the current visible HSL values |
| 4 | Version 3 controls plus black/white point, vibrance, curve, three grading wheels, clarity and dehaze |

Old macOS records without a marker use version 2 and fold the six additive
defaults into their saved controls once. `legacyDefaults` freezes those original
catalog values; subsequent tuning must never change them. Old iOS, Android and
Windows records without a marker use their already-released version 3 behavior.
Explicit version 2 transfer payloads retain version 2 HSL behavior on every
client. Unsupported versions are rejected.

New catalog entries specify version 4 and complete `tone`, `curve`, `grading`
and `atmosphere` objects, including identity values. Explicitly applying a v4
recipe replaces these groups, the old six controls and HSL, resets the legacy
S-curve amount to zero, and sets strength to 100%. Independent temperature,
denoise, sharpening, lens, geometry, grain and vignette settings are preserved.
Reapplying a recipe is the deliberate opt-in to new defaults; merely reopening
an older edit does not upgrade it.

## Strength and visible controls

All formulas use the current stored controls, including subsequent manual edits.
Changing strength never rewrites the controls stored in the photo.

- Signed new scalar controls scale around zero and clamp to `[-100, 100]`.
- Grading scales saturation only, clamped to `[0, 100]`; the selected hue stays
  available at zero saturation.
- A custom curve keeps each x coordinate and scales its displacement from the
  identity line: `y' = x + strength * (y - x)`. Zero strength is identity; 100%
  retains the original points. Other strengths clamp y to `[0, 1]` and use a
  left-to-right nondecreasing envelope. Fixed endpoints remain `(0, 0)` and
  `(1, 1)`, including extreme manual curves at 200%.
- The legacy S-curve amount also follows strength for v4. Custom mode suppresses
  that amount, as it does outside a recipe.

At zero strength, all recipe-owned contributions are neutral. Independent
effects and input processing remain active. A zero-strength recipe is therefore
not a request to disable denoise, geometry or grain.

LUT strength above 100% retains the existing extrapolation between the neutral
and LUT outputs. It can amplify local color reversals in a LUT, including cyan
patches in bright skin tones. A monotone adjustment curve and CPU/GPU parity do
not guarantee acceptable color at these strengths. Inspect high-strength output
visually; the v4 parameter refinement does not change this LUT behavior.

## Transfer, presets, batch and Agent

A complete recipe transfer preserves logical values, strength and settings
version. Completeness is version-dependent: v4 also requires all new owned
fields. Partial transfer materializes the selected effective values once. When
the destination retains a recipe context, the adapter solves for representable
logical values and verifies the result; a context change preserves unselected
effective values. Unrepresentable values are rejected instead of silently
changing the image. Removing a recipe materializes every owned field.
This includes direct selection of another film, “no recipe”, and imported looks,
as well as the reset workflow. A failed conversion leaves the existing edit and
selection intact. Direct selection retains the current LUT strength for the next
film; resetting the look group restores that control to 100%.

Photo edits, user presets and frozen batch settings retain the marker and saved
manual values. Agent export uses the same effective values as native rendering,
without an additional recipe multiplier in the exported document.

## Catalog refinement policy

Reference images provide visual direction, not paired color ground truth.
Scene, light, camera and earlier edits differ, and author metadata alone does
not establish attribution. Exclude conflicting author metadata, duplicates,
nonphotographic content and scenes outside a recipe's stated target. Handle
embedded ICC profiles before comparing reference appearance. Keep originals
read-only and reference inventories outside the repository.

The v4 catalog retains all existing LUTs and HSL values. Curves, endpoint controls
and weak grading separate adjustments formerly concentrated in global contrast,
saturation and tint:

| Recipe | Refinement |
| --- | --- |
| Hamada / Sakai | Reduce the uniform lifted-black offset; shape the shadows, midtones and highlight transition separately |
| Yasui / Billy Dinh | Reduce crushed shadows from stacked contrast; retain dark structure with a restrained curve and cool/warm grading |
| Jungraphy | Reduce global magenta tint and saturation; use vibrance and shadow grading for more selective color |
| withluke | Gentle endpoint and curve control, with weak cool shadows and warm highlights |
| rkrkrk | Moderate global saturation and contrast; use vibrance and a bounded curve |
| Samalive / Iwona | Reduce flat shadow offset; retain warm highlights with curve and grading controls |
| CineStill 800T | Moderate saturation and highlight transition without attempting halation |
| Daniel Casson / Wilson Lee / Luiz Clas / Ivan Ivanchenko | Retain the existing color parameters; new controls remain neutral pending a stronger reference basis |

Default clarity and dehaze remain zero. Their nonzero values require the CPU
photo path under the [atmosphere contract](../../lutools/docs/atmosphere-v1.md);
adding them indiscriminately would alter both existing atmosphere and rendering
cost. The current controls do not produce local lighting, optical blur or real
halation.

Validation should compare actual native output with explicit manual parameters
at 0%, 50%, 100% and 200%, include CPU/available hardware-GPU parity, legacy
restoration, selective transfer, presets, Agent and frozen batch output. Visual
review needs both whole frames and full-resolution regions across varied scenes.
Per-run measurements and platform limitations belong in the PR evidence.
