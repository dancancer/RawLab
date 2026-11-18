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

## P2 Review Follow-Up

The review found two test gaps, not a new rendering regression: GPU-off target-import validation
had no observable mode assertion, and active failure cleanup could delete a publishing URI while
native work continued into the next test. The earlier successful runs did not exercise that failure
path. Both original `240_000` export waits and the original-size Clean settings remain unchanged.

`EditorViewModel` now forwards a per-model processor factory to new and resumed batches. Its default
still constructs the real `NativeProcessor(mode, database)` at all three batch creation sites;
`@JvmOverloads` retains the Android `(Application)` constructor. The new focused GPU-off test records
exactly one CPU construction during `beginBatch -> addUris -> copyTarget`, before any effect preview
or export. The recording factory returns a real processor, not a mock render. This observes the
construction mode; the existing CPU/GLES differential tests separately verify native behavior.

Both batch test classes now use `BatchTestCleanup`. Each fixture records its UUID, actual job UUID,
process owner and render-file baseline. Active cleanup sends cancellation but deletes nothing and
terminates the failed instrumentation process. A crash is a failure, never a pass or a retry of the
240-second wait. Fresh-process recovery refuses a still-live owner, rereads the final checkpoint,
and cleans only the recorded jobs (including interrupted atomic-checkpoint `.tmp` files), inputs,
managed look, outputs and newly created render files.
Unique target names identify a pending MediaStore insert even before its checkpoint; both collection
queries and deletion verification explicitly include pending rows. Managed-look ownership is recorded
by unique original name before import, closing the import-return/ID-recording window.

Use the task-owned device only, with explicit ADB server and serial:

```sh
ANDROID_HOME="$HOME/Library/Android/sdk" ANDROID_ADB_SERVER_PORT=5063 \
ANDROID_SERIAL=emulator-5762 bash RawLabAndroid/tests/batch-gpu.sh /tmp/batch-gpu-results
```

The wrapper runs one method per invocation, force-stops the target package, verifies its PID is gone,
and invokes recovery in a new process after success or failure. It preserves an overall nonzero
result after any failed/crashed method. Normal per-method recovery may find no manifest; that is
not itself proof of a dead-owner takeover. The deterministic cleanup tests and opt-in crash probes
provide that evidence. `BATCH_ABORT_PROBE=true` injects failure only after the real CPU export enters
`nativeProcess`; `BATCH_LOOK_ABORT_PROBE=true` exits immediately after new-batch managed-look import.
Neither probe changes the formal export wait. These are expected failures, separate from normal
regression results, and not a reproduction that waits for a real 240-second expiration.

This is test-process isolation, not an interruptible production native API or a general atomic
crash-recovery protocol. Job ownership is recorded before export starts; arbitrary external
process death before that record and unrelated application caches are outside this cleanup contract.
No JNI/shared-core, GPU preference persistence or production cancellation behavior was changed.

### Local Results

All rendering checks below used application SHA-256
`b1fa839069d84dc99c0024d85b87ad6fe64412f12855d2b4a8b7b91bb9f9fbc1`.
The four GPU methods passed in independent invocations (wrapper exit 0); the original UI class
passed `OK (2 tests)`, 295.369 s. Formal export waits remain 240 seconds, not the entire method's
duration including independent reference renders.

| Scenario | Export Time | Result |
|---|---:|---|
| GPU-off new target validation | n/a | exactly one real processor created with CPU mode `[0]` |
| GPU-off resumed original-size Clean JPEG | 132005 ms | 4672x7008, exact CPU reference parity |
| GPU-on resumed / new GLES control | 5616 / 4673 ms | 200x300, FORCE parity and distinct from CPU |
| GPU-on resumed / new RLOOK fallback | 8326 / 8412 ms | 200x300, CPU parity, FORCE rejects without overwriting sentinel |
| Original complete UI workflow, GPU off, original-size Clean JPEG | 139828 ms | exact CPU reference parity; target edit record and input bytes unchanged |

The original UI workflow also completes rotation/recreation, effect viewing, publication and close.
Its published MediaStore row was independently read as 4672x7008, `is_pending=0` during the CPU
reference render. The second original test rechecks partial-output reconciliation and discard.

Negative controls remain separate from passes:

- Only target validation was temporarily changed from `processorFactory(gpuMode, ...)` to
  `processorFactory(AUTO, ...)`: FAIL, `expected [0] but was [1]`, 11.446 s. The site was restored.
- Only cleanup's collection query temporarily omitted `include_pending`: FAIL at
  `Cleanup also finds outputs not yet checkpointed`. The query was restored. The assertion runs
  before its emergency fixture deletion, so that deletion cannot mask the defect.
- Latest active-native probe: PID 6107 entered real `nativeProcess`, then the injected assertion
  caused immediate process termination; runner reports `Process crashed`. Recovery PID 6165 cleaned
  the recorded fixture. Wrapper exit 1, as required, with no extension or retry of the export wait.
