# Batch GPU Preference Verification

The initial sections record the `d1db748` fix. The later resume/AUTO coverage below closes the
explicit runtime gaps from that first verification without changing production behavior or waits.

## Scope and Behavior

Local follow-up on `feature/android-v08-editor`, starting from `a3c6651`.
Batch now inherits the editor GPU switch when a batch model is created:

- GPU disabled: `NativeProcessor.CPU`.
- GPU enabled: `NativeProcessor.AUTO`, retaining the existing CPU fallback, not FORCE.
- Both `beginBatch()` and `resumeBatch()` pass the current editor mode.
- Target validation, effect preview and final export all use the captured mode.
- Retry on the same model retains that mode. A newly resumed model reads the editor's current
  switch; no new GPU preference persistence or journal field was introduced.

Production changes are limited to Android Kotlin, with the existing workflow test and local
verification records updated. Native/JNI, Shared/core, edit parameters, image dimensions, journal
format and timeout values were not changed. No push, PR, release or shared-device operation.

## Red / Green

The existing `BatchWorkflowInstrumentedTest` was first changed to disable GPU through
`EditorViewModel.setGpuEnabled(false)` before importing either RAW. It also checks that the flag
remains false after activity recreation. The independent single-export reference explicitly uses
CPU, matching the requested batch mode. The original `compose.waitUntil(240_000)` remains intact.

Before changing production code, this test failed at that same wait after 240000 ms
(261.007 s total). Despite the editor flag being false, `RawLabGPU` initialized the SwiftShader
GLES backend in the batch path. This is the observed regression-test RED result, not a passing run.

After the three batch processor creation sites and both editor entry points were connected, the
entire existing class was run, including its recovery/partial-output cleanup case:

```sh
adb -P 5063 -s emulator-5762 shell am instrument -w -e class \
  com.rawlab.android.BatchWorkflowInstrumentedTest \
  com.rawlab.android.test/androidx.test.runner.AndroidJUnitRunner
```

Result: `OK (2 tests)`, 289.022 s total, 0 failures/ignored. Effect preview took 3121 ms;
the full original-size high-denoise batch export took 133402 ms, below the unchanged 240 s wait.
The class total includes a second, independent full-resolution CPU export for pixel comparison;
the original 240 s limit applies to the batch export wait, not the whole class.

The successful full workflow retained assertions for saved edits, frozen source settings, target
import, portrait/landscape/recreation, effect preview, completed MediaStore publication, target edit
record preservation, unchanged source/target bytes, identical decoded single/batch pixels and no
pending completed journal. The second case verifies known partial output removal and task discard.
This is not a direct-native diagnostic substituted for the batch workflow.

## Runtime Evidence

- Fixture: `DSC00316.ARW`, SHA-256
  `93a37abeaa3cd199773d25978a1045e580e26dbf884755f5d69c530e0bed5014`.
  Both frozen batch input copies matched this hash. The original fixture remains unchanged.
- Runtime journal: neutral film, exposure `.5`, contrast `.2`, Clean `true/10/72/100`, JPEG,
  empty `output.longEdge` (original size). Completed row is `SUCCESS`, output ready, no global error.
- Published output: MediaStore `is_pending=0`, 4672x7008; the pulled JPEG independently reports
  4672x7008 through host `sips`. The output was inspected before normal test cleanup deleted it.
- A native backtrace during the actual batch export reaches `BatchRunner` -> `nativeProcess` ->
  `applyWaveletDenoise` -> `filterPlane` -> `StationaryWavelet` -> `swt2` / `rawlab_swt_columns`.
  This positively identifies CPU wavelet work; the run has no `RawLabGPU` initialization entries.
- Task-private API 35 ARM64 AVD, 6144 MB, 4 vCPUs, SwiftShader, Java heap 576 MB. The emulator was
  cold-restarted between RED and GREEN; no Gradle build overlapped either instrumentation run.

Evidence is retained outside Git in `/tmp/rawlab-android-v08-56c3/gpu-preference`:
`red-workflow.txt`, `red-logcat.txt`, `green-workflow.txt`, `green-final-logcat.txt`,
`green-batch-native-stack.txt`, `green-batch-symbolized.txt`, `green-running-journals/`,
`green-completed-journal.properties`, `green-media-output.txt`, `green-batch-output.jpg`,
`green-batch-result.png` and `green-batch-effect.png`.

