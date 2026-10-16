# Android CPU Denoise Local Review

## Findings

No confirmed P1/P2 was found in this initial review's covered cases. The original physical
CPU timeout is addressed without extending waits, changing quality or bypassing GPU-off.
The later `5a9774b` review found a checker P2 and counting P3; this historical conclusion
does not supersede that review or its subsequent local corrections.

## Snapshot and Scope

- Self review of local incremental work on `feature/android-v08-editor` at validation HEAD
  `20f63978a75834dd19b253a7fca1253435801094`, before staging or the later authorized commit.
- Production change: Android Debug dependency optimization in
  `RawLabAndroid/app/src/main/cpp/CMakeLists.txt:44-47`.
- Verification additions: Android native test target in `lutools/CMakeLists.txt:289-293`,
  `RawLabAndroid/tests/check-cpu-build.py`, its six parser tests, README, performance
  verification record and plan. Prior Android WIP is preserved, not reclassified as new work.
- Frozen executable/source configuration: 212 entries in
  `/tmp/rawlab-android-v08-56c3/cpu-performance/final-source-sha256.txt`.
  Against the previous 132-entry WIP manifest, only the intended Android CMake differs.
- One independent read-only reviewer covered the correction, parser, numerical evidence
  and GPU integration chain. The primary independently checked completed runtime logs,
  final source restoration, package isolation and teardown. No provider review, comment,
  approval, push, PR or hosted CI; CI is not applicable to this local-only validation.

## Checks

1. The additional option is Debug-only on exactly `wavelib`, `opencv_core` and
   `opencv_imgproc`. Corrected object-level comparison covers arm64 783 -> 784 records
   (782 -> 783 unique sources) and x86_64 782 -> 783 records/sources. The original count
   of 782 per ABI conflated records with unique sources. Only 169/215 dependency objects
   gain `-O3`, with one new numerical-test object and no unexpected changes.
   No fast-math, algorithm, tile/halo, threading or memory-policy change is present.
2. The compile-policy validator checks the last effective optimization option, mandatory
   source/target identity and every object of affected targets. Missing, duplicate,
   hidden-target, trailing `-O0`, unsafe math and response-file inputs are covered.
   Actual pre-fix databases fail; final databases and six parser tests pass.
3. `EditorViewModel.kt:455,500-512` selects and propagates CPU/AUTO for new and restored
   batches. `BatchExport.kt:374-382,421-439,494-497` uses it for actual export, target
   validation and preview; retry retains the model's mode. JNI `rawlab_jni.cpp:297-345`
   reports the completed render's actual backend under the existing lock.
4. The C ABI still separates GPU Off, Auto fallback and Force failure. Final physical
   tests observe CPU backend 0, GLES backend 2, RLOOK fallback 0 and Force rejection.
   The GPU-off target-import assertion still uses one real processor, not a later probe.
5. Export waits remain 240000 ms at `BatchGpuModeInstrumentedTest.kt:226` and
   `BatchWorkflowInstrumentedTest.kt:136`; preview remains 90000 ms at line 111.
   Temporary native timing is absent; both formerly instrumented files compare exactly
   with their pre-profile copies, including the preserved JNI backend output fix.
6. The final preview-in-flight probe reaches SELECTING/NONE with active native processing.
   Failed owner 30987 exits before recovery 31551 verifies preserved input files and
   cleans. The wrapper remains exit 1 for the injected failure, not a false passing test.

## Final Evidence

- Final app SHA-256 `e3129f5f8024530a640297d7c0b2240a3677f2c0acd313b0a1a322643ebf22fd`;
  test APK unchanged at `763d1514a16d6f11db1f214c3261f1183452c34ec0c3071eaa3eabd401e5e7d4`.
- Six normal physical matrix methods and six recoveries pass. CPU UI export 78687 ms;
  resumed CPU 80858 ms, 4672 x 7008, independent CPU pixel parity.
- Additional full-size AUTO passes for new/resumed batches, 31306/31299 ms, actual GLES
  backend 2 and independent Force parity. Its injected preview failure is recorded separately.
- Four before/after float fixtures are byte-identical across 7,219,076 RGB pixels.
  Final Android numerical suite and the final greater-than-4MP float comparison pass.
- 88 JVM tests pass; lint has 0 errors/32 existing warnings. Both APK ZIP and all eight
  native ELF libraries meet 16KB alignment. Final source hashes and diff checks pass.
- Host core gate passes 39/39 after rebuilding the stale installed LibRaw dependency into
  a task-owned temporary prefix. The initial 38/39 failure remains recorded; the existing
  OOM patch, not a changed expectation, restores the `dng_jxl` classification assertion.
- Only owned packages/files/gallery rows are cleaned. The original APK/data scope, source
  RAW and Sony-memory packages are preserved. Powered-awake is restored to 0, screen-off
  timeout remains 600000, private ADB exits and shared USB ownership is restored.

## Limits

The pre-fix 240-second timeout is a censored observation, not an exact completion time.
There is no old full-size completed JPEG within that budget; numerical before/after
fixtures and final independent-reference parity are distinct forms of evidence.
The faster final APK does not repeat the natural 90-second contention probe; its active
preview crash/recovery boundary is tested instead. No x86_64 runtime, low-memory device,
all-camera quality sweep or Release performance claim is made. These are coverage limits,
not confirmed new defects requiring an unrelated refactor.

Detailed timings, failed/positive controls and artifact paths are in
`RawLabAndroid/cpu-denoise-performance-verification.md`.

## Packaging Scope

The later local commit packages only this CPU iteration; the earlier batch/GPU/JNI/UI WIP
stays uncommitted. Runtime results and line references above describe the frozen full WIP
snapshot, not an exact-tree device run of the CPU-only commit. Packaging changes documentation
wording and staging only; source/APK hashes and compile-policy regressions are rechecked.

## Later Checker Corrections

The P2/P3 follow-up after `5a9774b` adds unsafe-FP negative cases and a source/output-object
comparison CLI. Its final 24 test methods pass, including the independent review's full-path
source and single numerical-test-object guards; the saved WIP databases produce the corrected
counts above. The original source manifest and runtime results are preserved as historical
evidence, not relabeled as exact-commit or newly rerun device validation. See the follow-up
section in `RawLabAndroid/cpu-denoise-performance-verification.md` for RED/GREEN logs and scope.
