# Preview P2 Verification

Branch: `review/viewport-denoise-cache`
Worktree: `/Users/xupeng/.codex/worktrees/viewport-denoise-review/rawtools`
Base: `b31827cf9c4a3237eaebf3c3d4f8f6fa58422f13`

## Cache Failure Reproduction

Production code was unchanged when the first real-RAW regression ran. Panasonic
S5II daylight RW2, CPU, 512px viewport, embedded-preview exposure, wavelet active:
camera WB/FBDD=2 -> Kelvin/FBDD=1 -> camera WB/FBDD=1 -> Kelvin/FBDD=1.

```text
Preview anchor FBDD 2->1: 0.226269 -> 0.225645, output hits=1, different bytes=8963
Assertion failed: (restored == expected), function checkPreviewExposureRoundTrip
exit 134
```

The old wavelet key omitted the actual decoded baseline EV. A new RAW decode
could use the updated anchor while still selecting filtered pixels or analysis
from the previous gain. After reproduction, the key was extended with the exact
32-bit float identity of `session->baseline_ev`, not a rounded decimal value.
Request v2, algorithms and original RAWs were not changed.

## Regression Results

The external-RAW `wavelet_exposure_cache` test covers filtered preview reuse,
strength changes that could reuse old analysis, an exact slot preserved while
wavelet is disabled for intermediate camera WB, and a same-FBDD negative control.

```text
Viewport anchor FBDD 2->1: 0.226269 -> 0.225645, output hits=0, analysis hits=0, different bytes=0
Viewport anchor FBDD 2->1: 0.226269 -> 0.225645, output hits=0, analysis hits=0, different bytes=0
Exact anchor FBDD 2->1: 0.226269 -> 0.225645, output hits=0, analysis hits=0, different bytes=0
Viewport anchor FBDD 1->1: 0.225645 -> 0.225645, output hits=1, analysis hits=0, different bytes=0
```

Each changed-anchor case matches an independent session and recomputes both
output and source analysis. The unchanged-anchor case retains the output hit.
The test is registered when the external Bayer `SONY2FUJI_TEST_RAW` is configured;
without a fixture the synthetic cache tests still run, not this real-RAW case.

## Native File Export

`ViewportPreviewTests.denoiseExportChecks` enables wavelet, changes preview sizes,
chroma/coarse strengths, WB and exposure, then exports native JPEG and PNG from
that same session. A separate exact engine provides the reference. The test also
asserts that disabling denoise actually changes fixture pixels, so a no-op filter
cannot satisfy the intended coverage.

Panasonic S5II native 6000x4000 JPEG/PNG matched the independent exact file pixels
and dimensions. PNG retained 16-bit samples. Export was called with both preview
arguments true to verify that the wrapper still explicitly turns them off for
file output. A further proxy between formats verified that export state is not
dependent on the previous native render. No export long-edge cap was supplied.

## Commands And Evidence

- Fresh core Release build with Metal, chroma/wavelet and DNG SDK: passed.
- `ctest --test-dir lutools/build-macos --output-on-failure`: 24/24 passed,
  0 failures, 136.96s. Includes the new exposure-cache case and real Sony/DJI RAWs.
- Fresh `RawLabMac/tests/viewport-preview.sh` build/run: passed CPU/Metal,
  half-size WB, exact/proxy isolation, applied-denoise native exports, resize
  stabilization, stale-size cancellation, 100% restoration and unchanged originals.
- Final Swift test artifacts: `/tmp/rawlab-viewport-preview.gHIJ9J`.
- `git diff --check`: passed.

The follow-up Dual review closed both P2s without new Must/Should findings;
`reviews/self-p2-cache-export-20261013.md` records the Mac/core gate. Client rollout
may proceed under the user's request but requires its own checks/review. No
application release, commit or push was performed. GPU fault injection and physical
mobile-device memory/latency were not tested by this P2 verification.
