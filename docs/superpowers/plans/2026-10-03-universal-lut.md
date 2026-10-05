# Universal LUT Preparation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare explicitly described external LUTs and adapted DCP appearances for any RAW supported by RawLab.

**Architecture:** An optional offline Python adapter outputs the existing canonical CUBE contract. Native RAW decoding, C ABI, CPU and GPU rendering stay unchanged. Source data and camera calibration stay separate.

**Tech Stack:** Python unittest, NumPy, PyOpenColorIO, existing C++17 CTest/Metal regressions.

**Spec:** `docs/superpowers/specs/2026-10-03-universal-lut.md`

## Global Constraints

- Python 3.10+, NumPy >=1.26,<3, OpenColorIO >=2.4,<3. No change to the C ABI.
- Sources are read-only; no implicit overwrite or color-space guessing.
- Output is F-Gamut/F-Log2 to SDR display-sRGB, R-fast CUBE, native trilinear.
- No RAW calibration, WB, or RAW exposure baselines are baked into generic LUTs.
- No Adobe profile data is committed. No commit/push/publication is requested.

---

### Task 1: Contract And Generic LUT Composition

**Files:** Create `lutools/lutprep/{__init__,contract,color,pipeline}.py`,
`lutools/requirements-lutprep.txt`, `lutools/tests/test_lutprep.py`.

**Interfaces:** `Contract.from_dict(data)` validates a v1 manifest;
`ColorSpaces(config=None, reference_space=None).convert(rgb, src, dst)` returns
float RGB arrays; `LUTPipeline(source, contract).evaluate(flog2_rgb)` returns
display-sRGB. `neutral_linear` and `flog2_encode/decode` match native equations.

- [x] Write unittest cases before implementation, including:
  ```python
  with self.assertRaisesRegex(ValueError, 'input'):
      Contract.from_dict({'version': 1})
  np.testing.assert_allclose(flog2_decode(flog2_encode(rgb)), rgb, atol=1e-5)
  np.testing.assert_allclose(identity_display.evaluate(encoded), neutral, atol=2e-5)
  ```
- [x] Run `/tmp/rawlab-lutprep-venv/bin/python -m unittest discover -s lutools/tests -p 'test_lutprep.py' -v`; confirm missing implementation fails.
- [x] Implement strict field validation, OCIO color/file processors and branch-specific curve placement. Reject display-to-scene, unknown spaces and nonfinite transforms.
- [x] Re-run the same command; confirm round trips, legal range, CUBE domain and no-double-tone tests pass.

### Task 2: Baking, CLI And Non-Destructive Files

**Files:** Create `lutools/lutprep/{bake,__main__}.py`; extend `test_lutprep.py`;
create `lutools/docs/lut-preparation.md` and example JSON manifests.

**Interfaces:** `prepare(source, destination, contract=None, size=65,
max_error=0.02, allow_approximation=False, force=False, ...) -> dict` writes one
canonical cube and returns its report. `inspect_source(source) -> dict` is read-only.

- [x] Add failing CLI tests for unknown metadata, byte-identical legacy passthrough,
  serialized channel order, output metadata and protected files:
  ```python
  before = destination.read_bytes()
  with self.assertRaises(FileExistsError):
      prepare(source, destination, contract)
  self.assertEqual(destination.read_bytes(), before)
  ```
- [x] Run the tests and confirm the new cases fail.
- [x] Implement chunked baking, deterministic validation through OCIO INTERP_LINEAR,
  sampled error gate, atomic writes, embedded JSON, and CLI commands. Only canonical
  3D CUBE metadata can bypass resampling; source data must still parse successfully.
- [x] Run tests and execute documented CLI modes on synthetic or local inputs.

### Task 3: Separate DCP Looks

The original 1.0 matrix-separation assumption below was disproved by the DJI sky
regression. The 1.1 correction and replacement tests are recorded at the end.

**Files:** Create `lutools/lutprep/dcp.py`, `lutools/tests/test_lutprep_dcp.py`;
extend CLI, README and tests.

**Interfaces:** `DCPProfile.read(path)` reads TIFF-like DCP tags;
`profile.describe()` reports calibration/look separation;
`profile.evaluate(linear_srgb, apply_exposure=True)` returns display-sRGB.

- [x] Construct synthetic DCP fixtures with standard-library struct packing, no
  proprietary tables. Add failing tests for identity/colored look tables, encoded
  value scaling, hue-preserving tone mapping, both endiannesses, truncated IFDs,
  unsupported tags and unchanged results when only camera matrices change.
- [x] Run `python -m unittest discover -s lutools/tests -p 'test_lutprep_dcp.py' -v` and confirm failures.
- [x] Implement bounded tag decoding and the documented DNG look-only operations.
  Exclude camera calibration explicitly; support explicit profile exposure opt-out.