- Latest managed-look probe: PID 6212 exited immediately after import returned, before batch creation;
  recovery PID 6278 removed the look using its pre-recorded unique original name. Wrapper exit 1.

The rendering runs used test APK
`7f0df4ef93cca4e1ea8276e7e8afd9cdd4b8375fdf2fc4a923e701b348922ea4`.
Subsequent cleanup-only changes add interrupted journal `.tmp` removal and idempotent, pending-aware
MediaStore ID deletion. A real repeated-delete `SecurityException` exposed by the cleanup probe was
fixed rather than ignored. Final test APK
`15eb2b0d37e2677112c9028b4c876392b9460d4f4d87875f3ea81bd10af1b205`
passes `BatchTestCleanupInstrumentedTest`: `OK (3 tests)`, 0.231 s. Its publisher test covers an open
writer with no checkpoint, with a checkpoint, and with an already-deleted checkpoint URI. It verifies
live-owner refusal, no deletion/close while active, and pending-aware absence after stopping. The
simulated dead-owner test verifies both job IDs/properties, an interrupted checkpoint `.tmp`, new
render removal, and preservation of pre-existing render and unrelated input files. Both latest crash
probes above also ran on this final test APK. These incremental cleanup checks do not relabel the
earlier rendering invocation as having used the later test APK; the application APK is identical.
Targeted normal follow-up on the final test APK also PASSes (wrapper exit 0): target validation
again records `[0]` (11.482 s), and resumed/new AUTO RLOOK exports complete in 8746/11091 ms with CPU
pixel parity (63.092 s method total). Their normal cleanup and fresh-process recovery both pass.

Final host gates: Gradle JVM tests/lint/application and test APK builds PASS (82 JVM tests, zero
failures/errors/skips; lint zero errors/32 existing warnings), APK and all eight native libraries
16 KB aligned, `bash -n` and `git diff --check` clean. Valid up-to-date outputs were reused; this is
not a clean build. RAW SHA-256 remains
`93a37abeaa3cd199773d25978a1045e580e26dbf884755f5d69c530e0bed5014`.

Evidence: `/tmp/rawlab-android-v08-56c3/gpu-p2/`, including `final-batch-gpu/`, `final-workflow.log`,
`workflow-published-media.txt`, `validation-single-site-red/`, `publisher-missing-pending-red.log`,
`final-cleanup-tests.log`, `cleanup-final-native-abort-red/`, `cleanup-final-look-abort-red/`,
`final-cleanup-followup/`,
`final-build.log`, `native-alignment.log`, `rendering-sha256.txt` and `final-sha256.txt`.
Intermediate failures remain recorded separately; `preliminary-batch-gpu/` is not the final wrapper
gate (its running script was edited and its final parser step failed, then the stable script was
rerun successfully). Physical GPU, other cameras/devices and hosted CI remain NOT REACHED.

Final device inspection finds no task batch entries, cleanup manifest, render temporary files or
gallery rows (including pending); the managed-look registry has `count=0`. Installed application and
test APK hashes match `final-sha256.txt`. The task-owned emulator PID 17147 and private ADB server
were shut down; ports 5063/5762/5763 have no listener. Shared ADB 5037/5047 retain PIDs 23749/51027
and were not operated. At completion of device verification, the work was local and uncommitted;
this section records that pre-commit snapshot. No push, PR or release was performed.

### Local Commit Preparation

Before packaging this follow-up into one user-authorized local commit, all seven code/test/script
files and this verification document matched
`/tmp/rawlab-android-v08-56c3/gpu-p2/final-source-sha256.txt` (the earlier P2 snapshot, not the
later `preview-p2` snapshot). Only documentation wording
was then updated to distinguish the recorded pre-commit snapshot from the later commit preparation;
no tested implementation or regression-test code changed.

The Gradle JVM/lint/application and test APK gates were invoked again: PASS, with 5 tasks executed
and 77 up-to-date. JVM reports remain 82 tests with zero failures/errors/skips; APK/native 16 KB
alignment, `bash -n` and diff whitespace checks also pass. Both APKs and the external RAW still match
`final-sha256.txt`. The emulator/device suite was not restarted or rerun for commit packaging.
Pre-commit logs are `precommit-build.log` and `precommit-native-alignment.log` in the same evidence
directory. Only the P2 source/tests, wrapper, verification record and P2 re-review report are included;
the earlier `1440` review, sample RAW, generated APKs and temporary mutation artifacts are excluded.

## SELECTING Preview Isolation Follow-Up

Re-review of `20f6397` found a narrower remaining failure path: the original UI workflow's effect
preview runs from a Compose `LaunchedEffect`, while the batch remains `SELECTING` and the editor
operation remains `NONE`. A failed 90-second preview wait could therefore reach `finish(false)`
and delete frozen inputs without first stopping the native preview process.

