# GPU and Portrait Verification

Date: 2026-09-28. These are local physical-device measurements, not claims
about every Android GPU or the performance of RAW decoding.

## Device and Pipeline

- Physical Lenovo TB320FC, Android 15, ARM64, Qualcomm Adreno 730.
- Driver: OpenGL ES 3.2 V@0615.96, dated 2025-02-14.
- Queried limits: SSBO 134217728 bytes, 65535 workgroups on X, 3D texture size 2048.
- Compute workgroup: 128. Source uploads are streamed in bands limited to
  16 MiB and the device's SSBO limit. A single reduced linear preview cache
  is capped at 64 MiB; it is invalidated by the actual RAW decode revision.
- Sessions own GPU buffers, texture and EGL context. Calls restore prior EGL
  bindings; resource teardown works on a subsequent serialized worker thread.
- GPU stages: preview resize in linear space, matrices/exposure, neutral
  display mapping, F-Log2, LUT/strength, pointwise tone, final display resize.
- RAW unpacking, camera WB/demosaic and JPEG/PNG encoding remain CPU work.
  Neighborhood sharpening/denoise (not exposed by this editor) use CPU in
  Auto; Force fails rather than pretending that a GPU render succeeded.
- The app defaults to Auto and permits CPU selection. The initial canvas
  backend/timing badge was removed in the white-balance follow-up below.
  Native backend diagnostics remain available. `SONY2FUJI_BACKEND_GLES` was asserted in
  native tests, including neutral and full-resolution file requests.

## Measurements

Same Sony DSC09067.ARW, 7008x4672, same Velvia LUT at strength 0.8, same
settings and device. Native core was built with the existing `-O3` setting.
Five warm preview samples were measured per backend; the table reports the
median. The RAW has already been decoded, and the GPU reduced-linear cache
is warm. Native render includes output-buffer generation, but not the Kotlin
bitmap copy, Compose drawing, or a second neutral/result render.

| Operation | CPU | GLES | Ratio |
| --- | ---: | ---: | ---: |
| Warm 1600px single preview | 345.20 ms | 53.26 ms | 6.48x |
| Native 16-bit PNG, decoded RAW cache warm | 8293.10 ms | 4921.34 ms | 1.69x |

PNG timing is one sample per backend, includes file encoding, and is not a
statistical performance guarantee. An earlier complete GPU PNG call with a
fresh camera-WB decode took 16.68 s; do not compare that to a warm export or
claim RAW decoding became 6.48x faster. The UI's displayed time includes both
neutral/result work, asset preparation and bitmap copies, so it differs from
the single-render benchmark. That UI timing badge is no longer displayed.

## White-Balance Follow-Up

The connected-device Debug APK originally compiled `sony2fuji_core` with `-O3`
but compiled the separate LibRaw target without optimization. Debug LibRaw now
also uses `-O3`; Release flags, WB-before-demosaic order, highlight handling,
interactive half-size policy and exact export processing are unchanged.

The `NativeProcessorTest.whiteBalancePreviewLatency` reproduction uses the same
Sony fixture and a paired neutral/Velvia render, with changing temperature and
tint 12. Interactive requests use 1000px, initial/exact requests use 1600px.
Times below include both native calls and JNI pixel copies, not Compose drawing
or Bitmap construction. These are single paired sequences, not a device-wide
performance guarantee.

| Operation | Before (ms) | Optimized Debug (ms) |
| --- | ---: | ---: |
| Initial camera-WB preview | 12460 | 2366 |
| First custom WB, 4200 K | 2590 | 707 |
| Next custom WB, 5200 K | 1011 | 291 |
| Next custom WB, 7200 K | 1012 | 273 |
| Exact 7200 K after dragging | 10983 | 1661 |

Repeating unchanged interactive settings took 8-9 ms before and 8 ms after.
This isolates the expensive changed-WB CPU processing from the cached GPU pixel
stage. The first custom WB also changes LibRaw's identification mode and reloads
the unpacked source. Changing temperature/tint still requires CPU RAW processing;
no GPU RAW decoder or approximate post-demosaic WB replacement was added.

The opt-in 1000 ms interactive budget failed on the original APK and passed on
the optimized APK. Run on this device with:

```sh
adb -s "$ANDROID_SERIAL" shell am instrument -w \
  -e class 'com.rawlab.android.NativeProcessorTest#whiteBalancePreviewLatency' \
  -e wbPreviewBudgetMs 1000 \
  com.rawlab.android.test/androidx.test.runner.AndroidJUnitRunner
```

The budget is optional so slower devices are not assigned this tablet's limit.
The final installed APK passed all 8 instrumentation tests in 29.168 s, including
the no-timing-badge UI regression, RAW exports and GPU mode switching. JVM tests
passed 8/8; dual-ABI builds and all 8 packaged native library alignment checks
passed; lint reported 0 errors and 12 warnings. No shared core source changed in
this follow-up, so desktop/Metal results below remain the earlier GPU baseline.
Local evidence: `app/build/verification/wb-latency-before.txt`,
`wb-latency-after.txt` and `portrait-no-timing-badge.png`.