- [x] Run synthetic tests, then inspect and locally prepare the available Sony
  profiles in ignored `output/`; do not fabricate missing FL2/FL3 profiles.

### Task 4: Native Integration And Final Review

**Files:** Extend `lutools/docs/color-contract.md`, `lutools/README.md` and plan
verification record. Add a small native integration test only if existing probes
cannot consume prepared files.

- [x] Run Python tests and compare serialized cube interpolation to direct evaluators.
- [x] Build `lutools/build-macos`; pass prepared cubes into `acceleration_tests` with
  `DSC06251.ARW` and `DJI_20250602164503_0444_D.DNG`; require real CPU/Metal parity.
- [x] Run `ctest --test-dir lutools/build-macos --output-on-failure`.
- [x] Request a scoped read-only review of contract/curve placement, data integrity
  and tests; fix only supported findings and re-run affected checks.
- [x] Record commands, measured results and platform/UI limits; inspect `git diff
  --check` and final changed-file scope. Leave changes uncommitted for the user.

## Verification Record (2026-10-03)

This section records version 1.0. Its DCP appearance and numerical results are
historical, not acceptance evidence for the corrected 1.1 adapter below.

- Installed the documented optional environment at `lutools/.venv-lutprep`:
  Python 3.11.9, NumPy 2.4.6, OpenColorIO 2.6.0. No native dependency changes.
- `lutools/.venv-lutprep/bin/python -m unittest discover -s lutools/tests -p
  'test_lutprep*.py' -v`: 52 passed. Feature tests ran red before implementation;
  later regressions reproduced OCIO stale source caching, hue wrap at tiny negative
  shifts, unsafe OCIO data references and BYTE-profile-name JSON failure before fixes.
- `cmake --build lutools/build-macos -j 6`: passed. CTest: 8/8 passed, 47.13 s.
  No C/C++ core, shader, ABI or application source changed.
- `acceleration_tests` with `output/lutprep/sony-a7c2/FL-129.cube`: both
  `lutools/examples/DSC06251.ARW` and `DJI_20250602164503_0444_D.DNG` passed;
  actual Metal backend confirmed, CPU/Metal max difference 1 DN. Interactive cache,
  exact/FINAL and file-export assertions passed.
- Reused `experiments/ektar100-phuket-v1/raw_probe.cpp` against the freshly built
  core to decode full RAW, reduce in linear space to 400-pixel long edge, then apply
  the prepared LUT through native `LUTApplicator`. Native vs OCIO trilinear max
  difference was `1.78814e-7` for both fixtures.
- Direct DCP evaluation vs the 129-grid native-compatible bake on those reduced
  RAW samples: Sony max `0.0133958`, p99 `0.00572645`; DJI max `0.0135715`, p99
  `0.00416788`. These are channel errors, not Delta E or Lightroom parity.
- Native CLI exported `output/lutprep/sony-fl.jpg`; visual inspection confirmed
  a nonblank, correctly oriented image without obvious channel/order corruption.
- A fresh scoped review found the valid TIFF BYTE `ProfileName` case. Confirmed
  `ttByte=1` from Adobe source (not type 7), added failing CLI tests, decoded BYTE
  text and made unsupported metadata types fail explicitly. All 52 tests passed.

### Local Look Outputs And Quality Limits

Nine 129-grid looks are under ignored `output/lutprep/sony-a7c2/`: BW, FL, IN, NT,
PT, SH, ST, VV, VV2. Adobe source tables and generated CUBEs are not part of the
source changes. These files were generated with explicit `allow_approximation`
for local evaluation; only BW and IN passed the default full-domain maximum-error
gate. The remaining looks must not be represented as having passed that gate.

| Look | Sampled Max | Scene p99 | Default 0.02 Gate |
| --- | ---: | ---: | --- |
| BW | 0.003220 | 0.000762 | pass |
| FL | 0.054696 | 0.002942 | fail |
| IN | 0.018982 | 0.002595 | pass |
| NT | 0.032005 | 0.003051 | fail |
| PT | 0.037474 | 0.004374 | fail |
| SH | 0.043323 | 0.005244 | fail |
| ST | 0.029490 | 0.004236 | fail |
| VV | 0.065777 | 0.004565 | fail |
| VV2 | 0.051943 | 0.005316 | fail |

The 65-grid sRGB identity example also fails the conservative gate (max 0.494203
over stress samples). This demonstrates a real representational limit near
clipping boundaries: static baking is not a universal precision guarantee. The
CLI returns a report and leaves output untouched unless approximation is explicit.
Transforms failing this gate need accepted approximation or a future direct
runtime transform path; increasing grid size alone is not a universal solution.

FL2/FL3 sources were absent. No mobile custom-file UI, Windows/GLES hardware run,
all-camera calibration, Adobe full renderer, automatic untagged-LUT inference,
or direct runtime fallback was implemented or claimed. Changes remain uncommitted.

## DCP Sky Regression Correction (1.1)

