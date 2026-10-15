# Original-Size Clean Batch Timeout

## Scope

Local follow-up to the Android v0.8 verification failure. The production
`BatchWorkflowInstrumentedTest` and its `240_000 ms` export wait remain unchanged.
No production fix, timeout increase, push, PR, release, shared-device operation or Shared/core edit.

- Baseline: `440b9788ff4cfd8a3f5dfa781b16a33997ccd801`.
- Current application: `f598c74db28983c393b5560646cd01a77374a1b1`, delivered in `a55be23`.
- Opt-in diagnostic test source: `cba4b4ceb9235250355529b575094c24cf2e61ea`.
- Diagnostic test APK SHA-256: `483b679d172cac4ffaad81cc251062ca9c6b68e280147b9411755609cbbb8c1e`.
- Current APK SHA-256: `450e37714f5ae1980b5cdfdb53b4364ce43d8505ad07f285ce3bbc995c7c9b5a`.
- Baseline APK SHA-256: `88ed4544d43a989cebb450d797f5acb4041fa3ebc7b714ed0aad2bf28fc8da27`.
- Fixture: `DSC00316.ARW`, SHA-256
  `93a37abeaa3cd199773d25978a1045e580e26dbf884755f5d69c530e0bed5014`.
  Host ImageIO (`sips`) independently reports 7008x4672 pixels (32.7 MP); portrait output is 4672x7008.
- Device: task-private API 35 ARM64 AVD, 6144 MB, 4 vCPUs, SwiftShader/ANGLE software GLES.
  Private ADB `5063`, serial `emulator-5762`, emulator ports `5762/5763`.
- Evidence directory: `/tmp/rawlab-android-v08-56c3/diagnosis` (not committed).

## Source Comparison

`NativeProcessor.kt`, `BatchWorkflowInstrumentedTest.kt`, Android JNI/CMake, and `lutools`
are unchanged between baseline and current. `BatchExport.kt` only adds two count/progress getters.
The original batch snapshot has `output.longEdge=null`, JPEG, neutral film, exposure `.5`,
contrast `.2`, and Clean denoise `true/10/72/100`. Runtime journal and native-control settings agree.

The baseline was materialized with `git archive` into the task-private `baseline-src` directory;
it contains tracked baseline files only, no `.git` or dirty working-tree copies. Build command:

```sh
./gradlew :app:assembleDebug :app:assembleDebugAndroidTest \
  -PrawlabTestRaw=/Users/xupeng/mycode/rawtools/lutools/test-assets/DSC00316.ARW \
  -Pandroid.injected.build.abi=arm64-v8a --console=plain
```

JDK 21, SDK 35, NDK 27.2.12479018, CMake 3.22.1; `BUILD SUCCESSFUL in 6m 28s`.
The ABI-injected baseline APK has Android's test-only flag and was installed with `adb install -t`.
The wrapper then failed assigning zsh's reserved `status` variable; that was after Gradle success,
not a failed APK build. Both baseline APKs were installed successfully.

All 782 ARM64 compile commands match after normalizing only the two source/build-root prefixes
(`native-compile-comparison.json`). Independently built `.so`/`.text` hashes differ; no binary identity
claim is made. No baseline/current runtime throughput ratio is inferred from the build or test totals.

## Experiments

Results are recorded after each fixed-budget run finishes. A control does not replace or turn the
original batch test into a PASS.

| Experiment | Result |
|---|---|
| Current original batch, fresh app/process, no preceding DNG suite | Same 240000 ms export timeout; 270.395 s total. Exploratory profiling overlapped baseline build. |
| Baseline original batch, fresh app/process, no concurrent build | Same 240000 ms export timeout at line 74; 268.038 s total. |
| Current original batch, fresh app/process, no concurrent build | Same 240000 ms export timeout at line 74; 271.810 s total. |
| Current direct-native CPU Clean, fresh export session, whole-test 240 s budget | PASS: export 132008 ms, preview 2856 ms, JUnit total 135.314 s; original-size JPEG and unchanged input SHA verified. |
| Current direct-native FORCE, denoise disabled, whole-test 240 s budget | PASS: export 6062 ms, preview 3673 ms, JUnit total 10.072 s; original-size JPEG and unchanged input SHA verified. |

The first CPU probe completed native export in 175659 ms and produced a 4672x7008 JPEG, but the
probe incorrectly asserted 6000x4000 and FAILED. That exploratory test is not relabeled as passing.
After checking source dimensions with `sips`, the diagnostic expectation was corrected. The final
probe also uses `.dng` input names and a fresh export processor, matching the batch's cache boundary.
The emulator process was cold-restarted before the final native controls, so killed GPU work from
the censored original-test runs cannot carry into those controls. No Gradle build ran concurrently
with either controlled original-test run or the final controls. Other host activity was not stopped;
these are fixed-budget diagnostics, not a calibrated throughput benchmark.
Historical 24 MP camera timings are not used as a speed baseline for this 32.7 MP fixture.

The original invocation was identical for each installed application/test APK pair:

```sh
adb -P 5063 -s emulator-5762 shell am instrument -w -e class \
  'com.rawlab.android.BatchWorkflowInstrumentedTest#remembersEditsAndExportsFrozenBatchWithoutChangingTargetRecords' \
  com.rawlab.android.test/androidx.test.runner.AndroidJUnitRunner
```

## Native Localization

The current and baseline native backtraces both reach:

```text
BatchRunner render -> NativeProcessor.nativeProcess -> applyWaveletDenoise
-> gpuWaveletFilter -> computeWaveletFilter -> glMapBufferRangeAEMU
-> QemuPipeStream::commitBufferAndReadFully
```

