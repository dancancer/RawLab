# Windows 0.8 Implementation Plan

> Execution: main agent implements inline; independent agents provide read-only ABI/environment checks and final review. Latest user approval supersedes historical design approval gates.

**Goal:** Implement the approved Windows editor without changing shared rendering semantics.
**Architecture:** Keep the WPF system window, existing render scheduler, edit store and batch journal. Introduce reusable five-column parameter controls and pure interaction/draft models, then bind the existing editor to them.
**Tech Stack:** .NET 8, WPF, existing C ABI and managed executable regression tests.
**Spec:** Design worktree `88028a1ca49fd41ccb62bab88fed343e9566a549`, `docs/design/2026-10-14-windows-v08/WINDOWS-DESIGN.md` and `prototype-source.html`.

## Constraints

- Base `440b9788ff4cfd8a3f5dfa781b16a33997ccd801`; branch `feature/windows-v08-editor`; this independent worktree only.
- Own `RawLabWindows/**` only. No shared ABI changes, push, PR, merge, release or Library synchronization.
- Preserve standard caption/Snap and existing About fix; 1000x680 minimum, 1440x920 default DIP, at least 160 DIP canvas.
- Ordinary edits preview immediately and save after 400 ms; geometry/lens draft previews never persist until Apply.
- Native WPF, hardware, accessibility and cross-compile evidence are distinct.

## Tasks

1. Parameter interaction and reusable rows (`ParameterInteraction.cs`, `ParameterRow.cs`, parameter panels and managed tests).
   - [x] Add failing tests for exact fine grids, inverse-temperature mapping, wheel threshold/rate/reset/invalid-event contracts.
   - [x] Implement pure numeric/wheel model and bind five-column slider/text/unit/reset rows, Enter/blur/Escape and wheel handling.
   - [x] Verify managed suites and cross-build; commit focused changes.
2. Window shell and discovery (`MainWindow.xaml`, `MainWindow.xaml.cs`, `Controls.xaml`, platform resources).
   - [x] Add native layout/menu regression checks before shell changes.
   - [x] Implement five native menus, exact empty state, scrollable adjustment content, retained dock height and reset scopes; settings dialog and six-language keys.
   - [x] Verify cross-build and native layout where available; commit.
3. Geometry/lens workspace (`GeometrySettings.cs`, `Native.cs`, geometry/lens panels, canvas and MainWindow binding).
   - [x] Add failing tests for real current ABI, serialized perspective, draft apply/cancel/reset and constrained crop transforms.
   - [x] Implement platform binding and independent draft, leave prompt, crop overlay/ratio/ruler/keyboard controls; retain honest lens capability reports.
   - [x] Verify managed/native geometry checks and commit.
4. Workflow verification and completion (`tests/**`, platform verification record).
   - [x] Check save-failure switch blocking, exact-preview export/copy gate, RAW/output and frozen batch behavior.
   - [x] Run isolated Windows build/test and targeted native UI matrix where available; record precise NOT REACHED items.
   - [x] Independent read-only review, fix findings, re-run affected checks and commit verification record.

## Review Focus

- Pending invalid numeric input must not consume wheel or silently apply stale text.
- Switching tools/photos, closing and batch/export entry points must resolve dirty geometry/lens drafts without saving previews.
- Delayed render results and white-balance calibration must not overwrite committed state or publish stale draft frames.
- Small windows, long German labels and enlarged text must scroll rather than shrink or overlap.
- Native menus must retain submenu keyboard behavior and focus restoration; no invented save/undo/history commands.

## Progress

- Implementation commits are local to `feature/windows-v08-editor`; no shared or other-platform source changed.
- Managed editing, denoise-model, localization and Windows cross-build pass. The isolated Windows full `build.ps1 -Test` follow-up passes 33/33 CTest, About and 152 default WPF checks; the test-output discovery failure is fixed and covered by a PowerShell parser regression.
- Native targeted checks and final affected-check reruns are recorded separately in `VERIFICATION-v08.md`. Programmatic WPF composition is not physical DPI, Snap, Narrator, touchpad or multi-monitor acceptance.
- The real-RAW denoise assertion is corrected with an active-filter controlled RAW and retained real-photo cache/export/hash regressions; the final denoise rerun passes 42 checks. The fixture's five-flat-tile no-op is confirmed without shared changes. Implementation and owned verification are complete; physical acceptance gaps still keep release acceptance non-green. No claim of complete hardware/release verification is made.