## Host Gates and Limits

```sh
export JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home
export ANDROID_HOME=/Users/xupeng/Library/Android/sdk
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug :app:assembleDebugAndroidTest \
  -PrawlabTestRaw=/Users/xupeng/mycode/rawtools/lutools/test-assets/DSC00316.ARW --console=plain
bash scripts/check-native.sh
```

PASS: Gradle build, 82 JVM tests (0 failures/errors/skips), lint (0 errors, 32 warnings), both APKs,
ARM64/x86_64 packaging and all 8 native libraries' 16 KB alignment. No suppression was added.
Evidence: `green-build.txt`, `green-host-counts.json`, `green-native-alignment.txt`.

Application APK SHA-256: `6f9bf756b1b8b24be79730a7a2b9633437f67351b60cc86dd9ac7debd356a9d5`.
Test APK SHA-256: `c6faa415a0f3842d15eab64524c5ffda5386709d101d5333b60d48c9d8406d3b`.
Independent read-only review found no concrete defect in the scoped diff; this is static evidence,
not another device test pass.

The prior [AUTO/SwiftShader diagnosis](batch-timeout-diagnosis.md) remains historical evidence:
its original GPU-on runs still timed out. This fix makes GPU-off usable through the real batch
workflow; it does not make full-resolution Clean fast on software GLES. In that initial run, GPU-on
AUTO mapping and new/resumed mode propagation were source-reviewed, not a completed GPU-on Clean
or resumed-export runtime test. CPU single/batch pixel parity here is not CPU/GPU or all-camera parity. Physical GPU,
thermal/throughput acceptance and hosted CI remain NOT REACHED.

Task-owned emulator PID `68419` and private ADB PID `65067` exited after verification;
ports `5063/5762/5763` have no listener. Shared ADB `5037/5047` retain original PIDs `23749/51027`
and were not operated. `final-listeners.txt` records the remaining listeners.

## Resume and AUTO Follow-Up

The follow-up adds `BatchGpuModeInstrumentedTest` and moves the existing `syntheticRlook()`
implementation unchanged into test-only `LookTestFixtures.kt`, preserving the generated bytes. No production API, JNI/core code,
GPU preference persistence or timeout was changed. The original `BatchWorkflowInstrumentedTest`
and its `240_000` export wait are unchanged and were not rerun in this test-only follow-up.

The new recovery fixture saves an interrupted `PROCESSING` row to the real `BatchJournal`, reloads
it as `PENDING`, enters through `EditorViewModel.resumeBatch()` with the current editor switch,
and exports through `retryFailed()`. It does not claim that a GPU preference survives process death.
GPU-enabled controls cover both `beginBatch()` and `resumeBatch()` independently.

Final invocation on the same task-private API 35 ARM64 / SwiftShader AVD:

```sh
adb -P 5063 -s emulator-5762 shell am instrument -w -e class \
  'com.rawlab.android.BatchGpuModeInstrumentedTest,com.rawlab.android.NativeProcessorTest#nativeLookValidationAndRenderingUseSyntheticFixtures' \
  com.rawlab.android.test/androidx.test.runner.AndroidJUnitRunner
```

PASS: `OK (4 tests)`, 413.860 s total, 0 failures and 0 ignored. Three new methods execute five
actual batch jobs; the fourth method rechecks the extracted synthetic look fixture. Every batch
export wait is `240_000 ms`. The class total includes independent reference exports and controls.

| Batch Scenario | Export Time | Final Output and Evidence |
|---|---:|---|
| GPU off, resumed, original-size JPEG + Clean `true/10/72/100` | 135752 ms | 4672x7008, identical to independent CPU final export |
| GPU on, resumed, GLES-eligible PNG control | 6750 ms | 200x300, identical to FORCE final export, different from CPU |
| GPU on, new, GLES-eligible PNG control | 6358 ms | 200x300, identical to FORCE final export, different from CPU |
| GPU on, resumed, CPU-only RLOOK PNG control | 9068 ms | 200x300, identical to CPU final export; FORCE rejects same RLOOK |
| GPU on, new, CPU-only RLOOK PNG control | 9095 ms | 200x300, identical to CPU final export; FORCE rejects same RLOOK |

