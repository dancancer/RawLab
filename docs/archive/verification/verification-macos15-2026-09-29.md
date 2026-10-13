# macOS 15 Architecture Builds

Built separate arm64 and x86_64 applications from `d28de10` plus the local
Mac build-script changes. Existing `build/RawLab Mac.app` was not replaced.

## Build

- `RawLabMac/build-dependencies.sh` downloads checksum-pinned source archives
  and builds LibRaw 0.21.5, libjpeg-turbo 3.1.3, JasPer 4.2.8, Little CMS 2.17,
  and LLVM OpenMP 21.1.8 separately for each architecture and macOS 15.0.
- LibRaw uses the upstream CMake build at `eb98e4325aef2ce85d2eb031c2ff18640ca616d3`.
  JPEG, JPEG2000, zlib/DNG deflate, LCMS and OpenMP are explicitly checked.
- Intel libjpeg uses its non-SIMD implementation because NASM is not installed;
  this affects JPEG decoding performance, not format support. arm64 uses NEON.
- The app/core deployment target is 15.0. Swift uses the installed 26.5 SDK;
  C/C++ dependencies use CLT's current SDK. A newer build SDK does not change
  the verified minimum-OS field in the resulting binaries.
- Dynamic dependencies are embedded, their references rewritten to `@rpath`,
  and the resulting apps ad-hoc signed. No notarization or release upload.

## Verification

- Red: the prior app fails the new macOS 15 minimum-version check.
- Negative architecture check rejects the arm64 app when x86_64 is requested.
- Both apps pass bundle dependency closure, strict code-signature, exact
  architecture and minimum-OS checks. All six binaries in each app have
  `LC_BUILD_VERSION minos 15.0` and the expected single architecture.
- Core CTest: arm64 8/8, x86_64 8/8. Includes color contracts, image statistics,
  GPU photo, Sony/DJI acceleration, Sony highlights, DNG WB, and DJI RAW.
- Both packaged executables pass `RawLabMac/tests/smoke.sh` with Sony
  `DSC06251.ARW` and DJI `DJI_20250602164503_0444_D.DNG`: preview/LUT changes,
  exposure-mode cache isolation, JPEG and 16-bit PNG export, and missing-file
  rejection. These are private local fixtures, not newly committed resources.
- Shell syntax checks and `git diff --check` pass.

Runtime checks used the current Apple Silicon host, with x86_64 under Rosetta.
Neither macOS 15 itself nor physical Intel/AMD GPU hardware was tested.
macOS 15 deployment compatibility is built and inspected, not a claim of a
completed macOS 15 hardware acceptance matrix.

## Artifacts

- `build/RawLab-Mac-macOS15-arm64.zip`
- `build/RawLab-Mac-macOS15-x86_64.zip`
- `build/macos15-arm64/RawLab Mac.app`
- `build/macos15-x86_64/RawLab Mac.app`
- Dependency, app build and smoke logs under `build/macos15*`.
- Core test logs under `lutools/build-macos15-{arm64,x86_64}/Testing/Temporary/`.

Reproduction commands are in `RawLabMac/README.md`. Original source archives
remain in `build/macos15-deps/sources/`; no Homebrew installations were replaced.
