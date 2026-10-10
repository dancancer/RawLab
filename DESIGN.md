# RawLab Desktop Design

## Overview

Native macOS RAW verification and editing, with a Photos-inspired bottom adjustment dock. The actual photo leads; this is not a marketing page or a catalog database. Preserve RAW originals and the shared rendering contract. Controls are Chinese; film simulation names retain their proper names.

## Colors

- Dark neutral-gray canvas (`NSColor(white: 0.12, alpha: 1)`) and native window-background surfaces reduce glare.
- Yellow identifies selected tools, changed values, default-value markers and adjustment progress. It is functional, not decorative.
- Film icons are square, flat front-label artwork inspired by documented Fujifilm packaging. Preserve each reference's colors and typography; no perspective boxes, sides or generic all-green styling. Simulations without physical products use explicitly marked concept labels.
- Histogram RGB channels and clipping colors retain their output-diagnostic meanings, not sensor-measurement claims.

## Typography

Use macOS system typography, compact 11-point tool labels and native control sizes. Numeric values use monospaced digits. Built-in film names must remain readable; wrap long names inside stable two-line slots. Do not add a display font or scale text with window width.

## Layout

- Minimum content size is 950x620 points; the photo workspace expands with the window.
- A collapsible 200-300 point file tree spans the full content height on the left. Folder rows expand into subfolders and two-column RAW thumbnail grids.
- The photo area contains neutral/result comparison panes sharing zoom and pan. Fit mode uses bounded previews; actual-pixel viewing requests native resolution and accounts for display scale.
- Only a collapsible histogram floats at the photo area's upper-right. There is no fixed right-side adjustment inspector.
- Every edit control is in the bottom of the right-hand workspace, never beneath the file tree. Its header holds the active film name, exposure baseline and reset menu. Drag its upper edge to resize; collapse completely and restore using the toolbar adjustment icon without losing values or the previous height.
- A single circular tool row contains film, strength and all nine tonal/color/detail adjustments. Film is a peer tool, never a separate mode tab.
- Selecting film replaces the value editor below the tool row with a horizontal square-label chooser. Center the list when it fits and scroll when it overflows. Selecting a numeric tool restores its input, slider, ticks and reset button without changing other values.
- The photo canvas has no title strip. Comparison identifiers are small bottom-left overlays only in comparison mode.

## Elevation & Depth

Use continuous surfaces and separators, not floating section cards. The histogram has an 8-point radius, a translucent black surface and a quiet border. Its header uses icons only, with accessible names and tooltips. Film and file selections use restrained yellow outlines.

## Shapes

- Circular tool icons have a stable 40-point diameter inside 56x70-point button layouts.
- Progress starts at the top: positive changes run clockwise, negative changes counterclockwise. Normalize each side against its own distance from the default. Keep the ring visible on the selected tool.
- Thumbnail corners are 4 points; film selection outlines are 6 points. Do not introduce decorative blobs or nested cards.

## Components

- The macOS app icon is an abstract flat mark: two offset yellow/cyan photographic frames on a charcoal rounded-square tile. No aperture blades, film perforations, text, metallic bevels or 3D camera illustration. The color overlap represents the source-to-render transformation.

- Use SF Symbols, native sliders, numeric fields, pickers, menus and file dialogs. Film label bitmaps are bundled local resources with generation provenance.
- The toolbar contains file-tree visibility, open, a comparison toggle, one zoom menu, adjustment visibility and export. Fit, actual pixels, zoom in and zoom out live inside the zoom menu. Editing sliders do not belong in the toolbar.
- Directory contents load on demand. Thumbnail decoding uses embedded previews with orientation; no full RAW decode is triggered merely to populate the file tree.
- Histogram collapse state survives photo changes. Bottom tool selection survives film/numeric editor changes. Changed values retain their signed ring and marker.
- No-photo, loading, disabled, error/retry and export-complete states are explicit. Export must not overwrite RAW input.
- Photo adjustments and look identities persist locally per original photo; unseen photos start with defaults. Save failures remain visible and retryable. No sidecars or cloud catalog are created.
- Batch export uses a frozen source adjustment snapshot, including denoise settings, in a separate desktop window or mobile task page. It never changes target photos' saved edits. The confirmed flow is documented in [the batch export design](docs/design/2026-10-09-edit-memory-batch-export/README.md).

## Do's and Don'ts

- Keep all adjustments at the bottom and preserve the shared color-processing semantics.
- Keep both the file tree and floating histogram collapsible so the photo can occupy the workspace.
- Do not restore a right adjustment sidebar or a separate film-mode switch.
- RAW white balance starts at the per-photo as-shot calibration estimate. Kelvin increases toward warm; positive tint adds magenta. Use the camera baseline for reset and the signed ring. The slider uses reciprocal Kelvin; numeric input remains Kelvin. Do not claim Lightroom profile parity or that the estimate is a literal EXIF Kelvin tag.
- Histograms use shared linear pixel-count scaling with RGB/CMY/neutral-gray filled overlaps. The horizontal axis is the current sRGB output, not RAW sensor saturation or Adobe's internal working space.
