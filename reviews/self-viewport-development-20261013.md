# Development Delivery Review

## Findings

No confirmed Must/Should findings remain in the final source snapshot.
No remote review, comment or approval was posted by the reviewers.

## Scope

Self mode, Dual, `feature/viewport-denoise-preview`, against development
`12d6cc17b2b92233657d3eb548ee146dbdcb8530`. Reviewed local feature-only WIP,
including staged and unstaged source changes; this report precedes its delivery
commit. The delivered commit must contain this exact reviewed source snapshot.
The 58 changed source/test/contract paths are bound by a sorted SHA-256 manifest:
`build/delivery-validation/source-fingerprint.txt`, SHA-256
`1a06c45b850b456e8a7df98797587f045673ba83912ae38961b81f6edb310a5b`.
The main agent verified every checksum after the final Windows run.

The requested dimensions were denoise-cache invalidation, window/viewport
resizing and native export correctness. Both original independent reviewers
were reused for the development migration and the final Windows increment.
No additional broad audit or repeated Android memory experiment was required.
Reviewers were read-only; implementation and runtime verification were performed
separately by the main agent.

## Coverage

- Core: wavelet cache/tile/filter, C ABI/FFI, CMake and all changed native tests.
- macOS: Adjustments/EditorModel/EditorView/Engine/PhotoCanvas and all changed
  edit, presentation, progressive and viewport tests/scripts.
- iOS: RawProcessing/ViewModel, panel/zoom geometry/canvas and all changed tests/scripts.
- Android: JNI, editor scheduling/canvas/zoom/activity and all changed instrumented,
  unit and native-memory tests/scripts.
- Windows: MainWindow/Native/PhotoCanvas/RenderEngine and Comparison/Denoise/
  Interaction/Preview/Program checks.
- The color contract was reviewed. Historical plans, verification reports,
  reviews and README prose were not subjected to another behavior audit; the
  main agent checked their delivery-baseline claims. No added or large modified
  production/test file was omitted from the combined source coverage.

## Reconciliation

The migration preserves the current baseline's HSL, master recipes, automatic
exposure and generic Metal/GLES/D3D11 denoising. It does not import the original
branch's unrelated AI or JPEG XL DNG commits. Exact/viewport slots remain separate;
RAW and exposure-baseline identity, dimensions, denoise settings and backend
changes invalidate the appropriate output. Downstream edits reuse output;
strength changes retain analysis but release obsolete full-resolution pixels.
FINAL/file output never enters viewport reduction.

Three Windows initialization gaps were checked rather than dismissed as timing:

- The source-size callback could replace the initial proxy/refine request.
  RED reproduced it; `MainWindow.xaml.cs:340` now preserves initial preview while
  `result` is null. A current proxy remains non-exportable.
- Placeholder initialization could leave the main request at 2000px while the
  physical canvas requested 384px. The actual resized-window bitmap assertion
  failed before the guarded initialization/edge copy at `MainWindow.xaml.cs:265`.
  Final GREEN settled at 256x384 and retained current-file/settings guards.
- Without an image, metadata could not update the canvas resolution. Both
  reviewers raised this Should; the synchronous arranged-canvas metadata test
  failed against the old image-null early return. `PhotoCanvas.cs:108` now computes
  resolution without an image and only conditions drawing math on image presence.
  `ComparisonChecks.cs:55` covers initial/late aspect metadata; `Program.cs:197`
  covers no-supplied-placeholder photo switching. Final complete suite passed.

The detached-canvas fixture was corrected to arrange before its synchronous
metadata callback; a fresh valid RED/GREEN cycle replaced the invalid assumption
that standalone Arrange immediately dispatches SizeChanged. Both reviewers
confirmed this fixture-order change leaves their static conclusion unchanged.

## Runtime Evidence And Limits

Development-baseline gates: shared CTest 22/22; macOS viewport/progressive/native
exports and 14 master recipes; iOS framework/app, 220 export checks and viewport
state; Android arm64/60 unit/lint, eight regressions plus Sony metadata and fresh
2.5 GiB cold/warm/recompute controls; Windows CTest 20/20, managed 136 checks,
applied NR native exports/GPU parity/interactions and self-contained publish.
Full controls, heap measurements, byte-identical output hashes and collection
exceptions are in `docs/verification-viewport-development-2026-10-13.md`.

An authorized documentation-only follow-up closed the standalone macOS bundle
gap at source commit `e101b798c174356d0223ade1eff31ba8983f91db`: fresh dependencies
in this worktree, isolated Release/arm64 app build, strict ad-hoc signature and
dependency/resource/license checks, and packaged smoke with the source install
prefix unavailable passed. No production/test change or repeated RAW suite was
needed. The original source fingerprint remains unchanged.

Physical mobile devices, larger RAWs, Android x86_64 runtime and macOS x86_64
runtime are not covered. The new packaged smoke ran on macOS 27.0; fresh interactive
GUI use and macOS 26/15 runtime are not claimed. Sampling is not an instantaneous
heap maximum and timing is not a controlled throughput benchmark. No exact-head
remote CI or provider automated-review success is claimed; those remain separate
from the local/VM gates. This review does not authorize merge or release.
