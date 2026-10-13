# Android Denoise Memory Verification

Branch: `review/viewport-denoise-cache`
Worktree: `/Users/xupeng/.codex/worktrees/viewport-denoise-review/rawtools`
Before: `b31827cf9c4a3237eaebf3c3d4f8f6fa58422f13`
The investigation stayed in WIP. Later user-authorized coordination requested a
feature-only commit/push and draft PR to `development` in a separate worktree;
merge and release remain unauthorized. This report records the investigation
snapshot, not a claim that its old branch base is suitable for the final PR.

## Controlled Comparison

The before tree was extracted with `git archive` into ignored
`build/android-memory/baseline`; the branch and original checkout were not
switched or stashed. Both builds used the same Panasonic S5II 6000x4000 RW2,
CPU, Clean 10/72/100, API35 arm64 read-only AVD with `-memory 2560`, NDK 27.2,
and pinned DNG/OpenCV/wavelib sources. Native compile flags matched. OpenCV
reported two threads before the intentional large-Android-filter concurrency fix.
The identical initial memory test and temporary stage probes were applied to
both trees. All probes were removed from final production source.

Fixture SHA256:
`bf2f33175b63fc4ebfae59bd3f53bb1483eb7770196bbeed73764ade0ad12a1e`.

| Before Fix Run | Result | Native Heap Sample Maximum |
| --- | --- | ---: |
| Before, neutral preview -> native PNG, 2.5GB | LMK in full filter | 2,700,813,632 B |
| Current, neutral preview -> native PNG, 2.5GB | LMK in full filter | 2,241,845,504 B |
| Before, denoised preview -> native export, 2.5GB | LMK during full-size preview filter | See CSV |
| Current, denoised viewport -> native PNG, 2.5GB | Viewport passes; LMK in full filter | 2,262,337,840 B |
| Before reference, 6GB, preview -> native PNG/JPEG | Pass, 70.36s | 2,700,830,592 B |

These are 100ms native-heap/RSS samples, not exact instantaneous allocation peaks.
The successful 6GB reference recorded VmHWM 2,851,620 KiB. Wall-clock timings
are not an export-speed benchmark because RAM/background pressure differ.

## Confirmed Causes And Fix

The full-resolution CPU wavelet working set already exceeded this environment
before optimization. Viewport rendering moved that full computation from settled
preview to native export; a retained 1600 preview is only about 20.5MB and is not
necessary to reproduce the failure. Both cold before/current failed before
restore or encoding. PNG/JPEG encoding was not the initial cause.

The first fix shortened normalized/transformed/filtered/difference lifetimes and
limited Android coarse filtering above 4MP to one stripe. It still failed in
filter (`fixed-cold-2g`, sampled heap 1,988,136,896 B), so was not declared fixed.
Replacing the filter's approximately 356MB full padded RGB with per-channel
globally reflected tile planes then allowed native export. Tile centers, halo,
alignment, six/four levels, thresholds and reconstruction remain unchanged.
The remaining coarse calibration full padding is explicit residual memory, not
silently described as eliminated; the final cold budget includes that phase.

A further targeted test first exported, changed luma 10 -> 11, then exported
again. It was killed at 1,923,563,136 B (`final-cold-2g`): the old exact filtered
image still occupied 288MB during a cache miss. Only after this reproduction,
the miss path released invalid image output and set `completed=false`, retaining
the source analysis. Existing analysis/output-hit and backend/failure tests
protect reuse and retry semantics.

## Final Evidence

Cold/recompute fresh 2.5GB: `release-cold-2g`, pass 307.842s, native heap sample
maximum 1,635,520,336 B, VmHWM 1,590,452 KiB, under the explicit 1.8GB heap budget.
Both native files remain 6000x4000; PNG is 16-bit. Their complete file SHA256s
equal the before/6GB reference, not merely their 8-bit decoded previews:

- PNG: `1f13cc75fd0a91c60c656ea85e26e83d25abba1d68a854b5a9e8ac391ed1942a`
- JPEG: `2ef1a825823893290f606cd30d0430ca9b7ea9e7a9442ca52f4545c6bd4f8fc2`

