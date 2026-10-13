# Preview P2 Verification And Platform Rollout

**Goal:** Resolve both review P2s with evidence, then extend the proven viewport
pipeline to existing clients without changing exact export quality.

**Architecture:** Keep source-only wavelet analysis and filtered output separate.
Include the actual RAW baseline EV in source identity. Reuse existing per-client
latest-only queues; derive preview demand from physical viewport pixels and hold
the current denoised proxy during a 200 ms resize quiet period. FINAL/file outputs
remain exact and explicitly disable preview flags.

**Spec:** User request in this chat and `lutools/docs/color-contract.md`.

## Constraints

- Work only in `review/viewport-denoise-cache` in the attached worktree.
- Prove the cache failure before changing production code; no speculative fix.
- Preserve request v2 layout, original RAWs, the original checkout and other work.
- Do not start platform changes until the core/macOS verification and review pass.
- No commit, push, publishing or release is requested.

## Core And macOS Gate

- [x] Add a real Bayer RAW FBDD 2->1/camera->Kelvin round-trip regression.
  It failed before the fix: EV 0.226269 -> 0.225645, stale output hit, 8963 differing bytes.
- [x] Add exact float baseline identity to `sony2fuji_c.cpp` only after reproduction.
- [x] Add preview-output, preview-analysis, exact-output and unchanged-EV reuse cases
  to `wavelet_cache_tests.cpp`; register the external-RAW CTest.
- [x] Add applied-wavelet proxy/resize/strength/WB -> native JPEG/PNG comparisons
  with an independent exact engine in `ViewportPreviewTests.swift`.
- [x] Run fresh CTest and real-RAW viewport/export/model checks: 24/24 CTests and
  the full Swift integration passed. Evidence is in `docs/verification-preview-p2-2026-10-13.md`.
- [x] Inspect both P2s through independent review before advancing: both reviewers
  found no Must/Should issues; `reviews/self-p2-cache-export-20261013.md` records the gate.

## Conditional Client Rollout

- [x] Windows: extend PhotoCanvas physical edge events, MainWindow resize/latest
  scheduling and Native/RenderEngine viewport setter. Retain edge=0 native export.
  Add Preview/Interaction/Denoise checks for DPI, resize and export reset.
- [x] Android: return physical viewport demand from PhotoCanvas, add edge to
  preview work, stabilize denoise resize and pass the viewport flag through JNI.
  Export passes both preview flags off; add PhotoZoom/queue/request regressions.
- [x] iOS: return physical viewport demand from ZoomablePhoto, include edge in
  PreviewRequest and latest-result guards, stabilize denoise resize, and add the
  Processor viewport setter. Keep Photos/file output FINAL and exact; add geometry
  and processor/export regression coverage.
- [x] Run each available platform's established build/tests and a final independent
  review. State unavailable platform/runtime checks explicitly, never as passed.
  iOS simulator and Android arm64 build/unit/lint/integration passed; final Dual
  review has no Must/Should findings. Subsequent same-condition before/current
  diagnosis, fresh 2.5GB cold/warm/recompute, before-reference byte comparisons,
  and isolated Windows VM native exports/interactions passed. The original
  worktree gates are closed in `docs/verification-android-denoise-memory-2026-10-13.md`.
  Separately revalidate the new `development`-based delivery branch; do not carry
  unrelated old AI/JXL history or call original-worktree evidence exact-head CI.
