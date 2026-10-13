# Fuji Pipeline and Mac Client Implementation Plan

> **For agentic workers:** Use test-first implementation and verify each completed task against the approved spec.

**Goal:** Correct cross-brand Fuji LUT processing and provide a local Mac verification app.
**Architecture:** One C++ pipeline behind the existing C ABI; a thin native Mac client. Tests exercise real LUT files and RAW samples.
**Tech Stack:** C++17, LibRaw, CMake/CTest, SwiftUI/AppKit and ImageIO.
**Spec:** ../specs/2026-09-27-fuji-macos-design.md

## Global Constraints

Preserve existing source images and iOS API layout. No automatic commits/pushes. macOS 14+. No server or new package-manager dependencies.

## Tasks

- [x] Add `lutools/tests/core_tests.cpp` and CTest wiring. Demonstrated failures for R-fast channel swap, non-unit domain, table range, F-Log2 super-whites, near-zero strength, Log-output rejection and PNG depth. Exact anchors: 18% -> 400/1023, 2 -> 0.641440.
- [x] Correct `lut_parser`, `lut_applicator` and GPU coordinate/buffer handling. Generic parsing is separate from photo LUT contract validation; real Metal/CPU parity passed.
- [x] Correct RAW float decoding and PNG writing. Actual ARW/DNG tests cover finite values, exposure linearity, 8/16-bit options, camera matrix direction and Sony active crop. Arbitrary rotated RAW fixtures were not available.
- [x] Unify rendering through the C API. Exposure/WB precede LUT; display endpoints are blended. CLI and Mac JPEG outputs compared byte-for-byte equal.
- [x] Implement and package RawLabMac. Smoke tests exercise both RAWs, film changes, original-size PNG/JPEG and missing-file errors. Native comparison UI was inspected; the user began interacting with that running build. It was left undisturbed, so final dark-theme/menu changes require reopening the updated bundle and were not re-inspected live.
- [x] Update scripts/contracts and run CTest, Metal parity, ASan/UBSan, Mac build and signing verification. See ../../verification-2026-09-27.md for results and limits.