The first final warm run was invalidated by an unrelated APK reinstall:
`full-logcat.log` records `installPackageLI` killing the active instrumentation
process. This is not counted as an OOM. Warm validation moved to a new read-only
AVD on a separate port. `verified-warm-2g` passed in 263.222s with heap sample
maximum 1,656,051,504 B and VmHWM 1,506,268 KiB, also below 1.8GB. Both files have
the same before-reference SHA256s above. Warm and cold each also completed the
subsequent luma-strength recompute/native PNG.

Android applied-NR/independent-FINAL, quiet-resize/latest-edit and all five Canvas
tests passed (seven cases). An eighth broad metadata case failed its fixture
precondition `Fixture must contain LensModel` on Panasonic; the assertion was
not weakened. Rebuilding only the test APK with Sony DSC06251 and running that
case passed in 51.225s, including native JPEG/16-bit PNG/capture metadata. Logs
retain the fixture-precondition failure and the separate passing run. Final
arm64 build, 52 unit tests and lint passed; lint remains 0 errors/35 warnings.

Shared core: 24/24 CTests passed, 255.24s, including real RAW, CPU/Metal, exposure
anchor/cache and render regressions. Added full 1537x1025 fine/coarse tests compare
one/two-thread float RGB bitwise; Mac and Windows both passed. Tile planes also
match old full padding exactly at thin tail tiles, small dimensions and 1px axes.
Wavelet-disabled translation-unit compilation passed without OpenCV includes.
Mac viewport integration passed applied NR -> native JPEG/16-bit PNG against an
independent exact session, resize stabilization, latest-size cancellation and
100-percent restoration. Artifacts: `/tmp/rawlab-viewport-preview.mAaUev`.
iOS device arm64 and simulator arm64/x86_64 core slices were rebuilt and packaged;
framework architecture/license/runtime checks passed. The iOS simulator app was
rebuilt with this framework; processor/export checks passed native denoise after
512/768 viewport changes and independent native JPEG, WB and metadata. Artifacts:
`/tmp/rawlab-ios-export.dyyctI`. No physical iOS memory test was performed.

## Windows VM

The prior Windows VM was used with isolated
`C:/RawLabBuild/viewport-memory-20261013/workspace`; the previous shared workspace
was untouched. The initial complete build passed 17 native CTests and 126 managed
checks, including actual D3D11 path/parity and native JPEG/16-bit PNG metadata.
After final production changes, a fresh self-contained build, three affected
wavelet CTests, applied-NR native PNG/JPEG comparisons and interaction checks all
passed. The new full multi-tile thread regression separately passed in 58.79s.
Final production-file hashes on the VM match local source.

Sony DSC06251 was suitable for the broad native/D3D checks but did not produce a
visible NR preview change at either 600 or 1600px. The dedicated applied-NR gate
was not weakened: it used the same Panasonic fixture, retained the changed-pixel
assertion, and passed native 6000x4000 PNG/JPEG against independent FINAL output.
Why Sony gave identical RGB8 pixels (calibration early return versus quantization)
was not conclusively instrumented and is not asserted as a production defect.

## Artifacts And Limits

All APKs, RAW copies, output photos, CSVs, tombstone/logcat and build logs are under
ignored `build/android-memory/` or `build/windows-memory-review/`, not committed.
`RawLabAndroid/tests/native-memory.sh` reproduces the fixture-driven test and
returns failure for process crashes even when Android instrumentation exits zero.
The reviewed eight-file fingerprint is
`d4cf6ba12e269a65fa39422930c016b0f425331f060acf7afd009afcb7f883e7`.
Dual incremental review has no confirmed Must/Should findings after the full
multi-tile test addition, and the original-worktree gates above are complete.
Migration to `development` needs separate baseline-sensitive validation: it has
new HSL/master-recipe and generic GPU-wavelet calls, while this old HEAD includes
unrelated AI/JXL history. Neither that history nor old test results may silently
be treated as final-PR evidence.

Larger RAWs and physical-device memory/latency are not covered. Android x86_64
full build was attempted but the external DNG SDK download returned a partial
file; the verified Android build/runtime is arm64. Existing lint reports 0 errors
and 35 warnings. Large Android coarse exports intentionally trade concurrency
for memory; small viewport previews and other platforms retain their concurrency.
