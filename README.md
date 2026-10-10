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
- Built-in film looks with 0-200% strength, compatible CUBE/RLOOK imports and
  neutral-versus-edited comparison.
- Linear-light wavelet denoising with separate luma, chroma and coarse-chroma
  controls. macOS also provides vignette, grain and Metal-accelerated denoising.
- Per-photo local edit memory and resumable batch export with frozen settings,
  cancellation and failed-item retry, without modifying RAW files.
- Photo information overlays, zoom/pan and original-size or long-edge exports.
  Desktop file browsers can reveal photos and apply confirmed current settings.
- JPEG and 16-bit PNG export on Windows, macOS and Android; JPEG export on iOS.
  Readable capture metadata is retained, while output size and orientation are
  updated.
- Metal, Direct3D 11 and OpenGL ES processing where supported, with automatic CPU
  fallback. RAW decoding and file encoding remain CPU operations.
- A shared C++17 core, command-line tools and a desktop LUT preparation utility.

## Platforms

| Client | Requirements |
| --- | --- |
| Windows | Windows 10/11, x64 |
| macOS | macOS 15+, Apple Silicon or Intel |
| Android | Android 8.0+, ARM64 or x86_64 |
| iOS | iOS 18+, iPhone; the downloadable IPA requires re-signing |

## Downloads and Documentation

- [Download the latest release](https://github.com/dancancer/RawLab/releases/latest)
- [Installation and distribution notes](docs/installation.md)
- [Changelog](CHANGELOG.md)
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
(`GPL-3.0-only`). Third-party libraries, LUTs and other bundled assets retain their
own licenses and copyright notices. See [licensing and attribution](docs/licensing.md).
