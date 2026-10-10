# Product

<!-- impeccable:product-schema 1 -->

## Platform
adaptive

## Stack
Existing C++17/LibRaw core and SwiftUI iOS client. User approved a native SwiftUI/AppKit macOS client sharing the core.

## Users
Photographers and this repository's developer inspecting Fuji film LUT rendering on cross-brand RAW files.

## Product Purpose
Load a RAW, compare a neutral rendering with a selected film simulation, adjust input exposure/white balance, and export a reproducible result.

## Capabilities and Constraints
Local rendering and file management. Optional macOS AI color matching sends bounded, metadata-free sRGB previews to a user-configured HTTPS service only on explicit generation; API keys stay in Keychain and RAW originals are never uploaded or modified. Desktop verification, not a photo catalog. Numerical correctness and explicit color contracts precede visual polish. Do not claim Fuji in-camera JPEG equivalence or unmeasured camera calibration.

## Evidence on Hand
Bundled Sony ARW, user-provided DJI DNG and Fuji 33/65-grid LUTs. Review report under reviews/.

## Product Principles
- One rendering core across clients.
- Photos occupy the main workspace.
- Preserve input originals and report processing failures.
- Separate numerical validation from subjective style preference.