This follow-up changes tests and the host wrapper only. The workflow now sets `previewPending`
before clicking View and clears it only after the unique target preview Image appears. That Image
is published only after `BatchExportModel.preview()` returns, including synchronous native processing,
bitmap copying and the processor's `use`/`close`. A failure before that point is conservatively active,
regardless of phase, and takes the existing cancel/kill path without deleting inputs. Fresh-process
recovery remains responsible for cleanup. This is not a new production cancellation API.
The original preview wait remains `90_000`; both export waits remain `240_000`.

### Red / Green Failure Probe

The opt-in `BATCH_PREVIEW_ABORT_PROBE=true` probe uses the actual original UI workflow and real RAW.
Before injecting an assertion it requires one thread stack containing both `NativeProcessor.nativeProcess`
and the batch preview coroutine, then asserts `SELECTING`, editor `NONE`, and frozen input presence.
It does not substitute target validation/export for preview, mock native processing, or wait for a real
90/240-second expiration. The 60-second probe wait only bounds observing native entry; missing the
entry marker is NOT REACHED, not successful isolation evidence.

Before the fix, this probe reached the requested state in PID 3096, but the old process emitted
`cleanupComplete`. The fresh-process recovery assertion then FAILed at
`Failed preview must defer cleanup to this new process`: the ownership manifest had already been
deleted. The wrapper returned 1. This is the observed RED result, not a passing recovery.

After the fix, the same probe twice reached real preview native work and emitted `cleanupDeferred=true`
followed by `Process crashed`. Recovery in a distinct PID first required the old `/proc/<pid>` to be
absent, an existing ownership manifest, different fixture/job IDs, and two nonempty input files in
each owned directory. Only then did it run cleanup and assert both directories, journal properties
and the manifest absent. Thus an empty/no-op recovery cannot pass this probe.

- Owner 3369 -> recovery 3462: inputs preserved until takeover; recovery `OK (1 test)`.
- Owner 3515 -> recovery 3612: same assertions pass; the following independent CPU target-import
  test also passes with `modes=[0]`, showing subsequent real native work is not blocked by the old
  preview. The overall wrapper still returns 1 after the injected crash.

The wrapper now includes both original workflow methods by default, one invocation per method.
Selectors accept a GPU method name, `Class#method`, or `com.rawlab.android.Class#method`.
Preview injection/recovery arguments are enabled only for the complete workflow method. A verified
probe requires all native-entry, deferred-cleanup, crash, input-preservation and cleanup markers;
`Process crashed` alone is insufficient. Main-test failures remain sticky after successful recovery.
Recovery failure deliberately stops the wrapper immediately: it must not start another method while
resource ownership is unresolved.

```sh
ANDROID_ADB_SERVER_PORT=5063 ANDROID_SERIAL=emulator-5762 BATCH_PREVIEW_ABORT_PROBE=true \
  bash RawLabAndroid/tests/batch-gpu.sh /tmp/preview-isolation-probe \
  'com.rawlab.android.BatchWorkflowInstrumentedTest#remembersEditsAndExportsFrozenBatchWithoutChangingTargetRecords'
```

This command is an expected failing invocation, not a normal green regression command.

### Normal Regression

The default wrapper run PASSes all six methods and all six fresh-process recovery invocations,
exit 0. It uses test APK `8b6ad22a99eb8a4449df7f4d7725c79a2d3aa986297118c16182b62a97335a8d`.
The application APK remains unchanged at
`b1fa839069d84dc99c0024d85b87ad6fe64412f12855d2b4a8b7b91bb9f9fbc1`.

| Scenario | Export Time | Result |
|---|---:|---|
| GPU-off target validation | n/a | exactly one real CPU construction `[0]` |
| GPU-off resumed original-size Clean JPEG | 148315 ms | 4672x7008, exact CPU reference parity |
| GPU-on resumed / new eligible GLES | 5141 / 5378 ms | FORCE parity; distinct from CPU |
| GPU-on resumed / new AUTO RLOOK fallback | 9708 / 8451 ms | CPU parity; FORCE rejects without overwriting sentinel |
| Original complete UI workflow | 135464 ms | original-size Clean, exact CPU reference parity, frozen bytes/target edits unchanged |
| Original partial-output recovery/discard | n/a | PASS |

The complete UI method also passes rotation/recreation, effect preview (3386 ms), publication and
close; method total is 293.422 s including the independent full-resolution CPU reference. The resumed
CPU method total is 319.538 s, likewise including its reference. Neither method total changes the
240-second batch export wait.

Host gates PASS: Gradle JVM tests/lint/application and instrumentation APK builds, 82 JVM results
with zero failures/errors/skips, lint zero errors/32 existing warnings, APK/native 16 KB alignment,
`bash -n` and diff whitespace checks. Valid up-to-date outputs were reused; no Gradle build overlapped
device tests. RAW SHA-256 remains `93a37abeaa3cd199773d25978a1045e580e26dbf884755f5d69c530e0bed5014`.

