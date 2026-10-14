# iOS adjustment performance investigation — 2026-10-14

## Scope and baseline

Measured processing baseline: `66726f1f4f57b3d9bcc10600b0e671bd6794a511`.
Before PR creation, isolated branch `fix/ios-recipe-white-balance-cache` was
fast-forwarded to development `2f1faebcd1fab9801a0dd322fe6cdeb79ebfc582`, which adds
only the five Windows #49 files relative to the measured baseline. The iOS and
native processing sources are unchanged by that update. Isolated checkout:
`build/ios-adjustment-performance`. The user's original checkout and its
uncommitted work were not edited. No UX redesign, main/release update or public
comment is part of this change. Development PR/review/integration was subsequently
authorized; the full SwiftUI interaction validation is being completed separately
from the processor measurements below.

The user's Mac browser exposed the [RawLab 0.7 post](https://www.xiaohongshu.com/explore/6acee385000000001203531f).
Seafood reported ARW parameter changes taking about three seconds, with the
self-reported device/system “iPhone 18 promax” / iOS 27.1. The author asked which
parameters were changed and later replied that they would investigate. The
specific adjustment, Sony camera, compression and original fixture were not
provided. This investigation reproduces a concrete slow path, not the exact
reporter's workflow.

## Physical device and signing

`xcodebuild -version`: Xcode 27.0, build 27A266a. `devicectl` confirmed a
physical **iPhone 14 Pro Max / iOS 27.0.1**, wired, paired, booted, with Developer
Mode enabled. This is the user's test device, distinct from the commenter's
self-reported model. No system security, trust or account settings were changed.

The user configured their existing development Team/profile in the ignored
project `build/performance/device-project/RawLab/RawLab.xcodeproj`. The app scheme
and target are **RawLab**, the independent bundle ID is
**`com.rawlab.tests.adjustmentperformance`**, and its product/display name is
**RawLab Performance**. The tracked application project is unchanged. The initial
sandboxed identity query reported zero identities, but the authorized Xcode
build signed successfully with the user's existing Apple Development identity
and profile. No provisioning-update command, account login or credential creation
was performed by the agent.

A complete baseline arm64 iOS native framework was rebuilt with the pinned
LibRaw 0.22.2 and baseline dependency patches, Metal, DNG SDK, wavelet, chroma and
Lensfun enabled. The combined local XCFramework now contains separate device
and simulator slices. Its platform/minimum-version, C ABI symbols, system dynamic
dependencies and license resources were checked in
`build/performance/device-core/validation.json`.

The full Release application built and passed `codesign --verify --deep --strict`
outside the sandbox. `devicectl` installed and launched it successfully using the
independent test ID. A preinstallation apps query found no existing RawLab app;
no production app or its data was replaced. Test builds are subsequently updated
under this same independent ID, preserving the benchmark data container.

The physical benchmark uses copies of the unchanged baseline and optimized Swift
processors, the same device framework and a bundled copy of the authorized
fixture. It renders on a serial background queue and records process/image/
histogram time, thermal state, a 10 ms main-run-loop heartbeat and 10 ms sampled
physical footprint. It does not request Photos access. Four physical runs
completed with zero regression failures. SwiftUI frame traces and OS full-time
memory peaks remain unverified.

The first temporary UIKit benchmark entry exited with SIGTRAP before producing
valid metrics. Its crash report identifies the iOS 27 scene-lifecycle requirement
(`___UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption_block_invoke`),
not a RAW-processing failure. Adding the Scene delegate to the ignored host
resolved the failure; subsequent baseline and optimized runs completed.

## Substitute fixture

The user authorized a similar local Sony ARW in place of the original ~31 MP RAW.
Only local copies were used; nothing was uploaded and the original was not written.

| Field | Value |
| --- | --- |
| Fixture | `lutools/examples/DSC06251.ARW` in the original checkout |
| Camera | Sony ILCE-7CM2 |
| File size | 45,199,360 bytes |
| Sensor storage | 7168 × 5120 |
| Rendered active image | 7008 × 4672, 32,741,376 pixels |
| Upright render dimensions | 4672 × 7008 |
| Decoder | LibRaw `sony_ljpeg_load_raw()` — lossless JPEG RAW |
| RAW IFD compression tag | 7 |

ImageIO's top-level dimensions (1616 × 1080) and TIFF compression 6 describe the
embedded preview, not the RAW sensor. A direct LibRaw query and the processing
result supplied the RAW/render dimensions.

## Bottleneck and minimal change

Normal exposure/tone/LUT controls already reuse the Swift preview session and
decoded RAW. Numeric Kelvin/tint edits legitimately require RAW processing before
demosaic; changing those values preserves unpacked sensor data. The viewport
preview path is already enabled for adjustments. Rendering and histogram work
run on the background serial render queue; obsolete queued requests are skipped,
but an in-flight synchronous C render cannot be interrupted.

