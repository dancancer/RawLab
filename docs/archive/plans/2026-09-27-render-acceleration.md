# Render Acceleration Implementation Plan

**Goal:** Reduce RAW white-balance latency and accelerate supported image operations without changing color, highlight, preview/export, or failure contracts.

**Architecture:** Keep LibRaw's validated WB/demosaic/highlight path on CPU and retain unpacked RAW data across edits. Use Metal for the existing float pixel pipeline with an unchanged CPU fallback. During slider interaction publish a reduced preview and replace it with an exact preview when interaction ends; final export is never reduced-quality.

**Tech Stack:** C++17, LibRaw 0.21.5, Metal compute, SwiftUI/AppKit, native macOS test scripts.

## Tasks

- [x] RAW reuse: `raw_processor.cpp/.h`; preserve one LibRaw instance and unpacked data, re-identify only when identification-dependent WB mode changes, add explicit half-size interactive mode, compare reused and fresh renders including crop/orientation/highlights. FFI owns the processor lifetime and includes preview quality in its decoded-image cache key.
- [x] Metal image pipeline: new `gpu/photo_gpu.h`, `gpu/metal_photo.mm`, `tests/gpu_photo_tests.cpp`; process linear input through resize, matrices, exposure, neutral/F-Log2/LUT, strength, tone/detail, final resize. GPU uses the CPU formulas and preserves filter ordering. Auto failure leaves input untouched and falls back; Force failure remains visible.
- [x] Mac scheduling: `EditorModel.swift`, `AdjustmentRow.swift`, `AdjustmentDock.swift`, new scheduling tests; slider begin/end controls progressive quality, latest request wins without starving the preview, stopping always schedules exact quality, export stays disabled until exact work is complete.
- [x] Integration: FFI session settings/backend diagnostics; default Mac GPU Auto; accelerated histogram/mask calculation where supported; source/bundle/build checks and documentation. Histogram Auto prefers optimized CPU after measured Metal transfer overhead; Force Metal is implemented and tested.
- [x] Verify: compare CPU/Metal on synthetic and real RAW, all six existing core regressions, eight Mac RAW fixtures, progressive/full-resolution isolation, actual native UI and before/after benchmark using the same Sony sample and 2000-pixel output.

Evidence and remaining validation limits: `docs/verification-render-acceleration-2026-09-27.md`.

## Baseline

`DSC09067.ARW`, PROVIA, 2000-pixel preview. CPU cached neutral/film approximately 109/165 ms; existing LUT-only Metal approximately 113/142 ms. Kelvin edit neutral/film pair approximately 2.80-2.90 seconds CPU, 2.76-2.78 seconds LUT-only Metal. Temporary benchmark source: `/tmp/rawlab-render-benchmark.cpp`.

## Constraints

- Preserve current dirty checkout; do not commit, revert, or modify RAW originals.
- Preserve F-Gamut/F-Log2 input and current sRGB output, as-shot reset and pink-highlight regression.
- LibRaw is not represented as GPU-accelerated. Interactive approximation is identified in state and is never exported.
- CPU remains the reference and fallback. Tests using Force establish actual GPU execution rather than silently passing on CPU.
- No unrelated visual redesign or new third-party dependencies.