Evidence: `/tmp/rawlab-android-v08-56c3/preview-p2/`, including `red-test.diff`, `red-preview/`,
`red-preview-wrapper.log`, `final-preview-abort/`, `final-preview-followup/`, `final-batch/`,
their wrapper logs, `final-build.log`, `final-host-counts.json`, `native-alignment.log`,
`rendering-source-sha256.txt` and `final-sha256.txt`. The default run used the recorded rendering
source snapshot; the later selector-normalization-only wrapper edit does not change either APK.
No production GPU wiring, JNI/shared core, timeout or test rendering code changed during these runs.
Physical GPU, other devices and hosted CI remain NOT REACHED. Work stays local and uncommitted;
no push, PR or release is authorized or performed.

Final selector follow-up uses the fully qualified preview method, then a bare GPU method and a
short `Class#method` partial-recovery method in the same wrapper run. Owner 4621 -> recovery 4706
again verifies native entry, deferred cleanup, old-PID absence, preserved inputs and deletion;
both following normal methods and their recovery invocations PASS. Wrapper exit remains 1 for
the injected failure. The final script therefore exercises all three selector forms, not only syntax.
`final-qualified-preview/` and `final-qualified-preview-wrapper.log` record this incremental check;
`final-source-sha256.txt` records the final two test sources and wrapper. Neither APK changed.

Final `BatchTestCleanupInstrumentedTest` PASSes `OK (3 tests)`, 0.208 s, including the pending writer,
live-owner refusal and simulated dead-owner checks. Installed application/test hashes match
`final-sha256.txt`. Final device inspection finds an empty batch directory, no cleanup manifest or
render files, no RawLab gallery rows including pending, and only the managed-look registry with
`count=0` (no stage/orphan files). See `final-cleanup-tests.log`, `installed-*-sha256.txt`,
`final-batch-directory.txt`, `final-manifest.txt`, `final-renders.txt`, `final-gallery.txt` and
`final-look-*` under the same evidence directory.

All device commands selected task-owned `emulator-5762` through private ADB 5063. The emulator
PID 99188 and private server PID 99187 exited; ports 5063/5762/5763 have no listener. Shared ADB
5037/5047 retain PIDs 23749/51027 and were not operated. `final-listeners.txt` records this boundary.

## Boundary Follow-up and Physical-device Diagnosis (2026-10-15)

This section supersedes the earlier physical-device NOT REACHED statement only for the
specific cases below. Work remains local and uncommitted. No push, PR, release or hosted CI
write is authorized. Both export waits remain `240_000`; the effect-preview wait remains
`90_000`. No quality reduction, CPU/GPU substitution, native sleep or timeout padding is used.

### Isolation and Source Provenance

Evidence root: `/tmp/rawlab-android-v08-56c3/boundaries/`.

- Physical device: Lenovo TB320FC, Android 15/API 35, arm64; actual driver
  `Adreno (TM) 730`, GLES 3.2, driver `0615.96`.
- Test application/test packages: `com.rawlab.android.batchprobe56c3[.test]`.
  The baseline uses `com.rawlab.android.batchbaseline56c3[.test]`.
  APK application IDs are checked before installation. The Java namespace/JNI names are unchanged.
- The original `com.rawlab.android` and existing Sony-memory packages are not overwritten,
  cleared or force-stopped. The original APK hash/metadata are recorded before testing.
- Physical ADB uses private port 5063 and an explicit serial. The task AVD uses private port
  5065 and `emulator-5762`. Shared servers 5037/5047 are not restarted or killed.
- Initial frozen batch snapshot: `batch-source-sha256.txt`, `batch-sha256.txt`,
  `batch-app.apk`, `batch-test.apk`. These timings precede the save-feedback and atomic
  backend-reporting follow-ups; they are not relabelled as final-APK results.
- Pre-MissingLook application SHA-256: `41ecd27f4764fb36febf4241019843f56bf9452ccd72f3143dcb49a80209de52`.
  Its test SHA-256: `f5e4d3660b275317cdf6bd0f31db1949201118ae1ed0ca85d7ea898288921423`.
  See `final-resource-apk-sha256.txt` and `final-resource-source-sha256.txt`.
  The later MissingLook fix has its own incremental hashes below; earlier timings are not
  relabelled as results from that later APK.
  The original RAW SHA-256 remains
  `93a37abeaa3cd199773d25978a1045e580e26dbf884755f5d69c530e0bed5014`.

### Physical Results and CPU Timeout Attribution

The initial frozen matrix has 13 successful invocations and one genuine CPU UI-workflow
failure, including the fresh-process recovery calls. Its wrapper exits 1, not 0.
Evidence: `physical/final-matrix-wrapper.log`, `physical/final-matrix/`.

| Case | Batch Export Time | Evidence |
| --- | ---: | --- |
| GPU-on, resumed original-size Clean JPEG | 105426 ms | actual batch backend 2; 4672x7008; FORCE pixel parity |
| GPU-on, new original-size Clean JPEG | 81955 ms | actual batch backend 2; 4672x7008; FORCE pixel parity |
| GPU-off target validation | n/a | exactly one real processor construction, modes `[0]` |
| GPU-off, resumed original-size Clean JPEG | 230179 ms | backend 0; 4672x7008; exact CPU reference parity |
| Eligible GLES, resumed/new | 6885 / 6858 ms | backend 2; FORCE parity and distinct CPU pixels |
| RLOOK AUTO fallback, resumed/new | 14579 / 14517 ms | backend 0; CPU parity; FORCE rejects without changing sentinel |
| Complete original UI CPU workflow | exceeds 240 s | real Compose timeout; native-active process isolated before recovery |