This is before output publication and not a Compose/SAF/JPEG-writer wait. Current steady-state
simpleperf samples have 62.29% in `goldfish_pipe.ko:writel`; a later window has 61.16% there.
The task-owned host emulator remained active; macOS `sample` shows
`libvk_swiftshader.dylib` workers in `sw::ComputeProgram::run`, not only sleeping threads.
CPU-control samples instead execute native `iswt2` and `swt_per_stride`.
Baseline sampling shows `VmRSS=2005740 kB`, `VmHWM=2481868 kB` and `VmSwap=0`; the observed worker is
alive in the GPU readback path, not terminated by LMK or a reported native exception.

`RawLabGPU` records the actual software renderer in both source versions:
`ANGLE ... SwiftShader Device ... SwiftShader driver-5.0.0`, GLES 3.1.
The source confirms AUTO tries GPU wavelet and falls back only on processing failure, not on
slow successful software execution. Batch creates its own default-AUTO processor; the editor's
GPU preference does not propagate into batch. That behavior is pre-existing, not a v0.8 change.

File evidence: `current-steady-native-stack.txt`, `baseline-steady-native-stack.txt`,
`current-steady-perf.txt`, `current-late-perf.txt`, `current-qemu-sample.txt`,
`cpu-clean-perf.txt`, `current-original-logcat.txt`, and `baseline-gpu-logcat.txt`.

## Diagnostic Harness

`BatchExportDiagnosticTest` requires `batchDiagnosticEnabled=true`; ordinary device-suite discovery
skips it before opening a fixture. It pins the exact fixture hash, original-size request, snapshot
construction and 7008x4672 output, and verifies the source bytes are unchanged. The complete encoded
settings are compared with runtime journals in this investigation, not locked by a future-proof
full-snapshot assertion in the test itself. UUID output directories
prevent stale-artifact confusion. A 240 s JUnit budget covers the whole test, including setup;
the export must also finish below 240 s. This is stricter than the original export-only wait.

The harness records `previewBackend` only. JNI file export has no backend-return API, so
`exportBackend` is explicitly null; AUTO preview may validly return CPU or GLES. CPU/FORCE controls
select their mode explicitly. No preview backend value is silently relabeled as an export backend.
The harness does not cover BatchRunner, journal, MediaStore or single/batch pixel parity.
Within `EditSettings`, the `denoise=false` control changes only the enable flag, retaining Clean's numerical values to
isolate one variable; it is not advertised as the default denoise preset. JSON `passed` stays false
until all assertions and the total-budget check finish; JUnit output is the authoritative test result.
The FORCE-without-denoise control does not rely on a preview backend to assert export success:
the native FORCE contract returns an error instead of silently falling back when GLES rendering fails.

```sh
adb -P 5063 -s emulator-5762 shell am instrument -w \
  -e class com.rawlab.android.BatchExportDiagnosticTest \
  -e batchDiagnosticEnabled true -e batchDiagnosticGpu cpu \
  com.rawlab.android.test/androidx.test.runner.AndroidJUnitRunner
```

The second native control uses the same command with `batchDiagnosticGpu force` and
`-e batchDiagnosticDenoise false`. Opt-in protection was separately checked without the enable flag:
the runner reports assumption status `-4` in 0.015 s, not a completed export.

Authoritative final files:

- `baseline-original-batch.txt`, `current-controlled-original-batch.txt`: original-test failures.
- `baseline-original-journal.properties`, `current-controlled-journal.properties`: frozen settings/size.
- `final-current-cpu-clean.txt`, `final-current-force-no-denoise.txt`: completed native controls.
- `completed-native-control-artifacts/`, `completed-control-summary.json`: both final JSON reports
  have `passed=true`, `stage=done`, 4672x7008 dimensions and unique run IDs. Earlier partial/failed
  probe directories are retained separately and are not the final control evidence.
- `diagnostic-opt-in-guard.txt`, `final-diagnostic-build.txt`, `final-host-counts.json`: opt-in skip,
  instrumentation assembly, 82 JVM tests with no failures, lint 0 errors/32 warnings.

## Conclusion and Limits

This timeout is reproduced on the exact pre-v0.8 baseline. The sampled bottleneck is the existing
AUTO software-GLES full-resolution Clean wavelet path: the guest waits for wavelet compute/readback
while host SwiftShader workers execute compute shaders. The FORCE + denoise-disabled control
finishes in 6.062 s; the CPU + Clean control completes in 132.008 s, within the unchanged budget.
These controls change backend/mode as documented; they are not a completed direct-native AUTO Clean
run or a one-variable timing ratio. The evidence points to the pre-existing SwiftShader/emulator
slow path rather than v0.8 introducing this timeout.

Both original runs are censored at 240 s, so they do not prove equal uncensored GPU throughput or
exclude every possible smaller performance difference. The original failed production-test gate
remains failed, not waived or converted to a PASS. CPU control is a diagnostic route, not a product
fix: batch still defaults to AUTO and does not inherit the editor GPU switch. No production behavior
was changed. These are emulator measurements, not physical-device GPU, thermal or throughput
acceptance; they do not establish all-camera or single/batch pixel parity.

## Shutdown

Task-owned emulator processes `99322` and `29867`, and private ADB server `99319`, have exited.
Ports `5063/5762/5763` have no listener. Shared ADB servers `5037/5047` remain running with their
original PIDs `23749/51027`; they were not operated. Evidence and the baseline build snapshot remain
under the task-private `/tmp` directory. The original fixture SHA-256 is unchanged.
