---
version: 1
slug: "rawlabmac-sources-presentation-photocanvas-swift"
primary_target: "RawLabMac/Sources/Presentation/PhotoCanvas.swift"
related_targets: ["RawLabMac/Sources/Editor/View/EditorView.swift", "RawLab/RawLab/UI/Editor/ContentView+Panels.swift", "RawLab/RawLab/UI/Preview/ZoomablePhoto.swift", "Shared/Native/HDRCanvas.swift", "Shared/Native/HDRMonitoring.swift"]
---

# RawLab phone HDR editor extension

Mode: Operate. Scope: shared HDR presentation and the existing Mac/iOS photo workspace.
The approved phone HDR technical design owns mode, processing and export semantics.
Keep source photos, existing RAW/SDR behavior, geometry gestures and inactive edits.

## Direction contract

THESIS: Import a phone HDR original, adjust the photograph and inspect its HDR/SDR rendition in the existing editor.

OWN-WORLD: Inherit RawLab gray photo canvas, functional yellow selection, system typography, native menus, SF Symbols and current control sizes.

STORY: New HDR originals enter HDR editing; old records restore their saved mode. Relative WB, supported basic edits and geometry act on an immutable HDR/SDR source pair. Display choices never create edit history.

FIRST VIEWPORT: Retain the photo, bottom adjustments and histogram positions. Put automatic HDR, SDR compatibility and false-color monitoring in the existing photo processing settings: the Mac adjustment-bar popover and iOS More menu's processing sheet. The HDR histogram identifies reference white and current display capacity. Unsupported tools remain identifiable and disabled.

FORM: Code-led extension of the established native Operate surface. No visual-world replacement or concept selection applies; seed: none (unavailable). Preserve keyboard, VoiceOver, Dynamic Type and the photo's existing zoom/crop/comparison gestures.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