The 423.205 s full-GPU method total includes two independent full-size FORCE references;
the 506.274 s resumed-CPU total includes its independent full-size CPU reference.
Neither total changes the per-export 240-second wait.

An archived `20f6397` baseline, built outside the checkout, also times out at 240067 ms
on this physical device. Baseline production source is unchanged; source adapters only isolate
the application ID, add a diagnostic catch/rethrow and prefix screenshot paths. Its later
foreground-control variant adds the same test-only foreground rule to both sides.
Current/baseline rendering sources and all 782 native compile commands match, including `-O3`;
see `baseline20f-compile-flags.jsonl` and the baseline build/source records.

A later current-bridge UI diagnostic also times out at 240064 ms, `phase=RUNNING`,
`batchNativeProcess=true`; recovery uses PID 16115 after owner 15050 has exited.
Two samples show one native-worker candidate continuously running at 100% CPU, CPU time
advancing from 53.47 s to 139.35 s, all eight CPUs allowed, approximately 1.9-2.0 GiB RSS,
and no sampled thermal-throttling indication. This is evidence against an idle publication
wait, not a substitute for a native backtrace or proof of the exact instruction executing.
The Lenovo user build rejects `debuggerd -b` with `root is required`; simpleperf is blocked by
`security.perf_harden`. No root, device-property or profiling-security change is performed.

The UI request has `customWb=false`, whereas the resumed helper explicitly uses `true`.
The UI flow also retains the editor's native RAW session. Therefore the 230 s helper is not
an identical-request benchmark. The single-row batch invokes final render only once;
target validation/effect preview occur before the timed export and the reference after it.
The CPU final path uses full-resolution, six-level stationary-wavelet Clean processing;
the existing Android large-image path restricts coarse-filter stripes to one for memory safety.

These results establish a pre-existing physical CPU budget failure, not a rendering-core
regression introduced by this WIP. They do not yet prove a device hard limit: subsequent
inspection found the physical device can enter secure keyguard/doze during testing.
Foreground-controlled CPU comparison is recorded separately, rather than assuming this
environment variable has no effect on throughput.

### Closed Recovery and Observation Boundaries

- Look imports now create an exact `.import-<UUID>.pending` transaction before staging.
  A canonical-root JVM monitor and persistent OS file lock serialize instances/processes.
  Recovery preserves committed looks, corrupt registries and ownership-unknown legacy final
  files, while deleting only transaction-owned uncommitted files/internal temporary stages.
- JVM RED/GREEN includes real child JVM importers, process death, same-root instances,
  corrupt-registry preservation and single-point monitor/file-lock removals. Both mutations
  are restored. The full JVM suite has 88 tests, zero failures/errors/skips.
- Real physical crash probes cover SELECTING preview-in-flight, native-validated look stage
  before commit, MediaStore insert before checkpoint and after checkpoint. Each injected
  invocation remains failed; only the subsequent fresh-process recovery passes.
  See `physical/final-crash-probes*` and `physical/final-storage-checks*`.
- Cleanup journals the exact managed-look ID before commit, preserves independently imported
  same-named looks, and removes an exact-ID orphan left by interrupted removal. The repeated
  cleanup fixture has its own RED/GREEN evidence. Pending outputs are found by both journal
  URI and the exact fixture filename prefix/path; partial inputs live under the owned job.
- Actual file-export backend reporting has a real CPU/FORCE/AUTO/RLOOK RED/GREEN, and batch
  assertions read exactly one own-PID log entry for the exact job UUID. Reference backends
  are not passed off as batch backends. Missing native writes cannot look like CPU success:
  Kotlin initializes the output slot to -1 and checks it before metadata handling.
- A real second-session CPU preview exposed an additional getter-lock regression: completed
  export blocked in `nativeLastBackend` after metadata because the getter reacquired the
  global JNI mutex. RED records `exportReturned=false getterBlocked=true`; the fix returns
  backend through an output array while the original native-process lock is already held.
  GREEN records `exportReturned=true getterBlocked=false backend=0` while the second real
  preview is still native-active. `close()` occurs only after the observation.
- The cleanup manifest captures raw app locales before `LanguageTestRule` changes them.
  A fresh recovery restores that preference only after the old PID is dead. The failing
  locale fixture demonstrated `de -> zh-Hans`; the corrected fixture restores `de`.
  It does not claim that a stale Resources object has synchronously reconfigured.

### Save Feedback and Test-environment Findings

