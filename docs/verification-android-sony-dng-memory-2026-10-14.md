# Android Sony Native Export Memory Verification

## Scope And Revision

Branch: `feature/android-sony-dng-memory`.
Independent worktree: `/Users/xupeng/.codex/worktrees/android-sony-dng-memory/rawtools`.
Baseline HEAD and merge-base: `3f252a1006d349c2a3655129a9cf665385dccaca`.
Changes are local WIP, not merged or released. This compares before/after the
Sony-specific fix, not a new comparison of every earlier viewport optimization.
The original checkout and frozen PR30 candidate/packages were not modified.

The user explicitly limited GPU validation to devices with at least 6GB RAM.
The matrix is therefore CPU on the dedicated 2.5GB AVD and CPU/Force GLES on
the available approximately 12GB physical Lenovo TB320FC. No low-RAM GPU policy
was added to production code. Other client rollout is not part of this change.

## Controlled Input And Environment

- Sony `DSC06251.ARW`, 45,199,360 bytes, rendered orientation `4672x7008`.
- SHA256: `dc280884db9e0d2e1e7389dca1370958ea8fde749cef8169702f64237d98763f`.
- One full float RGB image is 392,896,512 bytes. The original RAW hash remains unchanged.
- API35 arm64 AVD, `-memory 2560 -cores 4 -gpu swiftshader`, no snapshots,
  read-only, dedicated AVD/port. Guest MemTotal 2,531,992 KiB; SwapTotal 1,898,988 KiB.
- Physical TB320FC: Android 15, arm64, MemTotal 11,480,140 KiB.
- Same arm64 Debug toolchain: Java 21, Gradle 8.11.1, NDK 27.2.12479018,
  SDK CMake 3.22.1, pinned LibRaw 0.22.2, DNG SDK 1.7.1, OpenCV 4.12.0,
  wavelib and TIFF 4.7.1. The local source cache contained verified source
  archives, not another worktree's compiled project core.
- Independent application IDs `com.rawlab.android.sonymemory` and
  `com.rawlab.android.sonymemory.test`; the user's normal installation/data
  were not replaced or force-stopped. No shared adb server reset/logcat clear.

Settings matched the prior Sony DNG regression: Velvia, strength .65,
exposure .35, highlights -.2, shadows .15, contrast .1, tone curve .15,
saturation -.1, absolute WB 5800K/tint 8, sharpening .2, exposure mode 1,
wavelet 10/72/100, display chroma mode 2, HSL hue[2]=12/saturation[4]=-15/
lightness[6]=8, effects (-30,42,-15,65,35,20,38,65), lens correction off.
Both versions use a 128px viewport followed by FINAL export.

## Confirmed Cause

The old `RenderedDngInstrumentedTest` requests 128px output. That is not a
128px processing budget: FINAL computes the full-resolution image before
the final resize. Its old crash logs did not establish the operation stage.

Two controlled baseline runs reproduced LMK. Finer temporary probes established
`raw-loaded -> normalized-transformed -> coarse-calibration-end ->
wavelet-filter-start -> LMK`, with no filter-end, restore or writer marker.
The second kill recorded 493,660 KiB RSS plus 1,497,064 KiB swap, low swap
56 KiB and 301% thrashing. This was SIGKILL/LMK, not a native writer crash.

The full-resolution immutable RAW cache, converted working RGB, opponent
coefficients, filter output and tile workspace overlap. The baseline native
heap sample reaches approximately 2.085GB. The DNG writer streams rows/64-row
strips; its small buffers were not the initial cause. The same processing
working set also precedes JPEG and PNG encoding.

## Minimal Fix

1. After independent opponent coefficients are generated, release the working
   RGB copy before calibration/filtering. Restore reconstructs it from the
   immutable RAW cache using the same AdobeRGB-to-sRGB matrix. This is only
   enabled for full RAW processing, not viewport/fast-wavelet proxies.
2. Blur the restore variance buffer in place rather than retain two full-size
   buffers. No thresholds, tile geometry or reconstruction formulas change.
3. Release the CPU film-blend reference before downstream chroma/detail/effects.

