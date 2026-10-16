# Android CPU Denoise Performance Plan

> **For agentic workers:** Use superpowers:executing-plans. The primary agent owns changes; delegated work is read-only.

**Goal:** Identify the physical-device original-size Clean CPU bottleneck, then remove the measured waste without changing pixels, GPU preference or the 240-second export wait.

**Architecture:** First add removable native stage timing to the existing isolated Debug APK. Inspect the complete effective compile flags of the measured dependencies. Prefer a narrow Android Debug build correction over changing the algorithm, tile layout, threading or memory policy. Freeze before/after evidence, remove temporary timing and validate the real workflow again.

**Tech Stack:** Kotlin instrumentation, C++17/wavelib/OpenCV, Android CMake/NDK, structured compile_commands.json checks, existing core numerical tests.

**Spec:** Current user request and `RawLabAndroid/batch-gpu-preference-verification.md`, including the unlocked baseline/current genuine CPU timeouts.

## Global Constraints

- During implementation/validation: local changes only, no staging or commit. The user subsequently authorized one CPU-only local commit; push, PR and original-app data changes remain prohibited.
- Preserve all existing WIP; use the current worktree and task-owned physical test package.
- Keep both export waits at 240_000 and preview wait at 90_000.
- GPU disabled means CPU; no GPU substitution, reduced resolution, fewer SWT levels, weaker thresholds or smaller halos.
- Do not bypass device security or root/profile restrictions. The user subsequently requested powered test-time wakefulness: temporarily set global stay_on_while_plugged_in from 0 to 7 and restore 0 before teardown. Screen-off timeout, PIN and CPU-frequency settings remain untouched.
- Keep shared C ABI and release behavior unchanged unless evidence requires a separate, justified change.

## Review Focus

- A dependency can remain unoptimized even though its caller has -O3; inspect the last effective optimization flag, not substring presence.
- Timing must identify real work before an unfinished export is terminated; completed tile/phase timings are not full-render completion times.
- Numerical equivalence must be measured, not inferred solely from compiler settings.
- CPU/AUTO/Force policies, peak memory and exact/original dimensions remain covered.
- Temporary profiling and test-only artifacts must not remain in production sources or Git artifacts.

## Tasks

- [x] Preserve the pre-profile source/build evidence and instrument native process, wavelet analysis, SWT/box-energy/inverse and tile progress without altering work.
- [x] Run the original physical CPU UI workflow with its original 240-second wait; collect actual native hotspot timing and foreground/resource evidence.
- [x] Add and run a failing structured build-policy regression for any measured unoptimized dependency; retain parser self-tests for ordering, missing files and unsafe math flags.
- [x] Capture numerical/image reference outputs from the unchanged implementation, then apply only the evidence-supported optimization.
- [x] Repeat identical stage timing, compare reference pixels and run affected native/core tests; preserve original image algorithm and quality thresholds.
- [x] Remove all temporary native timing, build the final APK, verify compile policy/JVM/lint/alignment, and run the physical original-size CPU complete workflow plus CPU recovery/AUTO regressions.
- [x] Perform independent read-only review, document measured before/after results and limits, verify cleanup and restore shared USB ownership. No publication.