The original flow-layout status moved the tool strip by 16 px in a real Compose RED.
Save feedback now occupies the photo overlay, not dock flow. Information and feedback
share a Column's measured height; the information panel scrolls when needed. This avoids
both overlap on short canvases and an `onSizeChanged` first-frame feedback race.
The photo viewport, dock, tool strip and slider bounds remain independent of status.
FAILED retains its complete retryable button and polite live region; drafts suppress feedback.

The matrix independently checks six literal translations, actual 360x720/960x600 fixture
measurements, side/bottom dock branches, font scales 1/1.6, expanded/collapsed states,
all save states, actual touch retry, glyph bounds, overlap and live-region semantics.
Additional checks cover capture-information scrolling without comparison, geometry/lens
draft suppression and the null-preview retry fallback. The synthetic viewport consumes
host window insets rather than inheriting the host display's unrelated physical-pixel insets.
Representative AVD screenshots are inspected; screenshot creation alone is not a visual assertion.

On Lenovo, the independent English literal guard correctly fails instead of falsely claiming
six-language coverage. The device's own `framework.jar` (SHA-256
`db0f1845848f9c77584bc5c55a9e1d5658e2b48aa6ac22386d8a0f3e2ba5e2c2`) contains a
`Configuration.setLocales` OEM branch: with `ZuiAntiCrossSell`, PRC region and test mode off,
non-Chinese locales other than exact `en_US` are rewritten to `zh_CN`. The branch is before
`createConfigurationContext`, not a Compose cache or general Android 15 rule.
See `physical/classes.dexdump.txt:1010851-1010907` and the `locale-*-probe*` diagnostics.
No locale/region/test-mode bypass is added to production. Six-language results come from
the API35 AVD; the later physical Chinese-only layout method remains NOT REACHED because
the secure-keyguard precondition is not satisfied.

Secure keyguard caused a later physical preview probe to fail before reaching its target.
This is NOT a successful crash/recovery probe. The test-only `ForegroundTestRule` uses
an `ExternalResource` precondition, not `TestWatcher.starting` (which records a failure but
still runs the test body). It requires the user's secure unlock, keeps only test windows on
across recreation, and restores only its owned window flag. It does not change global
screen-off settings, disable keyguard, guess a PIN or bypass device security.

### Final AVD and Recovery Results

The pre-MissingLook frozen default matrix completes with wrapper exit 0 and 12 `OK (1 test)`
results: six normal methods plus six independent recovery invocations.
Evidence: `emulator/final-default-wrapper.log` and `emulator/final-default/`.

- GPU-off target validation: exactly one real processor, modes `[0]`.
- Resumed original-size Clean CPU export: 127010 ms, actual batch backend 0,
  original dimensions and independent CPU reference parity.
- Complete original UI workflow: effect preview 3205 ms, original-size export 124096 ms,
  COMPLETE, one output, unchanged target edit record, unchanged RAW and independent CPU pixel parity.
- Eligible GLES and CPU-only RLOOK new/resumed cases pass with actual backend and FORCE/CPU
  controls; partial-output reconciliation and discard also pass.
- The long method totals include independent full-size reference exports after the timed batch
  wait. Neither `240_000` export wait nor the original `90_000` preview wait changes.

The explicit full-size AUTO/GPU AVD case genuinely fails its original 240-second wait.
`emulator/final-software-gpu-wrapper.log` remains exit 1; owner PID 5411 is terminated and
fresh recovery PID 5520 passes. The new-batch/reference cases after the first timed-out resumed
case are NOT REACHED. The driver is ANGLE/SwiftShader (software Vulkan/LLVM), not Adreno;
see `emulator/final-software-gpu-own-logcat.txt`. Because the timed-out export never returns,
there is no completed batch-backend result for that full-size AVD case. Combined with the
physical 82/105-second GPU completions, this supports a software-GPU throughput limitation,
not a newly introduced rendering-core regression or permission to extend the timeout.

The real 90-second SELECTING preview-contention probe expires after 90096 ms with an actual
`ComposeTimeoutException`: the blocker is in CPU export `nativeProcess` and the preview is
waiting in `nativeCreate`. Owner PID 5226 exits before recovery PID 5364 cleans its preserved
inputs. `emulator/final-natural-timeout-wrapper.log` remains exit 1, not a passing test.

On the final incremental APK, an additional real preview-in-flight crash starts with app locale
`de`; owner PID 7394 dies before recovery PID 7496 restores raw app locale `de`, verifies both
owned input directories survived until process exit, then removes them. The injected invocation
remains failed, wrapper exit 1; only fresh recovery passes. See
`emulator/final-preview-de-recovery-wrapper.log` and `preview-de-locales-recovered.txt`.
The isolated app's initial empty locale preference is restored after this probe.

### Restored Missing-Look GPU Mode Fix

Final review found a separate, pre-existing omission: `Work.Import` used the default/reused
processor mode while validating a restored edit whose managed Look no longer exists.
It bypassed the mode setter in the ordinary `Work.Preview` branch. The fix applies
`work.gpuMode` immediately before that validation preview; CPU-off and AUTO-on semantics
remain identical to ordinary imports.