`prepareRecipe` previously rendered a neutral camera-WB frame on every recipe
request to recover the original camera WB. A recipe with a tint offset then
renders temperature-WB RAW. Subsequent exposure changes repeat the camera-WB →
temperature-WB transition, invalidating the single decoded RAW cache twice.
This reproduced ~3.7-second updates even though exposure itself does not change
the RAW cache key.

The change caches only the immutable as-shot WB metadata for one file, keyed by
standardized URL, current file size and modification time. Unknown file identity
is never reused; successful loads alone replace the cache. The native RAW cache,
exposure anchoring, demosaic, color transforms, resolution, export and C ABI are
unchanged. Different file identities still load their own baseline. Configuration
after recipe preparation remains complete for RAW processing and DNG export.

## Physical-device before/after comparison

The device host runs eight cases in CPU mode followed by the same eight cases
with **Force Metal**, using the same rebuilt native framework, fixture, recipe,
1280-pixel viewport preview and Release optimization. Output is 853 × 1280 RGBA;
LibRaw still processes the 7008 × 4672 active source. Times include processor,
UIImage and histogram; result-file writes and quality comparisons are outside
that timing window. A settled preview means `interactive=false`, not a file export.

Four completed runs were retained. The first baseline started nominal and reached
fair; the first optimized run stayed fair. A repeated baseline stayed fair; the
last optimized repeat stayed serious. No more processing was run after that
rise. For the primary comparison below, both complete runs have
`thermalBefore=thermalAfter=1` (**fair**):

- Baseline: `baseline-1791985401553-E1B0BDE6` (second baseline).
- Optimized: `optimized-1791985302906-76186861` (first optimized).

The optimized run actually preceded this baseline repeat. This comparison matches
the recorded temperature category, source and parameters; it is not laboratory
control of physical temperature, battery/charging state or randomized trial order.
Each steady figure is the median of two recipe exposure updates or three normal
exposure updates within the selected run, rather than a latency distribution.

| Case | CPU before → after | Force Metal before → after |
| --- | --- | --- |
| First neutral preview | 2228.9 → 2362.3 ms | 2242.9 → 2222.9 ms |
| Normal warm exposure, three updates | 55.4 → 53.7 ms | 16.4 → 16.8 ms |
| First tinted-recipe preview | 2244.6 → 2254.1 ms | 2092.2 → 1993.0 ms |
| Recipe exposure, second/third updates, same resolved WB | 4203.6 → 118.7 ms | 4284.1 → 19.1 ms |
| Same-WB settled recipe preview | 4241.7 → 118.6 ms | 4322.8 → 18.2 ms |

The slow repeated-recipe path is removed, while initial RAW development remains
about two seconds. The other two temperature-mismatched run pairs show the same
order of improvement, but are not presented as controlled temperature comparisons.
Numeric WB changes, source switching, interactive preview and FINAL export were
covered by the broader simulator runner below; they were not timed on this device.

All 16 optimized outputs in each device run were byte-identical to their own saved
baseline. All 16 actual RGBA files were also byte-identical across the selected
fair-temperature comparison directories. Force Metal succeeded for all
eight cases per run; CPU/Metal differences were at most one RGB8 code value
(gate: two). Resolution and settings did not change between arms.

For the selected comparison, the largest 10 ms **sampled physical footprint**
across both backends was **1807.1 → 1253.6 MiB**. This is a process-footprint
observation from one workload sequence, not an OS full-time maximum or a general
memory guarantee. The maximum 10 ms main-run-loop heartbeat gap was
**11.06 → 10.98 ms**. This shows the serial background harness left its main run
loop responsive; it does not measure the full SwiftUI slider/display frame path.

After saving all outputs, the full optimized **RawLab Performance** app was
reinstalled under the independent test ID and launched successfully. Its data
container, including benchmark evidence, was retained. The automated benchmark
host is no longer the installed app.

## Controlled simulator comparison

Dedicated iPhone 18 Pro Max simulator, iOS 27.0 build 24A434, UUID
`66094B04-76B7-4BC0-959F-22B4498C7AD2`. This is a simulator on the Mac, not iPhone
hardware. Both arms use the same compiled native framework, fixture, parameters,
1280-pixel preview and output settings. The native framework came from
`build/phase-one-basic-geometry/build/ios-geometry-sim-core/output`; that checkout's
tracked `lutools` tree has no diff from the baseline. Baseline Swift processor
sources were copied before editing. Both binaries were compiled with `-O`.

The recipe was `hamada_daylight_v2`, tint offset 20, strength 0.65, then 1.15.
Recorded thermal state was nominal throughout. Times include processing,
UIImage construction and histogram computation; file writes and pixel comparisons
are outside the timing window. Steady rows below use the median of the stated
repetitions in one before/after trial, not a device benchmark distribution.

| Case | CPU before → after | Force Metal before → after |
| --- | --- | --- |
| Normal warm exposure, three updates | 50.5 → 48.4 ms | 19.3 → 17.4 ms |
| Recipe exposure, second/third updates, same resolved WB | 3717.3 → 98.9 ms | 3687.2 → 18.6 ms |
| Recipe strength change, actual WB changes | 3725.1 → 1433.3 ms | 3647.9 → 1416.4 ms |
| Interactive same-WB preview | 2671.7 → 100.8 ms | 2459.1 → 19.3 ms |
| Settled preview after interaction | 3662.5 → 102.1 ms | 3560.2 → 20.0 ms |
| FINAL, 1280-pixel export cap | 6958.8 → 6959.8 ms | 4117.7 → 4101.4 ms |

