# P2 Follow-Up Review

## Must-fix

（无）

## Should-fix

（无）

## Prior Findings

- Cache source identity: closed. A real Panasonic FBDD/WB sequence reproduced
  the failure before production changes (EV 0.226269 -> 0.225645, stale hit,
  8963 different bytes). Exact baseline float bits now participate in both
  filtered-output and analysis identities. Changed-anchor preview/output,
  analysis/options and exact cases match independent sessions; same-anchor
  reuse remains a hit.
- Applied-denoise viewport -> native file export: closed. The new real-RAW test
  exercises size/strength/WB changes and compares native JPEG/PNG dimensions
  and pixels with an independent exact engine. It proves the filter is active
  and PNG is 16-bit. FINAL/file and per-call flag resets remain intact.

## Scope And Evidence

- Self review in `review/viewport-denoise-cache`, attached isolated worktree.
- Base/head `b31827cf9c4a3237eaebf3c3d4f8f6fa58422f13` plus WIP, no Lensfun.
- Reviewed diff fingerprint `7b5fa187683b99877af1c1b1927582d57c8c7e45430d45b53dcfe79afdeff1cf`.
- Dual independent follow-up review plus main-thread verification. Both report
  no Must/Should findings. Relevant core, C ABI, cache and Mac tests/callers read.
- Fresh core build, CTest 24/24 (136.96s), full Swift viewport/native export/model
  checks and `git diff --check` passed before this review.
- Evidence: `docs/verification-preview-p2-2026-10-13.md`.
- No PR automation or exact-head remote CI (self WIP); no remote review posted.
- Remaining runtime limits: GPU fault injection and physical mobile memory/latency
  untested. Windows/Android/iOS rollout has not been reviewed or validated by this gate.

## Recommendation

The two P2s are resolved and the current Mac/core gate passes. Proceed with the
user-authorized client rollout, then validate and review those changes separately.
This is not approval of unimplemented platform code or an authorization to release.
