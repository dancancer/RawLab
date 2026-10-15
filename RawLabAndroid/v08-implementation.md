# Android 0.8 Implementation

## Authority and Isolation

- Current user approval supersedes the historical pending-approval notices in the design package.
- Base: `440b9788ff4cfd8a3f5dfa781b16a33997ccd801` (`origin/development`, PR #51).
- Worktree: `/Users/xupeng/.codex/worktrees/56c3/rawtools`.
- Branch: `feature/android-v08-editor`.
- Approved design source: `17b012361d2a4e470a7bba41cd7cf0c1bc7997a3`, read-only design worktree.
- Android implementation only. No Shared/C++ ABI changes, release, push, PR, or Library writes.

## Stages

1. Establish Gradle baseline and preserve RAW, recipe, persistence, export, and batch contracts.
2. Implement continuous gray/yellow editor, ordered circular tools, signed arcs, moving rulers,
   exact-value drafts, film labels and recipe badges, and phone/tablet portrait structure.
3. Implement geometry/lens group drafts with preview-only rendering, apply/cancel/exit protection,
   constrained crops and on-canvas controls. Ordinary adjustments remain immediate.
4. Replace single/batch format chips with full-width radio rows; preserve SAF/MediaStore,
   size validation, frozen snapshots, stop/recovery and complete bundled licenses.
5. Integrate approved adaptive launcher layers and settings. Validate using Gradle, native
   package checks, focused instrumentation, then independent read-only review.

## Review Focus

- Draft renders must not persist, alter ordinary settings, or become exportable.
- Stale render results must not overwrite newer draft or committed settings.
- Numeric drafts reject invalid/non-finite/out-of-range values without changing the live value.
- Portrait tablets stay stacked; font scaling must not hide format titles or fixed draft actions.
- DNG remains file-only; batch requires a directory. Cancelled pickers do not report success.
- 100% refers to bounded comparison-preview pixels, never full RAW pixels.
- Launcher resource validation is not installed-launcher or OEM-mask acceptance.

## Verification

Results and precise limitations are recorded here as stages complete. Design prototype checks
are reference evidence only and are not Android product verification.
