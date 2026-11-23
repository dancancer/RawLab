---
version: 1
slug: "rawlab-windows"
primary_target: "RawLabWindows/MainWindow.xaml"
related_targets: ["RawLabWindows/Controls.xaml", "RawLabWindows/EditorAppearance.cs", "RawLabWindows/PhotoCanvas.cs", "RawLabWindows/Core/WorkspaceLayout.cs", "RawLabWindows/MainWindow/Tools.cs", "RawLabWindows/MainWindow.HDR.cs", "RawLabWindows/BatchSelectionWindow.cs", "RawLabWindows/BatchExportWindow.xaml", "RawLabWindows/Updates/SoftwareUpdateWindow.cs"]
---

# RawLab Windows Editor

Mode: Operate. Target audience: sighted photographers working at standard Windows text scales across six supported languages (`PerMonitorV2` DPI aware; low-vision extreme `TextScaleFactor` reflow and UIA/screen-reader-first flows are out of active design scope).

Native WPF (`.NET 8.0-windows`) desktop editor using an explicit 33-brush dark palette (`WindowSurface #181A1E`, `CanvasSurface #1C1C1E`, `InputSurface #212124`, `TreeSurface #232326`, `Surface #272729`, `PopupSurface #292C32`, `RaisedSurface #303033`, `SelectedSurface #34332D`, `Outline #444449`, `Foreground #EEEEF2`, `Muted #B1B1BC`, `Accent/Indicator #F2CE48`, `AccentText #252110`, `ErrorForeground #FFAB92`; zero `DropShadowEffect`) and `Segoe UI, Microsoft YaHei UI` typography (`13 px` body, `11 px` captions, `FontNumeralAlignment.Tabular` in `ParameterNumberBox`).

- **Shell, Workspaces & Breakpoints**:
  - Window minimum `1000×680 px` (default `1440×920 px`) in a 4-row `EditorShell`: Menu (`28 px`), Toolbar (`48 px`), WorkspaceBody (`*`), Status Bar (`40 px` with `GpuMode` selector, backend/fallback tooltip, save/retry status, batch resume).
  - Three modes (`Editing`, `Selection`, `Preview`). Left library (`232 px` default, `200–288 px`) strictly separates virtualized folder `TreeView` (`min(220, height × 0.34)` in Editing, full height in Selection) from thumbnails (`2-col` `108 px` sidebar / multi-col `144 px` Selection grid with bottom batch bar) with per-folder `Gallery.Anchors` scroll memory. Right inspector (`304 px` default, `280–360 px` via `5 px` `GridSplitter`). Below `1180 px`, Library switches to a `264 px` slide-over `LibraryOverlay` drawer and Inspector locks to `280 px`.
- **Canvas & HDR Display**:
  - Dual `PhotoCanvas` + `HDRSurface` (`HwndHost` D3D11 + DXGI 1.6 `R16G16B16A16_FLOAT` `FLIP_DISCARD` linear scRGB swap chain with up to 32 WPF cutout rects and explicit SDR fallback; `16 px` optional `PhotoMargin`). Displays embedded preview immediately on load, degrades safely with fallback image + Retry on preview error, and supports Fit (`F`), 1:1 (`1`), zoom/pan, Side-by-Side / Wipe / hold-`\` compare, Clipping overlay, and `I`-cycled `InfoOverlay`.
- **Inspector, Controls & Discrepancy Notes**:
  - Collapsible `92 px` inline histogram (reparents to `280 px` `HistogramPopup` when hidden or body `< 400 px`), **6 SDR / 7 HDR groups** (` •` modified mark), SDR Look Strength row, scrolling tools with `ToolBody` expanded below the selected tool, Geometry/Lens `DraftActions` bar, and footer with active look + `330 px` `ProcessingPopup` (processing version, v3 auto-migration status & rollback, X3F mode, exposure baseline).
  - `ParameterSlider` (`14×14 px` circular thumb, `3 px` track, `Indicator` active fill, `Muted` origin tick) + `ParameterRow` (wheel stepping, Enter/Esc, double-click reset, right-click reset). Custom `24×24` grid `1.6 px` stroke `EditorIcon` vector set; compact `AdjustmentRing` renders a `4 px` yellow dot when modified.
  - **Current desktop parity limits**: `ToneCurvePanel` / `ToneCurveCanvas` edits only the master RGB curve (preserving and rendering stored R/G/B curves without channel tabs); SDR `LensPanel.xaml` enforces RAW-only visibility without a Vignetting checkbox (whereas the `HDR RAW…` dialog exposes `暗角校正` alongside Distortion, TCA, Auto-Crop, FBDD, WB, exposure ref, and `.dcp`/`.rlook` profiles). DirectML hardware-GPU AI denoise (`AISurface`) exposes device/VRAM picker and diagnostics `.zip` export.
- **Batch, Single-Instance Open With & Updates**: Modeless `BatchSelectionWindow` (`880×760 px`) and `BatchExportWindow` (`1040×720 px`, cancel finishes in-progress photo before stopping), `SystemPhotoOpen` named-pipe single-instance forwarding, and Velopack `1.2.161` `SoftwareUpdateWindow` + `UpdateLockBanner`.

[DESIGN.md](../../DESIGN.md) records the Windows tokens and cross-platform rules.
