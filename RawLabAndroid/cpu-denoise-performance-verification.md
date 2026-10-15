# Android CPU Denoise Performance Verification

Date: 2026-10-15. Validation snapshot: local worktree `feature/android-v08-editor` at
`20f6397` plus the preserved Android WIP, before any staging or commit. No push, PR or
hosted CI. This record extends
[batch verification](batch-gpu-preference-verification.md), not its earlier snapshots.
Evidence root: `/tmp/rawlab-android-v08-56c3/cpu-performance/`.

## Scope and Device

- Lenovo TB320FC, serial `HA1ZKK0Q`, Android 15/API 35, arm64, Adreno 730.
- Isolated application `com.rawlab.android.batchprobe56c3[.test]` on private ADB 5063.
  The original app, its data and the personal gallery are not test fixtures.
- External RAW `DSC00316.ARW`, SHA-256
  `93a37abeaa3cd199773d25978a1045e580e26dbf884755f5d69c530e0bed5014`.
- GPU disabled remains CPU. Original size, Clean `10/72/100`, algorithm, tile/halo,
  threading policy, output quality, both 240-second export waits and the 90-second
  preview wait remain unchanged. No host build or AVD runs during timed device tests.
- At the user's request, powered-awake is temporarily changed from 0 to 7. The
  device reports AC power and `mStayOn=true`; USB-only would not cover that state.
  PIN, screen-off timeout (600000 ms), CPU frequency and security properties are unchanged.
  The original powered-awake setting is restored and read back as 0 before teardown.

## Evidence Before Optimization

The unchanged UI workflow genuinely times out at 240072 ms with native CPU work
still active. Its 35-tile filter completes in 167544.650 ms; restore remains active.
The late logcat dump loses early records, so `profile-before-ui-native.log` is only
a partial trace. Fresh-process recovery passes; the original invocation remains failed.

A second, resumed CPU run uses continuous logcat and more detailed restore timers.
`profile-baseline-stream.log` and `profile-baseline-summary.json` show:

| Phase | Baseline Time |
| --- | ---: |
| Flat-sample selection | 1439.180 ms |
| Fine/coarse calibration | 588.872 / 2889.116 ms |
| Complete 35-tile filter | 166596.765 ms |
| Forward SWT, summed within filter | 69649.780 ms |
| Inverse SWT, summed within filter | 41263.713 ms |
| Box-energy, summed within filter | 41683.501 ms |
| Restore transform / normalize | 488.351 / 177.302 ms |
| Restore Gaussian blur | starts, does not finish before the 240-second owner termination |

The SWT/inverse/box calls account for 152596.994 ms, approximately 91.6% of filter
time. Box time is already inside the recorded band-loop time; it is not added twice.
Gaussian blur is still active approximately 59 seconds after entry. That is a lower
bound, not a completion time. The resumed helper uses custom white balance, unlike
the original UI request; its stage timings must not be presented as an identical UI run.

Structured inspection finds the caller `sony2fuji_core` already uses `-O3`, but all
nine wavelib C objects have no optimization flag (default `-O0`), and OpenCV core/imgproc
objects explicitly use `-O0`. Earlier matching baseline/current compile databases did
not establish that these dependencies were optimized.

## Narrow Build Correction

Only Android Debug dependency targets `wavelib`, `opencv_core` and `opencv_imgproc`
gain `-O3`. There is no fast-math, algorithm change, quality reduction, GPU substitution,
new threading or memory policy. Symbols and assertions remain enabled. Release and
other platforms do not receive this additional option.

`check-cpu-build.py` parses actual JSON/token arrays and checks the last optimization
option, all objects of each affected target, required source/target identity and
unsafe math/hidden response files. The unmodified databases fail on 169 arm64 and
215 x86_64 dependency objects. The optimized databases pass on 191/237 target objects,
including core objects. Six parser tests pass, including a RED/GREEN check for a
required source hidden under an unknown target.

The initial `compile-command-delta.json` counted unique source files, not all compilation
records. It is retained as historical evidence and superseded by
`compile-command-delta-arm64-objects.json` and `compile-command-delta-x86-objects.json`.
The corrected comparison uses the source and complete output object paths, normalized
against each entry's build directory, without dropping repeated sources:

| ABI | Compile Records Before / After | Unique Sources Before / After | Changed Objects |
| --- | --- | --- | ---: |
| arm64-v8a | 783 / 784 | 782 / 783 | 169 |
| x86_64 | 782 / 783 | 782 / 783 | 215 |

On arm64, `hal/carotene/src/dummy.cpp` is compiled into two different objects. Both are
now retained and checked. Only one `-O3` is added to each of the expected 169/215 dependency
commands, preserving the order of all other tokens. There are no removed objects or
unexpected changes. One extra object builds the existing native numerical test as an
Android `EXCLUDE_FROM_ALL` target; that executable is not packaged into the APK.