`RestoredLookGpuModeTest` uses the real import path, persisted missing-UUID settings and a fresh
EditorViewModel. It first requires a real GLES AUTO control. An append-only own-PID log cursor
then requires exactly one actual validation-frame backend, not a later session probe.
The backend-only observation is debug-only and contains no paths or photo identifiers.

- Refined RED: GPU off expects 0 but actually observes 2; AUTO-on control observes 2.
  `physical/missing-look-owned-red-wrapper.log` exits 1 and both fresh recoveries pass.
- GREEN: physical and AVD each observe GPU-off 0 and GPU-on 2, with four `OK (1 test)`
  results per wrapper including recovery. See `physical/missing-look-green-wrapper.log`
  and `emulator/missing-look-green-wrapper.log`, both exit 0.
- The test Application stores edits and random PhotoStorage cache under the already-journaled
  exact fixture directory. Process death therefore does not rely on an unexecuted `finally`
  callback to remove these files. Normal teardown clears the ViewModel, joins its canceled
  coroutine scope and waits for any already-running storage operation before fixture removal.

Final incremental app SHA-256:
`415cacb8a3dbaa0ddd0f0b5cbda3b12de55110a9cf6e4b5db984ecbba4f455b7`.
Test SHA-256:
`763d1514a16d6f11db1f214c3261f1183452c34ec0c3071eaa3eabd401e5e7d4`.
`missing-look-final-source-sha256.txt` covers 132 source/config/test/script entries and
`missing-look-final-source-check.log` verifies them. Earlier physical/default batch timings
belong to their earlier frozen snapshots. The incremental change only affects the missing-Look
import error branch; both real backend cases and the affected UI are rerun at this snapshot.

### Final Gates, Review and Teardown

- `missing-look-final-build.log`: Gradle build, JVM and lint PASS. Structured reports contain
  88 JVM tests, zero failures/errors/skips; lint has zero errors and 32 existing warnings.
- Both APKs pass 16 KB ZIP alignment; all eight arm64/x86_64 native libraries pass the repository
  ELF alignment check. No shared C ABI, rendering quality or native core source is changed.
- `emulator/missing-look-final-ui-wrapper.log`: final incremental APK passes the six-language
  save-layout matrix (41.183 s) plus all five existing PhotoCanvas gesture/viewport regression
  methods; six fresh recoveries also pass, wrapper exit 0, 12 `OK (1 test)` results.
  Representative current English/German narrow/wide screenshots are visually inspected.
- Independent final reviews cover cleanup/import transactions, JNI backend reporting, UI and
  the restored missing-Look path. The new test's initially unowned edits/cache finding is fixed
  structurally with the owned Application context. No remaining confirmed P1/P2 is found in
  the final modified code. Expected crashes, OEM-language failure and blocked foreground cases
  are not counted as normal passes.
- Final physical policy still reports secure keyguard showing and screen off. The negative
  foreground precondition correctly fails once before running the test body; it is NOT a GPU
  or preview success. The user has not unlocked the device during the remaining test window.
  Foreground-controlled current/baseline CPU comparison and physical Chinese UI remain
  NOT REACHED. No PIN, root, region, test-mode or profiling-security bypass is attempted.
- Before teardown, both isolated physical packages have no batch job files and no owned
  MediaStore rows, including pending ones. The probe managed-look registry has `count=0`,
  with only its persistent `.lock` and registry left. AVD checks also find no owned gallery/jobs,
  no import stages, and zero remaining wake locks.
- Only the four initially absent probe/baseline app/test packages are uninstalled. Exactly six
  observed task-prefixed `/data/local/tmp` screenshots are removed. The original app and
  Sony-memory packages remain installed. Original app APK SHA-256 stays
  `405ac39b7fd0094df3749dde833be5db01a22800e12f48aa3a4c7b30823250e6`, and version/install
  metadata is unchanged. Device screen-off timeout remains 600000 ms.
- The task AVD and private ADB servers 5063/5065 exit; ports 5063/5065/5762/5763 have no
  listener. USB serial HA1ZKK0Q is reattached to shared 5037 and visible as `device`.
  Shared ADB PIDs 23749/51027 on 5037/5047 are unchanged. See `final-listeners.txt`,
  `final-usb-restored.txt`, and the physical `original-app-after-*`/`final-*` checks.
- `git diff --check` and shell syntax PASS; all temporary wrong-mode, lock-removal and getter
  mutations are restored. There is no staged content, commit, push, PR or hosted CI run.

The strongest supported timeout conclusion is split: software GPU throughput explains the AVD
AUTO failure, while the physical CPU UI failure already exists at `20f6397` and samples support
CPU-bound, memory-heavy single-worker processing. Normal effect preview closes its processor
before publishing the bitmap; the timed export has one row/one final render, not a duplicate
reference render. No physical sample shows the active worker waiting on a futex. These facts
do not identify the exact native instruction or prove an immutable device limit. At that snapshot,
secure-unlocked foreground comparison and a permitted native profile remained diagnostic gaps.
The later user-unlocked comparison is recorded below.

