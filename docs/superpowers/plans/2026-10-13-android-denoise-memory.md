# Android Denoise Memory Investigation

**Goal:** Diagnose the 2.5GB native-export failure against the pre-optimization
version under identical conditions, fix only confirmed causes, and validate
native JPEG/PNG plus Windows on the previously used VM.

**Spec:** User request in this chat; `lutools/docs/color-contract.md`.

## Constraints

- Stay in the attached `review/viewport-denoise-cache` worktree. Preserve WIP.
- Before version is HEAD `b31827cf9c4a3237eaebf3c3d4f8f6fa58422f13`, extracted into
  ignored `build/android-memory/baseline`, without switching/stashing the checkout.
- Same Panasonic RAW, CPU, Clean 10/72/100, SDK/NDK, Debug settings, 2.5GB API35
  read-only emulator and common instrumentation test. No original RAW writes.
- Measure native heap/RSS/HWM and phase; keep both failed and passing logs.
- No algorithm/quality/resolution downgrade; C ABI stays compatible.
- Windows uses an isolated VM directory, never the old shared workspace.
- Investigation kept WIP intact. Later verified user coordination authorized
  feature-only commit/push and a draft `development` PR in another worktree;
  merge/release remain unauthorized. Remove temporary tagged core probes before
  final builds and review; keep the focused test and reproducible runner.

## Steps

- [x] Build before/current with an identical memory/export test and stage probes.
- [x] Compare cold export (neutral warm only) and adjusted-preview warm -> export.
- [x] Locate the peak and distinguish existing full-filter allocations from new
  retained cache buffers; test one discriminating variable at a time.
- [x] State confirmed cause before implementing the smallest adequate fix.
- [x] Prove numeric output against the before/unfixed native outputs, including
  native JPEG dimensions/pixels and PNG dimensions/16-bit content.
- [x] Re-run 2.5GB cold/warm exports and original Android regression suite.
- [x] Run shared-core CPU/Metal and affected macOS regressions if core changes.
- [x] Rebuild/test current source on the Windows VM, including Preview, Denoise,
  Interaction, native JPEG/PNG and actual D3D evidence or explicit limitations.
- [x] Dual follow-up review and evidence report, then update rollout gates.

The investigation gates are closed in `docs/verification-android-denoise-memory-2026-10-13.md`.
Final PR delivery must revalidate the migration to current `development`, not
carry the old HEAD's unrelated AI/JXL commits or relabel these tests as that head.