## Quality Verification

Before optimization, the old native executable and its shared libraries are frozen.
Both executables process the same deterministic float inputs on the physical device:

| Input | Parameters | Result |
| --- | --- | --- |
| 1089 x 1025, flat noise plus texture/color patch | 10/72/100 | byte-identical |
| Same input, coarse disabled | 65/72/0 | byte-identical |
| 2049 x 2049, irregular tiles and greater-than-4MP Android serial boundary | 10/72/100 | byte-identical |
| 1025 x 769, three intensity plateaus with signal-dependent noise | 10/72/100 | byte-identical |

All four runs actually apply denoising and find 144 flat samples. The last input has
nonzero fitted noise slopes (0.00387539/0.00193139/0.00583616). `cmp` and SHA-256 pairs
in `quality-sha256.txt` cover 7,219,076 RGB pixels, or 21,657,228 float channel values.
The original thresholds are not weakened. The physical native suite exits 0, covering
SWT inverse goldens, reflected edge tiles, one/two-thread bitwise parity, texture,
coarse color noise/structure/edges, cache equality, immutable-source reload and validation.
Its GPU-disabled-only forced-failure branch is not enabled in this GPU-capable build.

No completed pre-optimization 32.7MP JPEG exists within the original 240-second budget.
Thus the float fixtures establish measured before/after equivalence; the full workflow
separately checks batch pixels against an independent CPU export, not an old full-size JPEG.

## Optimized Diagnostic Run

The original UI workflow completes the export in 78932 ms, actual batch backend 0.
It then completes the independent original-size CPU reference and pixel comparison;
the full test passes in 180.206 seconds, followed by successful fresh-process recovery.
The test APK is byte-identical to its pre-optimization snapshot.

The first full native render takes 78562.410 ms, including 66375.435 ms for all 35
filter tiles and 583.567 ms for restore Gaussian blur. Complete wavelet time is
70747.383 ms. See `profile-optimized-ui-summary.json` and the continuous stream.
These figures are diagnostic-build observations, not final-APK measurements.

The resumed CPU control completes export in 81588 ms and the full test in 178.795 s,
with backend 0, 4672 x 7008 output, independent CPU pixel parity and fresh recovery.
Its matched 35-tile filter is 65943.488 ms (baseline 166596.765), forward/inverse SWT
25633.797 / 10864.594 ms, box-energy 16594.055 ms, and restore Gaussian 581.500 ms.
See `profile-optimized-resumed-summary.json`. These are completed timings; the old
240-second failure remains a censored observation, not an exact speedup denominator.

Thermal status samples remain 0 and the device is awake/unlocked. A filter-phase
native PSS sample is 2052383 KiB; process RSS high-water sampled after the batch export,
during its independent reference render, is 2513320 KiB.
The earlier 1.8-1.9 GiB values were sampled PSS at different points, not matching peak
measurements. This work claims no memory reduction or validation on low-memory devices.

## Final Verification

All temporary timing is removed before the final build. `wavelet_denoise.cpp` and
`rawlab_jni.cpp` compare byte-for-byte with their pre-profile copies, preserving the
earlier JNI `backendOut` fix. The shared wavelet source has no Git diff. Neither ABI's
packaged JNI library contains the profiling tag. The previous 132-file WIP manifest
still matches on 131 files; only the intentional Android CMake optimization differs.

Final app SHA-256:
`e3129f5f8024530a640297d7c0b2240a3677f2c0acd313b0a1a322643ebf22fd`.
Unchanged test APK SHA-256:
`763d1514a16d6f11db1f214c3261f1183452c34ec0c3071eaa3eabd401e5e7d4`.
`final-source-sha256.txt` freezes 212 source/config/test entries; its verification passes.

- Final Gradle build, 88 JVM tests and lint pass (0 errors, 32 existing warnings).
  Both APKs pass 16KB ZIP alignment; all eight native libraries pass ELF alignment.
- Final effective compile-policy checks pass for both ABIs. The final no-timing native
  numerical suite exits 0. The greater-than-4MP final float output remains byte-identical
  to the old unoptimized output.
- `final-matrix-wrapper.log` exits 0 with six test methods and six fresh recoveries:

| Final Physical Case | Result |
| --- | --- |
| GPU-off target validation | PASS, one real processor with CPU mode |
| Resumed CPU original-size Clean | 80858 ms export; backend 0; 4672 x 7008; CPU pixel parity |
| Original CPU UI workflow | 78687 ms export; complete workflow/reference parity PASS in 179.825 s |
| New/resumed AUTO GLES | backend 2; Force reference parity and distinct CPU pixels |
| New/resumed CPU-only RLOOK | AUTO backend 0; CPU parity; Force rejects without replacing output |
| Partial-output resume/discard | PASS |