### User-Unlocked Physical Follow-up (2026-10-15)

The user subsequently unlocked Lenovo TB320FC and requested continued testing. This follow-up
supersedes the preceding NOT REACHED entries for foreground CPU comparison, physical Chinese UI
and physical preview-crash locale recovery. Native function-level profiling remains unverified.
Evidence root: `/tmp/rawlab-android-v08-56c3/boundaries/unlocked/`.

No executable source changes or builds were made in this follow-up. The 132-entry final source
manifest still matches. APK IDs and SHA-256 values were checked before reinstalling only the
four previously removed isolated app/test packages. The current pair is the final MissingLook
snapshot above. Baseline app SHA-256 is
`d76b37492c949cd17ff23e10a2b697b87d2c70989f67b9c0ab89df95af272cda`; its foreground-rule
test APK is `a2339c6cd8dd88934faccc25d442b561866f65bd4016516cfd3f1a36a281b6b7`.
The baseline/current `ForegroundTestRule` source files compare byte-for-byte equal.

| Case | Result | Evidence |
| --- | --- | --- |
| 20f6397 foreground CPU UI workflow | genuine timeout at 240071 ms; preview 5228 ms | `baseline-cpu-wrapper.log`, wrapper 1 |
| Current foreground CPU UI workflow | genuine timeout at 240063 ms; preview 5174 ms | `current-cpu-wrapper.log`, wrapper 1 |
| Current physical Chinese save-layout matrix | PASS, 6.287 s; fresh recovery PASS | `chinese-ui-wrapper.log`, wrapper 0 |
| Current SELECTING/native-preview crash from locale de | injected invocation fails; preserved-input and locale recovery PASS | `preview-de-recovery-wrapper.log`, wrapper 1 |

Both CPU runs reach `phase=RUNNING`, `batchNativeProcess=true`. Baseline owner PID 5910 exits
before recovery PID 7232; current owner PID 8183 exits before recovery PID 9235. Both recoveries
remove the exact owned resources successfully. These are two real performance-test failures,
not passing complete workflows. The 240071/240063 ms values are censored timeout observations,
not measured render-completion times, so their proximity does not prove equal throughput.

Mid/late window snapshots on both sides show `showing=false`, `SCREEN_STATE_ON` and `AWAKE`.
Power snapshots show a WindowManager `SCREEN_BRIGHT_WAKE_LOCK` attributed to the correct isolated
package; the late acquisitions have lasted approximately 3m59s and 3m50s. Top samples show one
DefaultDispatch worker at 96.2-100% CPU, with editor native workers idle; sampled thermal status
is 0 on both sides. Native heap PSS is approximately 1.8-1.9 GiB. No host build or AVD workload
runs during the comparison. See the per-side `window-*`, `power-*`, `top-*`, `worker-late`,
`meminfo-*`, `frequencies-*` and `thermal-*` records.

The unlocked result rules out secure-keyguard/screen-off as a necessary cause of this CPU budget
failure. Together with the previously verified unchanged shared rendering core and compilation
flags, it confirms the original CPU case already exceeds the budget at 20f6397 under foreground
conditions. It does not prove an immutable hardware ceiling, identify the exact native function,
or exclude every smaller performance difference beyond the 240-second cutoff. No optimization,
quality change, CPU affinity tweak, root/property change or timeout extension was used.

The physical preview probe separately reaches `SELECTING`, `operation=NONE`, with a real active
preview `nativeProcess`. Owner PID 9603 is terminated before recovery PID 9974 verifies both input
directories were preserved, restores raw app locale `de`, and cleans the resources. A shell read
independently confirms `[de]`; the original empty isolated-app locale is then restored. This is
the short crash probe, not another claim of a natural 90-second timeout.

Independent read-only review of this new evidence finds no new actionable code defect and retains
the distinction between timeout deadlines and completed-render timings. Only validation records,
the plan and review addendum are updated. `git diff --check`, shell syntax and source hashes pass;
no new commit, staging, push, PR or hosted CI activity occurs.

Final teardown again finds no owned MediaStore rows (including pending), no batch job files and
zero wake locks. The fresh probe Look directory contains only `.lock`, with no imported Look or
stage. Only the four isolated packages and six observed task-prefixed temporary screenshots are
removed. Original app APK SHA-256 and version/install metadata remain unchanged; Sony-memory
packages remain installed; screen-off timeout remains 600000 ms. Private ADB 5063 exits, USB is
reattached to shared 5037, and shared PIDs 23749/51027 remain unchanged. No AVD was started for
this follow-up. See `final-*` and `original-app-after-*` under the follow-up evidence root.

### CPU Hotspot Follow-up

The later evidence-driven Android Debug dependency correction, unchanged 240-second
physical CPU workflows, numerical equivalence and teardown are recorded separately in
[CPU denoise performance verification](cpu-denoise-performance-verification.md).
