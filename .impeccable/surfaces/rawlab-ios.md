# RawLab iOS Editor

Mode: Operate.

Target: `RawLab/RawLab/UI/ContentView.swift`.
Native SwiftUI, iPhone only. Preserve the shared RAW processing contract.

- Use a dark neutral photo canvas, system text styles, SF Symbols and yellow
  selection accents, consistent with the existing editor.
- Before import, show the photo import action without inactive editing tools.
- After import, show the tool strip and film/value editor below the photo in
  portrait. In landscape, place the same adjustment surface beside the photo
  to preserve preview height. Keep large accessibility text vertically stacked
  and the adjustment surface scrollable.
- Preserve film selection, individual/all resets, comparison, histogram state
  and photo-library export. Processing feedback must not obscure the image center.
- The app icon uses the desktop yellow/cyan dual-frame identity on a full-bleed
  opaque charcoal square. The operating system supplies the corner mask.

Verification uses iPhone Simulator screenshots and `RawLabUITests` for empty,
imported, film, adjustment, portrait, landscape, large-text and export states.
Dark appearance is intentional for the photo editor, including when the system
appearance is light. No iPad layout or photo catalog is implied.
