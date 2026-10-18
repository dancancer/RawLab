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
- Ordinary opaque RGB8 SDR images: JPEG/PNG
  on all four clients, TIFF on macOS/iOS/Windows and HEIF on macOS/iOS. Raster
  input shares the editing/export core without the RAW scene curve or camera
  controls. Unsupported HDR, high-bit-depth, transparent and multi-frame inputs
  are rejected rather than silently converted. See the
  [input contract](lutools/docs/color-contract.md#display-referred-raster-input).
- New RAW edits start with embedded-preview exposure matching. One-shot Auto
  exposure and an eight-channel HSL mixer are shared across all four clients;
  existing saved exposure baselines are preserved.
- Built-in film looks with 0-200% strength, compatible CUBE/RLOOK imports and
  neutral-versus-edited comparison.
- Fourteen master recipes with style artwork and matching controls across all
  clients. Applying a recipe replaces six adjustments and all 24 HSL values;
  0-200% strength scales the current recipe controls, HSL and LUT together.
  Saved edits and frozen batches preserve manual changes and per-target RAW WB.
- Drag-only mobile film/recipe lists and desktop overflow buttons, plus adaptive
  iPad portrait/landscape layouts. iOS adjustment ranges, steps and highlight
  direction match macOS without changing older saved rendering values.
- Linear-light wavelet denoising with separate luma, chroma and coarse-chroma
  controls, plus matching vignette and deterministic grain on all four clients.
  Metal, GLES 3.1 and D3D11 accelerate the shared denoising and effects kernels.
- Per-photo local edit memory and resumable batch export with frozen settings,
  cancellation and failed-item retry, without modifying RAW files.
- Photo information overlays, zoom/pan and original-size or long-edge exports.
  Desktop file browsers can reveal photos and apply confirmed current settings.
- JPEG and 16-bit PNG export on Windows, macOS and Android; JPEG export on iOS.
  Rendered DNG file export is available in single and batch workflows on all four
  clients. It bakes the current adjustments, not reversible sensor RAW controls.
  See [verification and platform limits](docs/verification-rendered-dng-export.md).
  Readable capture metadata is retained, while output size and orientation are
  updated.
- Metal, Direct3D 11 and OpenGL ES processing where supported, with automatic CPU
  fallback. HSL runs in the platform photo GPU pipeline; RAW decoding and file
  encoding remain CPU operations.
- A shared C++17 core, command-line tools and a desktop LUT preparation utility.
- Desktop Agent JSON editing, capability discovery, previews and FINAL exports
  reuse the same parameters and processing core as the GUI and frozen batches.
- Crop, rotate, straighten, flip and perspective correction; photos open with
  one preview and optional before/after comparison.

## Platforms

| Client | Requirements |
| --- | --- |
| Windows | Windows 10/11, x64 |
| macOS | macOS 14 deployment target, Apple Silicon or Intel; physical minimum-OS coverage remains limited |
| Android | Android 8.0+, ARM64 or x86_64 |
| iOS | iOS 18+, iPhone and iPad; the downloadable IPA requires re-signing |

## Downloads and Documentation

- [Documentation index](docs/README.md)
- [Download the latest release](https://github.com/dancancer/RawLab/releases/latest)
- [v0.8.1 release notes (build 13)](docs/releases/v0.8.1.md)
- [Installation and distribution notes](docs/installation.md)
- [iPhone installation guide](docs/ios-installation.md)
- [Changelog](CHANGELOG.md)
- [Product roadmap (Chinese)](docs/roadmap.md)
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
their own licenses and copyright notices. See [licensing and attribution](docs/licensing.md).