The original-size recovery case retains exposure `.5`, contrast `.2`, neutral film and Clean values;
its test fixes white balance at 6500 K / tint 0 for mode comparisons. Runtime journal confirms
JPEG and empty `output.longEdge`; MediaStore and independently pulled JPEG bounds both report
4672x7008. A sampled `BatchRunner` export stack enters CPU `filterPlane` -> `cv::boxFilter` at
`wavelet_denoise.cpp:328`, after the GPU-success early-return branch. Recovery preview matches CPU
and differs from an independently asserted GLES preview. Input byte hashes remain unchanged.

The 300 px GPU-on controls intentionally disable denoise; they test mode selection/fallback, not
full-resolution Clean performance. Eligible batch previews/final exports match the FORCE controls
and are distinct from CPU controls on this fixture/driver. RLOOK is an existing Android GLES
capability boundary: AUTO uses CPU, while FORCE fails rather than silently falling back. Both entry
points complete real RLOOK exports and preserve an existing sentinel output when FORCE is rejected.
New-batch RLOOK uses a task-private managed look, removed during cleanup. Successful jobs, temporary
inputs and gallery outputs are cleaned; final batch directory is empty and MediaStore query has no rows.

JNI file export still returns no backend value. Final-file differential controls and the native
call chain are evidence, not a preview backend relabeled as an export backend. The CPU/GLES
nonzero pixel difference is a tested precondition for this fixture/driver, not a universal numerical
contract. These checks do not cover every RAW, physical GPU, driver context loss or thermal behavior.

### Failure Detection and Native Fallback

Temporary local mode mutations were applied only to verify the tests, then fully restored:

- GPU off -> AUTO and GPU on -> FORCE: both selected cases FAIL as expected in 24.357 s, at the
  wrong preview pixels and actual RLOOK processing failure respectively, before export waits.
- GPU on -> CPU: the eligible control FAILS at wrong batch preview pixels in 11.758 s.

The final application SHA-256 is unchanged from `d1db748`:
`6f9bf756b1b8b24be79730a7a2b9633437f67351b60cc86dd9ac7debd356a9d5`.
Final test APK SHA-256: `ef846817198b6018ef948cd724a36a98643909c73f8d33c45fade2a8f9017a36`.
There is no residual production diff from the mutations.

The existing Android `rawlab_gpu_tests` ARM64 target was also built and run without RAW arguments
(buffer-only phase), with an external `timeout 240` guard. Exit 0: the 400000x8 source halo exceeds
the GLES tile budget, FORCE returns processing error, AUTO reports actual CPU backend and matches
CPU pixels (`maxDN=0`). This tests a real resource-limit fallback separately from RLOOK capability
fallback; it is not an injected driver fault or a batch-file-export failure test.

Final host gate command remains the Gradle/native-alignment command above: PASS, 82 JVM results
with 0 failures/errors/skips, lint 0 errors/32 warnings, both APKs and all 8 native alignments.
Valid up-to-date outputs were reused; this was not a clean build. No build overlapped final device tests.

Evidence: `/tmp/rawlab-android-v08-56c3/gpu-followup/`, especially `final-instrumentation.txt`,
`final-logcat.txt`, `final-build.txt`, `final-host-counts.json`, `final-sha256.txt`,
`resumed-cpu-native-stack.txt`, `resumed-cpu-symbolized.txt`,
`resumed-cpu-running-journal.properties`, `resumed-cpu-completed-journal.properties`,
`resumed-cpu-media-output.txt`, `resumed-cpu-output.jpg`, `mutant-auto-force.txt`, `mutant-cpu.txt`,
`native-smoke.txt`, `final-batch-directory.txt` and `final-gallery.txt`.

The task-owned emulator `78889` and private ADB `77781` exited; `5063/5762/5763` have no listener.
Shared ADB `5037/5047` retain original PIDs `23749/51027`; no shared-device commands were issued.
All instrumentation used explicit private ADB/serial selection. The initial emulator launch was
restarted with explicit private-ADB environment settings before installing or testing the app.
No push, PR or release was performed.
