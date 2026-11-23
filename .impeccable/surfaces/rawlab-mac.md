---
version: 1
slug: "rawlab-mac"
primary_target: "RawLabMac/Sources/Editor/View/EditorView.swift"
related_targets: ["RawLabMac/Sources/Editor/View/AdjustmentDock.swift", "RawLabMac/Sources/Library/MacWorkspaceBrowser.swift", "RawLabMac/Sources/Presentation/PhotoCanvas.swift", "RawLabMac/Sources/Geometry/MacGeometryWorkspace.swift", "RawLabMac/Sources/Export/BatchSelectionView.swift", "RawLabMac/Sources/Export/BatchExportView.swift"]
---

# RawLab Mac Editor

Mode: Operate. Target audience: sighted photographers working at standard macOS text sizes across six supported languages.

Photographers browse RAW and supported raster photos, edit a selected photo in a dark neutral-gray canvas (`NSColor(white: 0.12)`), and export without altering source originals. Minimum content size is `950×620 pt` (default `1320×850 pt`). The flat center toolbar switches between `Edit`, `Select` (contact sheet + folder tree + bottom batch bar), and `Preview` (`Escape` restores the previous mode).

In `Edit`, the left browser (`232 pt` default, `200–288 pt`) strictly separates folders (`min(height × 0.34, 220 pt)`, Collapse All above tree) from 2-column `3 pt`-radius thumbnails with per-folder scroll memory, breadcrumbs, Up, retry on error, edited pencil badges, and `"应用当前设置"` context actions. Below `1180 pt` window width, the browser opens as a `264 pt` leading drawer (`Escape` or opening a photo dismisses) and the right inspector locks to `280 pt` (otherwise `304 pt` default, `280–360 pt`).

The central photo canvas spans full height between the toolbar and `30 pt` bottom status bar, with Fit / 1:1 actual pixels (`⌘0` / `⌘1`, `64 px` render steps), `12 pt` toggleable margin, Side-by-Side / Wipe / hold-`\` before comparisons, `I`-cycled `360 pt` info overlay, clipping mask toggle, drag-and-drop, and `ellipsis.circle` More menu (Copy/Paste/Undo/Redo/Session History/Histogram popover/Batch Edit).

The right inspector hosts the collapsible `68 pt` RGB/HDR histogram at top, followed by **6 adjustment groups in SDR / 7 in HDR** (`Looks`, `Light`, `Color`, `Effects`, `Detail`, `Geometry & Lens`, plus `HDR Rendition`). Group tabs and collapsible accordion tools replace retired circular tool icons. Look Strength sits above SDR Looks (3-col Film chooser with categories/search/Recent-12/LUT & DCP import dialogs, 3-col Master Recipes, Quick & My Presets); in HDR mode, clicking Looks opens `HDRLookControls` + `QuickPresetView`. Light includes Auto Exposure and S-Curve / Multi-point master Tone Curve (R/G/B channel curves are preserved and rendered, not edited in macOS UI); Color includes reciprocal Kelvin WB, 8-swatch HSL + canvas Target Adjustment, and 3-zone Color Grading; Effects includes Clarity, Dehaze, 5-param Vignette, and 3-param Grain; Detail includes Sharpening, Wavelet Denoise, and Core ML GPU AI Denoise; Geometry & Lens runs an explicit draft with bottom Cancel/Apply (`SDR` Lens is RAW-only without a Vignetting toggle). Outside geometry drafts, the inspector footer shows the active look and opens the `320 pt` Processing Settings popover (HDR toggle, HDR monitoring, HDR rendition controls, Bayer HDR RAW dev with Vignetting + FBDD + DCP profiles, processing version, v3 migration progress/rollback, X3F mode, exposure baseline).

Modeless `BatchSelectionView` (per-photo micro-edit, Sync, per-target frozen export) and `BatchExportView` (uniform & per-target frozen, `ExportSizePicker`), system Open With forwarding, and Sparkle software updates (`UpdateAvailabilityBanner` / `SoftwareUpdateView`) share the same desktop editing semantics.

[DESIGN.md](../../DESIGN.md) records desktop tokens and cross-platform rules. SwiftUI and AppKit provide the production interface.
