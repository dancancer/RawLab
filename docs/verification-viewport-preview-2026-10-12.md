# macOS Viewport Preview Verification

Date: 2026-10-12
Branch: `perf/viewport-preview`

## Scope

The macOS editor derives its preview size from the actual photo pane, display
scale and zoom. Ordinary previews reduce linear input before expensive filters
and effects. Settled actual-pixel views and exports retain source-resolution
processing. Other clients and existing C ABI callers keep their default behavior;
the new viewport session setting is opt-in and request v2 is unchanged.

Window resizing, comparison layout, file-tree visibility and adjustment-dock
height changes update preview demand. Sizes use 64-pixel steps to limit churn.
Only the latest pending request is retained; interactive results at obsolete
viewport sizes are discarded. The core caps proxies by source dimensions even
before a newly opened photo reports its geometry.

With denoise enabled, continuous resizing holds the current proxy until 200 ms
of quiet. Filtered RAW results retain one exact slot and two LRU preview slots,
with a 128 MiB preview-image budget. Each entry also retains small source-only
noise analysis across strength changes. No denoising algorithm was replaced.

## Checks Run

All commands ran locally on arm64 macOS with the configured Mac dependencies.

```sh
bash RawLabMac/build.sh
ctest --test-dir lutools/build-macos --output-on-failure
bash RawLabMac/tests/presentation.sh
bash RawLabMac/tests/render-scheduling.sh
RAWLAB_TEST_RAW=/path/to/fixture.RW2 bash RawLabMac/tests/adjustments.sh
bash RawLabMac/tests/viewport-preview.sh /path/to/fixture.RW2
bash RawLabMac/tests/viewport-preview.sh /path/to/fixture.RW2 --model-only
RUN_PROGRESSIVE_RENDER=1 RAWLAB_TEST_RAW=/path/to/fixture.RW2 bash RawLabMac/tests/progressive-render.sh
cmake --build lutools/build-macos --target denoise_cache_benchmark -j 6
lutools/build-macos/denoise_cache_benchmark /path/to/photo.ARW /path/to/PROVIA.cube
```

- Mac build, signing and bundled dependency checks passed.
- CTest: 23/23 passed after the denoise cache implementation, including real
  Sony/DJI RAW tests and the new filtered-cache regression.
- Adjustment checks passed on eight RAW fixtures, including a Panasonic S5II RW2.
- Viewport sizing checks cover Retina, split comparison, zoom and native caps.
- RAW viewport CPU/Metal comparisons passed for sharpening/effects,
  wavelet/effects and chroma/effects. Metal Force reported the Metal backend.
- Explicit half-size RAW plus viewport/WB tests passed in scene and embedded
  preview exposure modes; subsequent exact output matched a fresh exact session.
- Smaller/differently sized proxies did not contaminate exact rendering.
- JPEG and sixteen-bit PNG export pixels were unchanged after proxy rendering.
  The C ABI also ignored viewport opt-in for PREVIEW file output and FINAL buffers.
- Model integration passed for numeric edits, resize shrink/growth, rapid resize,
  resize during slider interaction, native release and immutable original frames.
- The obsolete-size interactive-frame regression failed before the completion
  guard was added, then passed after the fix.
- Source-analysis reuse is bit-identical to independent CPU denoise for luma,
  chroma and coarse strength changes. Source identity, dimensions and clear
  invalidate analysis; coarse analysis is prepared lazily.
- C API call counters verify exposure/tone edits and return-to-size/exact calls
  reuse filtered results, while strength and WB edits recompute only as required.
  CPU/Auto output isolation and the preview memory budget passed.
- Denoise resize bursts hold the old proxy, keep export blocked, retain current
  adjustments and settle at the latest size. A delayed second resize stays held
  past the cancelled timer's deadline. Actual-pixel switching cancels pending work.

## Timing Sample

Panasonic S5II daylight RW2, 6000x4000 source, PROVIA, 1200px output, Metal Force.
Each entry is the median of three exposure edits after warming the relevant
RAW/filter caches. These are render-call measurements including preview statistics,
not first-open or end-to-end slider latency. No machine-speed CI threshold is used.

| Active Settings | Exact Source Processing | Viewport Processing | Speedup |
| --- | ---: | ---: | ---: |
| Sharpening, vignette, grain | 67.0 ms | 9.2 ms | 7.31x |
| Wavelet, sharpening, vignette, grain | 79.2 ms | 9.9 ms | 8.00x |
| Chroma, sharpening, vignette, grain | 2015.7 ms | 455.6 ms | 4.42x |

Concurrent builds/tests produced different absolute timings on a second run;
these numbers are a representative local sample, not a general performance claim.

## Denoise Cache Timing

A separate run used the user's current Sony ARW, PROVIA, GPU Auto, 1600px output
and denoise luma/chroma/coarse 0/46/50. Times cover the native render call, not
Swift histogram generation or end-to-end interaction. Initial RAW warm-up took
1475 ms. The benchmark reads internal filter/analysis/output counters rather than
inferring cache use from timing.

| Operation | Time | Denoise Calls | Cache Result |
| --- | ---: | ---: | --- |
| First denoise at 1600px | 616.3 ms | 1 | Cold |
| Three exposure edits | 10.5-11.3 ms | 0 each | Filtered output hit |
| New 1200px size | 56.5 ms | 1 | Cold size |
| Return to 1600px | 10.9 ms | 0 | Filtered output hit |
| Chroma strength 46 to 60 | 171.6 ms | 1 | Source analysis hit |
| Disable then re-enable unchanged denoise | 11.6 ms on re-enable | 0 | Filtered output hit |

Both retained preview images occupied 32,006,400 bytes. These are local warm/cold
samples, not a guarantee for other images or hardware. The first GPU operation
can include initialization, so cold and strength-edit timings are not a controlled
measurement of analysis savings alone.

## Native UI Verification

An isolated app instance was used so an already-running editor was not replaced.
The Panasonic chart rendered correctly in both panes. The live status changed
from 1024x683 to 1600x1067 when entering fullscreen, to 2176x1451 when disabling
comparison, and to 2944x1963 when collapsing adjustments. Selecting actual pixels
through the zoom menu produced native 6000x4000 output. Restoring fit/comparison
and exiting fullscreen returned to 1088x725. Images remained nonblank and fitted
to their canvases throughout the layout changes.

After the denoise phase, the previous editor process (started on October 10) was
quit normally and the newly built app launched. The current Sony photo reopened
with the same custom look, exposure -0.20 EV, highlights -18, exposure baseline,
as-shot WB and enabled custom denoise 0/46/50. The saved edit record was unchanged
before/after restart. The new native UI rendered a nonblank 1536x1024 viewport
preview with the restored controls; no original RAW was modified.

## Limitations

Viewport sharpening radius, grain texture and denoise results are approximations;
inspect settled 100% output for real pixel detail. Initial RAW decode, absolute WB
reprocessing and legacy FBDD still incur CPU costs. This is not viewport-region
RAW decoding. Uncached sizes, source/WB changes and actual strength edits still
require filtering. Auto GPU failure retains the existing no-output-cache policy;
failure injection was not run. No Windows, Android or iOS runtime validation was
performed for this macOS-only change. Other clients do not opt into viewport
rendering, but share the internal exact-cache/analysis implementation.
