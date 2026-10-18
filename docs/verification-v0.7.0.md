# v0.7.0 Integration Tracking

Status: all five features and Sony memory repair PR #31 are merged into
development. The release candidate absorbed the repair at `2dac9d9` and the
affected available packages were rebuilt. [Release verification](verification-v0.7.0-release.md)
and [the remote Release](https://github.com/dancancer/RawLab/releases/tag/v0.7.0)
record final package/source identities and publication.

Source baseline: `3f252a1006d349c2a3655129a9cf665385dccaca`, merged on
2026-10-13. Its Git tree is `8cd099efca75c18765ec5db178746d8bd8da3ebd`,
identical to the accepted #25 source
`de3b79376d40657856285f5dfc41ca8bf4ecc1e9`. Root verified tree identity and
an empty diff. Fresh #25 client and language evidence can therefore be
bound to this final development tree with its original limits.

The candidate branch `release/0.7.0` starts from that accepted source. Version
metadata is committed at `465bd109f6aee6b6b36d4f9fd6d7d985dca4e7fe`
(0.7.0/build11); the final report was copied by a docs-only cherry-pick.
See [the final composition report](verification-final-composition-2026-10-13.md)
for new execution, adopted evidence and artifact identities.

## Completed Development Merges

| PR | Delivered source head | Development merge |
| --- | --- | --- |
| [#23, JPEG XL DNG](https://github.com/dancancer/RawLab/pull/23) | `d6d51b92cb1942b7745964325f3e5586baf3996c` | `caf51809102489dd0ecc5bc185352fe9992a5177` |
| [#28, documentation cleanup](https://github.com/dancancer/RawLab/pull/28) | `bdbb1d4343c918f0e95dc0fc10a11db491f121ce` | `261b9323bea13f562bcfee7db736fcf1728704f5` |
| [#24, rendered DNG](https://github.com/dancancer/RawLab/pull/24) | `5f0dea614138813cb58b6e3637fa997363ab14b4` | `802354aa9b54e540fc2ca1c55be09038a5f621bd` |
| [#29, integration workflow](https://github.com/dancancer/RawLab/pull/29) | `828018e1de67b701932eed73a880c31457b16dee` | `c7471a390e57fbdfe72213757d3547f876bc43fe` |
| [#26, Lensfun](https://github.com/dancancer/RawLab/pull/26) | `b89e1bd9080e2d320252f774fb82f97e0ffc9b17` | `d810fe6e47fbc70be79786a8ebaee2d1e9e9fe0e` |
| [#27, viewport/cache/memory](https://github.com/dancancer/RawLab/pull/27) | `15e0d044a91102a2157219e8250b69f5c5ac7ada` | `2c46edc5f0d8a26933f853afbb068e5def06e2bf` |
| [#25, six languages](https://github.com/dancancer/RawLab/pull/25) | `de3b79376d40657856285f5dfc41ca8bf4ecc1e9` | `3f252a1006d349c2a3655129a9cf665385dccaca` |
| [#31, Sony memory](https://github.com/dancancer/RawLab/pull/31) | `627d45e7a8dddb0424203afba08c46a0515113be` | `ff6ae5114ea7da7452f9dd7c7638636becf0893b` |

Root verified each delivery and the actual remote merge. The final merge has
parents `2c46edc5f0d8a26933f853afbb068e5def06e2bf` and
`de3b79376d40657856285f5dfc41ca8bf4ecc1e9`.

## Feature and Incremental Evidence

| Feature | Accepted evidence |
| --- | --- |
| JPEG XL DNG | [Decoder verification](https://github.com/dancancer/RawLab/blob/a38ac6065f747cc43ddbee1c8df232c049b288d2/docs/verification-dng-jpeg-xl-2026-10-12.md), PR #23, and the later SDK Stage3 integration evidence |
| Rendered DNG | [Export verification](https://github.com/dancancer/RawLab/blob/a38ac6065f747cc43ddbee1c8df232c049b288d2/docs/verification-rendered-dng-export.md), PR #24's accepted new-development review and actual file/export checks |
| Lensfun | [Platform verification](https://github.com/dancancer/RawLab/blob/a38ac6065f747cc43ddbee1c8df232c049b288d2/docs/verification-lens-correction-platforms-2026-10-13.md), [Lens/DNG integration](verification-lens-dng-integration-2026-10-13.md), and original independent reviewers bound to the final #26 source |
| Viewport/cache/memory | [Development verification](verification-viewport-development-2026-10-13.md), [Lens/DNG/NR combination](verification-viewport-lens-dng-integration-2026-10-13.md), and two original reviewers bound to `15e0d044` and the final 60-path manifest `be656f12197be66d1f7eb41b29023511859d724938cffd860b92a4ab7d0b1faf` |
| Six languages | [Localization verification](verification-localization-2026-10-13.md), [maintenance guide](localization.md), and both original reviewers bound to clean `de3b7937` |

Independent review closed the affected feature deltas. Existing observations
and coverage limits remain below. Source identity permits reuse of unchanged
checks; it does not turn an unexecuted device case into a pass. Ignored build
logs referenced by reports may be absent from a clean checkout.

## Final Integrated Verification

| Gate | Current evidence and state |
| --- | --- |
| Source and review | All five features merged; actual SHA/parents/tree identity confirmed; affected original reviews bound to their final source revisions |
| Fresh build/link | #25 fresh iOS/Android/Windows evidence applies through identical tree; own-prefix fresh Mac core/package PASS with SDK/JXL/TIFF/Lens/NR/GPU enabled |
| Decoder reuse | Actual SDK Stage3 and warning reset regressions retain #26's accepted source scope; final native tree is unchanged from #27 |
| Cache isolation and FINAL | Final source unique combination 1/1 PASS, 79.29 seconds; fresh Mac viewport/native JPEG/PNG/resize PASS, preserving exact independent FINAL assertions |
| Six-language integration | #25 resource, typed-state and actual six-language state/save checks apply through identical tree, with failed attempts and fixture limits retained |
| Package closure | Final source Mac resource/license/signature/RAW-exclusion and hidden-prefix DYLD runtime closure PASS. All four versioned local packages are complete in the separate [candidate report](verification-v0.7.0-candidate.md) |

The final executor owns `build/iteration-v070-integration`; it advances only
that worktree, uses its own dependencies and fresh CMake directory, and
records actual source/configuration, fixtures, commands and outputs. The
final report distinguishes new execution from reused evidence. Original
Android cold/warm/Scene measurements under 1,800,000,000 bytes are per-feature
evidence and are not repeated or relabeled as a new integrated memory test.

## Failed Attempts and Remaining Coverage

- The earlier Sony LMK attempts remain in the historical candidate record.
  Controlled follow-up located the kill in wavelet filter, fixed overlapping
  buffers and completed original-size JPEG/PNG/DNG plus independent FINAL on
  the 2.5GB CPU AVD and approximately 12GB physical CPU/Force GLES device.
  Complete before/after files match; sampled CPU heap 2.085→1.692GB. Existing
  budgets/tolerances and GPU ≥6GB acceptance remain unchanged. See
  [Sony verification](https://github.com/dancancer/RawLab/blob/a38ac6065f747cc43ddbee1c8df232c049b288d2/docs/verification-android-sony-dng-memory-2026-10-14.md).
- iOS earlier Files Cancel accessibility queries failed. The final two UI
  tests passed with the visible Save action and an actual copied 128x128
  float32 DNG. Native Files cancellation remains unverified.
- #25 Windows fresh native export checks used GPU OFF and do not establish
  hardware GPU or CTest coverage. Earlier #27 D3D11 checks retain their
  source/configuration. SaveFileDialog and Explorer acceptance are not reached.
- Existing iOS RAW-to-raster Lens-panel selection and model-level DNG
  preview/busy guard observations remain recorded for the relevant owners.
  Normal UI export has preview/busy gating; these were not localization
  regressions or silently changed as part of translation.
- Apart from the recorded Sony physical Android matrix, other physical mobile
  devices, larger RAWs, Android/macOS x86_64 runtime,
  untested OS versions and fresh interactive Mac GUI remain outside the
  stated coverage. The final composition verification uses host 27.0.1 and target 26.0;
  published v0.6.0 packages target 15.0. Candidate support remains macOS 15; the separate arm64 target 15 build,
  all-Mach-O minimum-OS/signature checks and hidden-prefix packaged smoke passed.
  Physical macOS15 runtime and Intel candidate packaging remain unverified.

## CI and Candidate Endpoint

At 2026-10-13 22:25:58 Asia/Shanghai, GitHub check-runs on exact development
`3f252a1` had `total_count=0`, and combined status had `total_count=0` with
an empty statuses list. The legacy status value `pending` does not mean a
workflow is running. No hosted CI was implemented or triggered.

The pre-fix candidate record is retained in
[candidate verification](verification-v0.7.0-candidate.md). Final release
packages and source are bound to the absorbed repair in
[release verification](verification-v0.7.0-release.md). The remote Release and
Git history record main/tag/development delivery; package validation is local.

See [candidate preparation](releases/v0.7.0-preparation.md) and
[the integration workflow](integration-workflow.md).