Immutable-source shape validation rejects malformed reload inputs. GPU Auto
can reload the released working image on CPU retry; Force still reports failure.
Noise-analysis/output cache keys and invalidation rules, export dimensions,
JPEG/PNG/DNG encoding, and the public C ABI are unchanged. All temporary
Android allocation probes were removed from final production source.

## Results

Native-heap values are 100ms samples, not exact instantaneous allocation peaks.
VmHWM is the kernel's persistent resident high-water mark; heap and resident
budgets are not interchangeable. Actual completion without LMK is a separate
gate. Timing includes different numbers of exports and is not a speed benchmark.

| Run | Result | Heap Sample Maximum (B) | VmHWM (KiB) |
| --- | --- | ---: | ---: |
| Baseline, 2.5GB CPU, viewport -> DNG128 | LMK in filter | 2,085,230,016 | 1,812,204 |
| Fixed, same 2.5GB CPU, viewport -> DNG128 | Instrumentation pass, 140.191s | 1,692,317,520 | 1,653,084 |
| Baseline physical CPU, native DNG/PNG/JPEG | Pass, 264.548s | 2,085,741,264 | 2,315,208 |
| Fixed physical CPU, native three formats + fresh FINAL | Instrumentation pass, 532.260s | 1,692,905,120 | 1,930,384 |
| Final probe-free cold 2.5GB CPU, native three formats + fresh FINAL | Full runner pass, 333.659s | 1,692,317,392 | 1,649,688 |
| Baseline physical Force GLES, native three formats | Full runner pass, 123.498s | 2,459,767,312 | 2,728,188 |
| Final physical Force GLES, native three formats + fresh FINAL | Full runner pass, 247.753s | 2,465,368,224 | 2,743,868 |

CPU working-set reduction is approximately 393MB, about 19%. The final cold
CPU gate satisfies the explicit 1.8GB sampled-native-heap budget; artifact
analysis also asserts kernel VmHWM <=2.1GB. The latter was checked from its
CSV, separately from the test's native-heap assertion. The current test also
supports a separately recorded RSS budget and reads final VmHWM directly.

The GPU total includes two serial processor sessions. Its first/history-session
heap maximum is 2,460,035,568 bytes versus baseline 2,459,767,312, essentially
unchanged. This fix is not a GPU-memory optimization. Force GLES success on
this approximately 12GB device is not a claim that an exact 6GB device was tested.
Devices below 6GB in GPU mode are explicitly outside the requested matrix.

Two intermediate wrappers exited 127 after the runner script was edited while
Bash awaited instrumentation. Their instrumentation logs contain `OK (1 test)`;
outputs were recovered separately. They are not counted as full-runner passes.
Final runs used immutable runner snapshots and completed with exit 0. An
intermediate label `fixed-avd-capped` actually used native/all-format defaults;
it is not used as the controlled 128px comparison above.

## Full-Resolution Quality

Every native file is `4672x7008`; PNG is 16-bit and rendered DNG is float32
LinearRaw RGB. Independent processors run serially, after the viewport-history
processor is closed. Each fresh file equals its corresponding history file.
Complete before/after files also compare byte-for-byte, for each backend:

| Backend | Format | Before And After SHA256 |
| --- | --- | --- |
| CPU | DNG | `6e2a6f2542551a21e8ab1610fae4b5c2ee5064a62b70bfd80e01ef708a3b77fe` |
| CPU | PNG | `889dca64ff249069e7338e1d15add98687d55c6b52caceae33a5c32295811cbc` |
| CPU | JPEG | `b39d6bf45a4a4f6b67759971013236797d7f05dc58ae04041a2ba218b9fb1789` |
| Force GLES | DNG | `95d57652779ad7eed3ed5dff9bffb83903a13b9b7b0e75456e5feca4dc589365` |
| Force GLES | PNG | `197d291b98386ec5960be4709e7c49810e136f2cfd991bbe23d23b949a79c756` |
| Force GLES | JPEG | `9854095c6ff1182f3065d573ad86d78a396df044062e4dee9d435815cfdd1362` |

The independent host DNG/PNG pixel validator reports maximum 16-bit difference
1 for CPU and Force GLES; CPU/GLES quantized RGB8 maximum difference is 1,
below the existing acceptance threshold 2. It also validates dimensions,
LinearRaw/float32 tags, range and finite samples. No tolerance was loosened.

## Regression And Review