The additional original-size Clean AUTO method passes in 166.483 s, including both
new/resumed workflows and their independent Force references. Resumed/new exports
take 31299/31306 ms, each backend 2, 4672 x 7008, pixel parity true. No 240-second wait
is altered. These final-APK results are separate from the diagnostic-build profiles.

The final SELECTING/native-preview failure probe confirms native work is active with
operation NONE. Owner 30987 exits before recovery 31551 verifies preserved inputs,
restores the original empty app locale and removes the owned resources. The injected
invocation remains failed and `final-extra-wrapper.log` exits 1; only its fresh recovery
passes. The earlier natural 90-second contention probe is not rerun: faster native work
may finish before that deadline, and this record does not claim that branch was reached.

The initial independent read-only review found no P1/P2 in its covered cases and confirmed
90/240 waits, CPU/AUTO/Force behavior and temporary-source restoration. The main thread
separately checked the subsequently completed additional AUTO and crash/recovery logs.
The later `5a9774b` review found additional checker and counting gaps, addressed below;
the original review conclusion does not supersede those later findings.

### Host Dependency Check

The first `bash lutools/test.sh` run passes 38/39 tests; only `dng_jxl` fails its SDK
OOM classification check. Its installed host LibRaw binary is from October 8, whereas
the source cache has the October 13 OOM-mapping patch. The failed log is preserved as
`host-core-test.log`. No repository rendering code or expected result is changed.

The existing repository dependency builder is used with a task-owned LibRaw source
copy and the pinned cached DNG SDK, installing only into `host-raw-prefix` under the
evidence directory. A fresh host build selects those LibRaw/DNG libraries explicitly
and retains the existing OpenCV/wavelib prefix. Initial split-prefix OpenCV discovery
fails at configure time; setting `OpenCV_DIR` to that existing installation resolves it.
The corrected full host gate passes 39/39 tests, exit 0, in 343.21 seconds:
`host-core-current-verified.log`. `Testing/Temporary/LastTest.log` explicitly reports
`PASS SDK OOM survives load, WB reload and C ABI`; the branch is not skipped.
`host-core-current-linkage.txt` confirms the freshly built LibRaw/DNG SDK paths.
The installed host dependency was stale; the repository's existing patch resolves
the failure without any rendering-source or test-expectation change.

### Teardown

No owned MediaStore rows remain, including pending rows. The isolated batch journal is
empty and managed-Look registry count is 0. All native test processes and the isolated
application process have exited before cleanup. Only the two initially absent isolated
packages, the four observed task-prefixed screenshots and `/data/local/tmp/rawlab-cpu56c3`
are removed. The original app's APK hash/version/install metadata and RAW fixture hash
remain unchanged; both Sony-memory packages remain installed.

Powered-awake is restored to 0, screen-off timeout remains 600000 ms, and private ADB
5063 exits. USB returns to shared 5037 as `device`; shared ADB PIDs 23749/51027 are
unchanged. No original app data, personal gallery, PIN, CPU frequency, root/property
security setting, remote branch or PR is modified. No AVD is started in this round.

## Local Commit Packaging

The user subsequently authorized one local commit containing only this CPU-performance
iteration. It includes the two CMake changes, compile-policy checker and six parser tests,
README instructions, this verification record, the CPU plan/review and only the CPU
follow-up link in the mixed batch-verification document. Earlier batch/GPU/JNI/cleanup/UI
work remains uncommitted and is not silently included.

The device results above belong to the frozen complete WIP snapshot, not a clean checkout
of this CPU-only commit. The 212-entry source/config manifest and final APK/native hashes
still match at packaging; the six parser tests and both ABI compile-policy checks pass
again. No executable source changes follow validation. Device and long-running core
suites are not restarted for this documentation/staging-only step.

RAW samples, APKs, float binaries, build directories, logs, temporary profiling and
mutation artifacts remain outside the commit. Both native source files still compare
exactly with their pre-profile copies. No push, PR, merge or original-app operation occurs.

## Checker and Counting Follow-up

The user subsequently requested fixes for the P2/P3 findings in the review of `5a9774b`.
This follow-up changes only the Python checker/tests and related documentation. It does
not change CMake optimization, rendering/native/Kotlin code, GPU mode, quality settings,
the 240-second export waits or the 90-second preview wait. It is local uncommitted work,
not a new commit, build, device run or hosted CI result.

