---
version: 1
slug: "rawlabmac-sources-presentation-photocanvas-swift"
primary_target: "RawLabMac/Sources/Presentation/PhotoCanvas.swift"
related_targets: ["RawLabMac/Sources/Editor/View/EditorView.swift", "RawLab/RawLab/UI/Editor/ContentView+Panels.swift", "RawLab/RawLab/UI/Preview/ZoomablePhoto.swift", "Shared/Native/HDRCanvas.swift", "Shared/Native/HDRMonitoring.swift", "RawLabAndroid/app/src/main/java/com/rawlab/android/editor/canvas/HDRMonitoring.kt", "RawLabAndroid/app/src/main/java/com/rawlab/android/editor/canvas/PhotoCanvas.kt", "RawLabWindows/MainWindow.HDR.cs", "RawLabWindows/Rendering/HDR/Surface.cs"]
---

# RawLab Cross-Platform HDR Editor Surface

Mode: Operate. Scope: four-client HDR editing, monitoring, and rendering (`macOS 15+` Metal EDR, `iOS` Metal EDR, `Android` API 34+ FP16/scRGB with SDR fallback, `Windows` D3D11 FP16 scRGB `HwndHost` with SDR fallback). Preserve source photos, SDR editing behavior, geometry drafts, and inactive mode edits.

## Direction contract

THESIS: Import phone gain-map HDR photos, linear Bayer/X-Trans Camera RAWs, or Apple ProRAW originals, adjust the photograph with full HDR semantics, monitor both HDR and SDR renditions, and export standards-compliant HDR or SDR deliverables across all four native clients.

OWN-WORLD: Inherit RawLab's `#1C1C1E` / `0.12` neutral photo canvas, functional yellow selection, native platform typography, monospaced/tabular numeric readouts, and native surface controls at standard OS text sizes for sighted photographers.

STORY: New phone gain-map HDR originals open in HDR editing while Camera RAW and ProRAW default to SDR and let the user opt into HDR editing after preflight; old records restore their saved mode. Full HDR toolsets (auto exposure, ±4 EV exposure, contrast, highlights/shadows, white/black points, `-8…+8 EV` luminance and RGB curves, relative WB, vibrance, saturation, 8-channel HSL + target sampling, 3-zone color grading, clarity, dehaze, vignette, grain, sharpening, image-level HDR denoise, desktop Bayer RAW AI denoise, geometry, HDR looks / recipes, and HDR peak limit + SDR-base controls) act non-destructively without polluting display-only monitoring choices into edit history.

FIRST VIEWPORT: Keep the photo unobstructed and central with zoom/pan/comparison preserved. Place HDR monitoring (`Auto HDR`, `SDR Compatible`, `False Color`, display headroom EV) and HDR controls inside each platform's existing structure:
- **macOS**: Right inspector 7th group (`HDR 输出与 SDR 底图`), `HDRLookControls` + `QuickPresetView` under Looks, 256-bin `log1p` EV histogram (`0 EV` solid white / headroom dashed yellow) at inspector top, and `320 pt` footer Processing Settings popover (`HDR 编辑`, `HDRMonitoringControls`, `HDRRenditionControls`, and Bayer `HDRCameraDevelopmentControls`).
- **Windows**: Right inspector 7th group (`HdrRendition`) and histogram, plus View menu (`HDR 编辑`, `自动 HDR`, `SDR 兼容预览`, `HDR 假色`) and dedicated HDR dialogs (`HDR 输出与 SDR 底图`, `HDR LUT…`, `HDR RAW…`).
- **iOS & Android**: Dedicated 7th `.hdrRendition` tool group inside the two-level tool dock, `HDRLookControls`, top-edge `HDRMonitoring` card + EV luminance histogram, and cancellable `HDR JPEG` / `HDR HEIF` (iOS) export progress banners.

FORM: Code-led native implementation across the four established Operate clients. No decorative overlays or low-vision AX/screen-reader redesigns apply; physical HDR peak brightness and display calibration remain hardware-verified outside simulator/headless runs.

FINISH: Checked against live client code, [PRODUCT.md](../../PRODUCT.md), and [DESIGN.md](../../DESIGN.md).
