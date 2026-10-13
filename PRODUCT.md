# Product

<!-- impeccable:product-schema 1 -->

## Platform
adaptive

## Stack
Shared C++17/LibRaw processing core with native SwiftUI/AppKit macOS, SwiftUI iOS, Kotlin/Compose Android and C#/WPF Windows clients.

## Users
Photographers and this repository's developer inspecting Fuji film LUT rendering on cross-brand RAW files.

## Product Purpose
Load a RAW, compare a neutral rendering with a selected film simulation, adjust input exposure/white balance, and export a reproducible result.

## Capabilities and Constraints
Local files only. Preserve RAW originals. Desktop verification, not a photo catalog. Numerical correctness and explicit color contracts precede visual polish. Do not claim Fuji in-camera JPEG equivalence or unmeasured camera calibration.

## Evidence on Hand
The repository includes a DJI DNG, synthetic JPEG XL DNG regression fixtures, and bundled film/master-recipe LUTs. Other camera RAWs are external test inputs. Current acceptance and historical records are linked from [the documentation index](docs/README.md).

## Product Principles
- One rendering core across clients.
- Photos occupy the main workspace.
- Preserve input originals and report processing failures.
- Separate numerical validation from subjective style preference.