Initial decode remains expensive (CPU neutral ~2 s). A genuine custom Kelvin
change still took ~1.4 s in this simulator. Source-URL switches still needed
~3.7 s to establish the target's WB and decode. The Metal cold-start measurement
was affected by first shader initialization and is not attributed to this fix.

All processing ran on a background serial queue. A 10 ms main-run-loop heartbeat
had maximum observed gaps of 24.8 ms before and 23.6 ms after. This confirms only
the harness's background execution, not the SwiftUI app's physical-device frame
performance. Resident memory was sampled before/after each case, not at its peak:
the largest snapshots were 804.2 MB before and 985.7 MB after. This trial does not
establish a memory improvement or explain allocator retention; device peak-memory
profiling is still required.

## Correctness and build checks

- Both arms completed 34 CPU/Force Metal cases with zero failures.
- All 32 strict settled/FINAL before/after outputs were byte-identical.
- Every Force Metal case succeeded and differed from its CPU reference by at
  most one 8-bit code value (test gate: two).
- FINAL output after interaction matched an independent manually expanded recipe
  in both backends. The FINAL cap is applied after exact RAW processing; native
  output-file encoding was not benchmarked by this runner.
- Interactive output differs from the baseline because the existing native
  contract can now reuse a same-WB **exact** cache. Both optimized interactive
  frames were byte-identical to their settled exact frames. No quality reduction
  was used for the speedup.
- Nine cache invariants passed: same-file reuse, size/mtime/URL invalidation,
  failed-load retry/preservation, successful replacement and unreadable identity.
- Full RawLab Release **arm64 simulator** Xcode build passed. The first build
  requested x86_64 too, which the single-arm64 test framework did not contain;
  setting `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` resolved that test-environment mismatch.
- `bash -n RawLab/tests/preview-performance.sh` and `git diff --check` passed.

The isolated `lutools/build-ios/sony2fuji.xcframework` contains arm64 device and
arm64 simulator slices as local test artifacts. Native sources were not changed;
the device slice was rebuilt from the baseline to make physical testing possible.

## Deliverables and reproduction

Changed production files: `Sony2FujiProcessor.swift` and
`Sony2FujiProcessor+Helpers.swift`. New runner:
`RawLab/tests/PreviewPerformanceTests.swift` / `preview-performance.sh`.

Local evidence (ignored files, not for commit):

- [Device comparison summary](../build/performance/device-benchmark/same-thermal-grade-summary.json)
- [Device baseline JSONL](../build/performance/device-benchmark/device-results-all/baseline-1791985401553-E1B0BDE6/metrics.jsonl)
- [Device optimized JSONL](../build/performance/device-benchmark/device-results-all/optimized-1791985302906-76186861/metrics.jsonl)
- [All four device runs](../build/performance/device-benchmark/device-results-all/)
- [Native device framework validation](../build/performance/device-core/validation.json)
- [Signed full device app build](../build/performance/device-app-build.log)
- [Restored app install](../build/performance/device-benchmark/restore-stock-install.log)
- [Restored app launch](../build/performance/device-benchmark/restore-stock-launch.log)
- [Baseline JSONL](../build/performance/baseline-01/metrics.jsonl)
- [Optimized JSONL](../build/performance/optimized-01/metrics.jsonl)
- [Baseline execution log](../build/performance/baseline-01.log)
- [Optimized execution log](../build/performance/optimized-01.log)
- [Successful arm64 app build log](../build/performance/app-build-arm64.log)

Run from this checkout with an already booted arm64 simulator and a matching
framework. Output directories must be new/empty and Git-ignored:

```bash
RAWLAB_PROCESSOR_SOURCE_ROOT="$PWD/build/performance/baseline-sources" \
  bash RawLab/tests/preview-performance.sh /path/to/simulator-framework-directory \
  <simulator-uuid> /path/to/Sony.ARW "$PWD/build/performance/baseline-new"

RAWLAB_PERFORMANCE_REFERENCE="$PWD/build/performance/baseline-new" \
  bash RawLab/tests/preview-performance.sh /path/to/simulator-framework-directory \
  <simulator-uuid> /path/to/Sony.ARW "$PWD/build/performance/optimized-new"
```

The local physical host, frozen processor copies and fixture copies are ignored
test artifacts under `build/performance/device-benchmark/`. Its `prepare.py`
produces single-target baseline/optimized projects with the same test ID and
bundled fixture; `summarize.py` accepts two metrics JSONL paths and verifies their
neighboring RGBA files. Use the existing configured development signature;
never change the production bundle ID or remove the test data container between
baseline and optimized installs. No credentials, RAW files or generated native
binaries are part of the tracked change.
