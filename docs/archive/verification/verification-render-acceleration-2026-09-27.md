# Render Acceleration Verification

## Environment

- Apple M3 Max, LibRaw 0.21.5, Release C++ (`-O3`) and Swift (`-O`).
- Command Line Tools selected via `DEVELOPER_DIR=/Library/Developer/CommandLineTools`.
- Mac app built with the 26.5 SDK and macOS 26.0 deployment target.
- No RAW originals changed; output artifacts remain under `/tmp`.

## Implementation Boundaries

- The Mac client defaults to Metal Auto for float image processing: resizing, color
  matrices, exposure, F-Log2, LUT interpolation/blending, tone/color, and detail.
- LibRaw unpacking, camera-space WB, demosaic and highlight reconstruction remain
  CPU operations. The unpacked RAW is reused across numeric WB changes. A change
  in camera/auto/custom identification mode can still require reopening the file.
- While dragging, a 1000-pixel preview can use LibRaw half-size processing. The
  release pass uses full RAW processing at the requested display size. A matching
  exact RAW cache can supply a proxy; a proxy never supplies an exact result.
- FINAL and every file output ignore the interactive flag. Export is disabled
  while an interaction or render request is pending.
- GPU uses two reusable processing buffers rather than a full-size allocation for
  every stage. CPU remains the reference and Auto fallback.
- Histogram/mask Metal code is implemented and parity-tested, but Auto selects the
  optimized C++ CPU loop for already CPU-resident bytes. Local optimized timings
  did not show a consistent gain from uploading these bytes to Metal.

## Performance

Same `DSC09067.ARW` (7008 x 4672), PROVIA, standard exposure, RGBA8 output.
The benchmark measures C API processing, not UI scheduling, histogram generation,
screen presentation or disk export. Every Metal result reported backend=1; all
calls returned status=0. These are local observations, not cross-device guarantees.

| Work | Before | After |
| --- | --- | --- |
| Cached neutral, 2000px | CPU about 109 ms | Metal 43-52 ms |
| Cached film, 2000px | CPU about 165 ms; LUT-only Metal about 142 ms | Metal 41-50 ms |
| Continuous WB updates, neutral + film | Full quality about 2.8 s | Interactive 1000px: 209-219 ms |
| Full-quality WB on release, neutral + film | About 2.8 s | About 2.44 s |

The interactive and original full-quality timings are deliberately different
quality levels. The speedup is useful feedback while dragging, not a claim that
full-quality demosaic became 13 times faster. Cold opening still takes about
2.7 seconds; the first switch from camera WB to custom WB can also re-identify RAW.

Final benchmark output (Metal):

```text
cached-neutral: 51.90, 42.52, 45.17 ms
cached-film: 48.83, 50.35, 41.26 ms
interactive neutral+film: 180.39+28.51, 204.24+14.76, 201.21+14.09 ms
release exact neutral+film: 2386.44+49.06 ms
```

Optimized histogram/mask benchmark, warmed 5 times, averaged over 10 runs:

| Input | CPU | Metal |
| --- | --- | --- |
| 2MP RGBA8 | 2.03 ms | 2.11 ms |
| 33MP RGB8 | 31.70 ms | 44.72 ms |

Use `lutools/tests/render_benchmark.cpp` through the `render_benchmark` CMake target
to repeat photo timings. Timings are not used as CI pass/fail thresholds.

## Verified Gates

- `bash RawLabMac/build.sh`: passes, app produced and ad-hoc signed.
- Metal-enabled CTest: 11/11 pass, including original color/WB/RAW/highlight tests,
  new float pipeline parity, RGB histogram/mask parity, unpacked RAW reuse and real
  `DSC06251.ARW` / DJI DNG acceleration tests.
- Real RAW acceleration tests require Force and verify the backend is Metal.
  CPU/Metal RGB8 comparisons allow at most 2 code values; exact-cache reuse,
  FINAL flag isolation and PNG file export flag isolation require exact equality.
- RAW reuse tests require fresh/reused float images to be pixel-identical across
  WB changes and full/half/full transitions. The source-rename check uses a copy
  in `/tmp`, not the original fixture.
- GPU-disabled Release build: `color_contracts` and `image_stats` both pass;
  histogram Force failure does not alter caller output.
- After the final histogram Auto-policy change, `image_stats` passes again.
- `bash RawLabMac/tests/adjustments.sh`: all 8 local RAW fixtures pass, including
  original-resolution 16-bit PNG and display/export pixel parity. Artifacts:
  `/tmp/rawlab-adjustments.V7RfBo`.
- `presentation.sh` and `histogram.sh`: pass.
- `render-scheduling.sh`: 19 checks pass, including continuous-drag coalescing,
  stale-file suppression, exact release and export blocking.
- `RUN_PROGRESSIVE_RENDER=1 bash RawLabMac/tests/progressive-render.sh`: 6 checks
  pass using the actual EditorModel, RAW and RenderEngine. Observed 1000px proxy
  while busy, then 2000px exact while idle; final histogram equals a direct render.
- Native UI: opened Sony RAW, displayed comparison/histogram, dragged temperature
  from as-shot 5096 K to 8910 K, and observed the custom WB value and exact 2000px
  result without an error. The short-lived proxy was verified by the model test,
  not inferred from a static screenshot. The user subsequently interacted with
  the QA window; that state was preserved.
- `codesign --verify --deep --strict 'build/RawLab Mac.app'`: passes.
- `git diff --check`: passes.
- Independent integration review found one persistent-state recovery issue: a
  fatal `dcraw_process` error can recycle LibRaw's unpacked data. The error path
  now invalidates the processor state instead of advertising it as reusable.
  The FFI already discards failed processors. No fatal LibRaw error was injected.

## Remaining Limits

- No GPU device-loss injection or non-Apple GPU validation was performed.
- Tested RAW coverage is local Sony ARW and DJI DNG, not every LibRaw-supported
  sensor layout. Fuji X-Trans/Super CCD proxy geometry is not fixture-validated.
- No promise of Lightroom profile equivalence or exact Fuji in-camera JPEG color
  is added by this performance work.
