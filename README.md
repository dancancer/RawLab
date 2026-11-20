# RawLab

[English](README.md) | [简体中文](docs/README.zh-CN.md)

Cross-brand RAW development and film looks, built around a shared C++ processing
core with native Windows, macOS, Android and iOS editors.

![RawLab Mac: neutral rendering and Velvia side by side](docs/images/rawlab-mac-velvia.png)

## Overview

RawLab develops camera RAW files, applies compatible Fujifilm film-simulation
LUTs and custom looks, and exports finished photographs without changing the
original files. It is an independent project, not an official Fujifilm product;
film looks do not promise an exact match to in-camera JPEGs.

## Features

- RAW development with exposure, camera-space white balance, tone, color and
  sharpening controls.
- Normal X3F rendering for supported Sigma DP1S, Merrill and Quattro files on
  all four clients, with a legacy mode for existing edits. This CPU renderer
  does not promise an exact Sigma Photo Pro match; see the
  [camera scope and limits](lutools/docs/x3f-rendering.md).
- Ordinary opaque SDR images: 8-bit JPEG/PNG and 16-bit integer RGB PNG on all
  four clients, 8/16-bit TIFF on macOS/iOS/Windows, and SDR HEIF on macOS/iOS,
  Windows and Android 9+. Raster input shares the editing/export core without
  the RAW scene curve or camera controls. Floating-point, other high-bit-depth,
  transparent and general multi-frame inputs are rejected rather than silently
  converted. See the
  [input contract](lutools/docs/color-contract.md#display-referred-raster-input).
- Phone gain-map HDR JPEG/HEIF on all four clients: independent HDR/SDR edits,
  automatic exposure, tone curves, HSL, color grading, detail, effects and
  geometry, plus an HDR peak limit and separate SDR-base adjustments. HDR CUBE
  looks, presets and selective synchronization carry supported settings.
  Export gain-map HDR JPEG or explicit SDR results; macOS/iOS also offer HDR
  HEIF where supported by the system. HDR source photos can use ordinary LUT
  previews after switching to SDR editing.
  HDR processing uses the CPU; HDR presentation requires a capable display and
  platform support. See the [release scope and limits](docs/releases/v0.10/v0.10.0.md).
- HDR editing for supported camera RAW and Apple ProRAW files on all four
  clients. RAW starts in SDR, with independent saved settings for the HDR mode.
  See [camera RAW support](docs/design/hdr-photos/camera-raw.md) and
  [ProRAW export limits](docs/design/hdr-photos/proraw.md).
- New RAW edits start with embedded-preview exposure matching. One-shot Auto
  exposure and an eight-channel HSL mixer are shared across all four clients;
  existing saved exposure baselines are preserved.
- Built-in film looks with 0-200% strength, compatible CUBE/RLOOK imports and
  neutral-versus-edited comparison.
- Fourteen master recipes with style artwork and matching controls across all
  clients, including tone endpoints, vibrance, curves, color grading and HSL.
  0-200% strength scales the current recipe controls, HSL and LUT together.
  Saved edits and frozen batches preserve manual changes and per-target RAW WB.
- Look categories, name search and a Recent list, with a separate import action.
  Apply a saved preset directly to the current photo, with cancellation and undo;
  adjustment transfers show which fields and values will change.
- Adaptive photo workspaces keep editing tools usable in narrow windows and
  mobile landscape. iOS adjustment ranges, steps and highlight direction match
  macOS without changing older saved rendering values.
- Linear-light wavelet denoising with separate luma, chroma and coarse-chroma
  controls, plus matching vignette and deterministic grain on all four clients.
  Metal, GLES 3.1 and D3D11 accelerate the shared denoising and effects kernels.
- Per-photo local edit memory and resumable batch export with frozen settings,
  cancellation and failed-item retry, without modifying RAW files.
  Collections automatically check targets and freeze each photo's settings;
  one final action starts export after choosing output settings.
- Photo information overlays, zoom/pan and original-size or long-edge exports.
  Desktop file browsers can reveal photos and apply confirmed current settings.
- JPEG and 16-bit PNG export on Windows, macOS and Android; JPEG export on iOS.
  Rendered DNG file export is available in single and batch workflows on all four
  clients. It bakes the current adjustments, not reversible sensor RAW controls.
  See the [rendered DNG contract and limits](lutools/docs/color-contract.md#rendered-dng).
  Readable capture metadata is retained, while output size and orientation are
  updated.
- Metal, Direct3D 11 and OpenGL ES processing where supported, with automatic CPU
  fallback. HSL runs in the platform photo GPU pipeline; RAW decoding and file
  encoding remain CPU operations.
- GPU-only AI denoising on Apple Silicon macOS and Windows. Windows provides
  automatic or explicit GPU selection and local diagnostic export. Intel Mac,
  iOS and Android packages do not include AI denoising. Bundled AI models have
  separate noncommercial licenses; see [licensing](docs/reference/licensing.md).
- A shared C++17 core, command-line tools and a desktop LUT preparation utility.
- Desktop Agent and MCP recipes support RAW, ordinary images and HDR sources,
  including camera RAW and ProRAW HDR, with capability discovery, SDR previews
  and final exports through the same processing core as the GUI and frozen batches.
- System Open With, document-open and file-drop entry points where supported;
  Android also accepts photo shares, and Windows forwards new file opens to the
  running app. Multiple photos open as a collection.
- Crop, rotate, straighten, flip and perspective correction; photos open with
  one preview and optional before/after comparison.

## Platforms

| Client | Requirements |
| --- | --- |
| Windows | Windows 10/11, x64 |
| macOS | macOS 14 deployment target, Apple Silicon or Intel; physical minimum-OS coverage remains limited |
| Android | Android 8.0+, ARM64 or x86_64 |
| iOS | iOS 18+, iPhone and iPad; the downloadable IPA requires re-signing |

HDR editing requires macOS 15+ on Mac. Android HDR presentation requires API 34+
and suitable display/window support; Windows uses FP16/scRGB when available.
Supported HDR photos remain editable with an SDR presentation on other displays.
See the [0.10.0 compatibility notes](docs/releases/v0.10/v0.10.0.md#compatibility-and-known-limits)
for X3F, AI, update and device-coverage limits.

## Downloads and Documentation

- [Documentation index](docs/README.md)
- [Download the latest release](https://github.com/dancancer/RawLab/releases/latest)
- [v0.10.0 release notes (build 19)](docs/releases/v0.10/v0.10.0.md)
- [Installation and distribution notes](docs/guides/installation.md)
- [iPhone installation guide](docs/guides/ios-installation.md)
- [Changelog](CHANGELOG.md)
- [Product roadmap (Chinese)](docs/architecture/roadmap.md)
- [Windows client](RawLabWindows/README.md)
- [macOS client](RawLabMac/README.md)
- [Android client](RawLabAndroid/README.md)
- [iOS core build and integration](lutools/platform/ios/README.md)
- [Processing core and CLI](lutools/README.md)
- [LUT preparation](lutools/docs/lut-preparation.md)
- [RAW and color-processing contract](lutools/docs/color-contract.md)

## License

Copyright (c) 2026 RawLab contributors. This release's original project code is
distributed under the [GNU General Public License v3.0 only](LICENSE)
(`GPL-3.0-only`), with a narrow [Alibaba Cloud RUM SDK linking exception](LICENSE-ALIYUN-RUM-EXCEPTION)
under GPLv3 section 7. Third-party libraries, LUTs and other bundled assets retain
their own licenses and copyright notices. See [licensing and attribution](docs/reference/licensing.md).
