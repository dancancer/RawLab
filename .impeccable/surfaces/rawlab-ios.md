# RawLab iOS / iPadOS Editor

Mode: Operate.

Target: `RawLab/RawLab/UI/Editor/ContentView.swift`.
Native SwiftUI/UIKit for iPhone and iPad. Preserve the shared RAW processing contract.
Root `DESIGN.md` records the scoped iOS system without changing desktop guidance.

- Use a dark neutral photo canvas, system text styles, SF Symbols and yellow
  selection accents. Dark appearance is intentional even with a light system
  appearance; semantic native labels and backgrounds remain the source of truth.
- Before import, show the photo import action and keep the adjustment surface
  absent. After import, keep the photograph available, the selected tool in view
  and the parameter surface independently scrollable.
- Compose beside the photo when window width is at least 600 pt, wider than its
  height and below accessibility text sizes. The side panel is bounded by 320 pt
  and 48% of the window width. Otherwise stack photo, tool strip and controls.
  Accessibility tools use a 44 pt glyph circle and complete body-style title;
  the stacked layout reserves up to 96 pt of photo space when available.
- Keep 44×44 pt action and drag targets. Ordinary tool circles start at 48 pt
  with Dynamic Type scaling. Scalar values fit by native font measurement;
  fallback to the glyph without losing the complete main value and unit.
- Preserve the fixed yellow ruler indicator, moving tape/default dot, legal grid
  and quarter-sensitivity Fine action. Local strokes rise from 13/22 to at most
  28 pt within 24 pt, then decay in 180 ms even while a paused finger stays down.
  Release settles only tape position over 120 ms. Focus fades in over 100 ms,
  uses phone/pad peripheral opacity 0.08/0.42, holds 160 ms and returns in 180 ms.
  New input interrupts the finish. Reduce Motion retains static values, arcs,
  ticks and defaults, with immediate release restoration.
- Numeric entry uses one native complete-value column with a protected local
  draft. Keep fixed 44 pt Cancel/Apply actions, title, complete temporary value
  and unit, and range. Changed drafts require explicit Cancel or Apply; closing
  returns accessibility focus to the original numeric button. Regular iPad
  popovers prefer 440 pt, or 600 with accessibility text, clamped to the current
  presenting window and safe area. iPhone explicitly uses a sheet, including
  landscape regular horizontal size class. iPad popovers adapt to a large sheet
  in compact presentation.
  Content wider than 480 pt and shorter than 400 pt puts context beside
  wheel/default; ordinary picker height
  is 200–220 pt, accessibility height 100–264 pt. Do not auto-scroll away context.
- Geometry and lens use staged preview settings with fixed Cancel/Apply. Apply
  commits, Cancel discards, and both return to Exposure. Dirty tool navigation
  asks Apply/Discard/Continue. Active drafts block export even when unchanged;
  single-photo import is guarded by changed drafts. Lens editing is RAW-only,
  and its export guard is source evidence without a raster UI coverage claim.
- Preserve film and master recipes as peer tools, individual/all resets,
  comparison, named HSL channels, existing effects, histogram state and local
  edit-save feedback. The master-recipe family is `square.stack.3d.up`.
- Preview feedback follows `previewRendering` / `previewResizePending` at the
  photo edge. Single JPEG and rendered DNG export support RAW and raster input;
  batch supports compatible RAW and raster photos, resolving camera-only settings for each target. Preserve size controls, destinations and actual output
  results without implying original-RAW or edit-history preservation by DNG.
- The app icon retains the desktop yellow/cyan dual-frame identity on a
  full-bleed opaque charcoal square. The operating system supplies the mask.

Native review evidence belongs in `.impeccable/review/ios-editor-v4/README.md`.
Required coverage includes iPhone/iPad portrait and landscape, narrow windows,
large Dynamic Type, the value wheel, drafts, looks, HSL and export. Screenshot
coverage does not establish hardware haptic feel, performance improvement or
RAW output correctness. No photo catalog is implied.
