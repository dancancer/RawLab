# Android Denoise Memory Follow-Up Review

## Findings

No confirmed Must/Should findings remain in the reviewed memory/export increment.
No remote review, comment or approval was posted.

## Scope

Self mode, Dual, branch `review/viewport-denoise-cache`, HEAD/base
`b31827cf9c4a3237eaebf3c3d4f8f6fa58422f13`, no commits, local WIP.
This is an incremental review after the prior core/Mac and platform reviews, not
an independent re-review of every unchanged client file. Eight-file SHA manifest:
`build/android-memory/review-fingerprint.txt`, manifest SHA256
`d4cf6ba12e269a65fa39422930c016b0f425331f060acf7afd009afcb7f883e7`.
Both reviewers covered all eight source/test files, Android JNI/export and
Windows preview/file boundaries. No files omitted in that increment.

## Reconciliation

- Global-reflection tile inputs match old full padding, including thin aligned
  tail tiles, small source sizes and one-pixel axes. Tile writes remain disjoint.
- The initially identified full multi-tile/thread test gap was closed with
  1537x1025 fine/coarse, one/two-thread float-RGB bitwise comparison. It passed
  on Mac and Windows; both reviewers reviewed the added test in the final snapshot.
- A preliminary claim that remaining coarse-calibration full padding blocked
  2.5GB cold export was withdrawn after fresh cold/recompute budget evidence.
  The allocation exists but the target case passes; larger RAWs remain a limit,
  not an asserted defect. No speculative calibration refactor was made.
- The cache-miss path releases only obsolete image output, clears completed,
  and retains the source analysis. Output/analysis hits, backend changes and
  failure retries remain covered by the existing cache/render tests.
- FINAL/files do not enter viewport reduction; Android/Windows wrappers reset
  both preview flags before native JPEG/PNG. Old/reference output files are byte
  identical after the fix, including the 16-bit PNG data.

## Gates And Limits

Fresh 2.5GB cold and warm, each including strength-recompute, passed the 1.8GB
sampled-native-heap budget. Shared CTest 24/24, Mac integration, eight Android
cases across appropriate Panasonic/Sony fixtures, Windows native exports and
interactions, and rebuilt iOS slices/app/native JPEG checks passed. Full details
and raw-log paths are in `docs/verification-android-denoise-memory-2026-10-13.md`.
The invalid warm run was explicitly caused by an external APK reinstall, not OOM.
Wavelet-disabled source compilation passed; no whole disabled-feature app build.

100ms sampling is not an instantaneous heap maximum. Physical mobile devices,
larger RAWs and injected GPU failures are not covered. Android x86_64 dependency
download failed; only arm64 runtime is claimed. No remote CI evidence exists.

Later authorized PR delivery on current `development` requires its own review
and baseline-sensitive gates. This old branch includes unrelated committed
AI/JXL changes that must not enter the feature PR.