The DJI Pocket 3 sample with Canon R5 Camera Standard rendered blue sky purple.
Direct evaluation, serialized CUBE and native rendering all showed the same
large hue error; disabling profile EV did not remove it. The source DCP's look
table expected its matrix input stages, which version 1.0 had discarded.

- Added the D65 white-relative virtual-camera input bridge documented in
  `lutools/docs/lut-preparation.md`. Target RAW sensor calibration, WB and exposure
  baselines are unchanged; this is not a full Adobe renderer.
- Replaced the incorrect source-matrix-invariance test with matrix projection,
  white-relative scale invariance, illuminant slot selection and rejection tests.
  Added an optional real Canon profile blue-sky regression, reproduced red on 1.0.
- Reject missing/ambiguous D65 matrix pairs and unsupported ProfileHueSatMap
  stages instead of silently applying a context-free look table.
- Ran all 58 Python tests with `RAWLAB_TEST_CANON_DCP` pointing to the local
  `Canon EOS R5 Camera Standard.dcp`: passed, including the real-profile test.
- Re-rendered six RAW models across seven profiles, 42/42 finite numerical
  passes. Native vs OCIO trilinear max error: `1.78814e-7`. These are execution
  and interpolation checks, not proof of camera/Lightroom appearance parity.
- DJI Canon Standard sky ROI native hue changed from `266.856` to `210.773`
  degrees; direct corrected evaluation is `210.918`. No WB, saturation, selective
  hue or tone-curve workaround was added. The Nikon, Panasonic and Ricoh samples'
  obvious purple shift also disappeared in the reviewed contact sheet.
- Ran `acceleration_tests` on the actual DJI RAW with the corrected Canon CUBE:
  real Metal confirmed, CPU/Metal max 1 DN for WB 0/4000/8500 and adjustments;
  interactive cache, FINAL and file-export assertions passed.
- A scoped independent read-only review found no further concrete matrix-order,
  white-normalization or failure-branch defect. It confirmed the real-profile
  regression is optional in environments without the private Adobe fixture.
- Regenerated all nine local Sony 129-grid CUBEs and the earlier 65-grid FL CUBE
  under `output/lutprep/sony-a7c2/` with preparer 1.1. Original DCPs and RAW files
  remain untouched. Old diagnostic comparisons remain under `output/dcp-cross-camera/`.

Fresh artifacts are under ignored `output/dcp-cross-camera-fixed/`:
`dji-sky-before-after.jpg`, `cross-camera.jpg`, `sky-regression.json`, `report.json`.
The reproduction harness remains in `output/dcp-cross-camera/verify.py` with
`RAWLAB_VERIFY_OUT=output/dcp-cross-camera-fixed`; the sky comparison is in
`output/dcp-cross-camera-fixed/compare.py`.

### Remaining Approximation Limit

All seven cross-camera 129-grid bakes and all nine regenerated Sony looks fail
the default `0.02` sampled full-domain error gate. They were explicitly generated
as approximations for local evaluation, not as gate-passing production assets.
Corrected input matrices expose additional steep/clipped regions that the
uniform F-Log2 grid cannot adequately resolve. Across the 42 actual sample images,
the worst single-channel bake/direct error is `0.0765232`, and the largest per-image
p99 is `0.0102398`; the DJI Canon sky ROI max is `0.0152841`.

The strict default refusal remains active. Fixing the missing DCP matrix input
does not establish unlimited any-DCP compatibility, eliminate the finite-grid
approximation limit, or make the historical 1.0 CUBEs valid. Users must regenerate
1.0 DCP-derived CUBEs from the original profiles.

### Follow-Up Blue-Region Audit

A subsequent user report broadened the symptom beyond the DJI sky. A diagnostic
pixel classifier compared all 42 old/current pairs: neutral hue 195..242 degrees,
saturation above 0.25 and value above 0.08 becoming hue 245..290 with saturation
above 0.15. This is a symptom locator, not a colorimetric acceptance threshold.
The old 1.0 renders have at least 20 such pixels in 31/42 pairs. The current 1.1
renders still have at least 20 in two pairs, both Panasonic Vivid: Sony A7C II
(136/41458 classified blue pixels) and Nikon Z6 (110/8265). The sampled residual
shifts are about 4..6 degrees at the deep-blue/violet boundary and also occur in
direct evaluation, not only in the CUBE. Their correctness relative to the source
profile has not been established; no compensating hue adjustment was made.

The clearly version-labelled comparison is
`output/dcp-cross-camera-fixed/blue-styles-v1.0-v1.1.jpg`. The runnable diagnostic
`audit_blue.py --before --check` and `audit_blue.py --check` both return 1 for the
old broad symptom and the remaining current boundary cases, respectively.
These results supersede any unqualified claim that every blue-region issue is
fixed. The exact screenshot/region in the user's follow-up is still unconfirmed.