## Correctness and Lifecycle

`tests/gpu_smoke.cpp` ran against the real driver:

- Forced neutral rendering first failed on the CPU build, then succeeded
  with an actual GLES backend assertion.
- Synthetic photo LUT with non-unit domains, strength 0/0.65/1, exposure
  -2/0/+2, neutral rendering, and FINAL resize after tone: max 0 DN vs CPU.
- Real RAW preview, cached exposure edits, WB half-size proxy and restored
  exact WB output: max 1 DN (8-bit); proxy never supplied the exact result.
- Full native 7008x4672 pixel buffers: max 1 DN, RMS 0.002188 DN (8-bit).
- Full-size CPU/GPU 16-bit PNGs: 7008x4672, 16-bit confirmed; FFmpeg RGB16
  comparison reported average PSNR 123.985 dB.
- Unsupported detail filters: Auto returned CPU-equivalent output; Force
  returned a processing error. Serial thread rebinding and interleaved
  creation/destruction of two GPU sessions passed.
- Oversized source-row halos are rejected before exceeding the upload
  budget; Auto still produces CPU-equivalent output.

## Android and Host Gates

- JVM tests: 8 passed.
- Android lint: 0 errors, 12 warnings.
- Physical-device instrumentation: 7 passed, covering GPU/CPU/Auto switching,
  RAW preview/export, rotated editor state, failed import preservation,
  MediaStore cleanup, and the portrait comparison/collapse/WB controls.
  Final installed APK rerun completed with `OK (7 tests)` in 72.715 seconds.
- Debug APK and test APK build for ARM64 and x86_64; native alignment check
  validates all packaged libraries, not just the JNI library.
- Shared desktop C++ regressions: 6/6 passed. An explicit real-Sony
  CPU/Metal acceleration regression also passed, including all tone/detail
  controls, interactive/exact isolation and file-export isolation.
- The physical firmware required the debug app to declare visibility of its
  instrumentation package for ActivityScenario cleanup. This declaration
  lives only in `src/debug/AndroidManifest.xml`; release permissions are unchanged.

## Portrait Visual Checks

Native Compose screenshots were inspected on the physical tablet at 1600x2560,
400 dpi, dark theme, and with a compact 1080x2400 / 480 dpi override (360 dp
wide), light theme and 1.3 font scale. The comparison wipe, separate tint slider,
film strip and fixed five-tool row remained usable without overlapping text.
Collapsing the dock preserves the selected tool and leaves the image visible.
The compact configuration also passed the portrait editor instrumentation test.

Screenshots in `app/build/verification/`:

- `portrait-gpu-tablet.png`
- `portrait-gpu-phone-large-text.png`
- `portrait-tint-phone-large-text.png`
- `portrait-collapsed-phone-large-text.png`

Device resolution, density, font scale and night mode were restored to their
original values after testing. The compact viewport is the same physical tablet,
not a separate phone model.

## Reproduction

From `RawLabAndroid/`:

```sh
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug :app:assembleDebugAndroidTest
ANDROID_HOME="$HOME/Library/Android/sdk" bash scripts/check-native.sh
```

The native build also produces `rawlab_gpu_tests` under
`app/build/intermediates/cxx/Debug/<configuration>/obj/arm64-v8a/`.
Push that executable, the matching `libraw.so`, NDK `libc++_shared.so`, the
repository Sony RAW and Velvia CUBE into an owned directory
`/data/local/tmp/rawlab-gpu-test/` on the selected test device. Then run:

```sh
adb -s "$ANDROID_SERIAL" shell \
  'LD_LIBRARY_PATH=/data/local/tmp/rawlab-gpu-test /data/local/tmp/rawlab-gpu-test/rawlab_gpu_tests /data/local/tmp/rawlab-gpu-test/DSC09067.ARW /data/local/tmp/rawlab-gpu-test/FLog2_to_Velvia_65grid_V.1.00.cube'
```

The runner writes only `domain.cube`, `full-gpu.png` and `full-cpu.png` in
that owned directory. No personal media is used. Instrumentation APKs were
installed with `adb install -r`, preserving unrelated device apps and data.

Generated logs, full-size comparison PNGs and screenshots are in
`app/build/verification/`, excluded from Git. No release was published.

## Remaining Coverage

No Mali/PowerVR driver matrix, 16 KB-page physical-device run, thermal/endurance
study, or all-camera format matrix. Screen-width overrides used for compact
portrait checks are not a claim of testing a second physical phone. GPU
Auto's fallback is tested with unsupported work and resource-limit rejection;
no real driver context-loss event was induced. New work does not change the
shared core's existing path/mtime/size file cache policy; Android imports use
new private working-file paths rather than modifying imported RAWs in place.