The checker now rejects individual finite-only, NaN/Inf, signed-zero, approximation and
reassociation options in addition to fast-math umbrella flags. FP-model, contraction,
denormal and reciprocal mode values use explicit safe sets; unknown values fail closed.
Response/config files and compiler/frontend forwarding are rejected for checked CPU
targets rather than silently hiding options. This is a conservative no-unsafe-options
policy, not an emulation of all Clang flag overrides. Safe standard modes and unrelated
targets have positive controls.

The original six test behaviors remain, with eighteen additional methods covering these negative
cases and object-level comparison, including a change to the first of two objects sharing
one source. CLI tests exercise JSON output and nonzero statuses for duplicate/missing or
conflicting output identity, unknown-target changes, unexpected additions, removal and
option reordering. Object-change, reorder and removal negatives each make a single change,
keep the CPU policy valid, and require the specific comparison error, so a separate policy
failure cannot mask a missing comparison guard. An intermediate unknown-target reporting
error was reproduced and fixed without weakening its assertion.

The final independent review also found that suffix-only required-source matching could
accept a same-named source in a different directory, and that the numerical-test addition
allowed more than one object. Both were reproduced before correction. Required sources
now use normalized full paths: repository sources belong to the current checkout and
dependency sources to the ABI build directory's default CMake layout. A comparison allows
at most one added object from the exact repository numerical-test source. Relative paths
have a positive control. This checks database metadata, not file-content provenance or
whether the compiler actually ran; it intentionally does not require historical sources
to remain on disk. Test fixtures use independent, explicit paths and targets rather than
deriving their expected source list from the checker.

- `p2-p3-tests-red.log`: the old checker fails the new expectations (38 failed assertions
  across 15 methods, including the then-missing comparison CLI).
- `p3-object-boundaries-red.log`: the additional unknown-target reporting test fails.
- `p2-p3-tests-final.log`: the initial 20 methods pass before the final review additions.
- `p2-p3-review-boundaries-red.log`: the four added methods reproduce 9 failures before
  correction (six source substitutions, two numerical-test addition cases and relative
  source normalization). `p2-p3-review-fixture-error.log` records one incomplete fixture
  missing its build directory; that fixture is completed without weakening its assertion.
- `p2-p3-review-boundaries-green.log`: the final 24 methods pass.
- `p2-p3-real-negative.log`: three in-memory, single-option mutations in each actual ABI
  database pass the old committed checker incorrectly and fail the corrected checker
  (finite-only core, fast contraction in imgproc, forwarded NaN assumption in wavelib).
  Neither the saved databases nor compiler/native source files are mutated.
- The original databases are still rejected for 169/215 unoptimized objects; both final
  WIP databases pass the strengthened policy. Both object comparisons exit 0, with the
  exact corrected counts above and no unexpected changes.
- `p2-p3-final-recheck.log`: the final checker repeats all six actual-ABI unsafe-FP
  controls, twelve source-path substitutions and four numerical-object negatives in
  memory. Every expected rejection is observed, and both full object reports still match
  the saved JSON exactly. The final independent review confirms both additional guards
  are closed and finds no remaining actionable defect in the five-file correction scope.

The historical 212-entry WIP manifest is not rewritten. Only its two checker/test entries
now differ; the other 210 source/config entries and recorded APK/native hashes remain
unchanged. Four before/after float-output pairs still match their saved hashes. These are
integrity checks of previous WIP evidence, not new pixel tests of an exact commit tree.
No APK, device or long-running rendering suite is rerun for this checker-only correction.
The final local review is recorded in
`reviews/self-android-v08-editor-20261015-2304.md`; no commit, push or PR is made.

## Subsequent Delivery Authorization

After the local reviews, the user authorized commit, push, a PR into `development`, and
merge only after the remaining checks are clear. They explicitly included the previously
verified batch recovery, GPU/backend, Look import and save-feedback WIP in this delivery.
Earlier no-push and uncommitted statements above describe their historical checkpoints.

Before packaging, all 210 non-checker entries of the frozen 212-entry runtime manifest
still match; only the two intentionally corrected Python files differ. Thus packaging
includes the executable source underlying the recorded full-WIP tests, rather than
silently omitting the earlier recovery fixes. This source-equivalence check is not a new
device experiment or a retroactive exact-tree device run of `5a9774b`.

Fresh local delivery gates pass: the 24 Python tests, an explicitly rerun 88-test JVM
suite, lint with 0 errors and 32 existing warnings, Debug app and instrumentation APK
assembly, both ABI compile-policy checks, shell syntax and APK/native 16 KB alignment.
The delivery build uses the normal application ID and no RAW fixture; its instrumentation
APK is compile-checked, not installed or used as new device evidence. Frozen physical-test
APKs remain separately preserved. Logs are under the sibling `delivery` evidence directory.
