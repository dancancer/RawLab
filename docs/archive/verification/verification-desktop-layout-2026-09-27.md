# Desktop Layout Verification

## Scope

Native macOS UI only: square flat film artwork, simplified toolbar, full-height file browser, resizable/collapsible right-hand adjustment panel, translucent icon-only histogram, and removal of the canvas title strip. RAW processing algorithms are unchanged by this UI iteration.

## Automated Checks

- `RawLabMac/tests/presentation.sh`: passed against both source and final app-bundled artwork. Covers panel height, resize limits, complete collapse and height restoration; existing signed rings, viewport behavior, per-photo settings and directory listing checks.
- `RawLabMac/tests/adjustments.sh`: passed with 8 real RAW fixtures, including preview/export adjustment parity and reset behavior. Artifacts: `/tmp/rawlab-adjustments.Rvikxi`.
- Independent scoped code review found no concrete functional or layout defect.
- `RawLabMac/build.sh`, `codesign --verify --deep --strict`, and `git diff --check` passed.
- Artwork provenance scan: 10 rasters, 0 missing, in both the source directory and packaged app.

## Native Interaction Checks

Tested in an isolated `RawLab Layout Preview.app`, preserving other running application instances and their edits.

- The file browser spans the full content height; only the right-hand workspace contains the adjustment dock and status bar.
- The top toolbar has one comparison button, one zoom menu, adjustment visibility and export, plus file actions on the left.
- The canvas title strip is absent. Comparison names appear as compact bottom-left overlays.
- Clicking the dock collapse button removes every adjustment control from the accessibility tree. The toolbar restore button brings back the selected film, tool and values.
- Dragging the compact-window resize grip from `(1162, 816)` to `(1162, 716)` in the Retina screenshot moves the boundary upward by 100 pixels. Film artwork scales with the available panel height.
- Dragging downward reaches the minimum height without clipping the strength input, slider or ticks.
- The histogram header contains icons only; the photo remains visible through the background.

Screenshots of the layout interaction checks (before final flat artwork was bundled):

- `.impeccable/review/mac-layout-expanded.jpg`
- `.impeccable/review/mac-layout-resize-compact.jpg`
- `.impeccable/review/mac-layout-minimum.jpg`

## Artwork

Generated artwork is reference-inspired, not official product photography. Exact prompts, references, and generation paths are recorded in `RawLabMac/Resources/FilmIcons/generated-set-a.md` and `generated-set-b.md`. Simulations without matching physical film products use marked concept labels rather than pretending to be real retail products.

All ten final flat labels were visually inspected individually and passed bundled-resource decoding tests. A final whole-window capture from `RawLab Flat Preview.app` was not obtained: native UI inspection timed out after the file dialog. The user was asked to display that window. The layout interaction screenshots above are from the preceding build and must not be presented as final-artwork screenshots.