- Core CPU: 23/23 CTests pass, 306.17s, including Sony RAW, exposure-anchor/cache,
  rendered DNG, Lens+wavelet and color contracts. Host diagnostic probes were
  no-ops; final probe-free focused wavelet test passes again, 20.93s.
- Final core Metal: four relevant tests pass, 102.65s, including Lens+wavelet
  rendered DNG, Metal denoise, wavelet and cache.
- New direct tests compare retained/reloaded AdobeRGB sources bitwise at multiple
  fine/coarse strengths, verify analysis reuse and source immutability, and
  check GPU-failure CPU retry in a GPU-disabled build. A malformed-source test
  first failed as intended, then passed after shape validation was added.
- New C API fallback test replaces GPU filter symbols only in its executable.
  Real `sony2fuji_process` Auto retries twice, reuses analysis, does not store
  failed-backend output, and matches independent CPU bytes. Force hard-fails.
  Removing empty-image reload produces RED at the C API assertion (10.85s);
  restored final source produces GREEN (25.13s; qualified-fixture rerun 25.11s).
- Wavelet/chroma/GPU disabled: fresh complete `sony2fuji_core` build passes.
- Android final arm64 app/test builds pass; 68 unit tests pass, none skipped;
  final lint passes with 0 errors/17 warnings. No clean-warning claim is made.
- Dual bounded review covered lifetime/cache/fallback/color/export logic and
  test/data isolation. The identified source validation, deterministic C API
  retry, disabled-build, reference-default and HWM-evidence gaps were addressed.

There was no new Windows/iOS app rebuild or whole-client UI matrix for this
Sony-only fix. Window-sizing code and viewport cache selection are unchanged.
Other platform rollout remains a separate decision after this evidence.

## Reproduction And Artifacts

Build an isolated APK rather than overwrite the normal app:

```sh
cd "$ROOT/RawLabAndroid"
./gradlew :app:assembleDebug :app:assembleDebugAndroidTest --max-workers=2 \
  -I tests/sony-dng-memory.gradle -Pandroid.injected.build.abi=arm64-v8a \
  -PrawlabTestRaw="$RAWLAB_TEST_RAW"
cd "$ROOT"
RAWLAB_MEMORY_BUDGET=1800000000 RAWLAB_MEMORY_RSS_BUDGET=2100000000 \
  bash RawLabAndroid/tests/sony-dng-memory.sh "$ROOT" "$CPU_DEVICE" unique-cpu \
  cpu dng,png,jpg 0 true
bash RawLabAndroid/tests/sony-dng-memory.sh "$ROOT" "$GPU_DEVICE" unique-gles \
  force dng,png,jpg 0 true
```

Use Java 21 and the Android SDK command-line tools. `$RAWLAB_TEST_RAW` must be
the Sony fixture above. The runner verifies actual APK application IDs before
any adb operation, records arguments/budgets/APK hashes, and rejects crashes
even if `am instrument` itself exits zero. Wrong-APK preflight was verified
to exit 2 before accessing an intentionally nonexistent device. Explicit
subsets, capped output or `reference=false` are diagnostic modes, not full gates.

Saved baseline APKs can be selected with `RAWLAB_MEMORY_APP_APK` and
`RAWLAB_MEMORY_TEST_APK`. The final app SHA256 is
`2254ee92d2d9f15c183d8a192369312ede58e4c1c1d67b36bdd38540053ce0dc`.
The cold final CPU test APK is `fcefab2ac4e5066a5a4523cc04679d15938df8b20a997abc05a542ef7f71981e`;
the subsequently strengthened HWM test APK used on physical Force GLES is
`dffa11e3223bb854ec3771d769d59e86e3d8c2108f5035d17f08097b6009fd7b`.
The production app is identical in both runs.

Ignored `build/sony-dng-memory/` contains baseline/final APKs, stage-probe patches,
build/RED/GREEN logs and per-run CSV/logcat/native files. The nine-code-file SHA
manifest is `final-source.sha256`, manifest SHA256
`60f5442e5ccd47525d567a0125fd0e8731b1ef2607c562fce79c5229e4027ecf`.
No RAWs, photos, APKs or generated dependency/output files are staged.
The owned AVD was stopped, all validation sessions completed, and the isolated
physical installation was restored to the tested final app and test APK.
